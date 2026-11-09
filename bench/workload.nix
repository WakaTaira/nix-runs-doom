# Benchmark workload: executes exactly `steps` instructions of a non-terminating
# loop that mixes loads, stores, branches and ALU ops, and returns the count.
{
  steps ? 100000,
  workload ? "memloop",
}:
let
  root = import ../default.nix;
  inherit (root.lib) cpu mem asm;

  # Infinite loop: a[i & 1023] += i forever (every iteration stores, so the tree is updated).
  memloopCode = [
    (asm.lui 5 65536) # 0: x5 = 0x10000 (array base)
    (asm.addi 6 0 0) # 4: i = 0
    (asm.andi 7 6 1023) # 8: j = i & 1023
    (asm.slli 7 7 2) # 12
    (asm.add 7 7 5) # 16: p = base + j*4
    (asm.lw 8 7 0) # 20
    (asm.add 8 8 6) # 24
    (asm.sw 7 8 0) # 28
    (asm.addi 6 6 1) # 32
    (asm.jal 0 (-28)) # 36: back to 8
  ];
  memloopState = cpu.mkState {
    mem = builtins.foldl' (m: i: mem.storeWord m (i * 4) (builtins.elemAt memloopCode i)) mem.empty (
      builtins.genList (i: i) (builtins.length memloopCode)
    );
  };

  final =
    if workload == "memloop" then
      cpu.run {
        maxSteps = steps;
        chunk = 4096;
      } memloopState
    else
      throw "unknown workload ${workload}";
in
{
  instructions = final.count;
  # Depend on the result to force evaluation to completion.
  checksum = mem.loadWord final.mem 65536;
}
