# C type checker: syntax tree (cc/parse.nix) -> typed syntax tree (input of cc/emit.nix).
#
# Entry point: check : unit node -> { funcs = [ <typed function> ]; }, the function
# definitions in source order. Errors are thrown as "cc: <line>:<col>: <message>", and as
# "cc: <line>:<col>: unsupported: <what>" for valid C outside the supported subset.
# `types` holds the type helpers shared with the emitter, and `collect` the tree walker.
#
# Types are those of cc/parse.nix. Sizes and ranges follow clang's ilp32 ABI (char 1; int,
# long and pointers 4; long long 8). Plain char is unsigned, as in clang's RISC-V ABI
# (the scaffold's), but stays a type of its own.
#
# Typed syntax tree
# -----------------
# Every expression node has `kind`, `type`, `line` and `col`. Implicit conversions are
# explicit "cast" nodes, a "cast" is present only where the types differ, and the
# conversion of an integer constant is folded into the constant.
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
    concatMap
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
    if isVoid e.type then
      node e "cast" e.type { expr = x; }
    else if isVoid x.type then
      fail e.expr "void value used"
    else
      mkCast e.type x;

  unaryExpr =
    env: e:
    let
      x = rv env e.expr;
      t = promote x.type;
      v = mkCast t x;
      folded = f: v // { value = wrapTo t (f v.value); };
    in
    if e.op == "!" then
      node e "not" tInt { expr = x; }
    else if !isInteger x.type then
      fail e "invalid argument type '${showType x.type}' to unary '${e.op}'"
    else if v.kind == "lit" then
      folded (if e.op == "-" then (n: -n) else (n: -n - 1))
    else
      node e (if e.op == "-" then "neg" else "bnot") t { expr = v; };

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
        node at "binop" t {
          inherit op;
          lhs = mkCast t a;
          rhs = mkCast t b;
        };
      cmp =
        x: y:
        node at "cmp" tInt {
          inherit op;
          lhs = x;
          rhs = y;
        };
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
      if ints then
        node at "binop" (promote ta) {
          inherit op;
          lhs = mkCast (promote ta) a;
          rhs = mkCast (promote tb) b;
        }
      else
        invalid
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

  binaryExpr =
    env: e:
    if e.op == "&&" || e.op == "||" then
      if hasSideEffects e.rhs then
        unsupported e "side effect on the right of '${e.op}'"
      else
        node e (if e.op == "&&" then "logand" else "logor") tInt {
          lhs = rv env e.lhs;
          rhs = rv env e.rhs;
        }
    else
      typeBinary e e.op (rv env e.lhs) (rv env e.rhs);

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
          isDef = item.kind == "func";
          funcs = acc.funcs // {
            ${item.name} = sig // {
              defined = isDef || (prev != null && prev.defined);
            };
          };
        in
        if item.kind == "typedef" then
          acc
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
  inherit check types collect;
}
