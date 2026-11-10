# C type checker: syntax tree (cc/parse.nix) -> typed syntax tree (input of cc/emit.nix).
#
# Entry point: check : unit node -> { funcs = [ <typed function> ]; }, the function
# definitions in source order. Errors are thrown as "cc: <line>:<col>: <message>", and as
# "cc: <line>:<col>: unsupported: <what>" for valid C outside the supported subset.
# `types` holds the type helpers shared with the emitter, `collect` the tree walker, and
# `constExpr` / `noConstHooks` the integer constant expression evaluator (see there).
#
# Types are those of cc/parse.nix. Sizes and ranges follow clang's ilp32 ABI (char 1; int,
# long and pointers 4; long long 8). Plain char is unsigned, as in clang's RISC-V ABI
# (the scaffold's), but stays a type of its own.
#
# Typed syntax tree
# -----------------
# Every expression node has `kind`, `type`, `line` and `col`. Implicit conversions are
# explicit "cast" nodes, a "cast" is present only where the types differ, and the
# conversion of an integer constant is folded into the constant. Operators on integer
# constants (unary, binary, comparisons, !, && and ||) are folded into a "lit" with the
# value the generated code would compute (signed int and long wrap to 32 bits), except a
# division by zero. A constant shift of a 32-bit value by a negative amount or by 32 or
# more is unsupported.
#   { kind = "lit"; value; }                     integer constant in the range of type
#   { kind = "var"; var; }                       var = { key; name; type; }; key is unique
#                                                per declaration
#   { kind = "old"; }                            the target's value before an assignment;
#                                                appears only inside an assign's value
#   { kind = "call"; name; args; }               args converted to the parameter types
#   { kind = "cast"; expr; }                     conversion of expr to type (void: discard)
#   { kind = "neg" | "bnot"; expr; }             unary - and ~ (expr has the result type)
#   { kind = "not"; expr; }                      !; expr is any scalar; type int
#   { kind = "deref"; expr; }                    memory read through a pointer; type is the
#                                                pointee (1 or 4 bytes)
#   { kind = "binop"; op; lhs; rhs; }            op: * / % + - << >> & | ^ on integers; both
#                                                operands have the result type, except the
#                                                rhs of << and >> (its own promoted type)
#   { kind = "ptradd"; op; ptr; index; size; }   pointer +/- integer; index is not scaled
#                                                by size (the pointee size in bytes)
#   { kind = "ptrdiff"; lhs; rhs; size; }        pointer - pointer; type int
#   { kind = "cmp"; op; lhs; rhs; }              < > <= >= == !=; type int
#   { kind = "logand" | "logor"; lhs; rhs; }     && and ||; type int; rhs has no side effects
#   { kind = "assign"; target; value; post; }    target is a "var" or "deref" node; value has
#                                                the target's type and may contain "old"; the
#                                                expression yields the old value when post
#                                                (postfix ++ and --), the new value otherwise
# `x op= y`, `++x` and `x--` are "assign" nodes whose value computes from "old".
#
# Statements (position of the first token):
#   { kind = "block"; items; }
#   { kind = "decl"; vars = [ { var; init; } ]; }    init is an expression or null
#   { kind = "expr"; expr; }                          expr may have type void
#   { kind = "if"; cond; thenStmt; elseStmt; }        elseStmt is a statement or null
#   { kind = "while"; cond; body; }
#   { kind = "do"; body; cond; }
#   { kind = "for"; init; cond; step; body; }         init is null, a "decl" or an "expr"
#                                                     statement; cond and step may be null
#   { kind = "return"; expr; }                        only as the last item of a function
#                                                     body; expr is null in a void function
# Empty statements and block-scope typedefs leave no node.
#
# Typed function (position of its name):
#   { name; ret; params = [ var ]; body = <block>; line; col; }
let
  B = import ../lib/bits.nix;
  inherit (builtins)
    any
    attrNames
    bitAnd
    bitOr
    bitXor
    concatMap
    div
    elem
    elemAt
    filter
    foldl'
    genList
    hasAttr
    head
    isAttrs
    isList
    length
    listToAttrs
    map
    stringLength
    substring
    ;

  fail = n: msg: throw "cc: ${toString n.line}:${toString n.col}: ${msg}";
  unsupported = n: what: fail n "unsupported: ${what}";

  # Every attribute set x in a value (lists and attribute sets are searched) with pred x,
  # not descending below the sets with stop x.
  collect =
    pred: stop: x:
    if isList x then
      concatMap (collect pred stop) x
    else if isAttrs x then
      (if pred x then [ x ] else [ ])
      ++ (if stop x then [ ] else concatMap (k: collect pred stop x.${k}) (attrNames x))
    else
      [ ];

  kindOf = x: x.kind or null;

  # Syntax the parser accepts but the checker does not support yet, by node kind, with
  # the description used in the error.
  pendingItems = {
    global = "global variable";
    struct = "struct";
    enum = "enum";
  };
  pendingStmts = {
    break = "'break' statement";
    continue = "'continue' statement";
    switch = "'switch' statement";
    case = "'case' label";
    default = "'default' label";
  };
  pendingExprs = {
    dot = "member access";
    arrow = "member access";
    addr = "address-of operator";
    sizeof = "sizeof";
    sizeoftype = "sizeof";
    cond = "conditional operator";
    charlit = "character literal";
  };
  pendingTypes = {
    short = "short";
    ushort = "unsigned short";
    array = "array type";
    struct = "struct";
    enum = "enum";
  };

  # Description of the unsupported part of the type t, or null.
  pendingType = t: if t.tag == "ptr" then pendingType t.to else pendingTypes.${t.tag} or null;

  # ---- Types ----

  ty = tag: { inherit tag; };
  tInt = ty "int";
  tUInt = ty "uint";
  tLong = ty "long";
  tULong = ty "ulong";
  tLLong = ty "llong";

  s32 = {
    lo = -2147483648;
    hi = 2147483647;
  };
  u32 = {
    lo = 0;
    hi = 4294967295;
  };
  s8 = {
    lo = -128;
    hi = 127;
  };
  u8 = {
    lo = 0;
    hi = 255;
  };
  ranges = {
    char = u8;
    schar = s8;
    uchar = u8;
    int = s32;
    long = s32;
    uint = u32;
    ulong = u32;
    ptr = u32;
    llong = {
      lo = -9223372036854775807 - 1;
      hi = 9223372036854775807;
    };
  };

  isScalar = t: hasAttr t.tag ranges;
  isPtr = t: t.tag == "ptr";
  isInteger = t: isScalar t && !isPtr t;
  isVoid = t: t.tag == "void";
  rangeOf = t: ranges.${t.tag};
  isUnsigned = t: isScalar t && (rangeOf t).lo == 0;
  # unsigned int, unsigned long and pointers: non-negative values below 2^32.
  isU32 =
    t:
    elem t.tag [
      "uint"
      "ulong"
      "ptr"
    ];
  # int and long: signed 32-bit.
  isS32 = t: t.tag == "int" || t.tag == "long";
  # signed char.
  isS8 = t: t.tag == "schar";
  # char and unsigned char.
  isU8 = t: t.tag == "char" || t.tag == "uchar";
  sizeOf =
    t:
    if
      elem t.tag [
        "char"
        "schar"
        "uchar"
      ]
    then
      1
    else if t.tag == "llong" then
      8
    else
      4;
  # Every value of type from is a value of type to.
  fits =
    from: to:
    let
      a = rangeOf from;
      b = rangeOf to;
    in
    b.lo <= a.lo && a.hi <= b.hi;

  # Integer promotion (char types to int).
  promote = t: if isInteger t && sizeOf t == 1 then tInt else t;

  rank =
    t:
    {
      int = 1;
      uint = 1;
      long = 2;
      ulong = 2;
      llong = 3;
    }
    .${t.tag};

  # Usual arithmetic conversions of two integer types.
  usual =
    a: b:
    let
      x = promote a;
      y = promote b;
      un = if isUnsigned x then x else y;
      sg = if isUnsigned x then y else x;
    in
    if x == y then
      x
    else if x.tag == "llong" || y.tag == "llong" then
      tLLong
    else if isUnsigned x == isUnsigned y then
      if rank x >= rank y then x else y
    else if rank un >= rank sg then
      un
    # long against unsigned int: long cannot hold every unsigned int.
    else
      tULong;

  # The integer v converted to type t (wrapped into the range of t).
  wrapTo =
    t: v:
    let
      b = bitAnd v 255;
    in
    if t.tag == "llong" then
      v
    else if isU32 t then
      B.u32 v
    else if isS32 t then
      B.toSigned (B.u32 v)
    else if isU8 t then
      b
    else if b >= 128 then
      b - 256
    else
      b;

  typeNames = {
    void = "void";
    char = "char";
    schar = "signed char";
    uchar = "unsigned char";
    int = "int";
    uint = "unsigned int";
    long = "long";
    ulong = "unsigned long";
    llong = "long long";
  };
  showType = t: if isPtr t then "${showType t.to} *" else typeNames.${t.tag};

  types = {
    inherit
      isScalar
      isPtr
      isInteger
      isVoid
      isUnsigned
      isU32
      isS32
      isS8
      isU8
      sizeOf
      fits
      ;
  };

  # ---- Expressions ----

  node =
    at: kind: type: fields:
    {
      inherit kind type;
      inherit (at) line col;
    }
    // fields;

  # Type of an integer literal: the first of the C candidate types that holds its value.
  litType =
    n:
    let
      hex = elem (substring 0 2 n.text) [
        "0x"
        "0X"
      ];
      candidates =
        if n.unsigned then
          if n.long == 0 then
            [
              tUInt
              tULong
            ]
          else if n.long == 1 then
            [ tULong ]
          else
            [ ]
        else if n.long == 0 then
          if hex then
            [
              tInt
              tUInt
              tLong
              tULong
              tLLong
            ]
          else
            [
              tInt
              tLong
              tLLong
            ]
        else if n.long == 1 then
          if hex then
            [
              tLong
              tULong
              tLLong
            ]
          else
            [
              tLong
              tLLong
            ]
        else
          [ tLLong ];
      holding = filter (t: n.value <= (rangeOf t).hi) candidates;
    in
    if holding == [ ] then unsupported n "unsigned long long literal '${n.text}'" else head holding;

  # x converted to type t. Constants are converted in place.
  mkCast =
    t: x:
    if x.type == t then
      x
    else if x.kind == "lit" && isScalar t then
      x
      // {
        type = t;
        value = wrapTo t x.value;
      }
    else
      node x "cast" t { expr = x; };

  isNullConst = x: x.kind == "lit" && x.value == 0 && isInteger x.type;

  # ---- Constant folding ----
  # Constants are folded with the values the generated code computes: signed int and long
  # wrap to 32 bits, long long does not wrap (its overflow is undefined in C, and it fails
  # the evaluation like in the generated code).

  isIntLit = x: x.kind == "lit" && isInteger x.type;

  litAt =
    at: t: value:
    node at "lit" t { inherit value; };

  # x << k for a value x of the integer type t, or null when it is not folded (long long
  # by 63 or more, whose product is not a Nix integer).
  foldShl =
    t: x: k:
    if t.tag == "llong" then
      (if k <= 62 then x * B.pow2 k else null)
    else if isU32 t then
      # Only the bits that stay below 2^32 are shifted, so the product fits.
      bitAnd x (B.pow2 (32 - k) - 1) * B.pow2 k
    else
      wrapTo t (x * B.pow2 k);

  # x >> k for a value x of the integer type t (arithmetic, floor, when t is signed).
  foldShr =
    t: x: k:
    let
      p = B.pow2 k;
    in
    if isUnsigned t then
      div x p
    else if k == 63 then
      (if x < 0 then -1 else 0)
    else
      div (x - bitAnd x (p - 1)) p;

  # Value of `a op b` for the constants a and b, where t is the type of the result (and of
  # a and b, except the rhs of a shift), or null when it is not folded (division by zero,
  # long long shifts outside 0..63, long long << 63).
  foldBinary =
    t: op: a: b:
    let
      d = div a b;
    in
    if op == "+" then
      wrapTo t (a + b)
    else if op == "-" then
      wrapTo t (a - b)
    else if op == "*" then
      (if isU32 t then B.mul a b else wrapTo t (a * b))
    else if op == "/" || op == "%" then
      (if b == 0 then null else wrapTo t (if op == "/" then d else a - b * d))
    else if op == "&" then
      bitAnd a b
    else if op == "|" then
      bitOr a b
    else if op == "^" then
      bitXor a b
    else if b < 0 || b > 63 then
      null
    else if op == "<<" then
      foldShl t a b
    else
      foldShr t a b;

  # The "binop" node n folded to a constant when both operands are constants.
  foldBinop =
    n:
    let
      v = foldBinary n.type n.op n.lhs.value n.rhs.value;
    in
    if isIntLit n.lhs && isIntLit n.rhs && v != null then litAt n n.type v else n;

  cmpOps = {
    "<" = a: b: a < b;
    ">" = a: b: a > b;
    "<=" = a: b: a <= b;
    ">=" = a: b: a >= b;
    "==" = a: b: a == b;
    "!=" = a: b: a != b;
  };
  boolValue = b: if b then 1 else 0;

  # The "cmp" node n folded when both operands are integer constants.
  foldCmp =
    n:
    if isIntLit n.lhs && isIntLit n.rhs then
      litAt n tInt (boolValue (cmpOps.${n.op} n.lhs.value n.rhs.value))
    else
      n;

  # The "not", "logand" and "logor" node n folded when its operands are integer constants.
  foldLogic =
    n:
    if n.kind == "not" then
      (if isIntLit n.expr then litAt n tInt (boolValue (n.expr.value == 0)) else n)
    else if isIntLit n.lhs && isIntLit n.rhs then
      litAt n tInt (
        boolValue (
          if n.kind == "logand" then
            n.lhs.value != 0 && n.rhs.value != 0
          else
            n.lhs.value != 0 || n.rhs.value != 0
        )
      )
    else
      n;

  # Conversion as by assignment (also for arguments and return values).
  assignConv =
    at: t: x:
    if (isInteger t && isInteger x.type) || (isPtr t && isPtr x.type) || (isPtr t && isNullConst x) then
      mkCast t x
    else
      fail at "incompatible conversion from '${showType x.type}' to '${showType t}'";

  hasSideEffects =
    e:
    collect (
      x:
      elem (kindOf x) [
        "assign"
        "prefix"
        "postfix"
        "call"
      ]
    ) (_: false) e != [ ];

  oldOf = target: node target "old" target.type { };

  # Expression of any type (void included).
  ex =
    env: e:
    let
      k = e.kind;
    in
    if k == "intlit" then
      node e "lit" (litType e) { inherit (e) value; }
    else if k == "ident" then
      identExpr env e
    else if k == "call" then
      callExpr env e
    else if k == "cast" then
      castExpr env e
    else if k == "unary" then
      unaryExpr env e
    else if k == "deref" then
      derefOf e (rv env e.expr)
    else if k == "index" then
      indexExpr env e
    else if k == "prefix" || k == "postfix" then
      incDec env e
    else if k == "binary" then
      binaryExpr env e
    else if k == "assign" then
      assignExpr env e
    else if hasAttr k pendingExprs then
      unsupported e pendingExprs.${k}
    else
      fail e "unexpected expression '${k}'";

  # Expression whose value is used (not void).
  rv =
    env: e:
    let
      x = ex env e;
    in
    if isVoid x.type then fail e "void value used" else x;

  identExpr =
    env: e:
    if hasAttr e.name env.vars then
      let
        v = env.vars.${e.name};
      in
      node e "var" v.type { var = v; }
    else if hasAttr e.name env.funcs then
      unsupported e "function '${e.name}' used as a value"
    else
      fail e "use of undeclared identifier '${e.name}'";

  callExpr =
    env: e:
    let
      f = env.funcs.${e.name};
      n = length f.params;
      m = length e.args;
      arg =
        i:
        let
          a = elemAt e.args i;
        in
        assignConv a (elemAt f.params i) (rv env a);
    in
    if hasAttr e.name env.vars then
      fail e "called object '${e.name}' is not a function"
    else if !hasAttr e.name env.funcs then
      fail e "call to undeclared function '${e.name}'"
    else if n != m then
      fail e "function '${e.name}' takes ${toString n} argument(s) but ${toString m} were given"
    else
      node e "call" f.ret {
        inherit (e) name;
        args = genList arg n;
      };

  castExpr =
    env: e:
    let
      x = ex env e.expr;
    in
    if pendingType e.type != null then
      unsupported e (pendingType e.type)
    else if isVoid e.type then
      node e "cast" e.type { expr = x; }
    else if isVoid x.type then
      fail e.expr "void value used"
    else
      mkCast e.type x;

  unaryExpr = env: e: typeUnary e e.op (rv env e.expr);

  # Typing of the unary operator op (- ~ !) on the typed operand x.
  typeUnary =
    at: op: x:
    let
      t = promote x.type;
      v = mkCast t x;
      folded = f: v // { value = wrapTo t (f v.value); };
    in
    if op == "!" then
      foldLogic (node at "not" tInt { expr = x; })
    else if !isInteger x.type then
      fail at "invalid argument type '${showType x.type}' to unary '${op}'"
    else if v.kind == "lit" then
      folded (if op == "-" then (n: -n) else (n: -n - 1))
    else
      node at (if op == "-" then "neg" else "bnot") t { expr = v; };

  derefOf =
    at: p:
    let
      t = p.type.to;
    in
    if !isPtr p.type then
      fail at "indirection requires a pointer operand ('${showType p.type}' invalid)"
    else if isVoid t then
      fail at "dereference of a 'void *' pointer"
    else if sizeOf t == 8 then
      unsupported at "8-byte memory access"
    else
      node at "deref" t { expr = p; };

  ptrAdd =
    at: op: p: i:
    if isVoid p.type.to then
      fail at "arithmetic on a pointer to void"
    else
      node at "ptradd" p.type {
        inherit op;
        ptr = p;
        index = mkCast (promote i.type) i;
        size = sizeOf p.type.to;
      };

  indexExpr =
    env: e:
    let
      b = rv env e.base;
      i = rv env e.index;
    in
    if isPtr b.type && isInteger i.type then
      derefOf e (ptrAdd e "+" b i)
    else if isInteger b.type && isPtr i.type then
      derefOf e (ptrAdd e "+" i b)
    else
      fail e "subscripted value is not a pointer";

  # Typing of the binary operator op (not && or ||) on the typed operands a and b.
  typeBinary =
    at: op: a: b:
    let
      ta = a.type;
      tb = b.type;
      ints = isInteger ta && isInteger tb;
      invalid = fail at "invalid operands to binary '${op}' ('${showType ta}' and '${showType tb}')";
      arith =
        t:
        foldBinop (
          node at "binop" t {
            inherit op;
            lhs = mkCast t a;
            rhs = mkCast t b;
          }
        );
      cmp =
        x: y:
        foldCmp (
          node at "cmp" tInt {
            inherit op;
            lhs = x;
            rhs = y;
          }
        );
      shift =
        let
          t = promote ta;
          amount = mkCast (promote tb) b;
        in
        if amount.kind == "lit" && sizeOf t == 4 && (amount.value < 0 || amount.value >= 32) then
          unsupported at "shift of a 32-bit value by ${toString amount.value}"
        else
          foldBinop (
            node at "binop" t {
              inherit op;
              lhs = mkCast t a;
              rhs = amount;
            }
          );
    in
    if
      elem op [
        "*"
        "/"
        "%"
        "&"
        "|"
        "^"
      ]
    then
      if ints then arith (usual ta tb) else invalid
    else if op == "+" then
      if ints then
        arith (usual ta tb)
      else if isPtr ta && isInteger tb then
        ptrAdd at "+" a b
      else if isInteger ta && isPtr tb then
        ptrAdd at "+" b a
      else
        invalid
    else if op == "-" then
      if ints then
        arith (usual ta tb)
      else if isPtr ta && isInteger tb then
        ptrAdd at "-" a b
      else if isPtr ta && ta == tb && !isVoid ta.to then
        node at "ptrdiff" tInt {
          lhs = a;
          rhs = b;
          size = sizeOf ta.to;
        }
      else
        invalid
    else if op == "<<" || op == ">>" then
      if ints then shift else invalid
    else if ints then
      let
        t = usual ta tb;
      in
      cmp (mkCast t a) (mkCast t b)
    else if isPtr ta && isPtr tb then
      cmp a b
    else if isPtr ta && isNullConst b then
      cmp a (mkCast ta b)
    else if isNullConst a && isPtr tb then
      cmp (mkCast tb a) b
    else
      invalid;

  # Typing of && and || on the typed operands a and b.
  typeLogical =
    at: op: a: b:
    foldLogic (
      node at (if op == "&&" then "logand" else "logor") tInt {
        lhs = a;
        rhs = b;
      }
    );

  binaryExpr =
    env: e:
    if e.op == "&&" || e.op == "||" then
      if hasSideEffects e.rhs then
        unsupported e "side effect on the right of '${e.op}'"
      else
        typeLogical e e.op (rv env e.lhs) (rv env e.rhs)
    else
      typeBinary e e.op (rv env e.lhs) (rv env e.rhs);

  # ---- Integer constant expressions ----
  # constExpr hooks e: the expression node e (cc/parse.nix) evaluated at compile time to a
  # typed "lit" node of an integer type, with the types, conversions and wrapping of the
  # typed tree (the same folding as above). It accepts literals, character literals, casts
  # to integer types, unary and binary operators and `?:`; anything else is not a constant
  # expression and fails. hooks supplies the leaves the checker does not know by itself:
  #   ident  : name -> { type; value; } or null   a named constant (enum constant)
  #   sizeOf : node -> integer or null            size in bytes for a "sizeof" or
  #                                               "sizeoftype" node (type unsigned int)
  # A null answer leaves the leaf unsupported or not constant. noConstHooks has none.
  noConstHooks = {
    ident = _: null;
    sizeOf = _: null;
  };

  constExpr =
    hooks: e:
    let
      x = constTyped hooks e;
    in
    if isIntLit x then x else fail e "expression is not an integer constant expression";

  # e typed by the constant rules; the result is a "lit" node unless e is not constant.
  constTyped =
    hooks: e:
    let
      k = e.kind;
      sub = constTyped hooks;
      notConst = fail e "expression is not an integer constant expression";
    in
    if k == "intlit" then
      litAt e (litType e) e.value
    else if k == "charlit" then
      litAt e tInt e.value
    else if k == "ident" then
      constIdent hooks e
    else if k == "sizeof" || k == "sizeoftype" then
      constSizeof hooks e
    else if k == "cast" then
      constCast e (sub e.expr)
    else if k == "unary" then
      typeUnary e e.op (sub e.expr)
    else if k == "binary" then
      (if e.op == "&&" || e.op == "||" then typeLogical else typeBinary) e e.op (sub e.lhs) (sub e.rhs)
    else if k == "cond" then
      constCond e (sub e.cond) (sub e.thenExpr) (sub e.elseExpr)
    else
      notConst;

  constIdent =
    hooks: e:
    let
      c = hooks.ident e.name;
    in
    if c == null then
      fail e "expression is not an integer constant expression"
    else
      litAt e c.type c.value;

  constSizeof =
    hooks: e:
    let
      size = hooks.sizeOf e;
    in
    if size == null then unsupported e "sizeof" else litAt e tUInt size;

  constCast =
    e: x:
    if pendingType e.type != null then
      unsupported e (pendingType e.type)
    else if !isInteger e.type || !isIntLit x then
      fail e "expression is not an integer constant expression"
    else
      mkCast e.type x;

  # `c ? a : b` on constants: the chosen operand converted to the common type.
  constCond =
    e: c: a: b:
    if !(isIntLit c && isIntLit a && isIntLit b) then
      fail e "expression is not an integer constant expression"
    else
      let
        t = usual a.type b.type;
      in
      mkCast t (if c.value != 0 then a else b) // { inherit (e) line col; };

  lvalue =
    env: e:
    let
      x = ex env e;
    in
    if x.kind == "var" || x.kind == "deref" then x else fail e "expression is not assignable";

  assignExpr =
    env: e:
    let
      target = lvalue env e.lhs;
      rhs = rv env e.rhs;
      op = substring 0 (stringLength e.op - 1) e.op;
      value =
        if e.op == "=" then
          assignConv e target.type rhs
        else
          assignConv e target.type (typeBinary e op (oldOf target) rhs);
    in
    node e "assign" target.type {
      inherit target value;
      post = false;
    };

  incDec =
    env: e:
    let
      target = lvalue env e.expr;
      one = node e "lit" tInt { value = 1; };
      op = if e.op == "++" then "+" else "-";
    in
    node e "assign" target.type {
      inherit target;
      value = assignConv e target.type (typeBinary e op (oldOf target) one);
      post = e.kind == "postfix";
    };

  # ---- Statements ----

  # env: { vars; local; funcs; ret; } with vars and local keyed by the C name (local:
  # the names declared in the innermost block), funcs the function signatures, ret the
  # return type of the current function.
  enterBlock = env: env // { local = { }; };

  declare =
    env: at: name: type:
    let
      var = {
        key = "${name}@${toString at.line}:${toString at.col}";
        inherit name type;
      };
    in
    if hasAttr name env.local then
      fail at "redefinition of '${name}'"
    else if isVoid type then
      fail at "variable '${name}' has type 'void'"
    else
      {
        inherit var;
        env = env // {
          vars = env.vars // {
            ${name} = var;
          };
          local = env.local // {
            ${name} = true;
          };
        };
      };

  # Check the statement n; tailOk: n is the last item of the function body.
  # -> { node (null when nothing is left); env; }
  stmt =
    env: tailOk: n:
    let
      k = n.kind;
      at = fields: {
        node = {
          inherit kind;
          inherit (n) line col;
        }
        // fields;
        inherit env;
      };
      kind = k;
    in
    if k == "block" then
      at { items = blockItems (enterBlock env) n.items false; }
    else if k == "decl" then
      declStmt env n
    else if k == "expr" then
      at { expr = ex env n.expr; }
    else if k == "empty" then
      {
        node = null;
        inherit env;
      }
    else if k == "if" then
      at {
        cond = rv env n.cond;
        thenStmt = sub env n.thenStmt;
        elseStmt = if n.elseStmt == null then null else sub env n.elseStmt;
      }
    else if k == "while" then
      at {
        cond = rv env n.cond;
        body = sub env n.body;
      }
    else if k == "do" then
      at {
        body = sub env n.body;
        cond = rv env n.cond;
      }
    else if k == "for" then
      forStmt env n
    else if k == "return" then
      returnStmt env tailOk n
    else if hasAttr k pendingStmts then
      unsupported n pendingStmts.${k}
    else
      fail n "unexpected statement '${k}'";

  # A statement that is the body or branch of another one (never null).
  sub =
    env: n:
    let
      r = stmt env false n;
    in
    if r.node == null then
      {
        kind = "block";
        items = [ ];
        inherit (n) line col;
      }
    else
      r.node;

  declStmt =
    env: n:
    let
      step =
        acc: d:
        if d.kind == "typedef" then
          acc
        else if hasAttr d.kind pendingItems then
          unsupported d pendingItems.${d.kind}
        else if pendingType d.type != null then
          unsupported d (pendingType d.type)
        else
          let
            # The scope of a name starts after its declarator, so the initializer sees it.
            r = declare acc.env d d.name d.type;
            init = if d.init == null then null else assignConv d.init d.type (rv r.env d.init);
          in
          {
            inherit (r) env;
            vars = acc.vars ++ [
              {
                inherit (r) var;
                inherit init;
              }
            ];
          };
      r = foldl' step {
        inherit env;
        vars = [ ];
      } n.decls;
    in
    {
      node =
        if r.vars == [ ] then
          null
        else
          {
            kind = "decl";
            inherit (r) vars;
            inherit (n) line col;
          };
      inherit (r) env;
    };

  forStmt =
    env: n:
    let
      fenv = enterBlock env;
      init =
        if n.init == null then
          {
            node = null;
            env = fenv;
          }
        else if n.init.kind == "decl" then
          declStmt fenv n.init
        else
          {
            node = {
              kind = "expr";
              expr = ex fenv n.init;
              inherit (n.init) line col;
            };
            env = fenv;
          };
      ienv = init.env;
    in
    {
      node = {
        kind = "for";
        init = init.node;
        cond = if n.cond == null then null else rv ienv n.cond;
        step = if n.step == null then null else ex ienv n.step;
        body = sub ienv n.body;
        inherit (n) line col;
      };
      inherit env;
    };

  returnStmt =
    env: tailOk: n:
    let
      isVoidFn = isVoid env.ret;
    in
    if !tailOk then
      unsupported n "'return' before the end of the function"
    else if isVoidFn && n.expr != null then
      fail n "void function should not return a value"
    else if !isVoidFn && n.expr == null then
      fail n "non-void function should return a value"
    else
      {
        node = {
          kind = "return";
          expr = if n.expr == null then null else assignConv n.expr env.ret (rv env n.expr);
          inherit (n) line col;
        };
        inherit env;
      };

  # Items of a block, checked in order; the last one is in tail position when tailLast.
  blockItems =
    env: items: tailLast:
    let
      count = length items;
      step =
        acc: i:
        let
          r = stmt acc.env (tailLast && i == count - 1) (elemAt items i);
        in
        {
          inherit (r) env;
          nodes = acc.nodes ++ (if r.node == null then [ ] else [ r.node ]);
        };
    in
    (foldl' step {
      inherit env;
      nodes = [ ];
    } (genList (i: i) count)).nodes;

  # ---- Functions ----

  funcDef =
    funcs: f:
    let
      step =
        acc: p:
        let
          r = declare acc.env p p.name p.type;
        in
        {
          inherit (r) env;
          vars = acc.vars ++ [ r.var ];
        };
      ps = foldl' step {
        env = {
          vars = { };
          local = { };
          inherit funcs;
          inherit (f) ret;
        };
        vars = [ ];
      } f.params;
      items = blockItems ps.env f.body.items true;
      count = length items;
      endsWithReturn = count > 0 && (elemAt items (count - 1)).kind == "return";
    in
    if !isVoid f.ret && !endsWithReturn then
      unsupported f "non-void function '${f.name}' without a final 'return'"
    else
      {
        inherit (f)
          name
          ret
          line
          col
          ;
        params = ps.vars;
        body = {
          kind = "block";
          inherit items;
          inherit (f.body) line col;
        };
      };

  # The first part of the signature of a proto or func whose type is not supported yet, as
  # { at; what; }, or null.
  pendingSig =
    item:
    let
      parts = [
        {
          at = item;
          type = item.ret;
        }
      ]
      ++ map (p: {
        at = p;
        inherit (p) type;
      }) item.params;
      bad = filter (x: pendingType x.type != null) parts;
    in
    if bad == [ ] then
      null
    else
      {
        inherit (head bad) at;
        what = pendingType (head bad).type;
      };

  # Signatures of the prototypes and definitions in unit order, and the checked definitions.
  checkItems =
    items:
    foldl'
      (
        acc: item:
        let
          sig = {
            inherit (item) ret;
            params = map (p: p.type) item.params;
          };
          prev = acc.funcs.${item.name} or null;
          pending = pendingSig item;
          isDef = item.kind == "func";
          funcs = acc.funcs // {
            ${item.name} = sig // {
              defined = isDef || (prev != null && prev.defined);
            };
          };
        in
        if item.kind == "typedef" then
          acc
        else if hasAttr item.kind pendingItems then
          unsupported item pendingItems.${item.kind}
        else if pending != null then
          unsupported pending.at pending.what
        else if prev != null && (prev.ret != sig.ret || prev.params != sig.params) then
          fail item "conflicting types for '${item.name}'"
        else if isDef && prev != null && prev.defined then
          fail item "redefinition of '${item.name}'"
        else
          {
            inherit funcs;
            defs = acc.defs ++ (if isDef then [ (funcDef funcs item) ] else [ ]);
          }
      )
      {
        funcs = { };
        defs = [ ];
      }
      items;

  check =
    unit:
    let
      r = checkItems unit.items;
      undefinedCalls = filter (c: !r.funcs.${c.name}.defined) (
        collect (x: kindOf x == "call") (_: false) r.defs
      );
      result = {
        funcs = r.defs;
      };
    in
    if undefinedCalls != [ ] then
      unsupported (head undefinedCalls) "call to function '${(head undefinedCalls).name}' that is declared but not defined"
    else
      builtins.deepSeq result result;
in
{
  inherit
    check
    types
    collect
    constExpr
    noConstHooks
    ;
}
