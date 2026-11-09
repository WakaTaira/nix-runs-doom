# Layout L4w: 4 levels of 12 + 6 + 6 + 6 bits over the 30-bit word address.
#   level 0: sparse 4096-ary root, bits 18..29 of w (one entry per touched 1 MiB)
#   level 1: 64-ary, bits 12..17 (16 KiB regions)
#   level 2: 64-ary, bits 6..11 (256 B regions)
#   level 3: 64-ary leaf, bits 0..5
# This is L5 with its two top levels merged. In L5 the root (64 MiB regions)
# usually holds a single entry, so it adds a node to every path while saving
# almost nothing; merging it removes that node, and the root stays small
# (a few entries for a working set of a few MiB) instead of growing with the
# number of touched pages as the flat page table of L3 does.
let
  inherit (builtins)
    bitAnd
    div
    seq
    genList
    elemAt
    toString
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
in
import ./bytes.nix { inherit empty loadWordAt storeWordAt; }
