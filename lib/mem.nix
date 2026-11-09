# Memory: persistent 64-ary trie addressed by 4-byte words.
# The 30-bit word address is split into 5 levels of 6 bits; each level is an attribute set.
# Unwritten regions are represented by missing children and read as 0 (sparse).
# An update copies only the 5 nodes on the path: O(log n) (fixed 5 levels, at most 64 entries copied per level).
let
  B = import ./bits.nix;
  inherit (builtins)
    bitAnd
    bitOr
    div
    seq
    genList
    elemAt
    toString
    ;

  keyList = genList toString 64;

  # A word address w is split into 5 keys of 6 bits each, from the top:
  # (w / 2^24) & 63, (w / 2^18) & 63, (w / 2^12) & 63, (w / 2^6) & 63 and w & 63.
  # The lower four keys are read in pairs from pairList (index: 12 address bits,
  # value: the keys of its upper and lower 6 bits), which keeps the arithmetic per
  # access small. The computations are written out inline to avoid function calls.
  pairList = genList (i: {
    hi = elemAt keyList (div i 64);
    lo = elemAt keyList (bitAnd i 63);
  }) 4096;

  empty = { };

  loadWordAt =
    m: w:
    let
      p12 = elemAt pairList (bitAnd (div w 4096) 4095);
      p34 = elemAt pairList (bitAnd w 4095);
    in
    ((((m.${elemAt keyList (bitAnd (div w 16777216) 63)} or { }).${p12.hi} or { }).${p12.lo} or { })
      .${p34.hi} or { }
    ).${p34.lo} or 0;

  # Rebuild the path from leaf to root. Each level is forced with seq to avoid thunk build-up.
  storeWordAt =
    m: w: v:
    let
      p12 = elemAt pairList (bitAnd (div w 4096) 4095);
      p34 = elemAt pairList (bitAnd w 4095);
      a0 = elemAt keyList (bitAnd (div w 16777216) 63);
      n0 = m.${a0} or { };
      n1 = n0.${p12.hi} or { };
      n2 = n1.${p12.lo} or { };
      n3 = n2.${p34.hi} or { };
      n3' = n3 // {
        ${p34.lo} = v;
      };
      n2' = n2 // {
        ${p34.hi} = n3';
      };
      n1' = n1 // {
        ${p12.lo} = n2';
      };
      n0' = n0 // {
        ${p12.hi} = n1';
      };
    in
    seq v (seq n3' (seq n2' (seq n1' (seq n0' (m // { ${a0} = n0'; })))));

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
