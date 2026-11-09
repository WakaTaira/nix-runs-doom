# Performance budget report.
#
# Input: the Nix evaluator statistics (NIX_SHOW_STATS_PATH JSON) of one
# `bench.run` evaluation, plus the number of instructions it executed.
#
# Output:
#   - measured cost: CPU seconds per emulated instruction. The fixed cost of an
#     evaluation (startup, library setup) is about 0.02 s, under 1% of a
#     400k-instruction run, so it is not subtracted.
#   - the Doom budget: the emulation speed required for each target frame rate,
#     and how far the measured speed is from it
#
# The Doom workload size (instructions per frame) is not measured yet. Until it
# is, the budget is shown for a range of assumed sizes; set `doomInstrPerFrame`
# once a real measurement exists.
{
  stats,
  steps,
  doomInstrPerFrame ? null,
  assumedInstrPerFrame ? [
    1000000
    5000000
    20000000
  ],
  # Proposed comfort levels. Doom's game logic runs at 35 tics per second.
  targets ? [
    {
      name = "comfortable";
      fps = 35;
    }
    {
      name = "playable";
      fps = 10;
    }
    {
      name = "slideshow";
      fps = 1;
    }
  ],
}:
let
  inherit (builtins)
    map
    foldl'
    floor
    toString
    concatStringsSep
    stringLength
    genList
    div
    ;

  # --- Number formatting ---
  repeatStr = n: s: concatStringsSep "" (genList (_: s) n);
  padLeft = w: s: repeatStr (w - stringLength s) " " + s;
  padRight = w: s: s + repeatStr (w - stringLength s) " ";
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
  # Integers with thousands separators.
  grouped =
    n:
    let
      s = toString n;
      len = stringLength s;
      head = len - (div (len - 1) 3) * 3;
      groups = genList (i: builtins.substring (head + 3 * i) 3 s) (div (len - 1) 3);
    in
    concatStringsSep "," ([ (builtins.substring 0 head s) ] ++ groups);

  # --- Measurement ---
  seconds = stats.cpuTime;
  heapMiB = div stats.gc.heapSize 1048576;
  perInstr = seconds / steps;
  usPerInstr = perInstr * 1000000;
  instrPerSec = 1 / perInstr;

  # --- Budget ---
  budgetRow =
    ipf: t:
    let
      requiredUs = 1000000.0 / (t.fps * ipf);
    in
    {
      target = t.name;
      inherit (t) fps;
      instrPerFrame = ipf;
      requiredUsPerInstr = requiredUs;
      speedupNeeded = usPerInstr / requiredUs;
      # Frame time at the measured speed, excluding the per-eval fixed cost.
      secondsPerFrame = ipf * perInstr;
    };

  frameSizes = if doomInstrPerFrame == null then assumedInstrPerFrame else [ doomInstrPerFrame ];
  budget = builtins.concatMap (ipf: map (budgetRow ipf) targets) frameSizes;

  # --- Text report ---
  budgetLines = map (
    r:
    "  ${padLeft 12 (grouped r.instrPerFrame)}  ${padRight 12 r.target}${padLeft 4 (toString r.fps)} fps  ${padLeft 10 (fixed 4 r.requiredUsPerInstr)} us/instr  ${padLeft 10 (fixed 1 r.speedupNeeded)}x faster needed"
  ) budget;

  text = concatStringsSep "\n" (
    [
      "== Measured =="
    ]
    ++ [
      "  ${grouped steps} instructions in ${fixed 3 seconds} s CPU (GC heap ${toString heapMiB} MiB)"
      "  cost per instruction : ${fixed 3 usPerInstr} us  (${grouped (floor instrPerSec)} instr/s)"
      ""
      "== Doom budget =="
      (
        if doomInstrPerFrame == null then
          "  instructions per frame: NOT MEASURED YET (showing assumed sizes)"
        else
          "  instructions per frame: ${grouped doomInstrPerFrame} (measured)"
      )
      "  ${padLeft 12 "instr/frame"}  ${padRight 12 "target"}${padLeft 4 ""}       ${padLeft 10 "required"}"
    ]
    ++ budgetLines
    ++ [ "" ]
  );
in
{
  inherit
    seconds
    usPerInstr
    budget
    text
    ;
}
