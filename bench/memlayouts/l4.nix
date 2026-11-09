# Layout L4: 4 levels of 8 + 8 + 8 + 6 bits over the 30-bit word address.
#   level 0: 256-ary, bits 22..29 of w (16 MiB regions)
#   level 1: 256-ary, bits 14..21 (64 KiB regions)
#   level 2: 256-ary, bits 6..13 (256 B regions)
#   level 3: 64-ary leaf, bits 0..5
# The two lower keys are read together from pairList (index: the low 14 bits of w).
let
  inherit (builtins)
    bitAnd
    div
    seq
    genList
    elemAt
    toString
    ;

  keyList = genList toString 256;

  pairList = genList (i: {
    hi = elemAt keyList (div i 64);
    lo = elemAt keyList (bitAnd i 63);
  }) 16384;

  empty = { };

  # w < 2^30, so w / 2^22 < 256 needs no mask.
  loadWordAt =
    m: w:
    let
      p = elemAt pairList (bitAnd w 16383);
    in
    (((m.${elemAt keyList (div w 4194304)} or { }).${elemAt keyList (bitAnd (div w 16384) 255)} or { })
      .${p.hi} or { }
    ).${p.lo} or 0;

  storeWordAt =
    m: w: v:
    let
      p = elemAt pairList (bitAnd w 16383);
      a0 = elemAt keyList (div w 4194304);
      a1 = elemAt keyList (bitAnd (div w 16384) 255);
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
