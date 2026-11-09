# Runs CPU tests on both execution paths of lib/cpu.nix: without a code region
# (every instruction is decoded from memory when it executes) and with a code
# region covering the loaded program (pre-decoded, linked ops).
let
  C = import ../lib/cpu.nix;
  inherit (builtins) mapAttrs map;

  # Fields of a final state on which both paths must agree.
  observe = s: {
    inherit (s)
      pc
      regs
      out
      halted
      exitCode
      count
      ;
  };

  mismatch = "the paths with and without a code region disagree";

  # Replace every observed field, so that any check derived from them fails.
  poison =
    s:
    s
    // {
      pc = mismatch;
      regs = mapAttrs (_: _: mismatch) s.regs;
      out = mismatch;
      halted = mismatch;
      exitCode = mismatch;
      count = mismatch;
    };

  # Run a program from pc with initial registers overridden by `regs` and return the
  # final state. On path "slow" no code region is declared. On path "fast" `code`
  # is declared as the code region and the run is compared with the slow path: if
  # they disagree on any observed field, the returned state has all of them poisoned.
  runOn =
    path:
    {
      mem,
      pc ? 0,
      regs ? { },
      code,
      maxSteps,
    }:
    let
      runWith =
        region:
        let
          s0 = C.mkState {
            inherit mem pc;
            code = region;
          };
        in
        C.run { inherit maxSteps; } (s0 // { regs = s0.regs // regs; });
      slow = runWith null;
      fast = runWith code;
    in
    if path == "slow" then
      slow
    else if observe slow == observe fast then
      fast
    else
      poison fast;
in
{
  inherit runOn;

  # `cases` maps a runner (runOn path) to a list of tests. The result holds the
  # slow-path tests under their own names, followed by the fast-path tests with
  # " [code region]" appended to their names.
  bothPaths =
    cases:
    cases (runOn "slow") ++ map (t: t // { name = "${t.name} [code region]"; }) (cases (runOn "fast"));
}
