# Shared byte-addressed accessors for the benchmark memory layouts.
# Given a layout's word accessors, returns the full interface of lib/mem.nix.
# The definitions mirror lib/mem.nix exactly, so that the layouts differ only in
# their word-level trie and the comparison measures the trie alone.
{
  empty,
  loadWordAt,
  storeWordAt,
}:
let
  B = import ../../lib/bits.nix;
  inherit (builtins) bitAnd bitOr div;

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
