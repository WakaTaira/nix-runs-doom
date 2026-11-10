# C type checker: syntax tree (cc/parse.nix) -> typed syntax tree (input of cc/emit.nix).
#
# Entry point: checkWith { dataBase; } : unit node -> { funcs; data; }, with funcs the
# typed function definitions in source order and data the placement of the file-scope
# variables (see "Data" below); check uses defaultDataBase. Errors are thrown as
# "cc: <line>:<col>: <message>", and as "cc: <line>:<col>: unsupported: <what>" for valid
# C outside the supported subset. `types` holds the type helpers shared with the emitter,
# `collect` the tree walker, and `constExpr` / `noConstHooks` the integer constant
# expression evaluator (see there).
#
# Types are those of cc/parse.nix, resolved: the length of an array is an integer (or null
# when not given), an enum type is its compatible integer type (unsigned int when no
# enumerator is negative, otherwise int, as in clang), and a function type has the
# resolved types of its parameters (adjusted like those of a function: arrays and
# functions to pointers) in params. A struct or union type stays a reference by tag to the
# layouts of the struct and union definitions; the tag of a block-scope definition is
# replaced by `<tag>@<line>:<col>` (of its keyword), which hides an outer one up to the end
# of the block. Sizes, alignments and ranges follow clang's ilp32 ABI (char 1; short 2;
# int, long, float and pointers 4; long long and double 8; a struct aligns to its most
# aligned member and is padded to a multiple of that; a union has all its members at
# offset 0; a packed struct or union aligns its members and itself to 1). Plain char is
# unsigned, as in clang's RISC-V ABI (the scaffold's), but stays a type of its own.
#
# Bit-fields are supported in the form whose layout equals one of plain unsigned members
# (see bitField): they are such members (unsigned char, unsigned short, or the declared
# type for a width of 32), except that `&` and `sizeof` reject them. A function pointer is a
# 4-byte pointer that can be copied, passed, returned, compared with == and != and tested;
# taking a function's address, calling through a pointer and converting between a function
# pointer and another type (but a null pointer constant) are unsupported. float and double
# are known types with their size and alignment, but every floating-point value (and
# variable, and the definition of or a call to a function with such a parameter or return
# value) is unsupported, as are calls to a variadic function.
#
# Typed syntax tree
# -----------------
# Every expression node has `kind`, `type`, `line` and `col`. Implicit conversions are
# explicit "cast" nodes, a "cast" is present only where the types differ, and the
# conversion of an integer constant is folded into the constant. Operators on integer
# constants (unary, binary, comparisons, !, &&, || and ?:) are folded into a "lit" with
# the value the generated code would compute (signed int and long wrap to 32 bits), except
# a division by zero. A constant shift of a 32-bit value by a negative amount or by 32 or
# more, and of a long long by a negative amount, by 64 or more, or left by 63, is
# unsupported. The address of a file-scope variable is a pointer "lit", and so is
# a constant pointer plus or minus a constant (member offsets and constant indices).
#   { kind = "lit"; value; }                     integer constant in the range of type, or
#                                                a constant address (pointer type)
#   { kind = "var"; var; }                       local variable or parameter;
#                                                var = { key; name; type; }; key is unique
#                                                per declaration
#   { kind = "old"; }                            the target's value before an assignment;
#                                                appears only inside an assign's value
#   { kind = "call"; name; args; }               args converted to the parameter types
#   { kind = "cast"; expr; }                     conversion of expr to type (void: discard)
#   { kind = "neg" | "bnot"; expr; }             unary - and ~ (expr has the result type)
#   { kind = "not"; expr; }                      !; expr is any scalar; type int
#   { kind = "deref"; expr; }                    memory read at the address expr; type is
#                                                the scalar read (1, 2 or 4 bytes)
#   { kind = "binop"; op; lhs; rhs; }            op: * / % + - << >> & | ^ on integers; both
#                                                operands have the result type, except the
#                                                rhs of << and >> (its own promoted type)
#   { kind = "ptradd"; op; ptr; index; size; }   pointer +/- integer; index is not scaled
#                                                by size (bytes per unit of index); type is
#                                                the result pointer type
#   { kind = "ptrdiff"; lhs; rhs; size; }        pointer - pointer; type int
#   { kind = "cmp"; op; lhs; rhs; }              < > <= >= == !=; type int
#   { kind = "logand" | "logor"; lhs; rhs; }     && and ||; type int; rhs is evaluated only
#                                                when lhs does not decide the result
#   { kind = "comma"; lhs; rhs; }                `lhs, rhs`; lhs (any type, void included)
#                                                is evaluated for its side effects; the
#                                                type and value are those of rhs
#   { kind = "cond"; cond; thenExpr; elseExpr; } ?:; cond is any scalar; both branches have
#                                                the result type and no side effects
#   { kind = "assign"; target; value; post; }    target is a "var" or "deref" node; value has
#                                                the target's type and may contain "old"; the
#                                                expression yields the old value when post
#                                                (postfix ++ and --), the new value otherwise
# `x op= y`, `++x` and `x--` are "assign" nodes whose value computes from "old".
# Arrays, structs and unions are objects in memory: while an expression is checked they are
# "deref" nodes of array, struct or union type (the address in expr), which never reach
# the typed tree. An array used as a value decays to a pointer to its first element; a
# struct or union is only used through its members, its address and sizeof.
#
# Statements (position of the first token):
#   { kind = "block"; items; }
#   { kind = "decl"; vars = [ { var; init; } ]; }    init is an expression or null; a
#                                                     declaration of static locals and
#                                                     block-scope extern variables also has
#                                                     statics and externs (see declStmt),
#                                                     which only this file uses
#   { kind = "expr"; expr; }                          expr may have type void
#   { kind = "if"; cond; thenStmt; elseStmt; }        elseStmt is a statement or null
#   { kind = "while"; cond; body; }
#   { kind = "do"; body; cond; }
#   { kind = "for"; init; cond; step; body; }         init is null, a "decl" or an "expr"
#                                                     statement; cond and step may be null
#   { kind = "return"; expr; }                        expr is null in a void function
#   { kind = "break"; }                               inside a loop or a switch
#   { kind = "continue"; }                            inside a loop
#   { kind = "switch"; cond; skipped; sections; cases; default; }
#       cond has its promoted type. The body is a block whose items may carry case and
#       default labels; a labelled item starts a section, and sections = [ [ statement ] ]
#       holds the statements of each section in order. skipped are the statements before
#       the first label, which never run (kept for their declarations, whose scope goes on
#       into the sections). cases = [ { value; section; } ] in source order, with value
#       converted to the type of cond; default is the index of its section or null.
# Empty statements, block-scope typedefs, function declarations and struct, union and enum
# definitions leave no node. Labels anywhere but directly in the body of a switch are
# unsupported.
#
# Typed function (position of its name):
#   { name; ret; params = [ var ]; body = <block>; line; col; }
#
# Data
# ----
# File-scope variables are placed in declaration order (of their definitions), each at the
# next offset aligned for its type, from the address dataBase (default 0x00400000), and
# after them the static locals in source order, each named
# `<function>'<name>'<line>'<col>` (of its name; not a C identifier):
#   { base; size; symbols = [ { name; addr; } ]; inits = [ { addr; size; value; } ]; }
# size is the end of the last variable minus base. inits are the scalar stores of the
# initializers whose value is not 0 (size 1, 2 or 4 bytes, value in the stored unsigned
# form), in address order within each variable.
let
  B = import ../lib/bits.nix;
  inherit (builtins)
    any
    attrNames
    bitAnd
    bitOr
    bitXor
    concatLists
    concatMap
    div
    elem
    elemAt
    filter
    foldl'
    genericClosure
    genList
    hasAttr
    head
    isAttrs
    isInt
    isList
    length
    listToAttrs
    map
    removeAttrs
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

  # Run `step` from state s0 iteratively (genericClosure), so long sequences do not nest
  # Nix calls. `step s` is null at the end of the sequence, or { node; s; }.
  # Returns { nodes; s; } with the final state.
  iterate =
    step: s0:
    let
      items = genericClosure {
        startSet = [
          {
            key = 0;
            s = s0;
            r = step s0;
          }
        ];
        operator =
          it:
          if it.r == null then
            [ ]
          else
            [
              {
                key = it.key + 1;
                inherit (it.r) s;
                r = step it.r.s;
              }
            ];
      };
      n = length items;
    in
    {
      nodes = genList (k: (elemAt items k).r.node) (n - 1);
      s = (elemAt items (n - 1)).s;
    };

  # ---- Types ----

  ty = tag: { inherit tag; };
  tInt = ty "int";
  tUInt = ty "uint";
  tLong = ty "long";
  tULong = ty "ulong";
  tLLong = ty "llong";
  ptrTo = t: {
    tag = "ptr";
    to = t;
  };

  s32 = {
    lo = -2147483648;
    hi = 2147483647;
  };
  u32 = {
    lo = 0;
    hi = 4294967295;
  };
  s16 = {
    lo = -32768;
    hi = 32767;
  };
  u16 = {
    lo = 0;
    hi = 65535;
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
    short = s16;
    ushort = u16;
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
  # short and unsigned short.
  isS16 = t: t.tag == "short";
  isU16 = t: t.tag == "ushort";
  # Size in bytes of a scalar type.
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
    else if isS16 t || isU16 t then
      2
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

  # Integer promotion (char and short types to int).
  promote = t: if isInteger t && sizeOf t < 4 then tInt else t;

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
      h = bitAnd v 65535;
    in
    if t.tag == "llong" then
      v
    else if isU32 t then
      B.u32 v
    else if isS32 t then
      B.toSigned (B.u32 v)
    else if isU16 t then
      h
    else if isS16 t then
      (if h >= 32768 then h - 65536 else h)
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
    short = "short";
    ushort = "unsigned short";
    int = "int";
    uint = "unsigned int";
    long = "long";
    ulong = "unsigned long";
    llong = "long long";
    float = "float";
    double = "double";
  };
  showType =
    t:
    if isPtr t then
      "${showType t.to} *"
    else if t.tag == "array" then
      "${showType t.of} [${if t.len == null then "" else toString t.len}]"
    else if t.tag == "struct" || t.tag == "union" then
      "${t.tag} ${t.name}"
    else if t.tag == "fn" then
      "${showType t.ret} (${
        builtins.concatStringsSep ", " (map showType t.params ++ (if t.variadic then [ "..." ] else [ ]))
      })"
    else
      typeNames.${t.tag};

  types = {
    inherit
      isScalar
      isPtr
      isInteger
      isVoid
      isUnsigned
      isU32
      isS32
      isS16
      isU16
      isS8
      isU8
      sizeOf
      fits
      ;
  };

  # ---- Objects: arrays, structs, sizes and alignments ----
  # ctx (the context, see checkItems) holds the struct and union layouts by tag:
  #   structs.<name> = { kind; size; align; fields = [ { name; type; offset; } ]; byName; }
  # kind is "struct" or "union", and byName maps a member name to its field. The field of
  # a bit-field also has bitfield = true.

  isArray = t: t.tag == "array";
  # Structs and unions.
  isStruct = t: t.tag == "struct" || t.tag == "union";
  isAggregate = t: isArray t || isStruct t;
  isFloat = t: t.tag == "float" || t.tag == "double";
  # A floating-point object: a float or double, or an array of them.
  hasFloat = t: isFloat t || isArray t && hasFloat t.of;
  isFnPtr = t: isPtr t && t.to.tag == "fn";
  # Sizes (and alignments) of the floating-point types; they are never read or written.
  floatSizes = {
    float = 4;
    double = 8;
  };

  # A type whose size is known: not void, not a function, not an array of unknown length,
  # not a struct or union without a definition.
  isComplete =
    ctx: t:
    if isVoid t || t.tag == "fn" then
      false
    else if isArray t then
      t.len != null && isComplete ctx t.of
    else if isStruct t then
      hasAttr t.name ctx.structs
    else
      true;

  # Size in bytes of the complete type t.
  sizeOfT =
    ctx: t:
    if isArray t then
      t.len * sizeOfT ctx t.of
    else if isStruct t then
      ctx.structs.${t.name}.size
    else if isFloat t then
      floatSizes.${t.tag}
    else
      sizeOf t;

  alignOfT =
    ctx: t:
    if isArray t then
      alignOfT ctx t.of
    else if isStruct t then
      ctx.structs.${t.name}.align
    else if isFloat t then
      floatSizes.${t.tag}
    else
      sizeOf t;

  alignUp = n: a: div (n + a - 1) a * a;

  # long long (8 bytes) as a scalar or array element; struct members are checked when the
  # struct is defined.
  hasLLong = t: if isArray t then hasLLong t.of else t.tag == "llong";

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
      # Hexadecimal and octal literals (and 0, whose type is int either way).
      nonDecimal = substring 0 1 n.text == "0";
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
          if nonDecimal then
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
          if nonDecimal then
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
  # A null pointer constant for a function pointer: also `(void *)0`.
  isNullFn = x: isNullConst x || x.kind == "lit" && isPtr x.type && isVoid x.type.to && x.value == 0;

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

  # Conversion as by assignment (also for arguments and return values). A function
  # pointer converts only from its own type and from a null pointer constant.
  assignConv =
    at: t: x:
    if isFnPtr t || isFnPtr x.type then
      (
        if t == x.type then
          x
        else if isFnPtr t && isNullFn x then
          mkCast t x
        else
          unsupported at "conversion from '${showType x.type}' to '${showType t}'"
      )
    else if
      (isInteger t && isInteger x.type) || (isPtr t && isPtr x.type) || (isPtr t && isNullConst x)
    then
      mkCast t x
    else
      fail at "incompatible conversion from '${showType x.type}' to '${showType t}'";

  # The operand of sizeof is not evaluated, so its side effects do not count.
  hasSideEffects =
    e:
    collect
      (
        x:
        elem (kindOf x) [
          "assign"
          "prefix"
          "postfix"
          "call"
        ]
      )
      (
        x:
        elem (kindOf x) [
          "sizeof"
          "sizeoftype"
        ]
      )
      e != [ ];

  oldOf = target: node target "old" target.type { };

  # Expression of any type (void included); arrays and structs are objects (see the header).
  ex =
    env: e:
    let
      k = e.kind;
    in
    if k == "intlit" then
      node e "lit" (litType e) { inherit (e) value; }
    else if k == "charlit" then
      litAt e tInt e.value
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
    else if k == "dot" then
      memberOf env.ctx e (ex env e.expr) e.name
    else if k == "arrow" then
      arrowExpr env e
    else if k == "addr" then
      addrExpr env e
    else if k == "sizeof" || k == "sizeoftype" then
      litAt e tUInt (sizeofValue env e)
    else if k == "prefix" || k == "postfix" then
      incDec env e
    else if k == "binary" then
      binaryExpr env e
    else if k == "cond" then
      condExpr env e
    else if k == "assign" then
      assignExpr env e
    else if k == "comma" then
      commaExpr env e
    else
      fail e "unexpected expression '${k}'";

  # Expression used for its value (void included): an array decays to a pointer to its
  # first element, and struct, union and floating-point values are unsupported.
  valueOf =
    env: e:
    let
      x = ex env e;
    in
    if isArray x.type then
      mkCast (ptrTo x.type.of) x.expr
    else if isStruct x.type then
      unsupported e "struct value"
    else if isFloat x.type then
      unsupported e "floating-point value"
    else
      x;

  # Expression whose value is used (not void).
  rv =
    env: e:
    let
      x = valueOf env e;
    in
    if isVoid x.type then fail e "void value used" else x;

  # The object of type t in memory at the data symbol sym (a file-scope variable or a
  # static local), at its address known once every variable is placed.
  objectAt =
    ctx: e: t: sym:
    node e "deref" t { expr = litAt e (ptrTo t) ctx.addrs.${sym}; };

  # A name in env.vars is a local variable, or a block-scope `extern` or `static` variable
  # ({ name; type; object; } with object its data symbol).
  identExpr =
    env: e:
    let
      inherit (env) ctx;
      name = e.name;
    in
    if hasAttr name env.vars then
      let
        v = env.vars.${name};
      in
      if v ? object then objectAt ctx e v.type v.object else node e "var" v.type { var = v; }
    else if hasAttr name ctx.consts then
      litAt e ctx.consts.${name}.type ctx.consts.${name}.value
    else if hasAttr name ctx.globals then
      objectAt ctx e ctx.globals.${name}.type name
    else if hasAttr name env.funcs then
      unsupported e "function '${name}' used as a value"
    else
      fail e "use of undeclared identifier '${name}'";

  # Whether the signature f has a floating-point parameter or return value.
  sigHasFloat = f: isFloat f.ret || any isFloat f.params;

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
      objType = env.vars.${e.name}.type or env.ctx.globals.${e.name}.type or null;
    in
    if hasAttr e.name env.vars || hasAttr e.name env.ctx.globals || hasAttr e.name env.ctx.consts then
      if objType != null && isFnPtr objType then
        unsupported e "call through the function pointer '${e.name}'"
      else
        fail e "called object '${e.name}' is not a function"
    else if !hasAttr e.name env.funcs then
      fail e "call to undeclared function '${e.name}'"
    else if f.variadic then
      unsupported e "call to the variadic function '${e.name}'"
    else if sigHasFloat f then
      unsupported e "call to a function with a floating-point parameter or return value"
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
      t = resolveType env e e.type;
      x = valueOf env e.expr;
    in
    if isAggregate t then
      fail e "used type '${showType t}' where arithmetic or pointer type is required"
    else if isVoid t then
      node e "cast" t { expr = x; }
    else if isVoid x.type then
      fail e.expr "void value used"
    else if isFloat t then
      unsupported e "conversion to '${showType t}'"
    else if (isFnPtr t || isFnPtr x.type) && t != x.type && !(isFnPtr t && isNullFn x) then
      unsupported e "cast from '${showType x.type}' to '${showType t}'"
    else
      mkCast t x;

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

  # The object p points to: a scalar read, or an array or struct object.
  derefOf =
    at: p:
    let
      t = p.type.to;
    in
    if !isPtr p.type then
      fail at "indirection requires a pointer operand ('${showType p.type}' invalid)"
    else if t.tag == "fn" then
      unsupported at "dereference of a function pointer"
    else if isVoid t then
      fail at "dereference of a 'void *' pointer"
    else if isScalar t && sizeOf t == 8 then
      unsupported at "8-byte memory access"
    else
      node at "deref" t { expr = p; };

  # p +/- i for the pointer p and the integer i. A constant address plus or minus a
  # constant is folded (unsigned, modulo 2^32).
  ptrAdd =
    ctx: at: op: p: i:
    let
      t = p.type.to;
      size = sizeOfT ctx t;
      index = mkCast (promote i.type) i;
    in
    if isVoid t then
      fail at "arithmetic on a pointer to void"
    else if !isComplete ctx t then
      fail at "arithmetic on a pointer to an incomplete type '${showType t}'"
    else if p.kind == "lit" && index.kind == "lit" then
      litAt at p.type ((if op == "+" then B.add else B.sub) p.value (index.value * size))
    else
      node at "ptradd" p.type {
        inherit op index size;
        ptr = p;
      };

  # The pointer p advanced by offset bytes, as a pointer of type pt (member addresses).
  addBytes =
    at: pt: p: offset:
    if offset == 0 then
      mkCast pt p
    else if p.kind == "lit" then
      litAt at pt (B.add p.value offset)
    else
      node at "ptradd" pt {
        op = "+";
        ptr = p;
        index = litAt at tInt offset;
        size = 1;
      };

  indexExpr =
    env: e:
    let
      b = rv env e.base;
      i = rv env e.index;
    in
    if isPtr b.type && isInteger i.type then
      derefOf e (ptrAdd env.ctx e "+" b i)
    else if isInteger b.type && isPtr i.type then
      derefOf e (ptrAdd env.ctx e "+" i b)
    else
      fail e "subscripted value is not a pointer";

  # The member name of the struct object x (a "deref" node of struct type).
  memberOf =
    ctx: at: x: name:
    let
      t = x.type;
      layout = ctx.structs.${t.name};
      f = layout.byName.${name};
    in
    if !isStruct t then
      fail at "member reference base type '${showType t}' is not a structure"
    else if !hasAttr t.name ctx.structs then
      fail at "incomplete definition of type '${showType t}'"
    else if !hasAttr name layout.byName then
      fail at "no member named '${name}' in '${showType t}'"
    else
      node at "deref" f.type (
        {
          expr = addBytes at (ptrTo f.type) x.expr f.offset;
        }
        // (if f ? bitfield then { bitfield = true; } else { })
      );

  arrowExpr =
    env: e:
    let
      p = rv env e.expr;
    in
    if !isPtr p.type then
      fail e "member reference type '${showType p.type}' is not a pointer"
    else
      memberOf env.ctx e (node e "deref" p.type.to { expr = p; }) e.name;

  # &x: the address of an object in memory. Locals are not in memory.
  addrExpr =
    env: e:
    let
      x = ex env e.expr;
    in
    if x ? bitfield then
      fail e "address of a bit-field requested"
    else if x.kind == "deref" then
      mkCast (ptrTo x.type) x.expr
    else if x.kind == "var" then
      unsupported e "address of a local variable"
    else
      fail e "cannot take the address of an rvalue of type '${showType x.type}'";

  # sizeof of the type or expression of the "sizeof" or "sizeoftype" node n (the
  # expression is typed, not evaluated).
  sizeofValue =
    env: n:
    let
      x = ex env n.expr;
      t = if n.kind == "sizeoftype" then resolveType env n n.type else x.type;
    in
    if n.kind == "sizeof" && x ? bitfield then
      fail n "invalid application of 'sizeof' to a bit-field"
    else if isVoid t then
      fail n "invalid application of 'sizeof' to a void type"
    else if !isComplete env.ctx t then
      fail n "invalid application of 'sizeof' to an incomplete type '${showType t}'"
    else
      sizeOfT env.ctx t;

  # `c ? a : b`: the branches converted to their common type.
  condExpr =
    env: e:
    let
      c = rv env e.cond;
      a = rv env e.thenExpr;
      b = rv env e.elseExpr;
      ta = a.type;
      tb = b.type;
      t =
        if isInteger ta && isInteger tb then
          usual ta tb
        else if isPtr ta && ta == tb then
          ta
        else if isPtr ta && isNullConst b then
          ta
        else if isNullConst a && isPtr tb then
          tb
        else
          fail e "incompatible operand types ('${showType ta}' and '${showType tb}') in '?:'";
      x = mkCast t a;
      y = mkCast t b;
    in
    if hasSideEffects e.thenExpr || hasSideEffects e.elseExpr then
      unsupported e "side effect in a branch of '?:'"
    else if isIntLit c && isIntLit x && isIntLit y then
      (if c.value != 0 then x else y) // { inherit (e) line col; }
    else
      node e "cond" t {
        cond = c;
        thenExpr = x;
        elseExpr = y;
      };

  # Typing of the binary operator op (not && or ||) on the typed operands a and b; ctx
  # gives the sizes for pointer arithmetic (null where only integers occur).
  typeBinary =
    ctx: at: op: a: b:
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
        else if amount.kind == "lit" && sizeOf t == 8 && (amount.value < 0 || amount.value >= 64) then
          unsupported at "shift of a 64-bit value by ${toString amount.value}"
        else if amount.kind == "lit" && sizeOf t == 8 && op == "<<" && amount.value == 63 then
          # 2^63 is not a Nix integer.
          unsupported at "left shift of a 64-bit value by 63"
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
        ptrAdd ctx at "+" a b
      else if isInteger ta && isPtr tb then
        ptrAdd ctx at "+" b a
      else
        invalid
    else if op == "-" then
      if ints then
        arith (usual ta tb)
      else if isPtr ta && isInteger tb then
        ptrAdd ctx at "-" a b
      else if isPtr ta && ta == tb && isComplete ctx ta.to then
        node at "ptrdiff" tInt {
          lhs = a;
          rhs = b;
          size = sizeOfT ctx ta.to;
        }
      else
        invalid
    else if op == "<<" || op == ">>" then
      if ints then shift else invalid
    else if isFnPtr ta || isFnPtr tb then
      fnPtrCmp at op a b
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

  # `==` and `!=` (anything else is unsupported) where an operand is a function pointer:
  # with the same type, or with a null pointer constant.
  fnPtrCmp =
    at: op: a: b:
    let
      ta = a.type;
      tb = b.type;
      cmp =
        x: y:
        node at "cmp" tInt {
          inherit op;
          lhs = x;
          rhs = y;
        };
    in
    if op != "==" && op != "!=" then
      unsupported at "relational comparison of function pointers"
    else if ta == tb then
      cmp a b
    else if isFnPtr ta && isNullFn b then
      cmp a (mkCast ta b)
    else if isNullFn a && isFnPtr tb then
      cmp (mkCast tb a) b
    else
      unsupported at "comparison of '${showType ta}' and '${showType tb}'";

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
      typeLogical e e.op (rv env e.lhs) (rv env e.rhs)
    else
      typeBinary env.ctx e e.op (rv env e.lhs) (rv env e.rhs);

  # `a, b`: a for its side effects, then b, whose value and type the expression has.
  commaExpr =
    env: e:
    let
      b = valueOf env e.rhs;
    in
    node e "comma" b.type {
      lhs = valueOf env e.lhs;
      rhs = b;
    };

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
  # Optionally, resolve : node -> type -> type resolves the type of a cast (enum types);
  # without it, cast types are used as written.
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
      constCast e (if hooks ? resolve then hooks.resolve e e.type else e.type) (sub e.expr)
    else if k == "unary" then
      typeUnary e e.op (sub e.expr)
    else if k == "binary" then
      (if e.op == "&&" || e.op == "||" then typeLogical else typeBinary null) e e.op (sub e.lhs) (
        sub e.rhs
      )
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
    e: t: x:
    if !isInteger t || !isIntLit x then
      fail e "expression is not an integer constant expression"
    else
      mkCast t x;

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
    if isArray x.type then
      fail e "array type '${showType x.type}' is not assignable"
    else if isStruct x.type then
      unsupported e "struct assignment"
    else if isFloat x.type then
      unsupported e "floating-point value"
    else if x.kind == "var" || x.kind == "deref" then
      x
    else
      fail e "expression is not assignable";

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
          assignConv e target.type (typeBinary env.ctx e op (oldOf target) rhs);
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
      value = assignConv e target.type (typeBinary env.ctx e op (oldOf target) one);
      post = e.kind == "postfix";
    };

  # ---- Statements ----

  # env: { vars; local; funcs; ret; jumps; ctx; } with vars and local keyed by the C name
  # (local: the names declared in the innermost block), funcs the function signatures, ret
  # the return type of the current function, jumps = { break; continue; } whether break and
  # continue have a target here, and ctx the file-scope context (see checkItems).
  enterBlock = env: env // { local = { }; };

  # env for the body of a loop, and of a switch.
  inLoop =
    env:
    env
    // {
      jumps = {
        break = true;
        continue = true;
      };
    };
  inSwitch =
    env:
    env
    // {
      jumps = env.jumps // {
        break = true;
      };
    };

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

  # Check the statement n. -> { node (null when nothing is left); env; }
  stmt =
    env: n:
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
      at { items = blockItems (enterBlock env) n.items; }
    else if k == "decl" then
      declStmt env n
    else if k == "expr" then
      at { expr = valueOf env n.expr; }
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
        body = sub (inLoop env) n.body;
      }
    else if k == "do" then
      at {
        body = sub (inLoop env) n.body;
        cond = rv env n.cond;
      }
    else if k == "for" then
      forStmt env n
    else if k == "return" then
      returnStmt env n
    else if k == "break" then
      if env.jumps.break then at { } else fail n "'break' statement not in loop or switch statement"
    else if k == "continue" then
      if env.jumps.continue then at { } else fail n "'continue' statement not in loop statement"
    else if k == "switch" then
      switchStmt env n
    else if k == "case" || k == "default" then
      unsupported n "'${k}' label not directly in the body of a 'switch'"
    else
      fail n "unexpected statement '${k}'";

  # A statement that is the body or branch of another one (never null).
  sub =
    env: n:
    let
      r = stmt env n;
    in
    if r.node == null then
      {
        kind = "block";
        items = [ ];
        inherit (n) line col;
      }
    else
      r.node;

  # A block-scope declaration: local variables (the typed node's vars), static locals
  # (statics, see staticVar), block-scope extern variables (externs, see externVar),
  # function declarations, and struct, union and enum definitions, each in scope from its
  # declarator on.
  declStmt =
    env: n:
    let
      step =
        acc: d:
        let
          k = d.kind;
          storage = d.storage or null;
        in
        if k == "typedef" then
          acc
        else if k == "struct" || k == "union" then
          withEnv acc (defineLocalStruct acc.env d)
        else if k == "enum" then
          withEnv acc (defineLocalEnum acc.env d)
        else if k == "proto" then
          withEnv acc (declareLocalFunc acc.env d)
        else if storage == "extern" then
          let
            r = externVar acc.env d;
          in
          acc
          // {
            inherit (r) env;
            externs = acc.externs ++ [ r.extern ];
          }
        else if storage == "static" then
          let
            r = staticVar acc.env d;
          in
          acc
          // {
            inherit (r) env;
            statics = acc.statics ++ [ r.static ];
          }
        else
          let
            t = resolveType acc.env d d.type;
            # The scope of a name starts after its declarator, so the initializer sees it.
            r = declare acc.env d d.name t;
            init = if d.init == null then null else assignConv d.init t (rv r.env d.init);
          in
          if isArray t then
            unsupported d "local array"
          else if isStruct t then
            unsupported d "local struct variable"
          else if isFloat t then
            unsupported d "floating-point variable"
          else
            acc
            // {
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
        statics = [ ];
        externs = [ ];
      } n.decls;
    in
    {
      node =
        if r.vars == [ ] && r.statics == [ ] && r.externs == [ ] then
          null
        else
          {
            kind = "decl";
            inherit (r) vars;
            inherit (n) line col;
          }
          // (if r.statics == [ ] then { } else { inherit (r) statics; })
          // (if r.externs == [ ] then { } else { inherit (r) externs; });
      inherit (r) env;
    };

  # acc with the env e, which is forced so that its declaration is checked even when
  # nothing reads it.
  withEnv = acc: e: builtins.seq e (acc // { env = e; });

  # Fails unless name is new in the innermost block of env.
  checkLocal =
    env: at: name:
    !(hasAttr name env.local) || fail at "redefinition of '${name}'";

  # env with name bound to the object of type t at the data symbol sym (see identExpr).
  bindObject =
    env: name: t: sym:
    env
    // {
      vars = env.vars // {
        ${name} = {
          inherit name;
          type = t;
          object = sym;
        };
      };
      local = env.local // {
        ${name} = true;
      };
    };

  # A block-scope `extern` variable: the file-scope variable of the same name, which must
  # be defined in the input with a compatible type (checked at the end, see checkWith).
  # -> { env; extern = { name; type; line; col; }; }
  externVar =
    env: d:
    let
      name = d.name;
      t = resolveType env d d.type;
      prev = env.ctx.globals.${name} or null;
      type = if prev != null && isComplete env.ctx prev.type then prev.type else t;
    in
    builtins.seq (checkLocal env d name) (
      if isVoid t then
        fail d "variable '${name}' has type 'void'"
      else if hasAttr name env.funcs then
        fail d "redefinition of '${name}' as a different kind of symbol"
      else if prev != null && !compatible prev.type t then
        fail d "redeclaration of '${name}' with a different type"
      else
        builtins.deepSeq t {
          env = bindObject env name type name;
          extern = {
            inherit name;
            type = t;
            inherit (d) line col;
          };
        }
    );

  # A static local: a variable at a fixed address in the data, placed after the file-scope
  # variables (see checkItems), with the data symbol `<function>'<name>'<line>'<col>`
  # (not a C identifier). Its type and initializer follow the rules of file-scope
  # variables. -> { env; static = { sym; size; align; line; col; writesAt; }; } with
  # writesAt the initial stores at a given address.
  staticVar =
    env: d:
    let
      name = d.name;
      sym = "${env.fn}'${name}'${toString d.line}'${toString d.col}";
      t0 = resolveType env d d.type;
      # The initializer sees the variable itself.
      env' = bindObject env name t sym;
      t = sizedType env' d t0;
    in
    builtins.seq (checkLocal env d name) (
      if isVoid t0 then
        fail d "variable '${name}' has type 'void'"
      else if hasLLong t0 then
        unsupported d "8-byte integer in a static variable"
      else if hasFloat t0 then
        unsupported d "floating-point variable"
      else if isArray t && t.len == null then
        unsupported d "array '${name}' without a length"
      else if !isComplete env.ctx t then
        fail d "variable '${name}' has incomplete type '${showType t}'"
      else
        builtins.deepSeq t {
          env = env';
          static = {
            inherit sym;
            size = sizeOfT env.ctx t;
            align = alignOfT env.ctx t;
            inherit (d) line col;
            writesAt = addr: if d.init == null then [ ] else initWrites env' t addr d.init;
          };
        }
    );

  # A block-scope function declaration: the function of the same name in the translation
  # unit, in scope to the end of the block. Its calls are checked against the file-scope
  # declarations at the end (see checkWith).
  declareLocalFunc =
    env: d:
    let
      name = d.name;
      sig = sigOf env d;
      prev = env.funcs.${name} or null;
    in
    if env.local.${name} or "function" != "function" || hasAttr name env.ctx.globals then
      fail d "redefinition of '${name}' as a different kind of symbol"
    else if prev != null && !sameSig prev sig then
      fail d "conflicting types for '${name}'"
    else
      builtins.deepSeq sig (
        env
        // {
          funcs = env.funcs // {
            ${name} = sig // {
              defined = prev != null && prev.defined;
            };
          };
          vars = removeAttrs env.vars [ name ];
          local = env.local // {
            ${name} = "function";
          };
          ctx = env.ctx // {
            consts = removeAttrs env.ctx.consts [ name ];
          };
        }
      );

  # The tag key in env.local of a block-scope struct, union or enum tag (not an
  # identifier, so it does not clash with ordinary names).
  tagKey = name: "tag ${name}";

  # The internal name of a block-scope tag defined at the node n: the tag with its
  # position, unique in the translation unit.
  localTagName = n: "${n.name}@${toString n.line}:${toString n.col}";

  # env with the tag of the definition n bound to the internal name.
  bindTag =
    env: n: internal:
    if hasAttr (tagKey n.name) env.local then
      fail n "redefinition of '${n.kind} ${n.name}'"
    else
      env
      // {
        local = env.local // {
          ${tagKey n.name} = true;
        };
        ctx = env.ctx // {
          tags = env.ctx.tags // {
            ${n.name} = internal;
          };
        };
      };

  # A block-scope struct or union definition: its tag hides an outer one up to the end of
  # the block. The tag is in scope in its own members.
  defineLocalStruct =
    env: n:
    let
      internal = localTagName n;
      env1 = bindTag env n internal;
      layout = structLayout env1 n;
    in
    builtins.deepSeq layout (
      env1
      // {
        ctx = env1.ctx // {
          structs = env1.ctx.structs // {
            ${internal} = layout;
          };
        };
      }
    );

  # A block-scope enum definition: its enumerators (int constants, as at file scope) and
  # its tag hide outer ones up to the end of the block.
  defineLocalEnum =
    env: n:
    let
      internal = localTagName n;
      step =
        st: c:
        let
          e = st.env;
          v = if c.value == null then st.next else (constExpr (hooksOf e) c.value).value;
        in
        builtins.seq (checkLocal e c c.name) (
          if v < s32.lo || v > s32.hi then
            unsupported c "enumerator value ${toString v} outside the range of int"
          else
            {
              env = e // {
                vars = removeAttrs e.vars [ c.name ];
                local = e.local // {
                  ${c.name} = true;
                };
                ctx = e.ctx // {
                  consts = e.ctx.consts // {
                    ${c.name} = {
                      type = tInt;
                      value = v;
                    };
                  };
                };
              };
              next = v + 1;
              negative = st.negative || v < 0;
            }
        );
      r = foldl' step {
        inherit env;
        next = 0;
        negative = false;
      } n.consts;
      env1 = bindTag r.env n internal;
    in
    env1
    // {
      ctx = env1.ctx // {
        enums = env1.ctx.enums // {
          ${internal} = if r.negative then tInt else tUInt;
        };
      };
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
          if any (d: d.kind == "proto" || (d.storage or null) != null) n.init.decls then
            fail n.init "declaration of a non-local variable in a 'for' loop"
          else
            declStmt fenv n.init
        else
          {
            node = {
              kind = "expr";
              expr = valueOf fenv n.init;
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
        step = if n.step == null then null else valueOf ienv n.step;
        body = sub (inLoop ienv) n.body;
        inherit (n) line col;
      };
      inherit env;
    };

  returnStmt =
    env: n:
    let
      isVoidFn = isVoid env.ret;
    in
    if isVoidFn && n.expr != null then
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

  # Items of a block, checked in order.
  blockItems =
    env: items:
    let
      step =
        acc: n:
        let
          r = stmt acc.env n;
        in
        {
          inherit (r) env;
          nodes = acc.nodes ++ (if r.node == null then [ ] else [ r.node ]);
        };
    in
    (foldl' step {
      inherit env;
      nodes = [ ];
    } items).nodes;

  # `switch` (see the header). The labels are taken from the items of the body block; a
  # label anywhere else is unsupported (stmt).
  switchStmt =
    env: n:
    let
      c = rv env n.cond;
      t = promote c.type;
      body = n.body;
      r = foldl' (switchItem t) {
        env = inSwitch (enterBlock env);
        skipped = [ ];
        sections = [ ];
        cases = [ ];
        default = null;
      } body.items;
    in
    if !isInteger c.type then
      fail n.cond "statement requires expression of integer type ('${showType c.type}' invalid)"
    else if body.kind != "block" then
      unsupported body "'switch' body that is not a compound statement"
    else
      {
        node = {
          kind = "switch";
          cond = mkCast t c;
          inherit (r)
            skipped
            sections
            cases
            default
            ;
          inherit (n) line col;
        };
        inherit env;
      };

  # One item of a switch body (acc as in switchStmt): its labels start a new section, and
  # its statement joins the last section (or skipped, before the first label).
  switchItem =
    t: acc: item:
    let
      l = unlabel item;
      opened = if l.labels == [ ] then acc.sections else acc.sections ++ [ [ ] ];
      index = length opened - 1;
      labelled = foldl' (addLabel acc.env t index) acc l.labels;
      r = stmt acc.env l.stmt;
      nodes = if r.node == null then [ ] else [ r.node ];
    in
    labelled
    // {
      inherit (r) env;
      skipped = if opened == [ ] then acc.skipped ++ nodes else acc.skipped;
      sections = genList (i: elemAt opened i ++ (if i == index then nodes else [ ])) (length opened);
    };

  # The case and default labels in front of the statement n, and that statement.
  # -> { labels; stmt; }
  unlabel =
    n:
    if n.kind == "case" || n.kind == "default" then
      let
        r = unlabel n.stmt;
      in
      {
        labels = [ n ] ++ r.labels;
        inherit (r) stmt;
      }
    else
      {
        labels = [ ];
        stmt = n;
      };

  # The label (a case or default node) of the section index added to acc; a case value is
  # converted to t, the promoted type of the controlling expression.
  addLabel =
    env: t: index: acc: label:
    let
      v = (mkCast t (constExpr (hooksOf env) label.value)).value;
    in
    if label.kind == "default" then
      if acc.default != null then
        fail label "multiple default labels in one switch"
      else
        acc // { default = index; }
    else if any (x: x.value == v) acc.cases then
      fail label "duplicate case value '${toString v}'"
    else
      acc
      // {
        cases = acc.cases ++ [
          {
            value = v;
            section = index;
          }
        ];
      };

  # ---- Type resolution ----

  # The parsed type t resolved in env (see the header): array lengths evaluated, enum types
  # replaced by their compatible integer type, the tags of block-scope definitions by their
  # internal names, and function types resolved with their parameters adjusted.
  resolveType =
    env: at: t:
    if t.tag == "ptr" then
      ptrTo (resolveType env at t.to)
    else if t.tag == "array" then
      resolveArray env at t
    else if t.tag == "enum" then
      env.ctx.enums.${tagName env t} or (fail at "incomplete enum type 'enum ${t.name}'")
    else if isStruct t then
      resolveRecord env at t
    else if t.tag == "fn" then
      {
        tag = "fn";
        ret = resolveType env at t.ret;
        params = map (p: adjustParam (resolveType env p p.type)) t.params;
        inherit (t) variadic;
      }
    else
      t;

  # The name a struct, union or enum tag stands for in env.
  tagName = env: t: env.ctx.tags.${t.name} or t.name;

  resolveRecord =
    env: at: t:
    let
      name = tagName env t;
      layout = env.ctx.structs.${name} or null;
    in
    if layout != null && layout.kind != t.tag then
      fail at "use of '${t.name}' with tag type that does not match previous declaration"
    else if name == t.name then
      t
    else
      t // { inherit name; };

  # A parameter of array type is a pointer to its element, and one of function type a
  # pointer to the function.
  adjustParam =
    t:
    if isArray t then
      ptrTo t.of
    else if t.tag == "fn" then
      ptrTo t
    else
      t;

  resolveArray =
    env: at: t:
    let
      of = resolveType env at t.of;
      len = if t.len == null then null else (constExpr (hooksOf env) t.len).value;
    in
    if !isComplete env.ctx of then
      fail at "array has incomplete element type '${showType of}'"
    else if len != null && len < 0 then
      fail t.len "array has a negative size"
    else if len == 0 then
      unsupported t.len "zero-length array"
    else
      {
        tag = "array";
        inherit of len;
      };

  # The constant expression hooks in env: enum constants not hidden by a local, sizeof,
  # and the types of casts.
  hooksOf = env: {
    ident = name: if hasAttr name env.vars then null else env.ctx.consts.${name} or null;
    sizeOf = sizeofValue env;
    resolve = resolveType env;
  };

  # ---- Functions ----

  # Signature of a proto or func: the resolved return and parameter types, with parameter
  # arrays and functions adjusted to pointers (adjustParam), and whether it is variadic.
  sigOf =
    env: item:
    let
      ret = resolveType env item item.ret;
      param =
        p:
        let
          t = resolveType env p p.type;
        in
        if isStruct t then unsupported p "struct parameter passed by value" else adjustParam t;
    in
    if isArray ret then
      fail item "function cannot return array type '${showType ret}'"
    else if isStruct ret then
      unsupported item "struct returned by value"
    else
      {
        inherit ret;
        params = map param item.params;
        variadic = item.variadic or false;
      };

  sameSig = a: b: a.ret == b.ret && a.params == b.params && a.variadic == b.variadic;

  funcDef =
    env: sig: f:
    let
      step =
        acc: i:
        let
          p = elemAt f.params i;
          r = declare acc.env p p.name (elemAt sig.params i);
        in
        {
          inherit (r) env;
          vars = acc.vars ++ [ r.var ];
        };
      ps = foldl' step {
        env = env // {
          inherit (sig) ret;
          fn = f.name;
        };
        vars = [ ];
      } (genList (i: i) (length f.params));
      items = blockItems ps.env f.body.items;
    in
    if sigHasFloat sig then
      unsupported f "definition of a function with a floating-point parameter or return value"
    else
      {
        inherit (f)
          name
          line
          col
          ;
        inherit (sig) ret;
        params = ps.vars;
        body = {
          kind = "block";
          inherit items;
          inherit (f.body) line col;
        };
      };

  # ---- File scope ----
  # The items are checked in order with the accumulator
  #   acc = { funcs; defs; ctx; size; objects; }
  # funcs: the function signatures by name ({ ret; params; defined; }); defs: the typed
  # function definitions; size: the bytes placed so far; objects: the placed variables
  # ([ { name; addr; writes; } ], writes as the inits of the data). The file-scope context
  #   ctx = { structs; enums; consts; globals; addrs; }
  # holds the struct layouts by tag (see "Objects"), the enum types by tag, the enumerators
  # by name ({ type; value; }), the variables by name ({ type; defined; hasInit; at; }) and the
  # addresses of all defined variables by name, taken from the end of the fold (an extern
  # declaration may precede the definition that places the variable).

  fileEnv = acc: {
    vars = { };
    local = { };
    ret = null;
    fn = null;
    jumps = {
      break = false;
      continue = false;
    };
    inherit (acc) funcs ctx;
  };

  withCtx = acc: fields: acc // { ctx = acc.ctx // fields; };

  # What the file-scope name is declared as so far, or null.
  declaredAs =
    acc: name:
    if hasAttr name acc.funcs then
      "function"
    else if hasAttr name acc.ctx.globals then
      "variable"
    else if hasAttr name acc.ctx.consts then
      "enumerator"
    else
      null;

  # Fails unless the file-scope name is new or already declared as kind.
  checkKind =
    acc: at: name: kind:
    let
      k = declaredAs acc name;
    in
    k == null || k == kind || fail at "redefinition of '${name}' as a different kind of symbol";

  itemStep =
    dataBase: acc: item:
    let
      k = item.kind;
    in
    if k == "typedef" then
      acc
    else if k == "struct" || k == "union" then
      defineStruct acc item
    else if k == "enum" then
      defineEnum acc item
    else if k == "global" then
      declareGlobal dataBase acc item
    else
      funcItem acc item;

  funcItem =
    acc: item:
    let
      env = fileEnv acc;
      sig = sigOf env item;
      prev = acc.funcs.${item.name} or null;
      isDef = item.kind == "func";
      funcs = acc.funcs // {
        ${item.name} = sig // {
          defined = isDef || (prev != null && prev.defined);
        };
      };
    in
    builtins.seq (checkKind acc item item.name "function") (
      if prev != null && !sameSig prev sig then
        fail item "conflicting types for '${item.name}'"
      else if isDef && prev != null && prev.defined then
        fail item "redefinition of '${item.name}'"
      else
        builtins.deepSeq sig (
          acc
          // {
            inherit funcs;
            defs = acc.defs ++ (if isDef then [ (funcDef (env // { inherit funcs; }) sig item) ] else [ ]);
          }
        )
    );

  # ---- Structs and enums ----

  defineStruct =
    acc: n:
    let
      layout = structLayout (fileEnv acc) n;
    in
    if hasAttr n.name acc.ctx.structs then
      fail n "redefinition of '${n.kind} ${n.name}'"
    else
      builtins.deepSeq layout (
        withCtx acc {
          structs = acc.ctx.structs // {
            ${n.name} = layout;
          };
        }
      );

  # The layout of the struct or union definition n, as clang's ilp32 ABI lays it out. A
  # struct has its members at increasing offsets, each aligned for its type; a union has
  # every member at offset 0. Either aligns to its most aligned member and its size is
  # padded to a multiple of that. A packed one aligns every member, and itself, to 1.
  # Bit-fields: see bitField.
  structLayout =
    env: n:
    let
      inherit (env) ctx;
      isUnion = n.kind == "union";
      packed = n.packed or false;
      step =
        acc: f:
        let
          t = resolveType env f f.type;
          isBit = (f.width or null) != null;
          bit = bitField env acc f t;
          a = if packed then 1 else alignOfT ctx t;
          type = if isBit then bit.type else t;
          offset =
            if isUnion then
              0
            else if isBit then
              acc.size
            else
              alignUp acc.size a;
          field = {
            inherit (f) name;
            inherit type offset;
          }
          // (if isBit then { bitfield = true; } else { });
          end = offset + sizeOfT ctx type;
        in
        if hasAttr f.name acc.byName then
          fail f "duplicate member '${f.name}'"
        else if isArray t && t.len == null then
          unsupported f "flexible array member"
        else if !isComplete ctx t then
          fail f "field '${f.name}' has incomplete type '${showType t}'"
        else if hasLLong t then
          unsupported f "8-byte integer in a struct"
        else if isBit && isUnion then
          unsupported f "bit-field in a union"
        else if !isBit && acc.run != 0 then
          unsupported acc.runAt "bit-fields that do not fill their declared type"
        else
          {
            size = if isUnion && acc.size > end then acc.size else end;
            align = if a > acc.align then a else acc.align;
            fields = acc.fields ++ [ field ];
            byName = acc.byName // {
              ${f.name} = field;
            };
            run = if isBit then bit.run else 0;
            runType = if isBit then t else null;
            runAt = f;
          };
      r = foldl' step {
        size = 0;
        align = 1;
        fields = [ ];
        byName = { };
        run = 0;
        runType = null;
        runAt = null;
      } n.members;
    in
    if r.run != 0 then
      unsupported r.runAt "bit-fields that do not fill their declared type"
    else
      {
        inherit (n) kind;
        inherit (r) align fields byName;
        size = alignUp r.size r.align;
      };

  # The bit-field f of the declared type t (resolved), placed after the members in acc (see
  # structLayout). Only named bit-fields of an unsigned type (not plain char, not an enum)
  # whose width w is 8, 16 or 32 are supported, each starting at a multiple of w bits, where
  # consecutive bit-fields of the same declared type fill it exactly (acc.run counts the
  # bits filled so far). Such a bit-field lies where clang places it, and it is read and
  # written as an unsigned member of w bits (as t when w is 32); its declared type gives the
  # alignment of the struct. -> { type; run; }
  bitField =
    env: acc: f: t:
    let
      w = (constExpr (hooksOf env) f.width).value;
      bits = 8 * sizeOf t;
      prev = if acc.runType == t then acc.run else 0;
      used = prev + w;
    in
    if f.type.tag == "enum" then
      unsupported f "bit-field of enum type"
    else if !isInteger t then
      fail f "bit-field '${f.name}' has non-integral type '${showType t}'"
    else
      builtins.seq w (
        if
          !elem t.tag [
            "uchar"
            "ushort"
            "uint"
            "ulong"
          ]
        then
          unsupported f "bit-field of type '${showType t}'"
        else if w < 0 then
          fail f.width "bit-field '${f.name}' has negative width"
        else if w > bits then
          fail f.width "width of bit-field '${f.name}' exceeds its type"
        else if w == 0 then
          fail f.width "named bit-field '${f.name}' has zero width"
        else if
          !elem w [
            8
            16
            32
          ]
        then
          unsupported f.width "bit-field of width ${toString w}"
        else if acc.run != 0 && acc.runType != t then
          unsupported acc.runAt "bit-fields that do not fill their declared type"
        else if bitAnd acc.size (div w 8 - 1) != 0 then
          unsupported f "bit-field that does not start at a multiple of its width"
        else if used > bits then
          unsupported f "bit-fields that do not fill their declared type"
        else
          {
            type =
              if w == 32 then
                t
              else if w == 16 then
                ty "ushort"
              else
                ty "uchar";
            run = if used == bits then 0 else used;
          }
      );

  # Enumerators are int constants: the given value, or one more than the previous one (0
  # for the first). Each is in scope from the next one on.
  defineEnum =
    acc: n:
    let
      step =
        st: c:
        let
          v = if c.value == null then st.next else (constExpr (hooksOf (fileEnv st.acc)) c.value).value;
        in
        if declaredAs st.acc c.name != null then
          fail c "redefinition of '${c.name}'"
        else if v < s32.lo || v > s32.hi then
          unsupported c "enumerator value ${toString v} outside the range of int"
        else
          {
            acc = withCtx st.acc {
              consts = st.acc.ctx.consts // {
                ${c.name} = {
                  type = tInt;
                  value = v;
                };
              };
            };
            next = v + 1;
            negative = st.negative || v < 0;
          };
      r = foldl' step {
        inherit acc;
        next = 0;
        negative = false;
      } n.consts;
    in
    if hasAttr n.name acc.ctx.enums then
      fail n "redefinition of 'enum ${n.name}'"
    else
      withCtx r.acc {
        enums = r.acc.ctx.enums // {
          ${n.name} = if r.negative then tInt else tUInt;
        };
      };

  # ---- File-scope variables ----

  # Two declarations of a variable agree: the same type, or arrays of the same element
  # type where one has no length.
  compatible =
    a: b: a == b || (isArray a && isArray b && a.of == b.of && (a.len == null || b.len == null));

  withGlobal =
    acc: name: g:
    withCtx acc {
      globals = acc.ctx.globals // {
        ${name} = g;
      };
    };

  # A declaration without an initializer and with `extern` only declares; anything else
  # defines (and places) the variable. `static` changes nothing (one translation unit).
  declareGlobal =
    dataBase: acc: g:
    let
      name = g.name;
      t = resolveType (fileEnv acc) g g.type;
      prev = acc.ctx.globals.${name} or null;
      isDef = g.storage != "extern" || g.init != null;
      keep = prev != null && (prev.defined || isComplete acc.ctx prev.type);
    in
    builtins.seq (checkKind acc g name "variable") (
      if isVoid t then
        fail g "variable '${name}' has type 'void'"
      else if hasLLong t then
        unsupported g "8-byte integer in a global variable"
      else if isDef && hasFloat t then
        unsupported g "floating-point variable"
      else if prev != null && !compatible prev.type t then
        fail g "redefinition of '${name}' with a different type"
      else if !isDef then
        builtins.deepSeq t (
          withGlobal acc name {
            type = if keep then prev.type else t;
            defined = prev != null && prev.defined;
            hasInit = prev != null && prev.hasInit;
            at = if prev != null then prev.at else { inherit (g) line col; };
          }
        )
      else if prev != null && prev.defined then
        (
          if prev.hasInit && g.init != null then
            fail g "redefinition of '${name}'"
          else
            unsupported g "second definition of '${name}'"
        )
      else
        # An earlier declaration may give the length the definition leaves out.
        defineGlobal dataBase acc g (if keep then prev.type else sizedType (fileEnv acc) g t)
    );

  # The type of a defined variable: an array without a length takes it from its
  # initializer list.
  sizedType =
    env: g: t:
    if isArray t && t.len == null && g.init != null && g.init.kind == "initlist" then
      t // { len = (fillFrom env t 0 g.init.items 0).count; }
    else
      t;

  # Place the variable g of type t after the ones placed so far.
  defineGlobal =
    dataBase: acc: g: t:
    let
      name = g.name;
      offset = alignUp acc.size (alignOfT acc.ctx t);
      addr = dataBase + offset;
      acc' =
        withGlobal acc name {
          type = t;
          defined = true;
          hasInit = g.init != null;
          at = acc.ctx.globals.${name}.at or { inherit (g) line col; };
        }
        // {
          size = offset + sizeOfT acc.ctx t;
          objects = acc.objects ++ [
            {
              inherit name addr;
              end = addr + sizeOfT acc.ctx t;
              at = { inherit (g) line col; };
              # The initializer sees the variable itself.
              writes = if g.init == null then [ ] else initWrites (fileEnv acc') t addr g.init;
            }
          ];
        };
    in
    if isArray t && t.len == null then
      unsupported g "array '${name}' without a length"
    else if !isComplete acc.ctx t then
      fail g "variable '${name}' has incomplete type '${showType t}'"
    else
      builtins.deepSeq t acc';

  # ---- Initializers ----
  # An initializer becomes the stores of its scalars: [ { addr; size; value; } ] with value
  # in the stored unsigned form. Slots without an initializer keep the 0 of the memory.

  initWrites =
    env: t: a: x:
    if isAggregate t then
      (
        if x.kind == "initlist" then
          fillList env t a x
        else
          fail x "initializer for an array or struct must be a braced list"
      )
    else if x.kind == "initlist" then
      scalarList env t a x
    else
      [ (scalarInit env t a x) ];

  fillList =
    env: t: a: list:
    let
      r = fillFrom env t a list.items 0;
    in
    if r.i < length list.items then
      fail (elemAt list.items r.i) "excess elements in initializer"
    else
      r.writes;

  # `{ x }` for a scalar.
  scalarList =
    env: t: a: list:
    let
      x = head list.items;
    in
    if length list.items != 1 || x.kind == "initlist" then
      fail list "too many initializers or braces for a scalar"
    else
      [ (scalarInit env t a x) ];

  # The slot k of the aggregate type t: { type; offset; }.
  slotOf =
    ctx: t: k:
    if isArray t then
      {
        type = t.of;
        offset = k * sizeOfT ctx t.of;
      }
    else
      let
        f = elemAt ctx.structs.${t.name}.fields k;
      in
      {
        inherit (f) type offset;
      };

  # Number of slots of the aggregate type t; null for an array without a length.
  # A union takes one initializer, for its first member.
  slotCount =
    ctx: t:
    let
      layout = ctx.structs.${t.name};
    in
    if isArray t then
      t.len
    else if layout.kind == "union" then
      1
    else
      length layout.fields;

  # The items from index i0 assigned to the slots of t at address a in order. A nested
  # aggregate takes a braced list, or without braces as many items as it has slots.
  # -> { writes; i; count; } with i the first item left and count the slots given.
  fillFrom =
    env: t: a: items: i0:
    let
      inherit (env) ctx;
      n = slotCount ctx t;
      total = length items;
      step =
        st:
        let
          slot = slotOf ctx t st.k;
          x = elemAt items st.i;
          sa = a + slot.offset;
          r =
            if x.kind == "initlist" then
              {
                writes = initWrites env slot.type sa x;
                i = st.i + 1;
              }
            else if isAggregate slot.type then
              fillFrom env slot.type sa items st.i
            else
              {
                writes = [ (scalarInit env slot.type sa x) ];
                i = st.i + 1;
              };
        in
        if (n != null && st.k >= n) || st.i >= total then
          null
        else
          {
            node = r.writes;
            s = {
              k = st.k + 1;
              inherit (r) i;
            };
          };
      r = iterate step {
        k = 0;
        i = i0;
      };
    in
    {
      writes = concatLists r.nodes;
      inherit (r.s) i;
      count = r.s.k;
    };

  # An integer scalar takes an integer constant expression; a pointer the null pointer
  # constant or an address constant (a constant address, such as &g, &a[1], &s.m or an
  # array name, plus or minus constants).
  scalarInit =
    env: t: a: x:
    let
      size = sizeOf t;
      v = if isInteger t then (mkCast t (constExpr (hooksOf env) x)).value else constAddress env t x;
    in
    if isFloat t then
      unsupported x "floating-point initializer"
    else
      {
        addr = a;
        inherit size;
        value = bitAnd v (B.pow2 (8 * size) - 1);
      };

  constAddress =
    env: t: x:
    let
      y = assignConv x t (rv env x);
    in
    if y.kind == "lit" then y.value else fail x "initializer element is not a compile-time constant";

  # ---- Translation unit ----

  defaultDataBase = 4194304; # 0x00400000

  # The field (statics or externs) of the block-scope declarations in the statement n
  # and the statements in it, in source order. Only statements are walked: their structure
  # does not depend on the addresses of the data, which the statics determine.
  declsIn =
    field: n:
    let
      k = kindOf n;
      sub = declsIn field;
    in
    if k == "block" then
      concatMap sub n.items
    else if k == "decl" then
      n.${field} or [ ]
    else if k == "if" then
      sub n.thenStmt ++ sub n.elseStmt
    else if k == "while" || k == "do" then
      sub n.body
    else if k == "for" then
      sub n.init ++ sub n.body
    else if k == "switch" then
      concatMap sub (n.skipped ++ concatLists n.sections)
    else
      [ ];

  # The objects acc.objects followed by the static locals of the functions defs in source
  # order, each at the next offset aligned for it. -> { size; objects; }
  placeStatics =
    dataBase: acc: defs:
    foldl' (
      st: o:
      let
        offset = alignUp st.size o.align;
        addr = dataBase + offset;
      in
      {
        size = offset + o.size;
        objects = st.objects ++ [
          {
            name = o.sym;
            inherit addr;
            end = addr + o.size;
            at = { inherit (o) line col; };
            writes = o.writesAt addr;
          }
        ];
      }
    ) { inherit (acc) size objects; } (concatMap (f: declsIn "statics" f.body) defs);

  checkItems =
    dataBase: items:
    let
      r = foldl' (itemStep dataBase) {
        funcs = { };
        defs = [ ];
        ctx = {
          structs = { };
          enums = { };
          consts = { };
          globals = { };
          tags = { };
          inherit addrs;
        };
        size = 0;
        objects = [ ];
      } items;
      placed = placeStatics dataBase r r.defs;
      addrs = listToAttrs (
        map (o: {
          inherit (o) name;
          value = o.addr;
        }) placed.objects
      );
    in
    r // { inherit (placed) size objects; };

  # Whether the block-scope extern x refers to a defined file-scope variable of the
  # compatible type in the final context ctx: true, null when there is no definition, or
  # false for another type.
  externOk =
    ctx: x:
    let
      g = ctx.globals.${x.name} or null;
    in
    if g == null || !g.defined then null else compatible g.type x.type;

  checkWith =
    { dataBase }:
    unit:
    let
      r = checkItems dataBase unit.items;
      calls = collect (x: kindOf x == "call") (_: false) r.defs;
      undefinedCalls = filter (c: !(hasAttr c.name r.funcs) || !r.funcs.${c.name}.defined) calls;
      # A call through a block-scope declaration that the file-scope one contradicts.
      conflicts = filter (
        c:
        hasAttr c.name r.funcs
        && (r.funcs.${c.name}.ret != c.type || r.funcs.${c.name}.params != map (a: a.type) c.args)
      ) calls;
      externs = filter (n: !r.ctx.globals.${n}.defined) (attrNames r.ctx.globals);
      blockExterns = filter (x: externOk r.ctx x != true) (
        concatMap (f: declsIn "externs" f.body) r.defs
      );
      blockExtern = head blockExterns;
      # The first variable that ends above 2^32.
      overflow = head (filter (o: o.end > B.mask32 + 1) r.objects);
      extern = r.ctx.globals.${head externs};
      result = {
        funcs = r.defs;
        data = {
          base = dataBase;
          inherit (r) size;
          symbols = map (o: { inherit (o) name addr; }) r.objects;
          inits = filter (w: w.value != 0) (concatMap (o: o.writes) r.objects);
        };
      };
    in
    if !(isInt dataBase && dataBase >= 0 && dataBase <= B.mask32 && bitAnd dataBase 3 == 0) then
      throw "cc: dataBase must be a multiple of 4 in 0..2^32-1"
    else if externs != [ ] then
      unsupported extern.at "extern variable '${head externs}' without a definition"
    else if blockExterns != [ ] && externOk r.ctx blockExtern == null then
      unsupported blockExtern "extern variable '${blockExtern.name}' without a definition"
    else if blockExterns != [ ] then
      fail blockExtern "redeclaration of '${blockExtern.name}' with a different type"
    else if dataBase + r.size > B.mask32 + 1 then
      fail overflow.at "the data does not fit below 2^32 from dataBase (variable '${overflow.name}')"
    else if conflicts != [ ] then
      fail (head conflicts) "conflicting types for '${(head conflicts).name}'"
    else if undefinedCalls != [ ] then
      unsupported (head undefinedCalls) "call to function '${(head undefinedCalls).name}' that is declared but not defined"
    else
      builtins.deepSeq result result;

  check = checkWith { dataBase = defaultDataBase; };
in
{
  inherit
    check
    checkWith
    defaultDataBase
    types
    collect
    constExpr
    noConstHooks
    ;
}
