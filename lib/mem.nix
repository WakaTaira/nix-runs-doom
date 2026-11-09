# Memory: persistent trie over 4-byte words, 4 levels of 12 + 6 + 6 + 6 bits
# over the 30-bit word address.
#   level 0: sparse 4096-ary root, bits 18..29 of w (one entry per touched 1 MiB)
#   level 1: 64-ary, bits 12..17 (16 KiB regions)
#   level 2: 64-ary, bits 6..11 (256 B regions)
#   level 3: 64-ary leaf, bits 0..5
# Unwritten regions are represented by missing children and read as 0 (sparse).
# An update copies only the 4 nodes on the path. The root grows only with the
# number of touched MiB, so it stays small for working sets of a few MiB.
# See bench/memlayout.nix for the comparison against other layouts.
let
  inherit (builtins)
    bitAnd
    div
    seq
    genList
    elemAt
    toString
    bitOr
    ;

  rootKeys = genList toString 4096;
  keyList = genList toString 64;

  pairList = genList (i: {
    hi = elemAt keyList (div i 64);
    lo = elemAt keyList (bitAnd i 63);
  }) 4096;

  empty = { };

  # w < 2^30, so w / 2^18 < 4096 needs no mask.
  loadWordAt =
    m: w:
    let
      p = elemAt pairList (bitAnd w 4095);
    in
    (((m.${elemAt rootKeys (div w 262144)} or { }).${elemAt keyList (bitAnd (div w 4096) 63)} or { })
      .${p.hi} or { }
    ).${p.lo} or 0;

  storeWordAt =
    m: w: v:
    let
      p = elemAt pairList (bitAnd w 4095);
      a0 = elemAt rootKeys (div w 262144);
      a1 = elemAt keyList (bitAnd (div w 4096) 63);
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      n2 = n1.${p.hi} or { };
      n2' = n2 // {
        ${p.lo} = v;
      };
      n1' = n1 // {
        ${p.hi} = n2';
      };
      n0' = n0 // {
        ${a1} = n1';
      };
    in
    seq v (seq n2' (seq n1' (seq n0' (m // { ${a0} = n0'; }))));
  B = import ./bits.nix;

  # Byte-addressed accessors (little-endian).
  loadByte = m: a: bitAnd (div (loadWordAt m (div a 4)) (B.pow2 (8 * bitAnd a 3))) 255;

  loadHalf =
    m: a:
    if bitAnd a 3 != 3 then
      bitAnd (div (loadWordAt m (div a 4)) (B.pow2 (8 * bitAnd a 3))) 65535
    else
      loadByte m a + 256 * loadByte m (B.add a 1);

  loadWord =
    m: a:
    if bitAnd a 3 == 0 then loadWordAt m (div a 4) else loadHalf m a + 65536 * loadHalf m (B.add a 2);

  # Replace the field of width widthMask starting at bit `shift` with v.
  replaceField =
    old: shift: widthMask: v:
    bitOr (bitAnd old (B.mask32 - widthMask * B.pow2 shift)) (bitAnd v widthMask * B.pow2 shift);

  storeByte =
    m: a: v:
    let
      w = div a 4;
    in
    storeWordAt m w (replaceField (loadWordAt m w) (8 * bitAnd a 3) 255 v);

  storeHalf =
    m: a: v:
    if bitAnd a 3 != 3 then
      let
        w = div a 4;
      in
      storeWordAt m w (replaceField (loadWordAt m w) (8 * bitAnd a 3) 65535 v)
    else
      storeByte (storeByte m a v) (B.add a 1) (div v 256);

  storeWord =
    m: a: v:
    if bitAnd a 3 == 0 then
      storeWordAt m (div a 4) v
    else
      storeHalf (storeHalf m a v) (B.add a 2) (div v 65536);
in
{
  inherit
    empty
    loadWordAt
    storeWordAt
    loadByte
    loadHalf
    loadWord
    storeByte
    storeHalf
    storeWord
    ;
}
