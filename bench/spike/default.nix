# Execution-strategy spike (M0): the three variants of the same workload and the
# report that compares their cost per frame.
#
#   rv   option 1: clang-compiled RV32IM code run on the emulator
#   rvx  option 1 with the custom instruction `fixmul`
#   nix  option 3: the C translated into Nix functions
#
# Measurement: every variant runs the full load (columns=160, spans=200,
# muls=10000) for 1 and for 2 frames, three times each. Nix records its own CPU
# time (a clock is not observable inside an evaluation), and the report reads it
# back. The cost of one frame is min(cpuTime of 2 frames) - min(cpuTime of 1
# frame), which cancels the fixed cost of an evaluation.
#
#   mkdir -p /tmp/spike && for v in rv rvx nix; do for k in 1 2; do for r in 1 2 3; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
#   SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.report
let
  D = import ./data.nix;
  inherit (builtins)
    concatStringsSep
    foldl'
    floor
    genList
    getEnv
    head
    length
    map
    readFile
    fromJSON
    stringLength
    toString
    div
    ;

  variants = {
    rv = import ./rv.nix { };
    rvx = import ./rvx.nix;
    nix = import ./nix.nix;
  };

  full = {
    columns = 160;
    spans = 200;
    muls = 10000;
  };

  # Run `frames` frames of the full load and evaluate to the result word.
  workload = v: frames: D.result (v.run (D.image (full // { inherit frames; })));

  entry = v: {
    n1 = workload v 1;
    n2 = workload v 2;
  };

  pixels = 64000;

  # --- Number formatting (fixed point, as in bench/report.nix) ---
  repeatStr = n: s: concatStringsSep "" (genList (_: s) n);
  fixed =
    digits: x:
    let
      scale = foldl' (a: _: a * 10) 1 (genList (i: i) digits);
      n = floor (x * scale + 0.5);
      frac = toString (n - div n scale * scale);
    in
    if digits == 0 then
      toString n
    else
      "${toString (div n scale)}.${repeatStr (digits - stringLength frac) "0"}${frac}";

  # Option 3 (a C-to-Nix compiler) wins when the custom-instruction RISC-V variant
  # is at least twice as slow; otherwise option 1 (compile to RISC-V) stays.
  verdict = rvxOverNix: if rvxOverNix >= 2.0 then "VERDICT: option 3" else "VERDICT: option 1";

  # `costs` holds the cost of one frame in seconds per variant: { rv; rvx; nix; }.
  mkReport =
    { costs }:
    let
      row =
        name:
        let
          c = costs.${name};
        in
        "  ${name}: ${fixed 0 (c * 1000000)} us/frame, ${fixed 3 (c * 1000000 / pixels)} us/pixel";
      ratio = a: b: fixed 2 (costs.${a} / costs.${b});
    in
    concatStringsSep "\n" [
      "== Cost per frame =="
      (row "rv")
      (row "rvx")
      (row "nix")
      ""
      "== Ratios =="
      "  rv/nix  : ${ratio "rv" "nix"}"
      "  rvx/nix : ${ratio "rvx" "nix"}"
      "  rv/rvx  : ${ratio "rv" "rvx"}"
      ""
      (verdict (costs.rvx / costs.nix))
      ""
    ];

  statsDir = getEnv "SPIKE_STATS_DIR";

  minimum = xs: foldl' (a: b: if b < a then b else a) (head xs) xs;

  cpuTime = path: (fromJSON (readFile path)).cpuTime;

  minTime =
    v: k:
    minimum (
      map (r: cpuTime "${statsDir}/${v}-n${toString k}-${toString r}.json") [
        1
        2
        3
      ]
    );

  measuredCost = v: minTime v 2 - minTime v 1;
in
{
  rv = entry variants.rv;
  rvx = entry variants.rvx;
  nix = entry variants.nix;

  inherit verdict mkReport;

  report =
    if statsDir == "" then
      throw "set SPIKE_STATS_DIR to the directory of <variant>-n<k>-<r>.json stats files (see bench/spike/default.nix)"
    else
      mkReport {
        costs = {
          rv = measuredCost "rv";
          rvx = measuredCost "rvx";
          nix = measuredCost "nix";
        };
      };
}
