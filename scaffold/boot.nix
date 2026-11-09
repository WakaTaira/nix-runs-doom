# Boot a clang-built doomgeneric ELF (hex text, see toolchain/doom.nix) on the
# emulator with the host-call libc (lib/libc.nix) and the platform layer
# (scaffold/platform.nix), and run it until it exits or has drawn `maxFrames` frames.
#
#   import ./boot.nix { hex; wadHex ? null; argv; maxFrames; maxSteps ? ...; profile ? false; }
#     -> final state of lib/cpu.nix
#
# The host-call world lives in `state.host.world`; the platform layer's frame records
# are `state.host.world.frames` (see scaffold/platform.nix). With `profile = true`,
# `state.profile` counts pc samples by "<pc>" (see runUntil in lib/cpu.nix); the
# function names come from `symbols` of lib/elf.nix.
#
# Memory layout: the PT_LOAD segments of the ELF; the heap from `_end` rounded up to
# 16 bytes; the stack below 0x08000000 holding the argv strings and the argv array.
# Only the executable segment that contains the entry point is the code region, so
# stores to data never leave the pre-decoded fast path.
{
  hex,
  wadHex ? null,
  argv,
  maxFrames,
  maxSteps ? 1000000000000,
  profile ? false,
}:
let
  A = import ../lib/ascii.nix;
  C = import ../lib/cpu.nix;
  E = import ../lib/elf.nix;
  H = import ../lib/hostcall.nix;
  L = import ../lib/libc.nix;
  M = import ../lib/mem.nix;
  inherit (builtins)
    bitAnd
    concatLists
    concatStringsSep
    div
    elemAt
    filter
    foldl'
    genList
    head
    length
    map
    stringLength
    substring
    ;

  stackTop = 134217728; # 0x08000000

  alignDown16 = x: x - bitAnd x 15;
  align16 = x: alignDown16 (x + 15);

  img = E.mkImage hex;
  elf = E.load hex;

  # --- Symbols by name (any type; lib/elf.nix `symbols` lists functions only) ---

  hexDigit = i: substring i 1 "0123456789abcdef";
  hexOf =
    s: concatStringsSep "" (map (b: hexDigit (div b 16) + hexDigit (bitAnd b 15)) (A.bytesOf s));

  sections =
    let
      shoff = img.u32 32;
      shentsize = img.u16 46;
    in
    genList (
      i:
      let
        base = shoff + i * shentsize;
      in
      {
        type = img.u32 (base + 4);
        offset = img.u32 (base + 16);
        size = img.u32 (base + 20);
        link = img.u32 (base + 24);
      }
    ) (img.u16 48);

  symtab =
    let
      tabs = filter (sh: sh.type == 2) sections;
    in
    if tabs == [ ] then throw "scaffold/boot.nix: the ELF has no symbol table" else head tabs;
  strtab = elemAt sections symtab.link;
  symCount = div symtab.size 16;

  # Address of the symbol `name`: its NUL-terminated name is compared as hex text.
  symbolAddr =
    name:
    let
      want = hexOf name + "00";
      n = stringLength want;
      at = i: symtab.offset + 16 * i;
      matches = i: substring (2 * (strtab.offset + img.u32 (at i))) n hex == want;
      go =
        i:
        if i >= symCount then
          throw "scaffold/boot.nix: symbol ${name} not found"
        else if matches i then
          img.u32 (at i + 4)
        else
          go (i + 1);
    in
    go 0;

  # --- Code region ---

  codeRegion =
    let
      inEntry = seg: elf.entry >= seg.base && elf.entry < seg.base + seg.size;
      segs = filter inEntry (E.execSegments hex);
    in
    if segs == [ ] then
      throw "scaffold/boot.nix: no executable segment contains the entry point"
    else
      head segs;

  # --- argv on the stack ---

  argBytes = map (a: A.bytesOf a ++ [ 0 ]) argv;
  allArgBytes = concatLists argBytes;
  argc = length argv;
  strBase = alignDown16 (stackTop - length allArgBytes);
  # Start address of each string: strBase plus the lengths of the strings before it.
  argAddrs =
    (foldl'
      (acc: bs: {
        next = acc.next + length bs;
        addrs = acc.addrs ++ [ acc.next ];
      })
      {
        next = strBase;
        addrs = [ ];
      }
      argBytes
    ).addrs;
  argvAddr = alignDown16 (strBase - 4 * (argc + 1));

  storeList =
    store: mem: base: step: xs:
    foldl' (m: i: store m (base + step * i) (elemAt xs i)) mem (genList (i: i) (length xs));

  memWithArgs = storeList M.storeWord (storeList M.storeByte elf.mem strBase 1
    allArgBytes
  ) argvAddr 4 (argAddrs ++ [ 0 ]);

  # --- Host calls ---

  platform = import ./platform.nix {
    screenBufferAddr = symbolAddr "DG_ScreenBuffer";
    colorsAddr = symbolAddr "colors";
  };

  libcWorld = L.mkWorld {
    mem = M.empty;
    heapBase = align16 (symbolAddr "_end");
    errnoAddr = symbolAddr "errno";
    wad =
      if wadHex == null then
        null
      else
        {
          hex = wadHex;
          size = div (stringLength wadHex) 2;
        };
  };

  host = {
    call = H.dispatch (L // platform.impls);
    world =
      removeAttrs libcWorld [
        "mem"
        "out"
      ]
      // platform.world;
  };

  s0 = C.mkState {
    mem = memWithArgs;
    pc = elf.entry;
    sp = argvAddr;
    code = codeRegion;
    inherit host;
  };
in
C.runUntil
  {
    inherit maxSteps profile;
    stop = s: s.host.world.frameCount >= maxFrames;
  }
  (
    s0
    // {
      regs = s0.regs // {
        "10" = argc;
        "11" = argvAddr;
      };
    }
  )
