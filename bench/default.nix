# Performance budget, measured nixboy-style: no scripts, just two evaluations.
#
#   export NIX_SHOW_STATS_PATH=/tmp/nix-doom-bench.json
#   NIX_SHOW_STATS=1 nix eval -f . bench.run     # run the workload, Nix writes its stats
#   nix eval --raw -f . bench.report             # turn those stats into the budget report
#
# A clock is not observable from inside an evaluation, so the first evaluation
# lets the Nix evaluator record its own CPU time, and the second reads it back.
let
  steps = 400000;
  statsPath = builtins.getEnv "NIX_SHOW_STATS_PATH";
in
{
  inherit steps;

  run = import ./workload.nix { inherit steps; };

  spike = import ./spike;

  report =
    if statsPath == "" then
      throw "set NIX_SHOW_STATS_PATH to the stats file written by `NIX_SHOW_STATS=1 nix eval -f . bench.run`"
    else
      (import ./report.nix {
        stats = builtins.fromJSON (builtins.readFile statsPath);
        inherit steps;
      }).text;
}
