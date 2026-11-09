# ELF32 (RISC-V, little-endian) loader.
# Nix strings cannot contain NUL, so builtins.readFile cannot read binaries.
# The ELF is therefore passed as hex text (od -An -v -tx1 | tr -d ' \n').
# Header parsing and PT_LOAD segment placement are done entirely in Nix.
let
  B = import ./bits.nix;
  M = import ./mem.nix;
  inherit (builtins)
    substring
    stringLength
    genList
    foldl'
    listToAttrs
    elemAt
    div
    bitAnd
    filter
    ;

  hexDigit = i: substring i 1 "0123456789abcdef";
  byteTable = listToAttrs (
    genList (n: {
      name = hexDigit (div n 16) + hexDigit (bitAnd n 15);
      value = n;
    }) 256
  );

  # Accessors that read bytes out of the hex text.
  mkImage =
    hex:
    let
      size = div (stringLength hex) 2;
      u8 = off: if off < size then byteTable.${substring (2 * off) 2 hex} else 0;
      u16 = off: u8 off + 256 * u8 (off + 1);
      u32 = off: u16 off + 65536 * u16 (off + 2);
    in
    {
      inherit
        size
        u8
        u16
        u32
        ;
    };

  parseHeader =
    img:
    let
      magicOk = img.u8 0 == 127 && img.u8 1 == 69 && img.u8 2 == 76 && img.u8 3 == 70;
    in
    if !magicOk then
      throw "not an ELF file"
    else if img.u8 4 != 1 then
      throw "not ELFCLASS32"
    else if img.u8 5 != 1 then
      throw "not little endian"
    else if img.u16 18 != 243 then
      throw "e_machine is not RISC-V"
    else
      {
        entry = img.u32 24;
        phoff = img.u32 28;
        phentsize = img.u16 42;
        phnum = img.u16 44;
      };

  programHeaders =
    img: hdr:
    genList (
      i:
      let
        base = hdr.phoff + i * hdr.phentsize;
      in
      {
        type = img.u32 base;
        offset = img.u32 (base + 4);
        vaddr = img.u32 (base + 8);
        filesz = img.u32 (base + 16);
        memsz = img.u32 (base + 20);
      }
    ) hdr.phnum;

  # Write a segment's file contents into memory word by word.
  # The memsz - filesz region (.bss) is left unwritten: the sparse memory already reads as 0.
  loadSegment =
    img: mem: ph:
    let
      nbytes = ph.filesz;
      byteAt = i: if i < nbytes then img.u8 (ph.offset + i) else 0;
      startPad = bitAnd ph.vaddr 3;
      base = ph.vaddr - startPad;
      nwords = div (startPad + nbytes + 3) 4;
      # If the start is not word-aligned, merge with the existing word.
      wordAt =
        w:
        let
          rel = w * 4 - startPad;
          byteOrOld = k: if rel + k < 0 then M.loadByte mem (base + w * 4 + k) else byteAt (rel + k);
        in
        byteOrOld 0 + 256 * byteOrOld 1 + 65536 * byteOrOld 2 + 16777216 * byteOrOld 3;
    in
    foldl' (m: w: M.storeWord m (base + w * 4) (wordAt w)) mem (genList (i: i) nwords);

  load =
    hex:
    let
      img = mkImage hex;
      hdr = parseHeader img;
      loads = filter (ph: ph.type == 1) (programHeaders img hdr);
      mem = foldl' (loadSegment img) M.empty loads;
    in
    {
      inherit (hdr) entry;
      inherit mem;
      segments = loads;
    };
in
{
  inherit load mkImage;
}
