# Execution-strategy spike (M0): the three variants of the same workload and the
# report that compares their cost per frame.
#
#   rv   option 1: clang-compiled RV32IM code run on the emulator
#   rvx  option 1 with the custom instruction `fixmul`
#   nix  option 3: the C translated into Nix functions
#   cc   the same C compiled to Nix by the Nix C compiler (cc/); `ccReport` compares it with nix
#   draw the workload in the shape Doom uses (file-scope variables, argument-less draw
#        functions, early return, wrapped signed arithmetic) compiled by cc/;
#        `drawReport` compares it with nix
#
# Measurement: every variant runs the full load (columns=160, spans=200,
# muls=10000) for 1 and for 2 frames, three times each. Nix records its own CPU
# time (a clock is not observable inside an evaluation), and the report reads it
# back. The cost of one frame is min(cpuTime of 2 frames) - min(cpuTime of 1
# frame), which cancels the fixed cost of an evaluation.
#
#   mkdir -p /tmp/spike && for v in rv rvx nix; do for k in 1 2; do for r in 1 2 3; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
#   SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.report
#
# The cc gate (cc/nix <= 1.25) needs only the nix and cc variants:
#
#   mkdir -p /tmp/spike && for v in nix cc; do for k in 1 2; do for r in 1 2 3; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
#   SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.ccReport
#
# The draw gate (draw/nix <= 1.25, the same bound as the cc gate) needs the nix and draw
# variants.
#
#   mkdir -p /tmp/spike && for v in nix draw; do for k in 1 2; do for r in 1 2 3; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
#   SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.drawReport
let
  D = import ./data.nix;
  cc = import ../../cc;
  spikeSrc = cc.examples.spike.src;
  drawSrc = cc.examples.draw.src;
  inherit (builtins)
    concatStringsSep
    foldl'
    getEnv
    head
    map
    readFile
    fromJSON
    toString
    ;

  variants = {
    rv = import ./rv.nix { };
    rvx = import ./rvx.nix;
    nix = import ./nix.nix;
    # The same C compiled by the Nix C compiler (cc/).
    cc = {
      run = mem: (cc.load spikeSrc).unit mem D.PARAMS;
    };
    # The draw input: the file-scope variables are initialized before the call.
    draw = {
      run =
        mem:
        let
          f = cc.load drawSrc;
        in
        f.unit (f.__data.init mem) D.PARAMS;
    };
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

  inherit (import ../format.nix) fixed;

  # Option 3 (a C-to-Nix compiler) wins when the custom-instruction RISC-V variant
  # is at least twice as slow; otherwise option 1 (compile to RISC-V) stays.
  verdict = rvxOverNix: if rvxOverNix >= 2.0 then "VERDICT: option 3" else "VERDICT: option 1";

  # Report line of variant name; `costs` holds the cost of one frame in seconds per variant.
  row =
    costs: name:
    let
      c = costs.${name};
    in
    "  ${name}: ${fixed 0 (c * 1000000)} us/frame, ${fixed 3 (c * 1000000 / pixels)} us/pixel";

  # `costs` holds the cost of one frame in seconds per variant: { rv; rvx; nix; }.
  mkReport =
    { costs }:
    let
      row' = row costs;
      ratio = a: b: fixed 2 (costs.${a} / costs.${b});
    in
    concatStringsSep "\n" [
      "== Cost per frame =="
      (row' "rv")
      (row' "rvx")
      (row' "nix")
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

  # A variant passes when it is at most `limit` times as slow as the hand-written Nix.
  gate =
    label: limit: ratio:
    if ratio <= limit then "${label} GATE: pass" else "${label} GATE: fail";

  ccGate = gate "CC" 1.25;
  drawGate = gate "DRAW" 1.25;

  # Report of the variant `name` against the hand-written Nix; `costs` holds { nix; <name>; }
  # in seconds per frame.
  mkGateReport =
    name: gateFn:
    { costs }:
    concatStringsSep "\n" [
      "== Cost per frame =="
      (row costs "nix")
      (row costs name)
      ""
      "  ${name}/nix : ${fixed 2 (costs.${name} / costs.nix)}"
      ""
      (gateFn (costs.${name} / costs.nix))
      ""
    ];

  mkCcReport = mkGateReport "cc" ccGate;
  mkDrawReport = mkGateReport "draw" drawGate;

  missingStats = throw "set SPIKE_STATS_DIR to the directory of <variant>-n<k>-<r>.json stats files (see bench/spike/default.nix)";
in
{
  rv = entry variants.rv;
  rvx = entry variants.rvx;
  nix = entry variants.nix;
  cc = entry variants.cc;
  draw = entry variants.draw;

  inherit
    verdict
    mkReport
    ccGate
    mkCcReport
    drawGate
    mkDrawReport
    ;

  report =
    if statsDir == "" then
      missingStats
    else
      mkReport {
        costs = {
          rv = measuredCost "rv";
          rvx = measuredCost "rvx";
          nix = measuredCost "nix";
        };
      };

  ccReport =
    if statsDir == "" then
      missingStats
    else
      mkCcReport {
        costs = {
          nix = measuredCost "nix";
          cc = measuredCost "cc";
        };
      };

  drawReport =
    if statsDir == "" then
      missingStats
    else
      mkDrawReport {
        costs = {
          nix = measuredCost "nix";
          draw = measuredCost "draw";
        };
      };
}
