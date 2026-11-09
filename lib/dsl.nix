# A Nix eDSL for writing RV32I guest programs as Nix values.
#
# A program is a (nested) list of items. Each item knows its size in bytes and
# how to emit its bytes given the assembly context { pc, labels }. Assembly is
# two-pass: the first pass lays items out and records label addresses, the
# second emits bytes. Nix itself is the macro language: helpers such as
# `storeString` or `ifElse` are ordinary Nix functions returning item lists.
#
# Example:
#   with import ./dsl.nix;
#   assemble { base = 65536; } [
#     (li a0 1)
#     (label "loop")
#     (addi a0 a0 1)
#     (bne a0 a1 "loop")
#   ]
let
  A = import ./asm.nix;
  B = import ./bits.nix;
  Ascii = import ./ascii.nix;
  inherit (builtins)
    isList
    isString
    concatMap
    foldl'
    genList
    length
    elemAt
    bitAnd
    div
    throw
    ;

  flatten = x: if isList x then concatMap flatten x else [ x ];
  # Size of a block, needed by the structured control-flow combinators.
  # Position-dependent items (align) have no fixed size and are rejected here.
  sizeOf =
    items:
    foldl' (
      n: it: if it ? sizeAt then throw "align cannot be used inside when/ifElse/while" else n + it.size
    ) 0 (flatten items);

  # Little-endian bytes of a 32-bit word.
  wordBytes =
    w:
    let
      u = B.u32 w;
    in
    [
      (bitAnd u 255)
      (B.bits u 8 8)
      (B.bits u 16 8)
      (B.bits u 24 8)
    ];

  # --- Item constructors ---

  # A fixed instruction word.
  raw = w: {
    size = 4;
    emit = _: wordBytes w;
  };

  # An instruction whose encoding depends on the context (labels, pc).
  instr = f: {
    size = 4;
    emit = ctx: wordBytes (f ctx);
  };

  # Several context-dependent instruction words.
  instrs = n: f: {
    size = 4 * n;
    emit = ctx: concatMap wordBytes (f ctx);
  };

  label = name: {
    size = 0;
    defines = name;
    emit = _: [ ];
  };

  # Resolve a branch/jump target: a string is a label, an integer is a pc-relative offset.
  offsetTo =
    ctx: target:
    if isString target then
      (ctx.labels.${target} or (throw "undefined label ${target}")) - ctx.pc
    else
      target;

  addressOf = ctx: name: ctx.labels.${name} or (throw "undefined label ${name}");

  # Split a 32-bit value into the upper 20 bits and a sign-extended low 12 bits,
  # so that (hi + lo) reconstructs it with lui/auipc + addi.
  hiLo =
    v:
    let
      lo = B.toSigned (B.sext (bitAnd v 4095) 12);
    in
    {
      hi = B.u32 (v - lo);
      inherit lo;
    };

  # --- Registers (ABI names) ---
  regs = {
    zero = 0;
    ra = 1;
    sp = 2;
    gp = 3;
    tp = 4;
    t0 = 5;
    t1 = 6;
    t2 = 7;
    s0 = 8;
    s1 = 9;
    a0 = 10;
    a1 = 11;
    a2 = 12;
    a3 = 13;
    a4 = 14;
    a5 = 15;
    a6 = 16;
    a7 = 17;
    s2 = 18;
    s3 = 19;
    s4 = 20;
    s5 = 21;
    s6 = 22;
    s7 = 23;
    s8 = 24;
    s9 = 25;
    s10 = 26;
    s11 = 27;
    t3 = 28;
    t4 = 29;
    t5 = 30;
    t6 = 31;
  };

  # --- Base instructions as items ---
  rType =
    f: rd: rs1: rs2:
    raw (f rd rs1 rs2);
  iType =
    f: rd: rs1: imm:
    raw (f rd rs1 imm);
  sType =
    f: rs2: imm: rs1:
    raw (f rs1 rs2 imm);
  branch =
    f: rs1: rs2: target:
    instr (ctx: f rs1 rs2 (offsetTo ctx target));

  base = {
    add = rType A.add;
    sub = rType A.sub;
    sll = rType A.sll;
    slt = rType A.slt;
    sltu = rType A.sltu;
    xor = rType A.xor;
    srl = rType A.srl;
    sra = rType A.sra;
    or = rType A.or;
    and = rType A.and;

    addi = iType A.addi;
    slti = iType A.slti;
    sltiu = iType A.sltiu;
    xori = iType A.xori;
    ori = iType A.ori;
    andi = iType A.andi;
    slli = iType A.slli;
    srli = iType A.srli;
    srai = iType A.srai;

    # Loads take (rd, offset, base) like `lw rd, offset(base)`.
    lb =
      rd: imm: rs1:
      raw (A.lb rd rs1 imm);
    lh =
      rd: imm: rs1:
      raw (A.lh rd rs1 imm);
    lw =
      rd: imm: rs1:
      raw (A.lw rd rs1 imm);
    lbu =
      rd: imm: rs1:
      raw (A.lbu rd rs1 imm);
    lhu =
      rd: imm: rs1:
      raw (A.lhu rd rs1 imm);
    # Stores take (src, offset, base) like `sw src, offset(base)`.
    sb = sType A.sb;
    sh = sType A.sh;
    sw = sType A.sw;

    lui = rd: v: raw (A.lui rd v);
    auipc = rd: v: raw (A.auipc rd v);

    beq = branch A.beq;
    bne = branch A.bne;
    blt = branch A.blt;
    bge = branch A.bge;
    bltu = branch A.bltu;
    bgeu = branch A.bgeu;

    jal = rd: target: instr (ctx: A.jal rd (offsetTo ctx target));
    jalr =
      rd: rs1: imm:
      raw (A.jalr rd rs1 imm);

    ecall = raw A.ecall;
    ebreak = raw A.ebreak;
    fence = raw A.fence;
  };

  # --- Pseudo-instructions ---
  pseudo = with base; {
    nop = addi 0 0 0;
    mv = rd: rs: addi rd rs 0;
    not = rd: rs: xori rd rs (-1);
    neg = rd: rs: sub rd 0 rs;
    j = target: jal 0 target;
    call = target: jal 1 target;
    ret = jalr 0 1 0;
    beqz = rs: beq rs 0;
    bnez = rs: bne rs 0;

    # Load a 32-bit constant: one instruction if it fits in 12 bits, else two.
    li =
      rd: v:
      if v >= -2048 && v < 2048 then
        addi rd 0 v
      else
        let
          p = hiLo (B.u32 v);
        in
        [
          (lui rd p.hi)
          (addi rd rd p.lo)
        ];

    # Load the address of a label (pc-relative, always two instructions).
    la =
      rd: name:
      instrs 2 (
        ctx:
        let
          p = hiLo (B.u32 (addressOf ctx name - ctx.pc));
        in
        [
          (A.auipc rd p.hi)
          (A.addi rd rd p.lo)
        ]
      );
  };

  # --- Data directives ---
  data = {
    bytes = bs: {
      size = length bs;
      emit = _: bs;
    };
    string = s: data.bytes (Ascii.bytesOf s);
    word = w: {
      size = 4;
      emit = _: wordBytes w;
    };
    space = n: data.bytes (genList (_: 0) n);
    # Pad with zeros up to the next multiple of n bytes.
    align =
      n:
      let
        padding =
          pc:
          let
            r = pc - div pc n * n;
          in
          if r == 0 then 0 else n - r;
      in
      {
        sizeAt = padding;
        emit = ctx: genList (_: 0) (padding ctx.pc);
      };
  };

  # --- Structured control flow ---
  # A condition is a branch that is taken when the condition is FALSE, so the
  # combinators can skip over a body whose size is known from the item list.
  conds = {
    eq = a: b: { skip = A.bne a b; };
    ne = a: b: { skip = A.beq a b; };
    lt = a: b: { skip = A.bge a b; };
    ge = a: b: { skip = A.blt a b; };
    ltu = a: b: { skip = A.bgeu a b; };
    geu = a: b: { skip = A.bltu a b; };
  };

  control = {
    # Run body when cond holds.
    when = cond: body: [
      (raw (cond.skip (4 + sizeOf body)))
      body
    ];

    ifElse = cond: thenBody: elseBody: [
      (raw (cond.skip (4 + sizeOf thenBody + 4)))
      thenBody
      (raw (A.jal 0 (4 + sizeOf elseBody)))
      elseBody
    ];

    # Run body while cond holds (condition checked before each iteration).
    while = cond: body: [
      (raw (cond.skip (4 + sizeOf body + 4)))
      body
      (raw (A.jal 0 (-(4 + sizeOf body))))
    ];
  };

  # Two-pass assembly: lay out items, collect labels, then emit bytes.
  assemble =
    {
      base ? 65536,
      entry ? null,
    }:
    program:
    let
      items = flatten program;
      n = length items;
      itemAt = elemAt items;
      # pcs is self-referential; forcing it front to back with foldl' keeps the
      # evaluation depth constant instead of recursing through all predecessors.
      sizeAtPc = it: pc: if it ? sizeAt then it.sizeAt pc else it.size;
      pcs = genList (
        i: if i == 0 then base else elemAt pcs (i - 1) + sizeAtPc (itemAt (i - 1)) (elemAt pcs (i - 1))
      ) n;
      forcedPcs = builtins.seq (foldl' (_: k: builtins.seq (elemAt pcs k) null) null (
        genList (k: k) n
      )) pcs;
      pcAt = elemAt forcedPcs;
      labels = builtins.listToAttrs (
        concatMap (
          i:
          let
            it = itemAt i;
          in
          if it ? defines then
            [
              {
                name = it.defines;
                value = pcAt i;
              }
            ]
          else
            [ ]
        ) (genList (i: i) n)
      );
      bytes = concatMap (
        i:
        (itemAt i).emit {
          pc = pcAt i;
          inherit labels;
        }
      ) (genList (i: i) n);
    in
    {
      inherit base bytes labels;
      size = length bytes;
      entry = if entry == null then base else labels.${entry};
    };

  # Place an assembled program into a memory image.
  toMemory =
    mem: prog:
    let
      M = import ./mem.nix;
      b = i: if i < prog.size then elemAt prog.bytes i else 0;
      nwords = div (prog.size + 3) 4;
    in
    foldl' (
      m: w:
      let
        i = 4 * w;
      in
      M.storeWord m (prog.base + i) (b i + 256 * b (i + 1) + 65536 * b (i + 2) + 16777216 * b (i + 3))
    ) mem (genList (i: i) nwords);
in
regs
// base
// pseudo
// data
// conds
// control
// {
  inherit
    label
    raw
    assemble
    toMemory
    sizeOf
    flatten
    ;
  inherit (Ascii) ord;
}
