# Layout L3: 3 levels over word addresses.
#   level 0: flat attribute set keyed by the 16 KiB page number, toString (w / 4096)
#   level 1: 64-ary, bits 6..11 of w
#   level 2: 64-ary leaf, bits 0..5 of w
# Only 3 nodes are on a path, but the flat page table is copied on every store,
# so the store cost grows with the number of touched 16 KiB pages.
let
  inherit (builtins)
    bitAnd
    div
    seq
    genList
    elemAt
    toString
    ;

  keyList = genList toString 64;

  # Index: the low 12 bits of w; value: the keys of its upper and lower 6 bits.
  pairList = genList (i: {
    hi = elemAt keyList (div i 64);
    lo = elemAt keyList (bitAnd i 63);
  }) 4096;

  empty = { };

  loadWordAt =
    m: w:
    let
      p = elemAt pairList (bitAnd w 4095);
    in
    ((m.${toString (div w 4096)} or { }).${p.hi} or { }).${p.lo} or 0;

  # Rebuild the path from leaf to root, forcing each level with seq.
  storeWordAt =
    m: w: v:
    let
      pk = toString (div w 4096);
      p = elemAt pairList (bitAnd w 4095);
      n0 = m.${pk} or { };
      n1 = n0.${p.hi} or { };
      n1' = n1 // {
        ${p.lo} = v;
      };
      n0' = n0 // {
        ${p.hi} = n1';
      };
    in
    seq v (seq n1' (seq n0' (m // { ${pk} = n0'; })));
in
import ./bytes.nix { inherit empty loadWordAt storeWordAt; }
