# C type checker: syntax tree (cc/parse.nix) -> typed syntax tree (input of cc/emit.nix).
#
# Entry point: checkWith { dataBase; link ? null; } : unit node -> { layout; checked; },
# with checked = { funcs; data; }, funcs the typed function definitions in source order
# and data the placement of the file-scope variables (see "Data" below); check uses
# defaultDataBase. layout is the part that reads no address value:
#   { size; symbols; exports; imports; }
# size and symbols as in data; exports = { vars = [ { name; type; size; align; addr; ltype;
# defs; } ]; funcs = [ { name; ret; params; variadic; lsig; defs; } ]; } the definitions
# with external linkage.
#
# Link mode (link = { externAddr; funcNum; }, for cc/link.nix): externAddr maps the name of
# a variable that the unit uses and does not define to its address, and funcNum the name
# of a function that the unit uses as a value to its number (see "Function pointers"),
# both lazily (layout never calls them). Such variables and the functions with external
# linkage that the unit calls or uses as values and does not define are not errors but
# imports:
#   imports = { vars = [ { name; type; size; align; ltype; defs; line; col; file?; } ];
#               funcs = [ { name; ret; params; variadic; lsig; defs; calls; line; col;
#                           file?; } ]; }
# one per name (sorted), at its first use, with calls the numbers of arguments of the
# direct calls of a function (none for one only used as a value); the type of a variable
# merges the declarations of the unit (an array length when one gives it), with size and
# align from objectExtent.
# For the linker's comparison of types between units, ltype is the type of a variable and
# lsig = { ret; params; variadic; unspecified; } the signature of a function with enum
# types kept (linkType), and defs = { structs; enums; } the struct, union and enum
# definitions that their tags name (scopeDefs, those of block-scope declarations
# included). A block-scope extern that disagrees with another declaration of the name,
# calls of a function through declarations that disagree (a call without arguments through
# a declaration without a prototype disagrees with a prototype that has parameters), and a
# call to a function with internal linkage that is declared but not defined stay errors
# (see linkUnit), raised when imports or checked is evaluated, and so is the use as a value
# of a function with internal linkage that is declared but not defined. checked also has
# link = { funcs; statics; }, the names of the imported functions and of the functions
# with internal linkage that the unit uses as values. Without link, imports are empty.
# layout also has fnvals = [ { name; internal; line; col; file?; ret?; params?; } ], the
# functions that the unit uses as values in the order of their first uses (in link mode;
# empty otherwise), internal telling one with internal linkage, which also has its return
# and parameter types. checked also has tables, the shapes of the calls through function
# pointers (sorted, each once), and, outside link mode, fnvals = [ { name; ret; params; } ],
# the functions used as values in number order.
#
# Errors are thrown as "cc: <line>:<col>: <message>" ("cc: <file>:<line>:<col>: ..." for
# a preprocessed file or a named unit of a link, whose nodes have `file`), and as
# "cc: <line>:<col>: unsupported: <what>" for valid C outside the supported subset.
# `types` holds the type helpers shared with the emitter, `collect` the tree walker, and
# `constExpr` / `noConstHooks` the integer constant expression evaluator (see there).
#
# Types are those of cc/parse.nix, resolved: the length of an array is an integer (or null
# when not given), an enum type is its compatible integer type (unsigned int when no
# enumerator is negative, otherwise int, as in clang), and a function type has the
# resolved types of its parameters (adjusted like those of a function: arrays and
# functions to pointers) in params, and unspecified for one without a prototype (`()` in a
# declaration that is not a definition, see cc/parse.nix). A struct or union type stays a
# reference by tag to the layouts of the struct and union definitions; the tag of a
# block-scope definition is replaced by `<tag>@<line>:<col>` (of its keyword), which hides
# an outer one up to the end of the block. Sizes, alignments and ranges follow clang's
# ilp32 ABI (char 1; short 2; int, long, float and pointers 4; long long and double 8; a
# struct aligns to its most aligned member and is padded to a multiple of that; a union
# has all its members at offset 0; a packed struct or union aligns its members and itself
# to 1). Plain char is unsigned, as in clang's RISC-V ABI (the scaffold's), but stays a
# type of its own.
#
# Bit-fields are supported in the form whose layout equals one of plain unsigned members
# (see bitField): they are such members (unsigned char, unsigned short, or the declared
# type for a width of 32), except that `&` and `sizeof` reject them. Function pointers
# hold the numbers of functions (see "Function pointers" below). A
# function type without a prototype agrees with any function type that is not variadic and
# returns a type that agrees with its own (typesAgree): in the declarations of a variable,
# and of a function, whose signature is then the composite one (a declaration without a
# prototype keeps the parameters of an earlier one with a prototype), and where function
# pointers are assigned, cast, compared and joined by ?:. A direct call with arguments to
# a function whose signature in scope has no prototype is unsupported ("call with
# arguments to the function '<name>' declared without a prototype"); one without arguments
# is checked against the signature at the end of the unit. float and double are known
# types with their size and alignment, but every floating-point value (and variable, and
# the definition of or a call to a function with such a parameter or return value) is
# unsupported, as are calls to a variadic function outside link mode (in link mode a call
# gives at least the fixed arguments, and each variable argument is passed after the
# default argument promotions; one of floating-point, struct or union type is
# unsupported). __builtin_va_list (the va_list of stdarg.h, see cc/parse.nix) may only be
# named in a typedef and in the parameters of a function declaration: a variable, member,
# return type, cast or sizeof of a type with it (hasVaList: through pointers, arrays and
# the return types of function types, not their parameters), the definition of a function
# with such a parameter and a call to one are unsupported ('va_list').
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
# unsupported. The address of a file-scope variable (or of a static local, a local in
# memory or a string literal) is a pointer "lit", and so is a constant pointer plus or minus a constant
# (member offsets and constant indices). The operand of sizeof, and the condition of a
# switch for the shape of its node, are also typed without the addresses (typeOnlyEnv),
# so the placement of the data never waits on an address folded there. An address is
# then a constant of unknown value, which folds to a known constant where the result does
# not depend on it (`(unsigned)&g & 0` is 0, see isSymbol). Any other value computed from
# an address stays unknown there, so a 0 that only the address or an identity gives
# (`(unsigned)&g & 3` for an aligned g, `(unsigned)&g - (unsigned)&g`) is no null pointer
# constant in those operands, and a shift by such a value is not checked there.
#   { kind = "lit"; value; }                     integer constant in the range of type, or
#                                                a constant address (pointer type)
#   { kind = "var"; var; }                       local variable or parameter, or element
#                                                of a split array (see "Locals in
#                                                memory"); var = { key; name; type; };
#                                                key is unique per declaration
#   { kind = "old"; }                            the target's value before an assignment;
#                                                appears only inside an assign's value
#   { kind = "call"; name; args; }               args converted to the parameter types
#   { kind = "call"; callee; table; args; }      a call through the function pointer callee
#                                                (see "Function pointers"): table is its
#                                                shape; type is the return type, or for
#                                                one narrower than 4 bytes its class type
#                                                (the node is then inside a "cast" to it)
#   { kind = "call"; name; args; va; }           a call to a variadic function (link
#                                                mode): va the variable arguments after
#                                                the default argument promotions (char
#                                                and short types to int)
#   { kind = "cast"; expr; }                     conversion of expr to type (void: discard)
#   { kind = "neg" | "bnot"; expr; }             unary - and ~ (expr has the result type)
#   { kind = "not"; expr; }                      !; expr is any scalar; type int
#   { kind = "deref"; expr; }                    memory read at the address expr; type is
#                                                the scalar read (1, 2 or 4 bytes). The
#                                                read of a bit-field also has
#                                                bitfield = true (only for & and sizeof)
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
# the typed tree, and so are function designators (see "Function pointers"). An array used
# as a value decays to a pointer to its first element; a
# struct or union is only used through its members, its address and sizeof. A string
# literal is such an array object of type char[N] (N counts the 0 at the end) at a
# constant address; its contents are read from memory, never folded, so it is not part
# of an integer constant expression (but sizeof of it is).
#
# Statements (position of the first token):
#   { kind = "block"; items; }
#   { kind = "decl"; vars = [ { var; init; } ]; }    init is an expression or null; a
#                                                     declaration of static locals,
#                                                     block-scope extern variables and
#                                                     locals in memory also has statics,
#                                                     externs and frames (see declStmt),
#                                                     which only this file uses. A
#                                                     declaration that stores initial values
#                                                     in memory is a "decl" node followed by
#                                                     "expr" nodes of the stores (a block of
#                                                     them where one statement is due)
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
#   { name; ret; params = [ var ]; body = <block>; linkage; frames; line; col; }
# frames are the parameters kept in memory (see "Locals in memory"), which the body
# begins by storing there, and only this file uses them.
# linkage is "internal" or "external" (C99 6.2.2): internal when the first declaration of
# the name is `static`. A `static` declaration of a function or variable after one with
# external linkage is an error, also after a block-scope declaration of the name (a
# function, or an extern variable) in an earlier function that gave it external linkage
# of its own: where no declaration of the name with linkage was visible, but nothing or
# one with no linkage, such as a local variable (C99 6.2.2p4-5). Such a block-scope
# declaration after a file-scope `static` one of the name is an error too ("non-static
# declaration of '<name>' follows static declaration"), raised after the errors of the
# file-scope declarations.
#
# Data
# ----
# File-scope variables are placed in declaration order (of their definitions), each at the
# next offset aligned for its type, from the address dataBase (default 0x00400000), and
# after them the static locals in source order, each named
# `<function>'<name>'<line>'<col>` (of its name; `<function>'<name>'<seq>` in a
# preprocessed file, seq the index of the name token; not a C identifier), after them the
# locals in memory (see "Locals in memory") function by function in source order, the
# parameters first, each named like a static local with `'frame` appended, and after them
# the arrays of the string literals that need storage (see stringUses), one for each distinct
# contents, with alignment 1, in the order of the first such literal of each:
#   { base; size; symbols = [ { name; addr; linkage; } ]; strings = [ { addr; size; } ];
#     inits = [ { addr; size; value; } ]; }
# linkage is that of a file-scope variable, or "none" for a static local or a local in
# memory. size is the end
# of the last variable or string minus base; strings are in address
# order. inits are the scalar stores of the initializers whose value is not 0 (size 1, 2
# or 4 bytes, value in the stored unsigned form), in address order within each variable,
# followed by the bytes of the strings that are not 0.
#
# A string literal initializes an array of char, signed char or unsigned char (alone or
# in braces, also as an element or member without braces): its bytes are stored, the
# rest of the array keeps 0, the array may leave out the 0 at the end, and an array
# without a length takes N. A literal there and in the operand of sizeof needs no storage;
# every other one does, which is decided from the syntax tree and the types only.
#
# Function pointers
# -----------------
# The value of a function pointer is the number of a function (from 1; 0 is the null
# pointer), stored in memory as a 4-byte word. A function name used as a value (also with
# `&`, and in an initializer) is a "deref" node of the function type (a function
# designator) whose address is a pointer "lit" with the number, which the value decays to;
# `*` of a function pointer gives such a designator, so `*fp`, `**fp` and `&*fp` are fp.
# The number comes from ctx.fnNum: in link mode the linker's (link.funcNum), otherwise
# that of a link of this unit alone: the functions used as values ("fnval" uses, see
# usesOf) numbered from 1 in the order of their first uses (fnvalsIn), which reads no
# address and no number. Where expressions are only typed (typeOnlyEnv) the address is a
# "symbol", so the number is never read there. A variadic function used as a value, and
# one that is declared but not defined (outside link mode, or with internal linkage), are
# unsupported.
# A function pointer converts by a cast to and from any integer and pointer type, keeping
# the number, and by assignment from a type that agrees with its own, a null pointer
# constant and `void *`, and to `void *`; == and != compare numbers, the other comparisons
# and pointer arithmetic are unsupported.
# A call of any expression of function pointer type (a variable `fp(x)`, `(*fp)(x)`,
# `s->f(x)`, `a[i](x)`) converts the arguments to the parameter types of the pointed-to
# type, or, for a type without a prototype, applies the default argument promotions and
# takes any number. Its shape is the class of the return type ("v" for void) followed by
# that of each converted argument, the class of a type being "s" (signed 32-bit: signed
# char, short, int, long), "u" (unsigned 32-bit: char, unsigned types, pointers) or "l"
# (long long), with the class types int, unsigned int and long long (shapeOf). A call to
# a name that is a function stays a direct call. A call through a pointer to a variadic
# function type, or to one with a floating-point, va_list, struct or union parameter or
# return value, is unsupported.
let
  B = import ../lib/bits.nix;
  inherit (builtins)
    all
    any
    attrNames
    attrValues
    bitAnd
    bitOr
    bitXor
    concatLists
    concatMap
    concatStringsSep
    div
    elem
    elemAt
    filter
    foldl'
    genericClosure
    genList
    groupBy
    hasAttr
    head
    isAttrs
    isInt
    isList
    length
    listToAttrs
    map
    removeAttrs
    sort
    stringLength
    substring
    ;

  # The position of a node: { line; col; }, with file and seq for a preprocessed file, and
  # file for a unit of a link (cc/parse.nix parseNamed).
  posOf =
    n:
    if n ? seq then
      {
        inherit (n)
          line
          col
          file
          seq
          ;
      }
    else if n ? file then
      { inherit (n) line col file; }
    else
      { inherit (n) line col; };
  # The identity of the node n in keys and names: its position "<line>:<col>", or in a
  # preprocessed file "#<seq>" (the tokens of one macro expansion share a position).
  idOf = n: if n ? seq then "#${toString n.seq}" else "${toString n.line}:${toString n.col}";
  posText = n: "${if n ? file then "${n.file}:" else ""}${toString n.line}:${toString n.col}";
  fail = n: msg: throw "cc: ${posText n}: ${msg}";
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

  # The tag name as shown in a diagnostic: an anonymous tag of a preprocessed file without
  # the token index that makes it unique (see cc/parse.nix).
  shownName =
    name:
    let
      m = builtins.match "(\\(anonymous at .*) #[0-9]+\\)" name;
    in
    if m == null then name else "${builtins.head m})";

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
    valist = "__builtin_va_list";
  };
  showType =
    t:
    if isPtr t then
      "${showType t.to} *"
    else if t.tag == "array" then
      "${showType t.of} [${if t.len == null then "" else toString t.len}]"
    else if t.tag == "struct" || t.tag == "union" then
      "${t.tag} ${shownName t.name}"
    else if t.tag == "fn" then
      "${showType t.ret} (${
        builtins.concatStringsSep ", " (
          map showType t.params
          ++ (if t.variadic then [ "..." ] else [ ])
          ++ (if t.unspecified || t.params != [ ] || t.variadic then [ ] else [ "void" ])
        )
      })"
    else
      typeNames.${t.tag};

  types = {
    inherit
      showType
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
      wrapTo
      classOf
      classTypes
      ;
  };

  # ---- Objects: arrays, structs, sizes and alignments ----
  # ctx (the context, see checkItems) holds the struct and union layouts by tag:
  #   structs.<name> = { kind; size; align; fields = [ { name; type; offset; ltype; } ];
  #                      byName; }
  # kind is "struct" or "union", byName maps a member name to its field, and ltype is the
  # declared type of the member as the linker compares it (linkType). The field of a
  # bit-field also has bitfield = true and its width.

  isArray = t: t.tag == "array";
  # Structs and unions (records).
  isRecord = t: t.tag == "struct" || t.tag == "union";
  isAggregate = t: isArray t || isRecord t;
  isFloat = t: t.tag == "float" || t.tag == "double";
  # A floating-point object: a float or double, or an array of them.
  hasFloat = t: isFloat t || isArray t && hasFloat t.of;
  isFnPtr = t: isPtr t && t.to.tag == "fn";
  isVoidPtr = t: isPtr t && isVoid t.to;
  # Two resolved types of one unit agree: they are equal, but that a function type without
  # a prototype (unspecified) agrees with any function type that is not variadic and whose
  # return type agrees with its own, also through pointers, arrays (of the same length)
  # and the return and parameter types of function types.
  typesAgree =
    a: b:
    a == b
    ||
      a.tag == b.tag
      && (
        if isPtr a then
          typesAgree a.to b.to
        else if a.tag == "array" then
          a.len == b.len && typesAgree a.of b.of
        else if a.tag == "fn" then
          fnTypesAgree a b
        else
          false
      );
  # Of two types that agree, the one that keeps the prototype where one of them has none.
  preferSpecified =
    a: b:
    if a == b then
      a
    else if isPtr a then
      a // { to = preferSpecified a.to b.to; }
    else if a.tag == "array" then
      a // { of = preferSpecified a.of b.of; }
    else if a.tag == "fn" then
      if a.unspecified then b else a
    else
      a;
  # Two function types (or signatures: { ret; params; variadic; unspecified; }) agree.
  fnTypesAgree =
    a: b:
    typesAgree a.ret b.ret
    && (
      if a.unspecified then
        !b.variadic
      else if b.unspecified then
        !a.variadic
      else
        a.variadic == b.variadic
        && length a.params == length b.params
        && all (i: typesAgree (elemAt a.params i) (elemAt b.params i)) (genList (i: i) (length a.params))
    );
  # __builtin_va_list (cc/parse.nix), or a pointer to, an array of or a function returning
  # it: only a typedef and the parameters of a function declaration may have such a type
  # (the parameters of a function type are not looked into).
  hasVaList =
    t:
    if t.tag == "valist" then
      true
    else if isPtr t then
      hasVaList t.to
    else if isArray t then
      hasVaList t.of
    else if t.tag == "fn" then
      hasVaList t.ret
    else
      false;
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
    else if isRecord t then
      hasAttr t.name ctx.structs
    else
      true;

  # Size in bytes of the complete type t.
  sizeOfT =
    ctx: t:
    if isArray t then
      t.len * sizeOfT ctx t.of
    else if isRecord t then
      ctx.structs.${t.name}.size
    else if isFloat t then
      floatSizes.${t.tag}
    else
      sizeOf t;

  alignOfT =
    ctx: t:
    if isArray t then
      alignOfT ctx t.of
    else if isRecord t then
      ctx.structs.${t.name}.align
    else if isFloat t then
      floatSizes.${t.tag}
    else
      sizeOf t;

  alignUp = n: a: div (n + a - 1) a * a;

  # long long (8 bytes) as a scalar or array element; struct members are checked when the
  # struct is defined.
  hasLLong = t: if isArray t then hasLLong t.of else t.tag == "llong";

  # An array of char, signed char or unsigned char (which a string literal may initialize).
  isCharArray =
    t:
    isArray t
    && elem t.of.tag [
      "char"
      "schar"
      "uchar"
    ];

  # The type of a string literal with the contents bytes: char[N], N counting the 0 at
  # the end.
  stringType = bytes: {
    tag = "array";
    of = ty "char";
    len = length bytes + 1;
  };

  hexDigits = "0123456789abcdef";
  hexByte = b: substring (div b 16) 1 hexDigits + substring (bitAnd b 15) 1 hexDigits;
  # The key of the contents bytes of a string literal in ctx.strings: `"` and two hex
  # digits per byte (not a data symbol, and the 0 bytes are kept).
  stringKey = bytes: "\"" + concatStringsSep "" (map hexByte bytes);

  # ---- Expressions ----

  node =
    at: kind: type: fields:
    {
      inherit kind type;
    }
    // posOf at
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
    else if isSymbol x && isScalar t then
      x // { type = t; }
    else
      node x "cast" t { expr = x; };

  # The type is tested before the value, so the address of a constant pointer is not read.
  isNullConst = x: x.kind == "lit" && isInteger x.type && x.value == 0;
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

  # Where expressions are only typed (see typeOnlyEnv), a "symbol" node is a constant of
  # unknown value (an address, or what folding one gives). Operators fold a symbol where
  # they fold a "lit": to a known constant where the result does not depend on its value
  # (`x & 0`, `x * 0`, `x % 1` and `x % -1` are 0, `0 && x` is 0, `1 || x` is 1, and
  # `c ? a : b` is a when c is not 0, b when c is 0, and k when a and b are both k),
  # otherwise to a symbol of the result type.
  isSymbol = x: x.kind == "symbol";
  # A constant, of known or unknown value.
  isConst = x: x.kind == "lit" || isSymbol x;
  isIntConst = x: isConst x && isInteger x.type;
  symbolAt = at: t: node at "symbol" t { };
  # Whether a and b are integer constants of which one at least is a symbol.
  symbolPair = a: b: (isSymbol a || isSymbol b) && isIntConst a && isIntConst b;

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
    if isIntLit n.lhs && isIntLit n.rhs && v != null then
      litAt n n.type v
    else if symbolPair n.lhs n.rhs then
      foldSymbolBinop n
    else
      n;

  # The "binop" node n on integer constants of which one at least is a symbol: 0 where
  # the value does not depend on the symbol, otherwise a symbol (see isSymbol).
  foldSymbolBinop =
    n:
    let
      zero = x: isIntLit x && x.value == 0;
    in
    if (n.op == "&" || n.op == "*") && (zero n.lhs || zero n.rhs) then
      litAt n n.type 0
    else if n.op == "%" && isIntLit n.rhs && (n.rhs.value == 1 || n.rhs.value == -1) then
      litAt n n.type 0
    else
      symbolAt n n.type;

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
    else if symbolPair n.lhs n.rhs then
      symbolAt n tInt
    else
      n;

  # The "not", "logand" and "logor" node n folded when its operands are integer constants.
  foldLogic =
    n:
    if n.kind == "not" then
      (
        if isIntLit n.expr then
          litAt n tInt (boolValue (n.expr.value == 0))
        else if isSymbol n.expr && isInteger n.expr.type then
          symbolAt n tInt
        else
          n
      )
    else if isIntLit n.lhs && isIntLit n.rhs then
      litAt n tInt (
        boolValue (
          if n.kind == "logand" then
            n.lhs.value != 0 && n.rhs.value != 0
          else
            n.lhs.value != 0 || n.rhs.value != 0
        )
      )
    else if symbolPair n.lhs n.rhs then
      foldSymbolLogic n
    else
      n;

  # The "logand" or "logor" node n on integer constants of which one at least is a
  # symbol: decided by a known operand (0 for &&, not 0 for ||), otherwise a symbol.
  foldSymbolLogic =
    n:
    let
      isAnd = n.kind == "logand";
      decides = x: isIntLit x && (if isAnd then x.value == 0 else x.value != 0);
    in
    if decides n.lhs || decides n.rhs then litAt n tInt (if isAnd then 0 else 1) else symbolAt n tInt;

  # Conversion as by assignment (also for arguments and return values). A function
  # pointer converts only from a type that agrees with its own (typesAgree), from a null
  # pointer constant and from `void *`, and only to such a type and to `void *`.
  assignConv =
    at: t: x:
    if isFnPtr t || isFnPtr x.type then
      (
        if typesAgree t x.type then
          mkCast t x
        else if isFnPtr t && isNullFn x then
          mkCast t x
        else if isVoidPtr t || isVoidPtr x.type then
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
    else if k == "strlit" then
      stringObject env.ctx e
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
    else if x.type.tag == "fn" then
      x.expr
    else if isRecord x.type then
      unsupported e "${x.type.tag} value"
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
    node e "deref" t { expr = addressAt ctx e (ptrTo t) (addressOf ctx sym); };

  # The constant address addr as a value of the pointer type t at the node e: a "lit", or,
  # where expressions are only typed (ctx.typeOnly, see typeOnlyEnv), a "symbol" node, a
  # constant of unknown value (see isSymbol), so that addr is never read.
  addressAt =
    ctx: e: t: addr:
    if ctx.typeOnly then symbolAt e t else litAt e t addr;

  # env for finding the type of an expression without reading any address: the placement
  # of the data, which gives the addresses, may depend on the type (an array length with
  # sizeof, the sections of a switch). Constant folding keeps the type of what it folds,
  # and a symbol folds like the address it stands for wherever the result does not
  # depend on the address (see isSymbol), so a null pointer constant, which decides a type,
  # is found as with the addresses. Only the type (and the shape that sizeof checks) of the
  # result is used, never its value.
  typeOnlyEnv =
    env:
    env
    // {
      ctx = env.ctx // {
        typeOnly = true;
      };
    };

  # The address of the data symbol sym: placed in this unit, or, in link mode (ctx.link,
  # see checkWith), a variable of another unit given by the linker.
  addressOf =
    ctx: sym:
    if ctx.link != null && !(hasAttr sym ctx.addrs) then ctx.link.externAddr sym else ctx.addrs.${sym};

  # ---- References for the linker ----
  # Every statement node and file-scope object carries `uses`: the references of its
  # expressions to file-scope variables and functions (outside link mode, ctx.link, only
  # the "fnval" ones), as
  #   { use = "var"; name; line; col; ... },
  #   { use = "func"; name; sig; nargs; line; col; ... }  or
  #   { use = "fnval"; name; sig; line; col; ... }
  # with the position of the identifier (posOf), sig the signature in scope (env.funcs) and
  # nargs the number of arguments of the call: "func" for a direct call, "fnval" for a
  # function name used as a value (see "Function pointers"). A call through a function
  # pointer makes no use of a name of its own (a variable called is a "var" use).
  # They are found in the syntax tree with the names in scope where the expression is
  # checked, resolved as identExpr and callExpr resolve them, so that finding them reads no
  # address (constant folding of addresses decides the shape of the typed tree). Operands
  # of sizeof are not evaluated and do not count.

  usesOf =
    env: e:
    concatMap (useOf env) (
      collect
        (
          x:
          elem (kindOf x) [
            "ident"
            "call"
          ]
        )
        (
          x:
          elem (kindOf x) [
            "sizeof"
            "sizeoftype"
            "strlit"
          ]
        )
        e
    );

  # The type definitions in the context ctx, as the linker compares types with them
  # (cc/link.nix): { structs; enums; } the struct and union layouts and the enum
  # definitions (ctx.enumDefs) by tag or internal name.
  scopeDefs = ctx: {
    inherit (ctx) structs;
    enums = ctx.enumDefs;
  };

  # The reference of the "ident" or "call" node x in env: a block-scope extern variable (a
  # name bound to the data symbol of its own name, see externVar), a file-scope variable or a
  # function; nothing for a local, a static local, an enumerator, or an error (which the
  # checker reports).
  useOf =
    env: x:
    let
      name = x.name;
      v = env.vars.${name} or null;
      isObject = v != null || hasAttr name env.ctx.globals || hasAttr name env.ctx.consts;
      at = posOf x;
    in
    if x.kind == "ident" then
      (
        if
          (
            if v != null then
              (v.object or null) == name
            else
              !hasAttr name env.ctx.consts && hasAttr name env.ctx.globals
          )
        then
          [
            (
              {
                use = "var";
                inherit name;
              }
              // at
            )
          ]
        else if !isObject && hasAttr name env.funcs then
          [
            (
              {
                use = "fnval";
                inherit name;
                sig = env.funcs.${name};
                defs = scopeDefs env.ctx;
              }
              // at
            )
          ]
        else
          [ ]
      )
    else if x ? callee then
      [ ]
    else if isObject then
      # A call of a variable (a function pointer) uses the variable.
      useOf env (
        {
          kind = "ident";
          inherit name;
        }
        // at
      )
    else if !hasAttr name env.funcs then
      [ ]
    else
      [
        (
          {
            use = "func";
            inherit name;
            sig = env.funcs.${name};
            nargs = length x.args;
            defs = scopeDefs env.ctx;
          }
          // at
        )
      ];

  # { uses } for a node whose references are uses (only the "fnval" ones outside link mode).
  withUses = env: uses: {
    uses = if env.ctx.link == null then filter (u: u.use == "fnval") uses else uses;
  };
  # The same for the expressions exprs (null for none) checked in env.
  linkUses = env: exprs: withUses env (concatMap (usesOf env) exprs);

  # The statements directly inside the typed statement n, but the initialization of a for
  # (which usesIn walks and declsIn does not). Only statements are walked: their structure
  # does not depend on the addresses of the data.
  subStmts =
    n:
    let
      k = kindOf n;
    in
    if k == "block" then
      n.items
    else if k == "if" then
      [
        n.thenStmt
        n.elseStmt
      ]
    else if k == "while" || k == "do" || k == "for" then
      [ n.body ]
    else if k == "switch" then
      n.skipped ++ concatLists n.sections
    else
      [ ];

  # The uses of the typed statement n and the statements in it (see declsIn).
  usesIn =
    n:
    (n.uses or [ ])
    ++ (if kindOf n == "for" then usesIn n.init else [ ])
    ++ concatMap usesIn (subStmts n);

  # The array of the string literal e (a "strlit" node), at the address of its contents
  # (see placeStrings). A literal in the operand of sizeof has no storage; the operand is
  # typed without reading addresses (see typeOnlyEnv), so its address is never asked for.
  stringObject =
    ctx: e:
    let
      t = stringType e.bytes;
      addr =
        ctx.strings.${stringKey e.bytes}
        or (unsupported e "value of the address of a string literal in an operand of sizeof");
    in
    node e "deref" t { expr = addressAt ctx e (ptrTo t) addr; };

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
      if v ? object then
        objectAt ctx e v.type v.object
      else if v ? elems then
        splitArray ctx e v
      else
        node e "var" v.type { var = v; }
    else if hasAttr name ctx.consts then
      litAt e ctx.consts.${name}.type ctx.consts.${name}.value
    else if hasAttr name ctx.globals then
      objectAt ctx e ctx.globals.${name}.type name
    else if hasAttr name env.funcs then
      funcDesignator env e name
    else
      fail e "use of undeclared identifier '${name}'";

  # The function type of the signature f (env.funcs).
  fnTypeOf = f: {
    tag = "fn";
    inherit (f)
      ret
      params
      variadic
      unspecified
      ;
  };

  # The function name used in the expression e: a "deref" node of function type whose
  # address is the number of the function (see "Function pointers"), a "symbol" where
  # expressions are only typed (see typeOnlyEnv), so that the number is never read there.
  funcDesignator =
    env: e: name:
    let
      f = env.funcs.${name};
      p = ptrTo (fnTypeOf f);
    in
    if f.variadic then
      unsupported e "variadic function '${name}' used as a value"
    else
      node e "deref" p.to {
        expr = if env.ctx.typeOnly then symbolAt e p else litAt e p (env.ctx.fnNum name);
      };

  # Whether the signature f has a floating-point parameter or return value.
  sigHasFloat = f: isFloat f.ret || any isFloat f.params;
  # Whether the signature f has a parameter or return value of a va_list type (hasVaList).
  sigHasVaList = f: hasVaList f.ret || any hasVaList f.params;

  callExpr =
    env: e: if e ? callee then indirectCall env e (valueOf env e.callee) else directCall env e;

  directCall =
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
      # A variable argument: its value after the default argument promotions.
      vaArg =
        i:
        let
          x = rv env (elemAt e.args (n + i));
        in
        mkCast (promote x.type) x;
      objType = env.vars.${e.name}.type or env.ctx.globals.${e.name}.type or null;
    in
    if hasAttr e.name env.vars || hasAttr e.name env.ctx.globals || hasAttr e.name env.ctx.consts then
      if objType != null && isFnPtr objType then
        indirectCall env e (
          valueOf env (
            {
              kind = "ident";
              inherit (e) name;
            }
            // posOf e
          )
        )
      else
        fail e "called object '${e.name}' is not a function"
    else if !hasAttr e.name env.funcs then
      fail e "call to undeclared function '${e.name}'"
    else if f.variadic && env.ctx.link == null then
      unsupported e "call to the variadic function '${e.name}'"
    else if sigHasVaList f then
      unsupported e "'va_list'"
    else if sigHasFloat f then
      unsupported e "call to the function '${e.name}' with a floating-point parameter or return value"
    else if f.unspecified && m > 0 then
      unsupported e "call with arguments to the function '${e.name}' declared without a prototype"
    else if (if f.variadic then m < n else n != m) then
      fail e "function '${e.name}' takes ${toString n} argument(s) but ${toString m} were given"
    else
      node e "call" f.ret (
        {
          inherit (e) name;
          args = genList arg n;
        }
        // (if f.variadic then { va = genList vaArg (m - n); } else { })
      );

  # A call through the function pointer p (typed): the arguments converted to the parameter
  # types of its function type, or, for a type without a prototype, promoted (see
  # "Function pointers").
  indirectCall =
    env: e: p:
    let
      ft = p.type.to;
      n = length ft.params;
      m = length e.args;
      arg =
        i:
        let
          a = elemAt e.args i;
          x = rv env a;
        in
        if ft.unspecified then mkCast (promote x.type) x else assignConv a (elemAt ft.params i) x;
      args = genList arg m;
      shape = shapeOf ft.ret (map (a: a.type) args);
      # A narrower return value comes in its class and is converted at the call.
      call = node e "call" (if isVoid ft.ret || sizeOf ft.ret >= 4 then ft.ret else classType ft.ret) {
        callee = p;
        table = shape;
        inherit args;
      };
    in
    if !isFnPtr p.type then
      fail e "called object type '${showType p.type}' is not a function or function pointer"
    else if ft.variadic then
      unsupported e "call through a pointer to the variadic function type '${showType ft}'"
    else if sigHasVaList ft then
      unsupported e "'va_list'"
    else if sigHasFloat ft then
      unsupported e "call through a function pointer with a floating-point parameter or return value"
    else if isRecord ft.ret || any isRecord ft.params then
      unsupported e "call through a function pointer with a struct or union parameter or return value"
    else if !ft.unspecified && n != m then
      fail e "function pointer of type '${showType p.type}' takes ${toString n} argument(s) but ${toString m} were given"
    else if isVoid ft.ret then
      call
    else
      mkCast ft.ret call;

  # The class of the representation of a value of the scalar type t in an indirect call:
  # "s" signed 32-bit, "u" unsigned 32-bit (pointers included), "l" long long.
  classOf =
    t:
    if t.tag == "llong" then
      "l"
    else if isPtr t || isUnsigned t then
      "u"
    else
      "s";
  # The type that holds every value of the class of t: int, unsigned int or long long.
  classType = t: classTypes.${classOf t};
  classTypes = {
    s = tInt;
    u = tUInt;
    l = tLLong;
  };
  # The shape of an indirect call (see "Function pointers") returning ret with arguments of
  # the types params: the class of ret ("v" for void) and of each parameter.
  shapeOf =
    ret: params: (if isVoid ret then "v" else classOf ret) + concatStringsSep "" (map classOf params);

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
    else if hasVaList t then
      unsupported e "'va_list'"
    else if isFloat t then
      unsupported e "conversion to '${showType t}'"
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
    else if isSymbol v then
      v
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
      node at "deref" t { expr = p; }
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
    else if t.tag == "fn" then
      unsupported at "arithmetic on a pointer to the function type '${showType t}'"
    else if !isComplete ctx t then
      fail at "arithmetic on a pointer to an incomplete type '${showType t}'"
    else if p.kind == "lit" && index.kind == "lit" then
      litAt at p.type ((if op == "+" then B.add else B.sub) p.value (index.value * size))
    else if (isSymbol p || isSymbol index) && isConst p && isConst index then
      symbolAt at p.type
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
    else if isSymbol p then
      symbolAt at pt
    else
      node at "ptradd" pt {
        op = "+";
        ptr = p;
        index = litAt at tInt offset;
        size = 1;
      };

  # The split array v (see "Locals in memory") named alone, which only an operand of sizeof
  # may do (scanFunc): an array object at a constant of unknown value (see isSymbol).
  splitArray =
    ctx: e: v:
    if ctx.typeOnly then
      node e "deref" v.type { expr = symbolAt e (ptrTo v.type); }
    else
      throw "cc: internal error: split array '${v.name}' used as a value";

  # The element of the split array v at the index of the "index" node e: its variable.
  splitElement =
    env: e: v:
    let
      i = rv env e.index;
    in
    if i.kind == "lit" && isInteger i.type && i.value >= 0 && i.value < length v.elems then
      node e "var" v.type.of { var = elemAt v.elems i.value; }
    else
      throw "cc: internal error: split array '${v.name}' indexed by a value that is not a constant in range";

  indexExpr =
    env: e:
    let
      v = if kindOf e.base == "ident" then env.vars.${e.base.name} or null else null;
      b = rv env e.base;
      i = rv env e.index;
    in
    if v != null && v ? elems then
      splitElement env e v
    else if isPtr b.type && isInteger i.type then
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
    if !isRecord t then
      fail at "member reference base type '${showType t}' is not a structure or union"
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

  # &x: the address of an object in memory. A local whose address is taken is one (see
  # "Locals in memory"); a local variable is left only where the scan does not look (a
  # static initializer, a type), and stays unsupported there.
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
  # expression is typed, without reading an address, and not evaluated).
  sizeofValue =
    env: n:
    let
      x = ex (typeOnlyEnv env) n.expr;
      t = if n.kind == "sizeoftype" then resolveType env n n.type else x.type;
    in
    if n.kind == "sizeof" && x ? bitfield then
      fail n "invalid application of 'sizeof' to a bit-field"
    else if isVoid t then
      fail n "invalid application of 'sizeof' to a void type"
    else if hasVaList t then
      unsupported n "'va_list'"
    else if !isComplete env.ctx t then
      fail n "invalid application of 'sizeof' to an incomplete type '${showType t}'"
    else
      sizeOfT env.ctx t;

  # Whether the expression e, typed as x, is a null pointer constant of type `void *`: a
  # cast to `void *` of an integer constant 0 (`(void *)0`). The test reads the form of e,
  # not the value of x, so it never reads a constant address.
  isVoidNull =
    env: e: x:
    isPtr x.type && isVoid x.type.to && e.kind == "cast" && isNullConst (valueOf env e.expr);

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
        else if isPtr ta && typesAgree ta tb then
          preferSpecified ta tb
        else if isFnPtr ta && isFnPtr tb && typesAgree ta tb then
          (if ta.to.unspecified then tb else ta)
        else if isFnPtr ta && isNullFn b then
          ta
        else if isNullFn a && isFnPtr tb then
          tb
        else if isPtr ta && isVoidNull env e.elseExpr b then
          ta
        else if isVoidNull env e.thenExpr a && isPtr tb then
          tb
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
      (if c.value != 0 then x else y) // posOf e
    else if isIntConst c && isIntConst x && isIntConst y then
      foldSymbolCond e t c x y
    else
      node e "cond" t {
        cond = c;
        thenExpr = x;
        elseExpr = y;
      };

  # `c ? x : y` (the node e, of type t) on integer constants of which one at least is a
  # symbol (see isSymbol): the chosen branch when c is known, the value of both branches
  # when they are equal, otherwise a symbol.
  foldSymbolCond =
    e: t: c: x: y:
    if isIntLit c then
      (if c.value != 0 then x else y) // posOf e
    else if isIntLit x && isIntLit y && x.value == y.value then
      x // posOf e
    else
      symbolAt e t;

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
      else if isPtr ta && typesAgree ta tb && isComplete ctx ta.to then
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
  # with a type that agrees (typesAgree), or with a null pointer constant.
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
    else if typesAgree ta tb then
      cmp a (mkCast ta b)
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
      mkCast t (if c.value != 0 then a else b) // posOf e;

  lvalue =
    env: e:
    let
      x = ex env e;
    in
    if isArray x.type then
      fail e "array type '${showType x.type}' is not assignable"
    else if isRecord x.type then
      unsupported e "${x.type.tag} assignment"
    else if isFloat x.type then
      unsupported e "floating-point value"
    else if x.type.tag == "fn" then
      fail e "non-object type '${showType x.type}' is not assignable"
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

  # env: { vars; local; funcs; fn; ret; jumps; ctx; } with
  #   vars   the variables in scope by C name: a local variable or parameter
  #          ({ key; name; type; }), or a block-scope extern or static variable
  #          ({ name; type; object; }, object its data symbol, see identExpr)
  #   local  what each name declared in the innermost block is: "object" (a variable),
  #          "constant" (an enumerator) or "function" (a function declaration), and
  #          "tag" for the key `tag <name>` of a struct, union or enum tag
  #   funcs  the function signatures in scope by name ({ ret; params; variadic; defined; })
  #   fn     the name of the current function (null at file scope)
  #   ret    the return type of the current function
  #   jumps  = { break; continue; } whether break and continue have a target here
  #   ctx    the context (see checkItems), with the tags, structs, enums and enumerators of
  #          the enclosing blocks added
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
        key = "${name}@${idOf at}";
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
            ${name} = "object";
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
        }
        // posOf n
        // fields
        // linkUses env (
          if k == "expr" then
            [ n.expr ]
          else if k == "if" || k == "while" || k == "do" then
            [ n.cond ]
          else
            [ ]
        );
        inherit env;
      };
      kind = k;
    in
    if k == "block" then
      at { items = blockItems (enterBlock env) n.items; }
    else if k == "decl" then
      let
        r = declStmt env n;
      in
      {
        node = declBlock n r.nodes;
        inherit (r) env;
      }
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
      posOf n
      // {
        kind = "block";
        items = [ ];
      }
    else
      r.node;

  # A block-scope declaration: local variables (the typed node's vars), static locals
  # (statics, see staticVar), block-scope extern variables (externs, see externVar),
  # locals in memory (frames, see frameLocal), function declarations, and struct, union
  # and enum definitions, each in scope from its declarator on. -> { nodes; env; } with
  # nodes the statements of the declaration in order: "decl" nodes of the variables, and
  # between them the "expr" nodes that store the initial values of scalars in memory. The
  # first is a "decl" node, which carries statics, externs, frames and the uses of the
  # whole declaration; there are none when the declaration leaves nothing to run or place.
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
            uses = acc.uses ++ usesOf r.env d.init;
          }
        else
          let
            t = resolveType acc.env d d.type;
            how = storageOf acc.env (localKey d d.name) t;
            # The scope of a name starts after its declarator, so the initializer sees it.
            r = declare acc.env d d.name t;
            init = if d.init == null then null else assignConv d.init t (rv r.env d.init);
          in
          if hasVaList t then
            unsupported d "'va_list'"
          else if hasFloat t then
            unsupported d "floating-point variable"
          else if isArray t || isRecord t || how == "frame" then
            frameLocal acc d t how
          else
            acc
            // {
              inherit (r) env;
              items = acc.items ++ [
                {
                  inherit (r) var;
                  inherit init;
                }
              ];
              uses = acc.uses ++ usesOf r.env d.init;
            };
      r = foldl' step {
        inherit env;
        items = [ ];
        statics = [ ];
        externs = [ ];
        frames = [ ];
        uses = [ ];
      } n.decls;
      declNode =
        vars:
        posOf n
        // {
          kind = "decl";
          inherit vars;
        };
      # A variable joins the "decl" node before it, a store is a statement of its own.
      join =
        ns: it:
        let
          count = length ns;
          last = elemAt ns (count - 1);
        in
        if it ? var && count > 0 && last.kind == "decl" then
          genList (i: elemAt ns i) (count - 1) ++ [ (last // { vars = last.vars ++ [ it ]; }) ]
        else
          ns ++ [ (if it ? var then declNode [ it ] else it.stmt) ];
      nodes = foldl' join [ ] r.items;
      meta =
        (if r.statics == [ ] then { } else { inherit (r) statics; })
        // (if r.externs == [ ] then { } else { inherit (r) externs; })
        // (if r.frames == [ ] then { } else { inherit (r) frames; })
        // withUses env r.uses;
    in
    {
      nodes =
        if nodes != [ ] && (head nodes).kind == "decl" then
          [ (head nodes // meta) ] ++ builtins.tail nodes
        else if r.statics != [ ] || r.externs != [ ] || r.frames != [ ] then
          [ (declNode [ ] // meta) ] ++ nodes
        else
          nodes;
      inherit (r) env;
    };

  # The statements nodes of a declaration (see declStmt) as one statement: null for none,
  # a block for more than one.
  declBlock =
    at: nodes:
    if nodes == [ ] then
      null
    else if length nodes == 1 then
      head nodes
    else
      posOf at
      // {
        kind = "block";
        items = nodes;
      };

  # The automatic local d of type t in the accumulator acc of declStmt, kept in memory
  # (how is "frame") or split (see "Locals in memory"). An array or struct with an
  # initializer is unsupported; a scalar in memory stores its initial value where it is
  # declared.
  frameLocal =
    acc: d: t: how:
    let
      env = acc.env;
      name = d.name;
      sym = frameSym env d name;
      env' = bindObject env name t sym;
      elems = genList (elemVar d name t) t.len;
      frame = {
        env = env';
        frames = acc.frames ++ [ (frameObject env d t sym) ];
      };
    in
    builtins.seq (checkLocal env d name) (
      if isArray t && d.init != null then
        unsupported d "initializer of a local array"
      else if isRecord t && d.init != null then
        unsupported d "initializer of a local ${t.tag} variable"
      else if isArray t && t.len == null then
        fail d "definition of variable with array type needs an explicit size or an initializer"
      else if !isComplete env.ctx t then
        fail d "variable '${name}' has incomplete type '${showType t}'"
      else if how == "split" then
        acc
        // {
          env = bindSplit env name t elems;
          items =
            acc.items
            ++ map (v: {
              var = v;
              init = null;
            }) elems;
        }
      else if hasLLong t then
        unsupported d "8-byte integer in a local variable in memory"
      else if isScalar t then
        acc
        // frame
        // {
          items =
            acc.items
            ++ (
              if d.init == null then
                [ ]
              else
                [ { stmt = frameStore env' d t sym (assignConv d.init t (rv env' d.init)); } ]
            );
          uses = acc.uses ++ usesOf env' d.init;
        }
      else
        acc // frame
    );

  # acc with the env e, which is forced so that its declaration is checked even when
  # nothing reads it.
  withEnv = acc: e: builtins.seq e (acc // { env = e; });

  # Fails unless name is new in the innermost block of env.
  checkLocal =
    env: at: name:
    !(hasAttr name env.local) || fail at "redefinition of '${name}'";

  # env with name bound to the split array of type t with the element variables elems (see
  # "Locals in memory").
  bindSplit =
    env: name: t: elems:
    env
    // {
      vars = env.vars // {
        ${name} = {
          inherit name elems;
          type = t;
        };
      };
      local = env.local // {
        ${name} = "object";
      };
    };

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
        ${name} = "object";
      };
    };

  # A block-scope `extern` variable: the file-scope variable of the same name, which must
  # be defined in the input with a compatible type (checked at the end, see checkWith).
  # -> { env; extern = { name; type; extent; ltype; defs; line; col; }; } with extent the
  # size and alignment of type here (see objectExtent; the linker's view of a block-scope
  # tag), ltype the type as the linker compares it and defs the type definitions in scope
  # (see scopeDefs).
  externVar =
    env: d:
    let
      name = d.name;
      t = resolveType env d d.type;
      lt = linkType env d d.type;
      prev = env.ctx.globals.${name} or null;
      type = if prev != null && isComplete env.ctx prev.type then prev.type else t;
    in
    builtins.seq (checkLocal env d name) (
      if isVoid t then
        fail d "variable '${name}' has type 'void'"
      else if hasVaList t then
        unsupported d "'va_list'"
      else if hasAttr name env.funcs then
        fail d "redefinition of '${name}' as a different kind of symbol"
      else if prev != null && !compatible prev.type t then
        fail d "redeclaration of '${name}' with a different type"
      else
        builtins.deepSeq
          [
            t
            lt
          ]
          {
            env = bindObject env name type name;
            extern = posOf d // {
              inherit name;
              type = t;
              extent = objectExtent env.ctx t;
              ltype = lt;
              defs = scopeDefs env.ctx;
            };
          }
    );

  # A static local: a variable at a fixed address in the data, placed after the file-scope
  # variables (see checkItems), with the data symbol `<function>'<name>'<line>'<col>`
  # (`<function>'<name>'<seq>` in a preprocessed file; not a C identifier). Its type and
  # initializer follow the rules of file-scope variables. -> { env; static = { sym; size; align; line; col; writesAt; }; } with
  # writesAt the initial stores at a given address.
  staticVar =
    env: d:
    let
      name = d.name;
      sym = localSym env d name;
      t0 = resolveType env d d.type;
      # The initializer sees the variable itself.
      env' = bindObject env name t sym;
      t = sizedType env' d t0;
    in
    builtins.seq (checkLocal env d name) (
      if isVoid t0 then
        fail d "variable '${name}' has type 'void'"
      else if hasVaList t0 then
        unsupported d "'va_list'"
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
          static = posOf d // {
            inherit sym;
            size = sizeOfT env.ctx t;
            align = alignOfT env.ctx t;
            writesAt = addr: if d.init == null then [ ] else initWrites env' t addr d.init;
          };
        }
    );

  # ---- Locals in memory ----
  # Before its body is checked, a function is scanned (scanFunc) for the uses of its
  # automatic locals and parameters, so that the storage of each is known at its
  # declaration, before any use that would read it. A use is
  #   { key; use = "plain" | "addr" | "index" | "sizeof"; value; }
  # with key that of the variable (see declare): "addr" for `&x`, "index" for `x[k]` (value
  # the integer constant expression k, or null when k is not one, see constIndex), "sizeof"
  # for `sizeof x`, and "plain" for any other use (`&x[k]` included). The names are resolved
  # through the scopes of the blocks as the checker resolves them; a name that a
  # declaration without automatic storage hides (a static or extern variable, a function,
  # a typedef, an enumerator) is no local. Static initializers and the expressions inside
  # types are not scanned: they cannot use a local but in an operand of sizeof, which is
  # only typed (see typeOnlyEnv).
  #
  # The storage of a local of type t (storageOf):
  #   "split"   an array of scalars with a length whose uses are all "sizeof" and "index"
  #             with a value in [0, length): one variable per element, named `<name>'<k>'`
  #             (elemVar), each 0 until assigned
  #   "frame"   any other array, a struct or union, and a scalar with an "addr" use: an
  #             object at a fixed address in the data (see "Data"), with the data symbol of
  #             a static local followed by `'frame` (frameSym); its contents are never
  #             cleared, and a parameter is written there on entry
  #   "bind"    any other scalar: a variable (see "Typed syntax tree")

  # The key of the local variable or parameter name declared at the node at.
  localKey = at: name: "${name}@${idOf at}";

  # The data symbol of the static local name declared at the node d in the current function.
  localSym =
    env: d: name:
    if d ? seq then
      "${env.fn}'${name}'${toString d.seq}"
    else
      "${env.fn}'${name}'${toString d.line}'${toString d.col}";

  frameSym =
    env: d: name:
    "${localSym env d name}'frame";

  # The value of the index expression e as an integer constant expression, with the
  # enumerators of file scope that no local name of scope hides, or null when it is none.
  # Anything else (a sizeof, an enumerator of a block, a division by zero) gives null,
  # which only keeps an array in memory.
  constIndex =
    env: scope: e:
    let
      hooks = {
        ident = name: if hasAttr name scope then null else env.ctx.consts.${name} or null;
        sizeOf = _: null;
        resolve = resolveType env;
      };
      r = builtins.tryEval (constExpr hooks e).value;
    in
    if r.success then r.value else null;

  # The uses of locals in the expression or initializer e (null for none), with scope the
  # names in scope (a key, or null for a name that is no local).
  scanExpr =
    env: scope: e:
    let
      k = kindOf e;
      sub = scanExpr env scope;
      use =
        name: u:
        let
          key = scope.${name} or null;
        in
        if key == null then
          [ ]
        else
          [
            {
              inherit key;
              use = u;
              value = null;
            }
          ];
      isIdent = x: kindOf x == "ident";
    in
    if e == null then
      [ ]
    else if k == "ident" then
      use e.name "plain"
    else if k == "addr" then
      if isIdent e.expr then
        use e.expr.name "addr"
      else if kindOf e.expr == "index" && isIdent e.expr.base then
        use e.expr.base.name "plain" ++ sub e.expr.index
      else
        sub e.expr
    else if k == "index" then
      (
        if isIdent e.base then
          map (u: u // { value = constIndex env scope e.index; }) (use e.base.name "index")
        else
          sub e.base
      )
      ++ sub e.index
    else if k == "sizeof" then
      if isIdent e.expr then use e.expr.name "sizeof" else sub e.expr
    else if k == "call" then
      (if e ? callee then sub e.callee else use e.name "plain") ++ concatMap sub e.args
    else if k == "initlist" then
      concatMap sub e.items
    else if
      elem k [
        "cast"
        "unary"
        "deref"
        "prefix"
        "postfix"
        "dot"
        "arrow"
      ]
    then
      sub e.expr
    else if
      elem k [
        "binary"
        "assign"
        "comma"
      ]
    then
      sub e.lhs ++ sub e.rhs
    else if k == "cond" then
      sub e.cond ++ sub e.thenExpr ++ sub e.elseExpr
    else
      [ ];

  # The names of the block-scope declaration d (a node of the decls of a "decl" statement)
  # added to scope: an automatic variable by its key, anything else as no local.
  scanDeclare =
    scope: d:
    let
      k = d.kind;
      none =
        names:
        scope
        // listToAttrs (
          map (n: {
            name = n;
            value = null;
          }) names
        );
    in
    if k == "vardecl" then
      scope // { ${d.name} = if (d.storage or null) == null then localKey d d.name else null; }
    else if k == "proto" || k == "typedef" then
      none [ d.name ]
    else if k == "enum" then
      none (map (c: c.name) d.consts)
    else
      scope;

  # The uses of locals in the statement n with the names scope in scope.
  # -> { uses; scope; } with scope the names in scope after n.
  scanStmt =
    env: scope: n:
    let
      k = n.kind;
      ex = scanExpr env scope;
      inner = x: if x == null then [ ] else (scanStmt env scope x).uses;
      done = uses: { inherit uses scope; };
    in
    if k == "block" then
      done (scanItems env scope n.items).uses
    else if k == "decl" then
      foldl' (
        acc: d:
        let
          s = scanDeclare acc.scope d;
          automatic = d.kind == "vardecl" && (d.storage or null) == null;
        in
        {
          scope = s;
          uses = acc.uses ++ (if automatic then scanExpr env s d.init else [ ]);
        }
      ) (done [ ]) n.decls
    else if k == "expr" then
      done (ex n.expr)
    else if k == "if" then
      done (ex n.cond ++ inner n.thenStmt ++ inner n.elseStmt)
    else if k == "while" || k == "do" then
      done (ex n.cond ++ inner n.body)
    else if k == "for" then
      let
        i =
          if n.init == null then
            done [ ]
          else if n.init.kind == "decl" then
            scanStmt env scope n.init
          else
            done (ex n.init);
      in
      done (
        i.uses
        ++ scanExpr env i.scope n.cond
        ++ scanExpr env i.scope n.step
        ++ (scanStmt env i.scope n.body).uses
      )
    else if k == "return" then
      done (ex n.expr)
    else if k == "switch" then
      done (ex n.cond ++ inner n.body)
    else if k == "case" || k == "default" then
      scanStmt env scope n.stmt
    else
      done [ ];

  # The uses of locals in the statements items of one block, in order. -> { uses; scope; }
  scanItems =
    env: scope: items:
    foldl'
      (
        acc: n:
        let
          r = scanStmt env acc.scope n;
        in
        {
          inherit (r) scope;
          uses = acc.uses ++ r.uses;
        }
      )
      {
        inherit scope;
        uses = [ ];
      }
      items;

  # The uses of the parameters and locals of the function definition f (its syntax tree)
  # by key, in env, the environment of its body.
  scanFunc =
    env: f:
    let
      scope = listToAttrs (
        map (p: {
          inherit (p) name;
          value = localKey p p.name;
        }) f.params
      );
    in
    groupBy (u: u.key) (scanItems env scope f.body.items).uses;

  # The storage of the local of type t with the key key in env: "split", "frame" or "bind"
  # (see "Locals in memory").
  storageOf =
    env: key: t:
    let
      uses = env.localUses.${key} or [ ];
      inRange = u: u.value != null && u.value >= 0 && u.value < t.len;
    in
    if isArray t then
      if
        isScalar t.of && t.len != null && all (u: u.use == "sizeof" || u.use == "index" && inRange u) uses
      then
        "split"
      else
        "frame"
    else if isRecord t then
      "frame"
    else if isScalar t && any (u: u.use == "addr") uses then
      "frame"
    else
      "bind";

  # The variable of element k of the split array name (of type t) declared at the node d.
  elemVar = d: name: t: k: {
    key = "${localKey d name}'${toString k}";
    name = "${name}'${toString k}'";
    type = t.of;
  };

  # A frame object of type t at the data symbol sym, declared at the node d, for the
  # placement of the data (see placeStatics).
  frameObject =
    env: d: t: sym:
    posOf d
    // {
      inherit sym;
      size = sizeOfT env.ctx t;
      align = alignOfT env.ctx t;
      writesAt = _: [ ];
    };

  # The statement that stores value (a typed expression of the scalar type t) into the
  # frame object at the data symbol sym, at the node at.
  frameStore =
    env: at: t: sym: value:
    posOf at
    // {
      kind = "expr";
      expr = node at "assign" t {
        target = objectAt env.ctx at t sym;
        inherit value;
        post = false;
      };
    };

  # A block-scope function declaration: the function of the same name in the translation
  # unit, in scope to the end of the block. Its calls are checked against the file-scope
  # declarations at the end (see checkWith).
  declareLocalFunc =
    env: d:
    let
      name = d.name;
      sig = sigOf env d;
      prev = env.funcs.${name} or null;
      kind = env.local.${name} or null;
      otherKind = (kind != null && kind != "function") || hasAttr name env.ctx.globals;
    in
    if otherKind then
      fail d "redefinition of '${name}' as a different kind of symbol"
    else if prev != null && !sameSig prev sig then
      fail d "conflicting types for '${name}'"
    else
      builtins.deepSeq sig (
        env
        // {
          funcs = env.funcs // {
            ${name} = mergeSig prev sig // {
              defined = prev != null && prev.defined;
              linkage = linkageOf prev null;
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
  # identity (idOf), unique in the translation unit.
  localTagName = n: "${n.name}@${idOf n}";

  # env with the tag of the definition n bound to the internal name.
  bindTag =
    env: n: internal:
    if hasAttr (tagKey n.name) env.local then
      fail n "redefinition of '${n.kind} ${shownName n.name}'"
    else
      env
      // {
        local = env.local // {
          ${tagKey n.name} = "tag";
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
          v = enumValue e st.next c;
        in
        builtins.seq (checkLocal e c c.name) (
          builtins.seq v {
            env = e // {
              vars = removeAttrs e.vars [ c.name ];
              local = e.local // {
                ${c.name} = "constant";
              };
              ctx = e.ctx // {
                consts = e.ctx.consts // {
                  ${c.name} = enumConst v;
                };
              };
            };
            next = v + 1;
            negative = st.negative || v < 0;
            values = st.values // {
              ${c.name} = v;
            };
          }
        );
      r = foldl' step {
        inherit env;
        next = 0;
        negative = false;
        values = { };
      } n.consts;
      env1 = bindTag r.env n internal;
    in
    env1
    // {
      ctx = env1.ctx // {
        enums = env1.ctx.enums // {
          ${internal} = enumType r.negative;
        };
        enumDefs = env1.ctx.enumDefs // {
          ${internal} = enumDef r;
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
            let
              r = declStmt fenv n.init;
            in
            {
              node = declBlock n.init r.nodes;
              inherit (r) env;
            }
        else
          {
            node =
              posOf n.init
              // {
                kind = "expr";
                expr = valueOf fenv n.init;
              }
              // linkUses fenv [ n.init ];
            env = fenv;
          };
      ienv = init.env;
    in
    {
      node =
        posOf n
        // {
          kind = "for";
          init = init.node;
          cond = if n.cond == null then null else rv ienv n.cond;
          step = if n.step == null then null else valueOf ienv n.step;
          body = sub (inLoop ienv) n.body;
        }
        // linkUses ienv [
          n.cond
          n.step
        ];
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
        node =
          posOf n
          // {
            kind = "return";
            expr = if n.expr == null then null else assignConv n.expr env.ret (rv env n.expr);
          }
          // linkUses env [ n.expr ];
        inherit env;
      };

  # The statement n checked as an item of a block or a switch body. -> { nodes; env; }, a
  # declaration giving its statements one by one (see declStmt).
  stmtNodes =
    env: n:
    if n.kind == "decl" then
      declStmt env n
    else
      let
        r = stmt env n;
      in
      {
        nodes = if r.node == null then [ ] else [ r.node ];
        inherit (r) env;
      };

  # Items of a block, checked in order.
  blockItems =
    env: items:
    let
      step =
        acc: n:
        let
          r = stmtNodes acc.env n;
        in
        {
          inherit (r) env;
          nodes = acc.nodes ++ r.nodes;
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
      # The sections, which the placement of the static locals walks, depend on the type of
      # the condition, so it is found without reading an address.
      ct = (rv (typeOnlyEnv env) n.cond).type;
      t = promote ct;
      body = n.body;
      r = foldl' (switchItem t) {
        env = inSwitch (enterBlock env);
        skipped = [ ];
        sections = [ ];
        cases = [ ];
        default = null;
      } body.items;
    in
    if !isInteger ct then
      fail n.cond "statement requires expression of integer type ('${showType ct}' invalid)"
    else if body.kind != "block" then
      unsupported body "'switch' body that is not a compound statement"
    else
      {
        node =
          posOf n
          // {
            kind = "switch";
            cond = mkCast t c;
            inherit (r)
              skipped
              sections
              cases
              default
              ;
          }
          // linkUses env [ n.cond ];
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
      r = stmtNodes acc.env l.stmt;
      inherit (r) nodes;
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
  resolveType = resolveTypeWith false;

  # The type of a declaration as the linker compares it (see linkUnit): resolved as by
  # resolveType, but an enum type stays { tag = "enum"; name; } with its internal name (the
  # key of its definition in ctx.enumDefs).
  linkType = resolveTypeWith true;

  # resolveType, keeping enum types when keepEnums.
  resolveTypeWith =
    keepEnums: env: at: t:
    let
      resolve = resolveTypeWith keepEnums env;
    in
    if t.tag == "ptr" then
      ptrTo (resolve at t.to)
    else if t.tag == "array" then
      resolveArray keepEnums env at t
    else if t.tag == "enum" then
      resolveEnum keepEnums env at t
    else if isRecord t then
      resolveRecord env at t
    else if t.tag == "fn" then
      {
        tag = "fn";
        ret = resolve at t.ret;
        params = map (p: adjustParam (resolve p p.type)) t.params;
        inherit (t) variadic unspecified;
      }
    else
      t;

  # The enum type t: its compatible integer type, or itself by internal name when
  # keepEnums (see linkType).
  resolveEnum =
    keepEnums: env: at: t:
    let
      name = tagName env t;
      int = env.ctx.enums.${name} or (fail at "incomplete enum type 'enum ${shownName t.name}'");
    in
    if keepEnums then
      builtins.seq int {
        tag = "enum";
        inherit name;
      }
    else
      int;

  # The name a struct, union or enum tag stands for in env.
  tagName = env: t: env.ctx.tags.${t.name} or t.name;

  resolveRecord =
    env: at: t:
    let
      name = tagName env t;
      layout = env.ctx.structs.${name} or null;
    in
    if layout != null && layout.kind != t.tag then
      fail at "use of '${shownName t.name}' with tag type that does not match previous declaration"
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
    keepEnums: env: at: t:
    let
      of = resolveTypeWith keepEnums env at t.of;
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
  # arrays and functions adjusted to pointers (adjustParam), and whether it is variadic;
  # lsig is the same with the types as the linker compares them (linkType).
  sigOf =
    env: item:
    let
      ret = resolveType env item item.ret;
      param =
        p:
        let
          t = resolveType env p p.type;
        in
        if isRecord t then unsupported p "${t.tag} parameter passed by value" else adjustParam t;
      variadic = item.variadic or false;
      unspecified = item.unspecified or false;
    in
    if isArray ret then
      fail item "function cannot return array type '${showType ret}'"
    else if hasVaList ret then
      unsupported item "'va_list'"
    else if isRecord ret then
      unsupported item "${ret.tag} returned by value"
    else
      {
        inherit ret variadic unspecified;
        params = map param item.params;
        lsig = {
          ret = linkType env item item.ret;
          params = map (p: adjustParam (linkType env p p.type)) item.params;
          inherit variadic unspecified;
        };
      };

  # Two signatures (or function types) of one name agree (see typesAgree).
  sameSig = fnTypesAgree;

  # The signature of a function after its declaration with the signature sig, where prev
  # (or null) is the one before: the composite type (C99 6.2.7p3) as far as a declaration
  # without a prototype keeps the parameters of an earlier one with a prototype.
  mergeSig =
    prev: sig:
    if prev != null && sig.unspecified then
      removeAttrs prev [
        "defined"
        "linkage"
      ]
    else
      sig;

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
      fenv = env // {
        inherit (sig) ret;
        fn = f.name;
      };
      ps = foldl' step {
        env = fenv // {
          localUses = scanFunc fenv f;
        };
        vars = [ ];
      } (genList (i: i) (length f.params));
      # The parameters whose address is taken live in memory (see "Locals in memory"),
      # written there on entry.
      framed = filter (i: storageOf ps.env (elemAt ps.vars i).key (elemAt ps.vars i).type == "frame") (
        genList (i: i) (length f.params)
      );
      frameOf =
        i:
        let
          p = elemAt f.params i;
          var = elemAt ps.vars i;
        in
        {
          inherit p var;
          sym = frameSym ps.env p p.name;
        };
      frameParams = map frameOf framed;
      benv = foldl' (e: x: bindObject e x.var.name x.var.type x.sym) ps.env frameParams;
      stores = map (
        x: frameStore benv x.p x.var.type x.sym (node x.p "var" x.var.type { inherit (x) var; })
      ) frameParams;
      items = stores ++ blockItems benv f.body.items;
      llongFrame = filter (x: x.var.type.tag == "llong") frameParams;
    in
    if sigHasVaList sig then
      unsupported f "'va_list'"
    else if sigHasFloat sig then
      unsupported f "definition of a function with a floating-point parameter or return value"
    else if llongFrame != [ ] then
      unsupported (head llongFrame).p "8-byte integer in a local variable in memory"
    else
      posOf f
      // {
        inherit (f) name;
        inherit (sig) ret;
        params = ps.vars;
        frames = map (x: frameObject benv x.p x.var.type x.sym) frameParams;
        body = posOf f.body // {
          kind = "block";
          inherit items;
        };
      };

  # ---- File scope ----
  # The items are checked in order with the accumulator
  #   acc = { funcs; defs; ctx; size; objects; blockLinked; }
  # funcs: the function signatures by name ({ ret; params; variadic; defined; linkage; },
  # see linkageOf); defs: the typed function definitions; size: the bytes placed so far;
  # objects: the placed variables
  # ([ { name; addr; end; at; writes; } ], writes as the inits of the data); blockLinked:
  # the block-scope declarations that give their name external linkage of their own, by
  # name (see withBlockDecls). The context
  #   ctx = { structs; enums; consts; globals; tags; enumDefs; typeOnly; addrs; strings; }
  # holds the struct and union layouts by tag (see "Objects"), the enum types by tag, the
  # enumerators by name ({ type; value; }), the file-scope variables by name
  # ({ type; ltype; defined; hasInit; at; linkage; }, ltype the type as the linker
  # compares it, see linkType), the internal names of the block-scope tags
  # in scope by tag (empty at file scope; see resolveType), the definitions of the enums
  # by tag (see enumDef; block-scope ones by internal name), whether expressions are only
  # typed (see typeOnlyEnv; false here), the addresses of all defined
  # variables and static locals by data symbol, taken from the end of the fold and
  # placeStatics (an extern declaration may precede the definition that places the
  # variable), and the addresses of the string literals by key (see stringKey), taken
  # from placeStrings.

  fileEnv = acc: {
    vars = { };
    local = { };
    localUses = { };
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
      linkage = linkageOf prev item.storage;
      funcs = acc.funcs // {
        ${item.name} = mergeSig prev sig // {
          defined = isDef || (prev != null && prev.defined);
          inherit linkage;
        };
      };
    in
    builtins.seq (checkKind acc item item.name "function") (
      if staticAfterExtern prev (hasAttr item.name acc.blockLinked.funcs) item.storage then
        fail item "static declaration of '${item.name}' follows non-static declaration"
      else if prev != null && !sameSig prev sig then
        fail item "conflicting types for '${item.name}'"
      else if isDef && prev != null && prev.defined then
        fail item "redefinition of '${item.name}'"
      else
        builtins.deepSeq sig (
          acc
          // {
            inherit funcs;
            defs =
              acc.defs
              ++ (
                if isDef then [ (funcDef (env // { inherit funcs; }) sig item // { inherit linkage; }) ] else [ ]
              );
            blockLinked = if isDef then withBlockDecls acc funcs item else acc.blockLinked;
          }
        )
    );

  # The block-scope declarations in the function definition f (its syntax tree) that give
  # their name external linkage of their own: the function declarations and the extern
  # variables where no declaration of the name with linkage is visible (C99 6.2.2p4-5).
  # Such a declaration takes the linkage of the visible one; otherwise, where nothing or a
  # declaration with no linkage (a parameter, a local or static local variable, a typedef
  # or an enumerator of an enclosing block) is visible, its linkage is external. The
  # bindings of the blocks are followed in source order, scope = { <name> = "none" |
  # "linked"; }; a name bound in no block is visible with linkage when the file-scope
  # declarations so far (file = { funcs; vars; }, by kind) declare it.
  # -> [ <proto or vardecl node> ]
  ownLinksOf =
    file: f:
    linkStmt file (listToAttrs (
      map (p: {
        inherit (p) name;
        value = "none";
      }) f.params
    )) f.body;

  # The declarations of ownLinksOf in the statement n, with the bindings scope.
  linkStmt =
    file: scope: n:
    let
      k = n.kind;
      sub = linkStmt file scope;
    in
    if k == "block" then
      linkItems file scope n.items
    else if k == "if" then
      sub n.thenStmt ++ (if n.elseStmt == null then [ ] else sub n.elseStmt)
    else if k == "while" || k == "do" || k == "switch" then
      sub n.body
    else if k == "case" || k == "default" then
      sub n.stmt
    else if k == "for" && n.init != null && n.init.kind == "decl" then
      linkItems file scope [
        n.init
        n.body
      ]
    else if k == "for" then
      sub n.body
    else
      [ ];

  # The declarations of ownLinksOf in the items of a block, each in the scope of the
  # declarations before it.
  linkItems =
    file: scope: items:
    (foldl'
      (
        acc: s:
        if s.kind == "decl" then
          linkDecl file acc s
        else
          acc
          // {
            found = acc.found ++ linkStmt file acc.scope s;
          }
      )
      {
        inherit scope;
        found = [ ];
      }
      items
    ).found;

  # acc = { scope; found; } after the declaration statement n.
  linkDecl =
    file: acc: n:
    foldl' (
      a: d:
      let
        k = d.kind;
        bind =
          names: v:
          a.scope
          // listToAttrs (
            map (name: {
              inherit name;
              value = v;
            }) names
          );
      in
      if k == "proto" || k == "vardecl" && d.storage == "extern" then
        {
          scope = bind [ d.name ] "linked";
          found = a.found ++ (if ownsLink file a.scope d then [ d ] else [ ]);
        }
      else if k == "vardecl" || k == "typedef" then
        a // { scope = bind [ d.name ] "none"; }
      else if k == "enum" then
        a // { scope = bind (map (c: c.name) d.consts) "none"; }
      else
        a
    ) acc n.decls;

  # Whether the block-scope declaration d (a function declaration or an extern variable)
  # gives its name external linkage of its own in the bindings scope (see ownLinksOf).
  ownsLink =
    file: scope: d:
    let
      v = scope.${d.name} or null;
    in
    if v != null then
      v == "none"
    else
      !hasAttr d.name (if d.kind == "proto" then file.funcs else file.vars);

  # acc.blockLinked with the declarations of ownLinksOf in the function definition f
  # (funcs: the functions declared so far, f included), the first of each name kept, as
  # { funcs; vars; } (declaration nodes by name). A later file-scope `static` declaration
  # of such a name is an error (staticAfterExtern), and so is an earlier one
  # (checkBlockLinks).
  withBlockDecls =
    acc: funcs: f:
    let
      ds = ownLinksOf {
        inherit funcs;
        vars = acc.ctx.globals;
      } f;
      named =
        k:
        listToAttrs (
          map (d: {
            inherit (d) name;
            value = d;
          }) (filter (d: d.kind == k) ds)
        );
    in
    {
      funcs = named "proto" // acc.blockLinked.funcs;
      vars = named "vardecl" // acc.blockLinked.vars;
    };

  # Fails at the first block-scope declaration of r.blockLinked (see withBlockDecls) whose
  # name an earlier file-scope `static` declaration gives internal linkage: the name would
  # have both linkages (C99 6.2.2p7). r is the end of the fold over the items, which has
  # failed already where a `static` declaration follows.
  checkBlockLinks =
    r:
    let
      linkageIn = decls: d: (decls.${d.name} or { linkage = null; }).linkage;
      bad =
        filter (d: linkageIn r.funcs d == "internal") (attrValues r.blockLinked.funcs)
        ++ filter (d: linkageIn r.ctx.globals d == "internal") (attrValues r.blockLinked.vars);
      d = earliest bad;
    in
    bad == [ ] || fail d "non-static declaration of '${d.name}' follows static declaration";

  # The linkage ("internal" or "external", C99 6.2.2) of a file-scope declaration with the
  # storage class storage, after the earlier declaration prev of the name (or null): that
  # of prev when there is one, otherwise internal for `static`. A `static` declaration
  # after one with external linkage is an error (staticAfterExtern); a declaration without
  # `static` after a `static` variable is a second definition (see declareGlobal).
  linkageOf =
    prev: storage:
    if prev != null then
      prev.linkage
    else if storage == "static" then
      "internal"
    else
      "external";
  # Whether a declaration with the storage class storage is `static` after one with
  # external linkage: the earlier file-scope declaration prev, or a block-scope
  # declaration in an earlier function that gave the name external linkage of its own
  # (blockLinked, see withBlockDecls).
  staticAfterExtern =
    prev: blockLinked: storage:
    storage == "static" && (prev != null && prev.linkage == "external" || blockLinked);

  # ---- Structs and enums ----

  defineStruct =
    acc: n:
    let
      layout = structLayout (fileEnv acc) n;
    in
    if hasAttr n.name acc.ctx.structs then
      fail n "redefinition of '${n.kind} ${shownName n.name}'"
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
      r = foldl' (layoutStep env n) {
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

  # The layout so far acc = { size; align; fields; byName; run; runType; runAt; } of the
  # struct or union n with its member f added. run and runType are those of bitField, and
  # runAt is the last member. The diagnostics come in member order.
  layoutStep =
    env: n: acc: f:
    let
      t = resolveType env f f.type;
      m = placeMember env n acc f t;
    in
    builtins.seq (checkMember env n acc f t) (
      builtins.seq m {
        size = if n.kind == "union" && acc.size > m.end then acc.size else m.end;
        align = if m.align > acc.align then m.align else acc.align;
        fields = acc.fields ++ [ m.field ];
        byName = acc.byName // {
          ${f.name} = m.field;
        };
        inherit (m) run runType;
        runAt = f;
      }
    );

  # Fails unless the member f of type t can follow the members in acc (see layoutStep) in
  # the struct or union n; true otherwise.
  checkMember =
    env: n: acc: f: t:
    let
      isBit = f.width != null;
    in
    if hasAttr f.name acc.byName then
      fail f "duplicate member '${f.name}'"
    else if isArray t && t.len == null then
      unsupported f "flexible array member"
    else if !isComplete env.ctx t then
      fail f "field '${f.name}' has incomplete type '${showType t}'"
    else if hasVaList t then
      unsupported f "'va_list'"
    else if hasLLong t then
      unsupported f "8-byte integer in a struct"
    else if isBit && n.kind == "union" then
      unsupported f "bit-field in a union"
    else if !isBit && acc.run != 0 then
      unsupported acc.runAt "bit-fields that do not fill their declared type"
    else
      true;

  # The place of the member f of type t after the members in acc (see layoutStep) in the
  # struct or union n -> { field; end; align; run; runType; } with field its entry in the
  # layout, end the offset after it, align its contribution to the alignment, and run and
  # runType those of bitField (0 and null for other members).
  placeMember =
    env: n: acc: f: t:
    let
      isBit = f.width != null;
      bit = bitField env acc f t;
      align = if n.packed or false then 1 else alignOfT env.ctx t;
      type = if isBit then bit.type else t;
      offset =
        if n.kind == "union" then
          0
        else if isBit then
          acc.size
        else
          alignUp acc.size align;
      field = {
        inherit (f) name;
        inherit type offset;
        # The declared type as the linker compares it (see linkUnit).
        ltype = linkType env f f.type;
      }
      // (
        if isBit then
          {
            bitfield = true;
            inherit (bit) width;
          }
        else
          { }
      );
    in
    builtins.seq (if isBit then bit else null) {
      inherit field align;
      end = offset + sizeOfT env.ctx type;
      run = if isBit then bit.run else 0;
      runType = if isBit then t else null;
    };

  # The bit-field f of the declared type t (resolved), placed after the members in acc (see
  # structLayout). Only named bit-fields of an unsigned type (not plain char, not an enum)
  # whose width w is 8, 16 or 32 are supported, each starting at a multiple of w bits, where
  # consecutive bit-fields of the same declared type fill it exactly (acc.run counts the
  # bits filled so far). Such a bit-field lies where clang places it, and it is read and
  # written as an unsigned member of w bits (as t when w is 32); its declared type gives the
  # alignment of the struct. -> { type; run; width; }
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
            width = w;
          }
      );

  # The value of the enumerator c in env: the given value, or next (one more than the
  # previous one, 0 for the first). A value outside the range of int is unsupported.
  enumValue =
    env: next: c:
    let
      v = if c.value == null then next else (constExpr (hooksOf env) c.value).value;
    in
    if v < s32.lo || v > s32.hi then
      unsupported c "enumerator value ${toString v} outside the range of int"
    else
      v;

  # An enumerator: an int constant.
  enumConst = v: {
    type = tInt;
    value = v;
  };

  # The compatible integer type of an enum, int when an enumerator is negative.
  enumType = negative: if negative then tInt else tUInt;

  # The definition of an enum in ctx.enumDefs, from the end r of the fold over its
  # enumerators: { type; consts; } with type its compatible integer type and consts the
  # values of its enumerators by name.
  enumDef = r: {
    type = enumType r.negative;
    consts = r.values;
  };

  # Enumerators are int constants (enumValue). Each is in scope from the next one on.
  defineEnum =
    acc: n:
    let
      step =
        st: c:
        let
          v = enumValue (fileEnv st.acc) st.next c;
        in
        if declaredAs st.acc c.name != null then
          fail c "redefinition of '${c.name}'"
        else
          builtins.seq v {
            acc = withCtx st.acc {
              consts = st.acc.ctx.consts // {
                ${c.name} = enumConst v;
              };
            };
            next = v + 1;
            negative = st.negative || v < 0;
            values = st.values // {
              ${c.name} = v;
            };
          };
      r = foldl' step {
        inherit acc;
        next = 0;
        negative = false;
        values = { };
      } n.consts;
    in
    if hasAttr n.name acc.ctx.enums then
      fail n "redefinition of 'enum ${shownName n.name}'"
    else
      withCtx r.acc {
        enums = r.acc.ctx.enums // {
          ${n.name} = enumType r.negative;
        };
        enumDefs = r.acc.ctx.enumDefs // {
          ${n.name} = enumDef r;
        };
      };

  # ---- File-scope variables ----

  # Two declarations of a variable agree: types that agree (typesAgree), or arrays of the
  # same element type where one has no length.
  compatible =
    a: b:
    typesAgree a b
    || (isArray a && isArray b && typesAgree a.of b.of && (a.len == null || b.len == null));

  withGlobal =
    acc: name: g:
    withCtx acc {
      globals = acc.ctx.globals // {
        ${name} = g;
      };
    };

  # A declaration without an initializer and with `extern` only declares; anything else
  # defines (and places) the variable. `static` gives it internal linkage (linkageOf).
  declareGlobal =
    dataBase: acc: g:
    let
      name = g.name;
      t = resolveType (fileEnv acc) g g.type;
      lt = linkType (fileEnv acc) g g.type;
      prev = acc.ctx.globals.${name} or null;
      isDef = g.storage != "extern" || g.init != null;
      keep = prev != null && (prev.defined || isComplete acc.ctx prev.type);
    in
    builtins.seq (checkKind acc g name "variable") (
      if staticAfterExtern prev (hasAttr name acc.blockLinked.vars) g.storage then
        fail g "static declaration of '${name}' follows non-static declaration"
      else if isVoid t then
        fail g "variable '${name}' has type 'void'"
      else if hasVaList t then
        unsupported g "'va_list'"
      else if hasLLong t then
        unsupported g "8-byte integer in a global variable"
      else if isDef && hasFloat t then
        unsupported g "floating-point variable"
      else if prev != null && !compatible prev.type t then
        fail g "redeclaration of '${name}' with a different type"
      else if !isDef then
        builtins.deepSeq
          [
            t
            lt
          ]
          (
            withGlobal acc name {
              type = if keep then prev.type else t;
              ltype = if keep then prev.ltype else lt;
              defined = prev != null && prev.defined;
              hasInit = prev != null && prev.hasInit;
              at = if prev != null then prev.at else posOf g;
              linkage = linkageOf prev g.storage;
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
        let
          st = if keep then prev.type else sizedType (fileEnv acc) g t;
        in
        defineGlobal dataBase acc g st (if keep then prev.ltype else sizedLinkType lt st)
    );

  # The link type lt (see linkType) of an array without a length with the length of the
  # sized type t (see sizedType).
  sizedLinkType =
    lt: t: if isArray t && isArray lt && lt.len == null then lt // { inherit (t) len; } else lt;

  # The type of a defined variable: an array without a length takes it from its
  # initializer list.
  sizedType =
    env: g: t:
    let
      s = stringInit t g.init;
    in
    if !(isArray t && t.len == null && g.init != null) then
      t
    else if s != null then
      t // { len = length s.bytes + 1; }
    else if g.init.kind == "initlist" then
      t // { len = (fillFrom env t 0 g.init.items 0).count; }
    else
      t;

  # Place the variable g of type t (and link type lt) after the ones placed so far.
  defineGlobal =
    dataBase: acc: g: t: lt:
    let
      name = g.name;
      offset = alignUp acc.size (alignOfT acc.ctx t);
      addr = dataBase + offset;
      acc' =
        withGlobal acc name {
          type = t;
          ltype = lt;
          defined = true;
          hasInit = g.init != null;
          at = acc.ctx.globals.${name}.at or (posOf g);
          linkage = linkageOf (acc.ctx.globals.${name} or null) g.storage;
        }
        // {
          size = offset + sizeOfT acc.ctx t;
          objects = acc.objects ++ [
            {
              inherit name addr;
              end = addr + sizeOfT acc.ctx t;
              at = posOf g;
              # The initializer sees the variable itself.
              writes = if g.init == null then [ ] else initWrites (fileEnv acc') t addr g.init;
              # Its references in link mode (see usesOf).
              uses = usesOf (fileEnv acc') g.init;
            }
          ];
        };
    in
    if isArray t && t.len == null then
      unsupported g "array '${name}' without a length"
    else if !isComplete acc.ctx t then
      fail g "variable '${name}' has incomplete type '${showType t}'"
    else
      builtins.deepSeq [
        t
        lt
      ] acc';

  # ---- Initializers ----
  # An initializer becomes the stores of its scalars: [ { addr; size; value; } ] with value
  # in the stored unsigned form. Slots without an initializer keep the 0 of the memory.

  initWrites =
    env: t: a: x:
    let
      s = stringInit t x;
    in
    if s != null then
      stringWrites t a s
    else if isAggregate t then
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

  # The string literal that initializes the array t from the initializer x: x itself, or
  # the only item of a braced x, when t is an array of a character type; null when x is
  # no such initializer. A string literal for an array of another type is an error.
  stringInit =
    t: x:
    let
      items = x.items;
    in
    if !isArray t then
      null
    else if x.kind == "strlit" then
      (
        if isCharArray t then x else fail x "array of non-character type initialized from a string literal"
      )
    else if x.kind == "initlist" && isCharArray t && (head items).kind == "strlit" then
      (
        if length items > 1 then
          fail (elemAt items 1) "excess elements in char array initializer"
        else
          head items
      )
    else
      null;

  # The stores of the string literal s into the character array t at address a: its bytes
  # (the end of the array keeps the 0 of the memory). The array may leave out the 0 at the
  # end of the literal, but no other byte.
  stringWrites =
    t: a: s:
    let
      n = length s.bytes;
    in
    if t.len < n then fail s "initializer-string for char array is too long" else byteWrites a s.bytes;

  # The 1-byte stores of the byte values bytes from address a on.
  byteWrites =
    a: bytes:
    genList (i: {
      addr = a + i;
      size = 1;
      value = elemAt bytes i;
    }) (length bytes);

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
            if x.kind == "initlist" || (x.kind == "strlit" && isCharArray slot.type) then
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
    {
      addr = a;
      inherit size;
      # The check sits on the value, so that walking the stores for their string literals
      # (stringUses) raises no error before the values are read in order.
      value =
        if isFloat t then unsupported x "floating-point initializer" else bitAnd v (B.pow2 (8 * size) - 1);
      # The initializer, whose string literals need storage (see stringUses).
      expr = x;
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
  # and the statements in it (subStmts, which the addresses of the data, determined by the
  # statics, do not change), in source order. The declaration of a for initialization
  # declares no static or extern variable.
  declsIn =
    field: n: if kindOf n == "decl" then n.${field} or [ ] else concatMap (declsIn field) (subStmts n);

  # The objects acc.objects followed by the static locals of the functions acc.defs in
  # source order, then by their locals in memory (see "Locals in memory"), function by
  # function, the parameters first, each at the next offset aligned for it.
  # -> { size; objects; }
  placeStatics =
    dataBase: acc:
    foldl'
      (
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
              at = posOf o;
              writes = o.writesAt addr;
            }
          ];
        }
      )
      { inherit (acc) size objects; }
      (
        concatMap (f: declsIn "statics" f.body) acc.defs
        ++ concatMap (f: f.frames ++ framesIn f.body) acc.defs
      );

  # The frames (see declStmt) of the declarations in the statement n and the statements in
  # it, those of a for initialization included, in source order.
  framesIn =
    n:
    (if kindOf n == "decl" then n.frames or [ ] else [ ])
    ++ (if kindOf n == "for" && n.init != null then framesIn n.init else [ ])
    ++ concatMap framesIn (subStmts n);

  # The string literals in the syntax tree n that need storage: all of them but those in
  # the operand of sizeof and in the initializers of static locals (whose literals come
  # from their stores, see stringUses).
  stringsIn = collect (x: kindOf x == "strlit") (
    x:
    elem (kindOf x) [
      "strlit"
      "sizeof"
      "sizeoftype"
    ]
    || kindOf x == "vardecl" && x.storage == "static"
  );

  # The string literals that need storage: those in the function bodies, and those in the
  # scalar initializers of the placed objects (a literal that initializes a character
  # array is not one of them). Both are found from the syntax tree and the types, without
  # the addresses, which depend on them.
  stringUses =
    items: objects:
    concatMap (i: if i.kind == "func" then stringsIn i.body else [ ]) items
    ++ concatMap (o: concatMap (w: if w ? expr then stringsIn w.expr else [ ]) o.writes) objects;

  # Whether the node a comes before the node b in the source (by seq in a preprocessed
  # file, whose positions are not in order across files and macro expansions).
  before =
    a: b: if a ? seq then a.seq < b.seq else a.line < b.line || a.line == b.line && a.col < b.col;

  # The arrays of the string literals uses (see stringUses), one for each contents, placed
  # from the offset start in the order of the first use of each, with alignment 1.
  # -> { list = [ { key; addr; size; bytes; at; } ]; end; addrs; } with end the offset
  # after the last one and addrs the addresses by key (ctx.strings). The offsets are forced
  # in order, so they do not build a chain of thunks.
  placeStrings =
    dataBase: start: uses:
    let
      groups = groupBy (u: stringKey u.bytes) uses;
      firsts = sort before (
        map (us: foldl' (a: b: if before b a then b else a) (head us) us) (attrValues groups)
      );
      n = length firsts;
      step =
        st:
        let
          s = elemAt firsts st.k;
          size = length s.bytes + 1;
        in
        builtins.seq st.off (
          if st.k >= n then
            null
          else
            {
              node = {
                key = stringKey s.bytes;
                addr = dataBase + st.off;
                inherit size;
                inherit (s) bytes;
                at = s;
              };
              s = {
                k = st.k + 1;
                off = st.off + size;
              };
            }
        );
      r = iterate step {
        k = 0;
        off = start;
      };
    in
    {
      list = r.nodes;
      end = r.s.off;
      addrs = listToAttrs (
        map (s: {
          name = s.key;
          value = s.addr;
        }) r.nodes
      );
    };

  checkItems =
    dataBase: link: items:
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
          enumDefs = { };
          typeOnly = false;
          inherit addrs link;
          strings = strings.addrs;
          fnNum = if link != null then link.funcNum else localNum;
        };
        size = 0;
        objects = [ ];
        blockLinked = {
          funcs = { };
          vars = { };
        };
      } items;
      placed = placeStatics dataBase r;
      addrs = listToAttrs (
        map (o: {
          inherit (o) name;
          value = o.addr;
        }) placed.objects
      );
      strings = placeStrings dataBase placed.size (stringUses items placed.objects);
      # Outside link mode, the functions are numbered as a link of this unit alone numbers
      # them (see "Function pointers").
      localNums = listToAttrs (
        imap0 (i: u: {
          inherit (u) name;
          value = i + 1;
        }) (fnvalsIn (unitUses r))
      );
      localNum = name: localNums.${name} or (throw "cc: internal error: no number for '${name}'");
    in
    builtins.seq (checkBlockLinks r) (
      r
      // {
        inherit (placed) size objects;
        inherit strings;
      }
    );

  # How the block-scope extern x refers to the file-scope variable of its name in the final
  # context ctx: "ok" (defined, with a compatible type), "undefined" or "type" (defined
  # with another type).
  externStatus =
    ctx: x:
    let
      g = ctx.globals.${x.name} or null;
    in
    if g == null || !g.defined then
      "undefined"
    else if compatible g.type x.type then
      "ok"
    else
      "type";

  # The size and alignment of an object of type t as the linker sees them: an array
  # without a length has size 0 and the alignment of its element, and an incomplete
  # struct or union size 0 and alignment 1.
  objectExtent =
    ctx: t:
    if isArray t && t.len == null then
      {
        size = 0;
        align = alignOfT ctx t.of;
      }
    else if !isComplete ctx t then
      {
        size = 0;
        align = 1;
      }
    else
      {
        size = sizeOfT ctx t;
        align = alignOfT ctx t;
      };

  # The first of the nodes xs in the source (see before).
  earliest = xs: foldl' (a: b: if before b a then b else a) (head xs) xs;

  # The references of the checked unit r (see usesOf): those of its file-scope objects and
  # of its function bodies.
  unitUses = r: concatMap (o: o.uses or [ ]) r.objects ++ concatMap (f: usesIn f.body) r.defs;

  # The functions used as values in the uses, each as its first "fnval" use, in the order
  # of their first uses.
  fnvalsIn =
    uses:
    let
      g = groupBy (u: u.name) (filter (u: u.use == "fnval") uses);
    in
    sort before (map (n: earliest g.${n}) (attrNames g));

  imap0 = f: xs: genList (i: f i (elemAt xs i)) (length xs);

  # The position of the use u in an import: { line; col; } and file when it has one.
  useAt = u: { inherit (u) line col; } // (if u ? file then { inherit (u) file; } else { });

  # The declarations of each variable name of the unit: the file-scope one (globals) and
  # the block-scope extern ones (externs, in source order), merged into the one that
  # gives an array length when any does. -> { decls = { <name> = { type; extent; }; };
  # bad; } with bad the first block-scope extern whose type does not agree with the
  # declarations before it (or null); extent is null for a file-scope declaration.
  mergeExterns =
    globals: externs:
    foldl'
      (
        st: x:
        let
          prev = st.decls.${x.name} or null;
        in
        if st.bad != null then
          st
        else if prev != null && !compatible prev.type x.type then
          st // { bad = x; }
        else
          st
          // {
            decls = st.decls // {
              ${x.name} = if prev == null || isArray prev.type && prev.type.len == null then x else prev;
            };
          }
      )
      {
        decls = builtins.mapAttrs (_: g: {
          inherit (g) type ltype;
          extent = null;
          defs = null;
        }) globals;
        bad = null;
      }
      externs;

  # Whether the call u (a "func" use) agrees with the signature s that the calls of its
  # name must have: their signatures agree (sameSig), and a call without arguments through
  # a declaration without a prototype is not one to a function with parameters (a call
  # with arguments through one is unsupported, see callExpr).
  callAgrees =
    s: u: sameSig s u.sig && !(u.sig.unspecified && u.nargs == 0 && !s.unspecified && s.params != [ ]);

  # The link interface of the checked unit r in link mode, from its uses (see usesOf), which
  # reads no address. -> { checks; imports; } with checks true or the first error of the
  # unit that link mode finds this way: a block-scope extern whose type disagrees with
  # another declaration of the name, a call through a block-scope declaration that the
  # file-scope one (or, without one, that of the first call) contradicts, and a call to a
  # function with internal linkage that is
  # declared but not defined. imports (see checkWith) are the variables used and not
  # defined, and the functions called and not defined that have external linkage.
  linkUnit =
    r:
    let
      uses = unitUses r;
      merged = mergeExterns r.ctx.globals (concatMap (f: declsIn "externs" f.body) r.defs);
      usesOfKind = k: groupBy (u: u.name) (filter (u: u.use == k) uses);
      varUses = usesOfKind "var";
      funcUses = usesOfKind "func";
      valUses = usesOfKind "fnval";
      # The direct calls and the uses as values of each function.
      fnUses = groupBy (u: u.name) (filter (u: u.use == "func" || u.use == "fnval") uses);
      fileFunc = n: r.funcs.${n} or null;
      linkageOfFunc = n: if fileFunc n == null then "external" else (fileFunc n).linkage;
      undefinedIn =
        byName: linkage:
        filter (
          n:
          let
            f = fileFunc n;
          in
          !(f != null && f.defined) && linkageOfFunc n == linkage
        ) (attrNames byName);
      undefinedFuncs = undefinedIn fnUses;
      internalCalls = concatMap (n: funcUses.${n}) (undefinedIn funcUses "internal");
      internalValues = concatMap (n: valUses.${n}) (undefinedIn valUses "internal");
      # The signature that the calls and values of n must have: the file-scope one, or
      # without one that of the first use.
      sigFor = n: if fileFunc n != null then fileFunc n else (earliest fnUses.${n}).sig;
      useAgrees =
        u: if u.use == "func" then callAgrees (sigFor u.name) u else sameSig (sigFor u.name) u.sig;
      conflicts = filter (u: !useAgrees u) (concatLists (attrValues fnUses));
      # The type definitions of the unit at its end, with those in scope at a block-scope
      # declaration (local, or null at file scope): a tag of the file may be completed
      # after the block, and a block-scope tag has an internal name of its own.
      defsWith =
        local:
        let
          u = scopeDefs r.ctx;
        in
        if local == null then
          u
        else
          {
            structs = u.structs // local.structs;
            enums = u.enums // local.enums;
          };
      importVar =
        n:
        let
          d = merged.decls.${n};
          e = if d.extent == null || isComplete r.ctx d.type then objectExtent r.ctx d.type else d.extent;
        in
        {
          name = n;
          inherit (d) type ltype;
          inherit (e) size align;
          defs = defsWith d.defs;
        }
        // useAt (earliest varUses.${n});
      importFunc =
        n:
        {
          name = n;
          inherit (sigFor n)
            ret
            params
            variadic
            lsig
            ;
          defs = defsWith (if fileFunc n != null then null else (earliest fnUses.${n}).defs);
          # The numbers of arguments of the direct calls.
          calls = map (u: u.nargs) (funcUses.${n} or [ ]);
        }
        // useAt (earliest fnUses.${n});
    in
    {
      checks =
        if merged.bad != null then
          fail merged.bad "redeclaration of '${merged.bad.name}' with a different type"
        else if conflicts != [ ] then
          fail (earliest conflicts) "conflicting types for '${(earliest conflicts).name}'"
        else if internalCalls != [ ] then
          unsupported (earliest internalCalls) "call to function '${(earliest internalCalls).name}' that is declared but not defined"
        else if internalValues != [ ] then
          undefinedValue (earliest internalValues)
        else
          true;
      imports = {
        vars = map importVar (filter (n: !(r.ctx.globals.${n}.defined or false)) (attrNames varUses));
        funcs = map importFunc (undefinedFuncs "external");
      };
      fnvals = map (
        u:
        let
          internal = linkageOfFunc u.name == "internal";
        in
        {
          inherit (u) name;
          inherit internal;
        }
        // useAt u
        // (if internal then { inherit (fileFunc u.name) ret params; } else { })
      ) (fnvalsIn uses);
    };

  # The error of the "fnval" use u of a function that is not defined where it must be.
  undefinedValue =
    u: unsupported u "function '${u.name}' used as a value that is declared but not defined";

  # The definitions with external linkage of the checked unit r (see checkWith).
  exportsOf = r: {
    vars = concatMap (
      o:
      let
        g = r.ctx.globals.${o.name} or null;
      in
      if g == null || g.linkage != "external" then
        [ ]
      else
        [
          {
            inherit (o) name addr;
            inherit (g) type ltype;
            size = o.end - o.addr;
            align = alignOfT r.ctx g.type;
            defs = scopeDefs r.ctx;
          }
        ]
    ) r.objects;
    funcs = concatMap (
      n:
      let
        f = r.funcs.${n};
      in
      if f.defined && f.linkage == "external" then
        [
          {
            name = n;
            inherit (f)
              ret
              params
              variadic
              lsig
              ;
            defs = scopeDefs r.ctx;
          }
        ]
      else
        [ ]
    ) (attrNames r.funcs);
  };

  # The data symbols of the checked unit r, with the linkage of each: that of a file-scope
  # variable, "none" for a static local or a local in memory.
  symbolsOf =
    r:
    map (o: {
      inherit (o) name addr;
      linkage = r.ctx.globals.${o.name}.linkage or "none";
    }) r.objects;

  checkWith =
    {
      dataBase,
      link ? null,
    }:
    unit:
    let
      r = checkItems dataBase link unit.items;
      lu = linkUnit r;
      allCalls = collect (x: kindOf x == "call") (_: false) r.defs;
      calls = filter (c: c ? name) allCalls;
      # The shapes of the calls through function pointers (sorted, each once).
      tables = attrNames (groupBy (x: x) (map (c: c.table) (filter (c: c ? table) allCalls)));
      fnvals = fnvalsIn (unitUses r);
      undefinedValues = filter (u: !(r.funcs.${u.name}.defined or false)) fnvals;
      undefinedCalls = filter (c: !(hasAttr c.name r.funcs) || !r.funcs.${c.name}.defined) calls;
      # A call through a block-scope declaration, or through one without a prototype, that
      # the file-scope one contradicts.
      conflicts = filter (
        c:
        let
          f = r.funcs.${c.name};
        in
        hasAttr c.name r.funcs
        && (
          !typesAgree f.ret c.type
          ||
            !f.unspecified
            && (
              length f.params != length c.args
              || !all (i: typesAgree (elemAt f.params i) (elemAt c.args i).type) (genList (i: i) (length c.args))
            )
        )
      ) calls;
      externs = filter (n: !r.ctx.globals.${n}.defined) (attrNames r.ctx.globals);
      blockExterns = filter (x: externStatus r.ctx x != "ok") (
        concatMap (f: declsIn "externs" f.body) r.defs
      );
      blockExtern = head blockExterns;
      # The first variable that ends above 2^32.
      overflow = head (filter (o: o.end > B.mask32 + 1) r.objects);
      overflowFail = fail overflow.at "the data does not fit below 2^32 from dataBase (variable '${overflow.name}')";
      # The string literals that end above 2^32 (after the variables, which end below).
      stringOverflows = filter (s: s.addr + s.size > B.mask32 + 1) r.strings.list;
      stringOverflowFail = fail (head stringOverflows).at "the data does not fit below 2^32 from dataBase (string literal)";
      extern = r.ctx.globals.${head externs};
      objectInits = map (w: { inherit (w) addr size value; }) (concatMap (o: o.writes) r.objects);
      stringInits = concatMap (s: byteWrites s.addr s.bytes) r.strings.list;
      size = if r.strings.list == [ ] then r.size else r.strings.end;
      layout = {
        inherit size;
        symbols = symbolsOf r;
        exports = exportsOf r;
        imports =
          if link == null then
            {
              vars = [ ];
              funcs = [ ];
            }
          else
            builtins.seq lu.checks lu.imports;
        fnvals = if link == null then [ ] else lu.fnvals;
      };
      result = {
        funcs = r.defs;
        inherit tables;
        data = {
          base = dataBase;
          inherit size;
          symbols = symbolsOf r;
          strings = map (s: { inherit (s) addr size; }) r.strings.list;
          inits = filter (w: w.value != 0) (objectInits ++ stringInits);
        };
      }
      // (
        if link == null then
          {
            fnvals = map (u: {
              inherit (u) name;
              inherit (r.funcs.${u.name}) ret params;
            }) fnvals;
          }
        else
          {
            link = {
              funcs = map (f: f.name) layout.imports.funcs;
              statics = map (u: u.name) (filter (u: u.internal) lu.fnvals);
            };
          }
      );
      single =
        if externs != [ ] then
          unsupported extern.at "extern variable '${head externs}' without a definition"
        else if blockExterns != [ ] && externStatus r.ctx blockExtern == "undefined" then
          unsupported blockExtern "extern variable '${blockExtern.name}' without a definition"
        else if blockExterns != [ ] then
          fail blockExtern "redeclaration of '${blockExtern.name}' with a different type"
        else if dataBase + r.size > B.mask32 + 1 then
          overflowFail
        else if conflicts != [ ] then
          fail (head conflicts) "conflicting types for '${(head conflicts).name}'"
        else if undefinedCalls != [ ] then
          unsupported (head undefinedCalls) "call to function '${(head undefinedCalls).name}' that is declared but not defined"
        else if undefinedValues != [ ] then
          undefinedValue (head undefinedValues)
        else if stringOverflows != [ ] then
          stringOverflowFail
        else
          builtins.deepSeq result result;
      linked = builtins.seq lu.checks (
        if dataBase + r.size > B.mask32 + 1 then
          overflowFail
        else if stringOverflows != [ ] then
          stringOverflowFail
        else
          builtins.deepSeq result result
      );
    in
    {
      inherit layout;
      checked =
        if !(isInt dataBase && dataBase >= 0 && dataBase <= B.mask32 && bitAnd dataBase 7 == 0) then
          # 8: the largest alignment (of a struct with a double).
          throw "cc: dataBase must be a multiple of 8 in 0..2^32-1"
        else if link == null then
          single
        else
          linked;
    };

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
