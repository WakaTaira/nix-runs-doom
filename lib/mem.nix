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
  key = i: elemAt keyList i;

  # Split a word address into the keys for the 5 levels.
  k0 = w: key (bitAnd (div w 16777216) 63);
  k1 = w: key (bitAnd (div w 262144) 63);
  k2 = w: key (bitAnd (div w 4096) 63);
  k3 = w: key (bitAnd (div w 64) 63);
  k4 = w: key (bitAnd w 63);

  empty = { };

  loadWordAt =
    m: w: ((((m.${k0 w} or { }).${k1 w} or { }).${k2 w} or { }).${k3 w} or { }).${k4 w} or 0;

  # Rebuild the path from leaf to root. Each level is forced with seq to avoid thunk build-up.
  storeWordAt =
    m: w: v:
    let
      a0 = k0 w;
      a1 = k1 w;
      a2 = k2 w;
      a3 = k3 w;
      a4 = k4 w;
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      n2 = n1.${a2} or { };
      n3 = n2.${a3} or { };
      n3' = n3 // {
        ${a4} = v;
      };
      n2' = n2 // {
        ${a3} = n3';
      };
      n1' = n1 // {
        ${a2} = n2';
      };
      n0' = n0 // {
        ${a1} = n1';
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
