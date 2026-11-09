# RV32IM CPU core: single-instruction interpreter (step) and execution loop (run).
# State is an attribute set { pc, regs, mem, out, halted, exitCode, count }.
# regs is an attribute set keyed by "0".."31"; mem is the persistent tree from lib/mem.nix.
let
  B = import ./bits.nix;
  M = import ./mem.nix;
  inherit (builtins)
    bitAnd
    bitOr
    bitXor
    div
    seq
    genList
    elemAt
    toString
    listToAttrs
    foldl'
    ;

  regKeyList = genList toString 32;
  rk = i: elemAt regKeyList i;

  inherit (import ./ascii.nix) chr;

  # Build an initial state.
  mkState =
    {
      mem ? M.empty,
      pc ? 0,
      sp ? 0,
    }:
    {
      inherit mem pc;
      regs = listToAttrs (
        genList (i: {
          name = rk i;
          value = if i == 2 then sp else 0;
        }) 32
      );
      out = "";
      halted = false;
      exitCode = null;
      count = 0;
    };

  getReg = s: i: s.regs.${rk i};

  setReg =
    regs: rd: v:
    if rd == 0 then regs else seq v (regs // { ${rk rd} = v; });

  # Build the next state strictly (prevents memory blow-up from chained lazy thunks).
  commit =
    s: pc: regs: mem: out: halted: exitCode:
    let
      count = s.count + 1;
    in
    seq pc (
      seq regs (
        seq mem (
          seq out (
            seq count {
              inherit
                pc
                regs
                mem
                out
                halted
                exitCode
                count
                ;
            }
          )
        )
      )
    );

  # Turn a byte range into a string for the write syscall.
  readString =
    mem: addr: len:
    foldl' (acc: i: acc + chr (M.loadByte mem (B.add addr i))) "" (genList (i: i) len);

  # ALU operation shared by OP and OP-IMM. isSubSra corresponds to funct7[5].
  alu =
    funct3: isSubSra: a: b:
    if funct3 == 0 then
      (if isSubSra then B.sub a b else B.add a b)
    else if funct3 == 1 then
      B.shl a (bitAnd b 31)
    else if funct3 == 2 then
      (if B.lt a b then 1 else 0)
    else if funct3 == 3 then
      (if a < b then 1 else 0)
    else if funct3 == 4 then
      bitXor a b
    else if funct3 == 5 then
      (if isSubSra then B.sra a (bitAnd b 31) else B.srl a (bitAnd b 31))
    else if funct3 == 6 then
      bitOr a b
    else
      bitAnd a b;

  # M extension (OP with funct7 = 1), selected by funct3.
  mext =
    funct3: a: b:
    if funct3 == 0 then
      B.mul a b
    else if funct3 == 1 then
      B.mulh a b
    else if funct3 == 2 then
      B.mulhsu a b
    else if funct3 == 3 then
      B.mulhu a b
    else if funct3 == 4 then
      B.divs a b
    else if funct3 == 5 then
      B.divu a b
    else if funct3 == 6 then
      B.rems a b
    else
      B.remu a b;

  branchTaken =
    funct3: a: b:
    if funct3 == 0 then
      a == b
    else if funct3 == 1 then
      a != b
    else if funct3 == 4 then
      B.lt a b
    else if funct3 == 5 then
      !(B.lt a b)
    else if funct3 == 6 then
      a < b
    else if funct3 == 7 then
      a >= b
    else
      throw "illegal branch funct3 ${toString funct3}";

  doLoad =
    mem: funct3: addr:
    if funct3 == 0 then
      B.sext (M.loadByte mem addr) 8
    else if funct3 == 1 then
      B.sext (M.loadHalf mem addr) 16
    else if funct3 == 2 then
      M.loadWord mem addr
    else if funct3 == 4 then
      M.loadByte mem addr
    else if funct3 == 5 then
      M.loadHalf mem addr
    else
      throw "illegal load funct3 ${toString funct3}";

  doStore =
    mem: funct3: addr: v:
    if funct3 == 0 then
      M.storeByte mem addr v
    else if funct3 == 1 then
      M.storeHalf mem addr v
    else if funct3 == 2 then
      M.storeWord mem addr v
    else
      throw "illegal store funct3 ${toString funct3}";

  # Minimal Linux-like syscalls: a7=64 write, a7=93 exit.
  doEcall =
    s: pcNext:
    let
      a0 = getReg s 10;
      a7 = getReg s 17;
    in
    if a7 == 64 then
      commit s pcNext (setReg s.regs 10 (getReg s 12)) s.mem (
        s.out + readString s.mem (getReg s 11) (getReg s 12)
      ) false null
    else if a7 == 93 then
      commit s s.pc s.regs s.mem s.out true a0
    else
      throw "unsupported syscall a7=${toString a7} at pc=${toString s.pc}";

  # Execute one instruction and return the next state.
  step =
    s:
    let
      pc = s.pc;
      inst = M.loadWord s.mem pc;
      opcode = bitAnd inst 127;
      rd = B.bits inst 7 5;
      funct3 = B.bits inst 12 3;
      rs1 = B.bits inst 15 5;
      rs2 = B.bits inst 20 5;
      funct7 = div inst 33554432;
      v1 = getReg s rs1;
      v2 = getReg s rs2;
      pcNext = B.add pc 4;

      immI = B.sext (div inst 1048576) 12;
      immS = B.sext (funct7 * 32 + rd) 12;
      immB = B.sext (
        B.bits inst 31 1 * 4096 + B.bits inst 7 1 * 2048 + B.bits inst 25 6 * 32 + B.bits inst 8 4 * 2
      ) 13;
      immU = bitAnd inst 4294963200;
      immJ = B.sext (
        B.bits inst 31 1 * 1048576
        + B.bits inst 12 8 * 4096
        + B.bits inst 20 1 * 2048
        + B.bits inst 21 10 * 2
      ) 21;

      writeRd = v: commit s pcNext (setReg s.regs rd v) s.mem s.out false null;
    in
    if opcode == 51 then
      # OP (funct7 = 1 selects the M extension)
      writeRd (if funct7 == 1 then mext funct3 v1 v2 else alu funct3 (funct7 == 32) v1 v2)
    else if opcode == 19 then
      # OP-IMM (shifts use funct7 to detect SRAI; everything else uses the sign-extended immediate)
      writeRd (
        if funct3 == 1 || funct3 == 5 then alu funct3 (funct7 == 32) v1 rs2 else alu funct3 false v1 immI
      )
    else if opcode == 3 then
      # LOAD
      writeRd (doLoad s.mem funct3 (B.add v1 immI))
    else if opcode == 35 then
      # STORE
      commit s pcNext s.regs (doStore s.mem funct3 (B.add v1 immS) v2) s.out false null
    else if opcode == 99 then
      # BRANCH
      commit s (if branchTaken funct3 v1 v2 then B.add pc immB else pcNext) s.regs s.mem s.out false null
    else if opcode == 111 then
      # JAL
      commit s (B.add pc immJ) (setReg s.regs rd pcNext) s.mem s.out false null
    else if opcode == 103 then
      # JALR (the target's least significant bit is cleared)
      commit s (bitAnd (B.add v1 immI) 4294967294) (setReg s.regs rd pcNext) s.mem s.out false null
    else if opcode == 55 then
      # LUI
      writeRd immU
    else if opcode == 23 then
      # AUIPC
      writeRd (B.add pc immU)
    else if opcode == 15 then
      # FENCE (no-op on a single hart)
      commit s pcNext s.regs s.mem s.out false null
    else if opcode == 115 then
      # SYSTEM: ECALL / EBREAK
      (
        if inst == 115 then
          doEcall s pcNext
        else if inst == 1048691 then
          commit s pc s.regs s.mem s.out true (-1)
        else
          throw "unsupported SYSTEM instruction ${toString inst} at pc=${toString pc}"
      )
    else
      throw "illegal instruction ${toString inst} at pc=${toString pc}";

  # Run `chunk` instructions at a time with foldl' until halted or maxSteps is reached.
  # Recursion depth is proportional to maxSteps / chunk, so keep chunk large.
  run =
    {
      maxSteps ? 100000000,
      chunk ? 8192,
    }:
    let
      ticks = genList (_: null) chunk;
      stepIfRunning = st: _: if st.halted then st else step st;
      go =
        s:
        let
          remaining = maxSteps - s.count;
          batch = if remaining < chunk then genList (_: null) remaining else ticks;
        in
        if s.halted || remaining <= 0 then s else go (foldl' stepIfRunning s batch);
    in
    go;

  # Run exactly n instructions (for benchmarking).
  runExactly = n: s: foldl' (st: _: if st.halted then st else step st) s (genList (_: null) n);
in
{
  inherit
    mkState
    step
    run
    runExactly
    getReg
    ;
}
