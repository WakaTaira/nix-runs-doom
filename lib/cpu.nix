# RV32IM CPU core: instruction decoder, single-instruction interpreter (step) and execution loop (run).
# State is an attribute set { pc, regs, mem, out, halted, exitCode, count, code, op }.
# regs is an attribute set keyed by "0".."31"; mem is the persistent tree from lib/mem.nix.
# code is the pre-decoded code region (see mkCode) and op the op to execute next (see fetchOp).
# Programs without a code region decode every instruction from memory when it executes.
let
  B = import ./bits.nix;
  M = import ./mem.nix;
  inherit (builtins)
    bitAnd
    bitOr
    bitXor
    div
    seq
    deepSeq
    genList
    elemAt
    toString
    listToAttrs
    foldl'
    ;

  mask32 = 4294967295;

  regKeyList = genList toString 32;
  rk = i: elemAt regKeyList i;

  inherit (import ./ascii.nix) chr;

  getReg = s: i: s.regs.${rk i};

  # --- Instruction fields ---
  fRd = inst: bitAnd (div inst 128) 31;
  fFunct3 = inst: bitAnd (div inst 4096) 7;
  fRs1 = inst: bitAnd (div inst 32768) 31;
  fRs2 = inst: bitAnd (div inst 1048576) 31;
  fFunct7 = inst: div inst 33554432;
  immI = inst: B.sext (div inst 1048576) 12;
  immS = inst: B.sext (fFunct7 inst * 32 + fRd inst) 12;
  immB =
    inst:
    B.sext (
      B.bits inst 31 1 * 4096 + B.bits inst 7 1 * 2048 + B.bits inst 25 6 * 32 + B.bits inst 8 4 * 2
    ) 13;
  immU = inst: bitAnd inst 4294963200;
  immJ =
    inst:
    B.sext (
      B.bits inst 31 1 * 1048576
      + B.bits inst 12 8 * 4096
      + B.bits inst 20 1 * 2048
      + B.bits inst 21 10 * 2
    ) 21;

  # --- Operation tables (selected once per decoded instruction) ---

  # ALU operation shared by OP and OP-IMM. isSubSra corresponds to funct7[5].
  aluFn =
    funct3: isSubSra:
    if funct3 == 0 then
      (if isSubSra then B.sub else B.add)
    else if funct3 == 1 then
      (a: b: B.shl a (bitAnd b 31))
    else if funct3 == 2 then
      (a: b: if B.lt a b then 1 else 0)
    else if funct3 == 3 then
      (a: b: if a < b then 1 else 0)
    else if funct3 == 4 then
      bitXor
    else if funct3 == 5 then
      (if isSubSra then (a: b: B.sra a (bitAnd b 31)) else (a: b: B.srl a (bitAnd b 31)))
    else if funct3 == 6 then
      bitOr
    else
      bitAnd;

  # M extension (OP with funct7 = 1), indexed by funct3.
  mextFns = [
    B.mul
    B.mulh
    B.mulhsu
    B.mulhu
    B.divs
    B.divu
    B.rems
    B.remu
  ];

  loadFn =
    funct3:
    if funct3 == 0 then
      (m: a: B.sext (M.loadByte m a) 8)
    else if funct3 == 1 then
      (m: a: B.sext (M.loadHalf m a) 16)
    else if funct3 == 2 then
      M.loadWord
    else if funct3 == 4 then
      M.loadByte
    else if funct3 == 5 then
      M.loadHalf
    else
      throw "illegal load funct3 ${toString funct3}";

  storeFn =
    funct3:
    if funct3 == 0 then
      M.storeByte
    else if funct3 == 1 then
      M.storeHalf
    else if funct3 == 2 then
      M.storeWord
    else
      throw "illegal store funct3 ${toString funct3}";

  # Little-endian byte lane divisors for a byte at address offset 0..3.
  laneDiv = [
    1
    256
    65536
    16777216
  ];

  # --- Code region ---
  # The words of a code region are read once from the memory given to mkState and
  # decoded lazily. Two op lists are kept:
  #   linked  - each op knows the op of its successor (straight-line code and direct
  #             branches/jumps inside the region), so no fetch is needed;
  #   checked - each op hands over to fetchOp, which looks the next op up by pc.
  # Execution starts with the linked list. The first store that may touch the
  # region switches the region to the checked list for the rest of the run and
  # lowers `fast` to the first word it touches (later stores can lower it further).
  # A fetch below `fast` uses the pre-decoded op directly; a fetch at or above it
  # reads the word from memory and reuses the pre-decoded op only if the word is
  # unchanged. Writes into the region (including self-modifying code) therefore
  # always execute the current memory contents.
  noCode = {
    base = 0;
    size = 0;
    fast = 0;
    words = [ ];
    ops = [ ];
    checked = [ ];
  };

  mkCode =
    mem:
    { base, size }:
    let
      n = div (size + 3) 4;
      bytes = 4 * n;
      words = genList (i: M.loadWordAt mem (div base 4 + i)) n;
      # Successor op for a target pc: the linked op inside the region, else a fetch.
      link =
        target:
        let
          off = target - base;
        in
        if off >= 0 && off < bytes && bitAnd off 3 == 0 then elemAt linked (div off 4) else fetchOp;
      linked = genList (i: decode link (base + 4 * i) (elemAt words i)) n;
      checked = genList (i: decode unlinked (base + 4 * i) (elemAt words i)) n;
    in
    if bitAnd base 3 != 0 then
      throw "code region base ${toString base} is not word-aligned"
    else if base + bytes > B.two32 then
      throw "code region exceeds the 32-bit address space"
    else
      {
        inherit base words checked;
        size = bytes;
        fast = bytes;
        ops = linked;
      };

  # Successor resolution for ops that must always fetch (checked list, code outside a region).
  unlinked = _: fetchOp;

  # A store of up to 4 bytes at address a may touch the region. Stores that may wrap
  # around the address space are treated as touching it, conservatively.
  touchesCode = c: a: (a < c.base + c.size && a + 3 >= c.base) || a > mask32 - 3;
  markStore =
    c: a:
    let
      off = a - c.base;
      low = if off < 0 || a > mask32 - 3 then 0 else off - bitAnd off 3;
    in
    if low < c.fast then
      c
      // {
        fast = low;
        ops = c.checked;
      }
    else
      c;

  # --- Ops: decoded instructions as functions state -> state ---
  # Register numbers, immediates, the next pc, branch targets and successor ops are
  # resolved at decode time; frequent instructions get dedicated ops with their
  # arithmetic inlined. `nxt` is the pc of the next instruction and `nop` its op.
  # Fields (pc, regs, mem) are left lazy; `strict` forces them periodically. Ops do not
  # touch `count`: the loop adds whole batches (see `batch`).
  opNop =
    nxt: nop: s:
    s
    // {
      pc = nxt;
      op = nop;
    };

  # rd = f(x[rs1], x[rs2]) (rd != 0)
  opRR =
    f: rd: rs1: rs2: nxt: nop:
    let
      k1 = rk rs1;
      k2 = rk rs2;
      kd = rk rd;
    in
    s:
    s
    // {
      pc = nxt;
      op = nop;
      regs = s.regs // {
        ${kd} = f s.regs.${k1} s.regs.${k2};
      };
    };

  # rd = f(x[rs1], imm) (rd != 0)
  opRI =
    f: rd: rs1: imm: nxt: nop:
    let
      k1 = rk rs1;
      kd = rk rd;
    in
    s:
    s
    // {
      pc = nxt;
      op = nop;
      regs = s.regs // {
        ${kd} = f s.regs.${k1} imm;
      };
    };

  # rd = v (a constant known at decode time)
  opConst =
    rd: v: nxt: nop:
    if rd == 0 then
      opNop nxt nop
    else
      let
        kd = rk rd;
      in
      s:
      s
      // {
        pc = nxt;
        op = nop;
        regs = s.regs // {
          ${kd} = v;
        };
      };

  # rd = load(x[rs1] + imm) (rd != 0). LW and LBU read the trie directly when aligned.
  opLoad =
    funct3: rd: rs1: imm: nxt: nop:
    let
      k1 = rk rs1;
      kd = rk rd;
      ld = loadFn funct3;
    in
    if funct3 == 2 then
      s:
      s
      // {
        pc = nxt;
        op = nop;
        regs = s.regs // {
          ${kd} =
            let
              a = bitAnd (s.regs.${k1} + imm) mask32;
            in
            if bitAnd a 3 == 0 then M.loadWordAt s.mem (div a 4) else M.loadWord s.mem a;
        };
      }
    else if funct3 == 4 then
      s:
      s
      // {
        pc = nxt;
        op = nop;
        regs = s.regs // {
          ${kd} =
            let
              a = bitAnd (s.regs.${k1} + imm) mask32;
            in
            bitAnd (div (M.loadWordAt s.mem (div a 4)) (elemAt laneDiv (bitAnd a 3))) 255;
        };
      }
    else
      s:
      s
      // {
        pc = nxt;
        op = nop;
        regs = s.regs // {
          ${kd} = ld s.mem (bitAnd (s.regs.${k1} + imm) mask32);
        };
      };

  # store(x[rs1] + imm, x[rs2]); SW writes the trie directly when aligned.
  # A store that may touch the code region continues through fetchOp.
  opStore =
    funct3: rs1: rs2: imm: nxt: nop:
    let
      k1 = rk rs1;
      k2 = rk rs2;
      st = storeFn funct3;
      isWord = funct3 == 2;
    in
    s:
    let
      a = bitAnd (s.regs.${k1} + imm) mask32;
      mem =
        if isWord && bitAnd a 3 == 0 then
          M.storeWordAt s.mem (div a 4) s.regs.${k2}
        else
          st s.mem a s.regs.${k2};
    in
    if touchesCode s.code a then
      s
      // {
        pc = nxt;
        op = fetchOp;
        inherit mem;
        code = markStore s.code a;
      }
    else
      s
      // {
        pc = nxt;
        op = nop;
        inherit mem;
      };

  # Signed comparisons flip the sign bit, which maps signed order onto unsigned order.
  # `target` / `top` are the taken pc and op.
  opBranch =
    funct3: rs1: rs2: target: top: nxt: nop:
    let
      k1 = rk rs1;
      k2 = rk rs2;
    in
    if funct3 == 0 then
      s:
      if s.regs.${k1} == s.regs.${k2} then
        s
        // {
          pc = target;
          op = top;
        }
      else
        s
        // {
          pc = nxt;
          op = nop;
        }
    else if funct3 == 1 then
      s:
      if s.regs.${k1} != s.regs.${k2} then
        s
        // {
          pc = target;
          op = top;
        }
      else
        s
        // {
          pc = nxt;
          op = nop;
        }
    else if funct3 == 4 then
      s:
      if bitXor s.regs.${k1} 2147483648 < bitXor s.regs.${k2} 2147483648 then
        s
        // {
          pc = target;
          op = top;
        }
      else
        s
        // {
          pc = nxt;
          op = nop;
        }
    else if funct3 == 5 then
      s:
      if bitXor s.regs.${k1} 2147483648 >= bitXor s.regs.${k2} 2147483648 then
        s
        // {
          pc = target;
          op = top;
        }
      else
        s
        // {
          pc = nxt;
          op = nop;
        }
    else if funct3 == 6 then
      s:
      if s.regs.${k1} < s.regs.${k2} then
        s
        // {
          pc = target;
          op = top;
        }
      else
        s
        // {
          pc = nxt;
          op = nop;
        }
    else if funct3 == 7 then
      s:
      if s.regs.${k1} >= s.regs.${k2} then
        s
        // {
          pc = target;
          op = top;
        }
      else
        s
        // {
          pc = nxt;
          op = nop;
        }
    else
      throw "illegal branch funct3 ${toString funct3}";

  # JAL: `target` / `top` are the jump target pc and op; rd receives nxt.
  opJal =
    rd: target: top: nxt:
    if rd == 0 then
      opNop target top
    else
      let
        kd = rk rd;
      in
      s:
      s
      // {
        pc = target;
        op = top;
        regs = s.regs // {
          ${kd} = nxt;
        };
      };

  # JALR: the target's least significant bit is cleared; rs1 is read before rd is
  # written. The target is dynamic, so the next op is fetched.
  opJalr =
    rd: rs1: imm: nxt:
    let
      k1 = rk rs1;
      kd = rk rd;
    in
    if rd == 0 then
      s:
      s
      // {
        pc = bitAnd (s.regs.${k1} + imm) 4294967294;
        op = fetchOp;
      }
    else
      s:
      s
      // {
        pc = bitAnd (s.regs.${k1} + imm) 4294967294;
        op = fetchOp;
        regs = s.regs // {
          ${kd} = nxt;
        };
      };

  # Turn a byte range into a string for the write syscall.
  readString =
    mem: addr: len:
    foldl' (acc: i: acc + chr (M.loadByte mem (B.add addr i))) "" (genList (i: i) len);

  # Minimal Linux-like syscalls: a7=64 write, a7=93 exit. The result is forced
  # completely because `out` is never forced by the periodic strict step.
  opEcall =
    nxt: nop: s:
    let
      r = s.regs;
      a7 = r."17";
    in
    if a7 == 64 then
      let
        out = s.out + readString s.mem r."11" r."12";
      in
      seq out (
        strict (
          s
          // {
            pc = nxt;
            op = nop;
            regs = r // {
              "10" = r."12";
            };
            inherit out;
          }
        )
      )
    else if a7 == 93 then
      strict (
        s
        // {
          op = idleOp;
          idle = 0;
          halted = true;
          exitCode = r."10";
        }
      )
    else
      throw "unsupported syscall a7=${toString a7} at pc=${toString s.pc}";

  opEbreak =
    s:
    strict (
      s
      // {
        op = idleOp;
        idle = 0;
        halted = true;
        exitCode = -1;
      }
    );

  # --- Decoder: one handler per major opcode, dispatched through a table ---
  # A handler takes `link` (target pc -> successor op), the pc and the instruction
  # word, and returns an op. Faults (illegal encodings) are raised when the op is
  # forced, which happens exactly when the instruction is about to execute.

  # OP (funct7 = 1 selects the M extension; funct7 = 32 selects SUB / SRA)
  decOp =
    link: pc: inst:
    let
      funct3 = fFunct3 inst;
      funct7 = fFunct7 inst;
      rd = fRd inst;
      k1 = rk (fRs1 inst);
      k2 = rk (fRs2 inst);
      kd = rk rd;
      nxt = B.add pc 4;
      nop = link nxt;
    in
    if rd == 0 then
      opNop nxt nop
    else if funct7 != 1 && funct3 == 0 then
      (
        if funct7 == 32 then
          s:
          s
          // {
            pc = nxt;
            op = nop;
            regs = s.regs // {
              ${kd} = bitAnd (s.regs.${k1} - s.regs.${k2}) mask32;
            };
          }
        else
          s:
          s
          // {
            pc = nxt;
            op = nop;
            regs = s.regs // {
              ${kd} = bitAnd (s.regs.${k1} + s.regs.${k2}) mask32;
            };
          }
      )
    else
      opRR (
        if funct7 == 1 then elemAt mextFns funct3 else aluFn funct3 (funct7 == 32)
      ) rd (fRs1 inst) (fRs2 inst) nxt nop;

  # OP-IMM (shifts use funct7 to detect SRAI and the rs2 field as the shift amount;
  # everything else uses the sign-extended immediate)
  decOpImm =
    link: pc: inst:
    let
      funct3 = fFunct3 inst;
      rd = fRd inst;
      rs1 = fRs1 inst;
      k1 = rk rs1;
      kd = rk rd;
      imm = immI inst;
      shamt = fRs2 inst;
      nxt = B.add pc 4;
      nop = link nxt;
    in
    if rd == 0 then
      opNop nxt nop
    else if funct3 == 0 then
      s:
      s
      // {
        pc = nxt;
        op = nop;
        regs = s.regs // {
          ${kd} = bitAnd (s.regs.${k1} + imm) mask32;
        };
      }
    else if funct3 == 7 then
      s:
      s
      // {
        pc = nxt;
        op = nop;
        regs = s.regs // {
          ${kd} = bitAnd s.regs.${k1} imm;
        };
      }
    else if funct3 == 1 then
      (
        let
          p = B.pow2 shamt;
        in
        s:
        s
        // {
          pc = nxt;
          op = nop;
          regs = s.regs // {
            ${kd} = bitAnd (s.regs.${k1} * p) mask32;
          };
        }
      )
    else if funct3 == 5 then
      opRI (aluFn 5 (fFunct7 inst == 32)) rd rs1 shamt nxt nop
    else
      opRI (aluFn funct3 false) rd rs1 imm nxt nop;

  # A load into x0 is a no-op (the value, and any illegal funct3, is never evaluated).
  decLoad =
    link: pc: inst:
    let
      rd = fRd inst;
      funct3 = fFunct3 inst;
      nxt = B.add pc 4;
    in
    if rd == 0 then
      opNop nxt (link nxt)
    else
      seq (loadFn funct3) (opLoad funct3 rd (fRs1 inst) (immI inst) nxt (link nxt));

  decStore =
    link: pc: inst:
    let
      funct3 = fFunct3 inst;
      nxt = B.add pc 4;
    in
    seq (storeFn funct3) (opStore funct3 (fRs1 inst) (fRs2 inst) (immS inst) nxt (link nxt));

  decBranch =
    link: pc: inst:
    let
      target = B.add pc (immB inst);
      nxt = B.add pc 4;
    in
    opBranch (fFunct3 inst) (fRs1 inst) (fRs2 inst) target (link target) nxt (link nxt);

  decJal =
    link: pc: inst:
    let
      target = B.add pc (immJ inst);
    in
    opJal (fRd inst) target (link target) (B.add pc 4);

  decJalr =
    link: pc: inst:
    opJalr (fRd inst) (fRs1 inst) (immI inst) (B.add pc 4);

  decLui =
    link: pc: inst:
    let
      nxt = B.add pc 4;
    in
    opConst (fRd inst) (immU inst) nxt (link nxt);

  decAuipc =
    link: pc: inst:
    let
      nxt = B.add pc 4;
    in
    opConst (fRd inst) (B.add pc (immU inst)) nxt (link nxt);

  # FENCE is a no-op on a single hart.
  decFence =
    link: pc: inst:
    let
      nxt = B.add pc 4;
    in
    opNop nxt (link nxt);

  # SYSTEM: ECALL / EBREAK
  decSystem =
    link: pc: inst:
    let
      nxt = B.add pc 4;
    in
    if inst == 115 then
      opEcall nxt (link nxt)
    else if inst == 1048691 then
      opEbreak
    else
      throw "unsupported SYSTEM instruction ${toString inst} at pc=${toString pc}";

  decIllegal =
    link: pc: inst:
    throw "illegal instruction ${toString inst} at pc=${toString pc}";

  decoders = genList (
    opcode:
    if opcode == 51 then
      decOp
    else if opcode == 19 then
      decOpImm
    else if opcode == 3 then
      decLoad
    else if opcode == 35 then
      decStore
    else if opcode == 99 then
      decBranch
    else if opcode == 111 then
      decJal
    else if opcode == 103 then
      decJalr
    else if opcode == 55 then
      decLui
    else if opcode == 23 then
      decAuipc
    else if opcode == 15 then
      decFence
    else if opcode == 115 then
      decSystem
    else
      decIllegal
  ) 128;

  # Decode the instruction word `inst` located at `pc` into an op.
  decode =
    link: pc: inst:
    (elemAt decoders (bitAnd inst 127)) link pc inst;

  # --- Fetch and execution ---

  # Op for the instruction at s.pc: the pre-decoded op inside the fast range of the
  # code region, otherwise the word read from memory (reusing the pre-decoded op
  # when the word inside the region is unchanged).
  fetch =
    s:
    let
      c = s.code;
      off = s.pc - c.base;
    in
    if off >= 0 && off < c.fast && bitAnd off 3 == 0 then
      elemAt c.ops (div off 4)
    else
      fetchSlow s c off;

  fetchSlow =
    s: c: off:
    let
      inst = M.loadWord s.mem s.pc;
      i = div off 4;
    in
    if off >= 0 && off < c.size && bitAnd off 3 == 0 && inst == elemAt c.words i then
      elemAt c.checked i
    else
      decode unlinked s.pc inst;

  # The op used whenever the successor is not known statically: fetch by pc, then execute.
  fetchOp = s: fetch s s;

  # The op of a halted machine: the loop keeps ticking until the end of its batch, but
  # only `idle` (the number of ticks since the halting instruction) changes. Halting
  # ops install it and reset `idle`, so the loop needs no per-step halted check.
  idleOp =
    s:
    let
      idle = s.idle + 1;
    in
    seq idle (s // { inherit idle; });

  # Force every field that ops leave lazy (out, halted and exitCode are forced by the
  # ops that set them; op is forced by the next step).
  strict = s: seq s.pc (deepSeq s.regs (seq s.mem (seq s.code s)));

  # Build an initial state. `code = { base; size; }` (byte address and length)
  # declares the code region; its words are taken from this `mem`, so a state whose
  # `mem` is replaced afterwards (rather than written by stores) needs a new mkState.
  mkState =
    {
      mem ? M.empty,
      pc ? 0,
      sp ? 0,
      code ? null,
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
      code = if code == null then noCode else mkCode mem code;
      op = fetchOp;
    };

  # Execute one instruction (even on a halted state) and return the next, fully forced state.
  step =
    s:
    let
      e = strict (fetch s s);
      count = s.count + 1;
    in
    seq count (e // { inherit count; });

  # Run up to n steps (stopping early if the machine halts). Ops leave fields lazy, so
  # the state is forced every `groupLen` steps: often enough to keep thunk chains
  # short, rarely enough to amortize the cost.
  groupLen = 64;
  nulls = n: genList (_: null) n;
  tick = st: _: st.op st;
  groupTicks = nulls groupLen;

  # Run the n ticks of `ticks` from st and add the executed instructions to count:
  # all n if the machine is still running, none if it was already halted, and the
  # ticks before `idle` started counting if it halted inside this batch.
  batch =
    n: ticks: st:
    let
      e = strict (foldl' tick st ticks);
      executed =
        if !e.halted then
          n
        else if st.halted then
          0
        else
          n - e.idle;
      count = st.count + executed;
    in
    seq count (e // { inherit count; });

  group = st: _: batch groupLen groupTicks st;
  runSteps =
    s: n:
    let
      q = div n groupLen;
      r = n - q * groupLen;
    in
    batch r (nulls r) (foldl' group s (nulls q));

  # Entry to the loop: the op is re-derived from pc, so states built or edited
  # outside this file (e.g. `s // { pc = ...; }`) are always executed correctly.
  enter = s: s // { op = if s.halted then idleOp else fetchOp; };

  # Run `chunk` instructions at a time until halted or maxSteps is reached.
  # Recursion depth is proportional to maxSteps / chunk, so keep chunk large.
  run =
    {
      maxSteps ? 100000000,
      chunk ? 8192,
    }:
    let
      go =
        s:
        let
          remaining = maxSteps - s.count;
        in
        if s.halted || remaining <= 0 then
          s
        else
          go (runSteps s (if remaining < chunk then remaining else chunk));
    in
    s: go (enter s);

  # Run exactly n instructions (fewer if the machine halts; for benchmarking).
  runExactly = n: s: runSteps (enter s) n;
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
