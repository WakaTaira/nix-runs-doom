# C parser: source string -> syntax tree (hand-written recursive descent; binary
# operators by precedence climbing). Typedef names are tracked per scope, so a
# declaration and an expression or a cast are told apart as in C.
#
# Entry points: parse : string -> unit node, parseNamed : name -> string -> unit node (a
# unit of a link, see below), and parseTokenList : tokens -> unit node (for the tokens of
# a preprocessed file, cc/lex.nix fromPp). Errors are thrown as
# "cc: <line>:<col>: <message>", and as "cc: <line>:<col>: unsupported: <what>" for valid
# C outside the supported subset; for a preprocessed file the position is
# "<file>:<line>:<col>", and every node also has `file` and `seq` (the index of its
# token in the translation unit, see cc/lex.nix fromPp), which identifies it where the
# position does in other input: the tokens of one macro expansion share a position. With
# parseNamed, every node has `file` (the name of the unit) and no `seq`, so the position
# is "<name>:<line>:<col>" (but in the errors of cc/lex.nix, which has no name) and
# nodes are identified by their position as with parse.
#
# Syntax tree
# -----------
# Every node is an attribute set with `kind` (a string) and the 1-based `line` and `col`
# of the token given below. Fields not listed do not exist. Lists keep source order.
#
# Types are plain values, not nodes (no position), so they compare with == (except that
# the length of an array type and the parameters of a function type are nodes, which carry
# their position). Typedef names are already resolved to the type they stand for, and the
# qualifiers `const`, `volatile`, `restrict` and `__restrict` are dropped:
#   { tag = <base>; }                one of "void", "char", "schar" (signed char),
#                                    "uchar", "short", "ushort", "int", "uint", "long",
#                                    "ulong", "llong", "float", "double"
#   { tag = "ptr"; to = <type>; }    pointer
#   { tag = "array"; of = <type>; len = <expression or null>; }
#                                    array; len is null for `[]`. `int m[2][3]` is an
#                                    array of 2 arrays of 3 int. Parameters keep their
#                                    array type (no adjustment to a pointer).
#   { tag = "fn"; ret = <type>; params = [ <param> ]; variadic; }
#                                    function; variadic tells that the parameter list
#                                    ends in `...`. A parameter list `()` or `(void)`
#                                    gives params = [ ]. Parameters keep their function
#                                    type, as they keep array types.
#   { tag = "struct"; name; }        struct, by tag; an anonymous struct gets the name
#                                    "(anonymous at <line>:<col>)" (of its keyword), or
#                                    "(anonymous at <file>:<line>:<col> #<index>)" in
#                                    a preprocessed file (index: of the keyword token)
#   { tag = "union"; name; }         union, by tag (named like struct)
#   { tag = "enum"; name; }          enum, by tag (named like struct)
#   { tag = "valist"; }              __builtin_va_list, a type name predefined like a
#                                    typedef (the va_list of stdarg.h)
# `unsigned` and `unsigned int` are "uint"; `signed`, `signed int` and `int` are "int";
# `long int` and `signed long` are "long"; `long long` (with optional `int`/`signed`) is
# "llong"; `short`, `short int` and `signed short` are "short", `unsigned short` (with
# optional `int`) is "ushort". Specifiers may come in any order. Declarators follow C,
# parentheses included (`int (*f[2])(void)` is an array of 2 pointers to functions). A
# declarator that makes a pointer to an array (`int (*p)[3]`), an array of functions or a
# function returning a function or an array is unsupported; a pointer to an array type
# named by a typedef (`typedef int A[3]; A *p;`) is accepted.
#
# `register` and `inline` are accepted and not recorded (`register` only at block scope
# and on parameters, `inline` only on functions). `__attribute__((...))` may appear among
# the specifiers, after `struct`, `union` or `enum`, after the `}` of their body, and after
# a declarator (and its bit-field width). The attributes noreturn, format, unused, used,
# deprecated, const, pure, malloc, nonnull, warn_unused_result, always_inline and noinline
# (also written with `__` around the name) are ignored; `packed` after `struct` or `union`
# or after the `}` of a definition makes it packed; anything else is unsupported.
#
# Translation unit (line 1, col 1):
#   { kind = "unit"; items = [ <typedef | proto | func | global | struct | union | enum> ]; }
#
# File-scope items (position: the declared name):
#   { kind = "typedef"; name; type; }
#   { kind = "proto"; name; ret = <type>; params = [ <param> ]; variadic; storage; }
#   { kind = "func"; name; ret = <type>; params = [ <param> ]; storage; body = <block>; }
#   { kind = "global"; name; type; storage; init = <initializer or null>; }
#       file-scope variable; storage is null, "static" or "extern".
#   One declaration may declare several names (`int f(int), g(void);`); each becomes
#   its own item. A declarator whose type is a function declares a proto or a func (ret,
#   params and variadic are those of the function type), whose storage is null, "static"
#   or "extern" as for variables. Defining a variadic function is unsupported.
#
# Tag definitions (position: the `struct`, `union` or `enum` keyword), at file scope as
# items and at block scope in the decls of a "decl" statement. They come before the
# declarators of their declaration, and a struct, union or enum defined inside a struct or
# union before it. At file scope, `struct s;` and the like without a body leave no node; at
# block scope, `struct s;` and `union s;` (which would declare a new tag hiding an outer
# one) are unsupported.
#   { kind = "struct" | "union"; name; members = [ <field> ]; packed; }
#       name as in the struct or union type; packed tells that the attribute is given
#   { kind = "field"; name; type; width = <expression or null>; }
#       position: the member name; width is the width of a bit-field (null otherwise).
#       An unnamed bit-field is unsupported.
#   { kind = "enum"; name; consts = [ <enumconst> ]; }  name as in the enum type
#   { kind = "enumconst"; name; value = <expression or null>; }
#       position: the name; value is null when not given (one more than the previous).
#
# Initializers (of a "global"): an expression, or
#   { kind = "initlist"; items = [ <initializer> ]; }   `{ ... }`; position: the `{`
#
# Parameter (position: the name, or the first specifier token if unnamed):
#   { kind = "param"; name = <string or null>; type; }
#   name is null only in a proto; every param of a func has a name.
#
# Statements (position: the first token of the statement):
#   { kind = "block"; items = [ <statement> ]; }
#   { kind = "decl"; decls = [ <vardecl | proto | typedef | struct | union | enum> ]; }
#       a block-scope declaration
#   { kind = "expr"; expr; }                                  expression statement
#   { kind = "empty"; }                                       `;`
#   { kind = "if"; cond; thenStmt; elseStmt = <statement or null>; }
#   { kind = "while"; cond; body; }
#   { kind = "do"; body; cond; }
#   { kind = "for"; init; cond; step; body; }
#       init is null, a "decl" statement or an expression; cond and step are an
#       expression or null.
#   { kind = "return"; expr = <expression or null>; }
#   { kind = "break"; }
#   { kind = "continue"; }
#   { kind = "switch"; cond; body = <statement>; }
#   { kind = "case"; value = <expression>; stmt = <statement>; }    `case value: stmt`
#   { kind = "default"; stmt = <statement>; }                       `default: stmt`
#       Labels wrap the statement they label, wherever they appear; `case 1: case 2: s`
#       is a case whose stmt is a case. In the usual form they are items of the block
#       that is a switch's body.
#
# Block-scope declarators (position: the declared name):
#   { kind = "vardecl"; name; type; storage; init = <initializer or null>; }
#       storage is null, "static" or "extern"; the initializer is an expression, or an
#       "initlist" for a static one (for others it is unsupported). An extern one has
#       no initializer.
#   { kind = "proto"; name; ret; params; variadic; storage; }
#                                                         function declaration; storage
#                                                         is null or "extern"
#   { kind = "typedef"; name; type; }
#
# Expressions:
#   { kind = "intlit"; value; unsigned; long; text; }     literal; position: the literal
#       value is a non-negative integer, unsigned a bool (u/U suffix), long 0, 1 or 2
#       (no suffix, l/L, ll/LL), text the literal as written. `-1` is a "unary" node.
#   { kind = "charlit"; value; text; }                     character literal (type int);
#       value is the character code, text the literal as written; position: the literal
#   { kind = "strlit"; bytes; }                            string literal (adjacent ones
#       joined, see cc/lex.nix); bytes are the byte values without the terminating 0;
#       position: the first literal
#   { kind = "ident"; name; }                              variable; position: the name
#   { kind = "call"; name; args = [ <expression> ]; }      direct call; position: the name
#   { kind = "cast"; type; expr; }                         position: the `(`
#   { kind = "unary"; op; expr; }                          op: "-" "~" "!"; position: op
#   { kind = "deref"; expr; }                              `*e`; position: the `*`
#   { kind = "addr"; expr; }                               `&e`; position: the `&`
#   { kind = "sizeof"; expr; }                             `sizeof e`; position: `sizeof`
#   { kind = "sizeoftype"; type; }                         `sizeof (type)`; position: `sizeof`
#   { kind = "index"; base; index; }                       `base[index]`; position: `[`
#   { kind = "dot"; expr; name; }                          `expr.name`; position: the `.`
#   { kind = "arrow"; expr; name; }                        `expr->name`; position: `->`
#   { kind = "prefix"; op; expr; }                         op: "++" "--"; position: op
#   { kind = "postfix"; op; expr; }                        op: "++" "--"; position: op
#   { kind = "binary"; op; lhs; rhs; }                     position: the operator
#       op: "*" "/" "%" "+" "-" "<<" ">>" "<" ">" "<=" ">=" "==" "!=" "&" "^" "|" "&&" "||"
#   { kind = "cond"; cond; thenExpr; elseExpr; }           `?:`; position: the `?`
#   { kind = "assign"; op; lhs; rhs; }                     position: the operator
#       op: "=" "*=" "/=" "%=" "+=" "-=" "<<=" ">>=" "&=" "^=" "|="
#   { kind = "comma"; lhs; rhs; }                          `lhs, rhs`; position: the `,`
# Parentheses leave no node. Binary operators and the comma operator are
# left-associative, and `?:` and assignment are right-associative, with C precedence (from
# loosest): comma, assignment, ?:, ||, &&, |, ^, &, == !=, < > <= >=, << >>, + -, * / %;
# then casts, prefix operators and sizeof; then postfix operators. As in C, arguments and
# initializers are assignment expressions and the middle operand of `?:` is an expression.
#
# Left to the type checker: lvalue checks, the types of literals, implicit conversions,
# calls to undeclared functions, `return` placement, the placement of `break`,
# `continue`, `case` and `default`, constant expressions (array lengths, bit-field widths,
# case labels, enum values, initializers), the meaning of struct, union and enum tags
# (scopes, completeness, duplicate members), bit-fields, and the uses of function
# pointers and floating-point types.
let
  L = import ./lex.nix;
  inherit (builtins)
    concatLists
    elemAt
    genericClosure
    genList
    hasAttr
    head
    length
    listToAttrs
    map
    ;

  # A token or node of a preprocessed file also has the file name (see cc/pp.nix).
  posText = t: "${if t ? file then "${t.file}:" else ""}${toString t.line}:${toString t.col}";
  fail = t: msg: throw "cc: ${posText t}: ${msg}";
  unsupported = t: what: fail t "unsupported: ${what}";
  describe = t: if t.kind == "eof" then "end of input" else "'${t.text}'";

  mk =
    t: kind: fields:
    {
      inherit kind;
      inherit (t) line col;
    }
    // (if t ? file then { inherit (t) file; } else { })
    // (if t ? seq then { inherit (t) seq; } else { })
    // fields;

  setOf =
    xs:
    listToAttrs (
      map (x: {
        name = x;
        value = true;
      }) xs
    );

  # Type specifiers that are counted and combined into a base type.
  counted = [
    "void"
    "char"
    "short"
    "int"
    "long"
    "signed"
    "unsigned"
    "float"
    "double"
  ];
  # Qualifiers, accepted and ignored (`__restrict` is an identifier token).
  qualifiers = setOf [
    "const"
    "volatile"
    "restrict"
  ];
  # Declaration keywords outside the subset, with the description used in the error.
  rejected = {
    _Bool = "_Bool";
    _Complex = "_Complex";
    auto = "storage class 'auto'";
  };
  # Attributes (named without the optional `__` around them) that do not change the
  # layout, accepted and ignored. `packed` is handled on struct and union definitions;
  # any other attribute is unsupported.
  ignoredAttrs = setOf [
    "noreturn"
    "format"
    "unused"
    "used"
    "deprecated"
    "const"
    "pure"
    "malloc"
    "nonnull"
    "warn_unused_result"
    "always_inline"
    "noinline"
  ];
  # Keywords that can start a type name.
  typeKeywords = setOf (
    counted
    ++ builtins.attrNames qualifiers
    ++ [
      "struct"
      "union"
      "enum"
      "_Bool"
      "_Complex"
    ]
  );
  # Keywords that can start a declaration.
  declKeywords =
    typeKeywords
    // setOf [
      "typedef"
      "static"
      "extern"
      "auto"
      "register"
      "inline"
    ];

  binPrec = {
    "||" = 1;
    "&&" = 2;
    "|" = 3;
    "^" = 4;
    "&" = 5;
    "==" = 6;
    "!=" = 6;
    "<" = 7;
    ">" = 7;
    "<=" = 7;
    ">=" = 7;
    "<<" = 8;
    ">>" = 8;
    "+" = 9;
    "-" = 9;
    "*" = 10;
    "/" = 10;
    "%" = 10;
  };
  assignOps = setOf [
    "="
    "*="
    "/="
    "%="
    "+="
    "-="
    "<<="
    ">>="
    "&="
    "^="
    "|="
  ];

  ptrTo = ty: {
    tag = "ptr";
    to = ty;
  };

  # One derivation of a declarator (see `declarator`) applied to the type acc.type; prev
  # is the kind of the derivation applied before it in the same declarator (null first).
  derive =
    acc: o:
    let
      t = acc.type;
    in
    {
      prev = o.op;
      type =
        if o.op == "ptr" then
          if acc.prev == "array" then unsupported o.tok "pointer to array declarator" else ptrTo t
        else if o.op == "array" then
          if t.tag == "fn" then
            unsupported o.tok "array of functions"
          else
            {
              tag = "array";
              of = t;
              inherit (o) len;
            }
        else if t.tag == "fn" || t.tag == "array" then
          unsupported o.tok "function returning a function or an array"
        else
          {
            tag = "fn";
            ret = t;
            inherit (o) params variadic;
          };
    };

  # The type declared by declarator d on the specifier type ty.
  declType =
    ty: d:
    (builtins.foldl' derive {
      type = ty;
      prev = null;
    } d.ops).type;

  # Hide a typedef name behind an ordinary identifier declared in an inner scope.
  shadow = tn: name: if hasAttr name tn then tn // { ${name} = null; } else tn;

  # Run `step` from state s0 iteratively (genericClosure), so long sequences do not
  # nest Nix calls. `step s` is null at the end of the sequence, or { node; s; }.
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

  parseTokens =
    toks:
    let
      n = length toks;
      tok = i: elemAt toks (if i < n then i else n - 1);
      isP =
        i: s:
        let
          t = tok i;
        in
        t.kind == "punct" && t.text == s;
      isKw =
        i: s:
        let
          t = tok i;
        in
        t.kind == "keyword" && t.text == s;
      expect =
        i: s: if isP i s then i + 1 else fail (tok i) "expected '${s}' but found ${describe (tok i)}";

      isTypeName = tn: t: t.kind == "ident" && hasAttr t.text tn && tn.${t.text} != null;
      startsType =
        tn: i:
        let
          t = tok i;
        in
        (t.kind == "keyword" && hasAttr t.text typeKeywords) || isTypeName tn t;
      startsDecl =
        tn: i:
        let
          t = tok i;
        in
        (t.kind == "keyword" && hasAttr t.text declKeywords) || isTypeName tn t || isAttr t;

      # ---- Attributes ----

      isAttr = t: t.kind == "ident" && t.text == "__attribute__";

      # `__attribute__((...))` specifiers from i on -> { attrs = [ { name; tok; } ]; i; },
      # with name stripped of the `__` around it.
      attributes =
        i:
        let
          r = attrItems (expect (expect (i + 1) "(") "(");
          rest = attributes (expect (expect r.i ")") ")");
        in
        if isAttr (tok i) then
          {
            attrs = r.attrs ++ rest.attrs;
            inherit (rest) i;
          }
        else
          {
            attrs = [ ];
            inherit i;
          };
      # The attributes inside `((` -> { attrs; i; } with i at the first `)`.
      attrItems =
        i:
        let
          t = tok i;
          m = builtins.match "__(.*)__" t.text;
          args = if isP (i + 1) "(" then afterParens (i + 1) 0 else i + 1;
          rest = attrItems (args + 1);
          attr = {
            name = if m == null then t.text else head m;
            tok = t;
          };
        in
        if isP i ")" then
          {
            attrs = [ ];
            inherit i;
          }
        else if isP i "," then
          attrItems (i + 1)
        else if t.kind != "ident" && t.kind != "keyword" then
          fail t "expected an attribute name but found ${describe t}"
        else if isP args "," then
          {
            attrs = [ attr ] ++ rest.attrs;
            inherit (rest) i;
          }
        else
          {
            attrs = [ attr ];
            i = args;
          };
      # Fails on an attribute that is not ignored, with packedError the description used in
      # the error for `packed` here (null when it is allowed); true otherwise.
      checkAttrs =
        packedError: attrs:
        builtins.all (
          a:
          if hasAttr a.name ignoredAttrs || (a.name == "packed" && packedError == null) then
            true
          else if a.name == "packed" then
            unsupported a.tok packedError
          else
            unsupported a.tok "attribute '${a.name}'"
        ) attrs;
      hasPacked = attrs: builtins.any (a: a.name == "packed") attrs;
      # Index after the attributes at i, which must all be ignored ones; packedError is the
      # description used in the error for `packed` there.
      skipAttrs =
        packedError: i:
        let
          r = attributes i;
        in
        builtins.seq (checkAttrs packedError r.attrs) r.i;

      # x, unless the specifiers sp have `inline` and do not declare a function (isFn),
      # which fails at the token at.
      inlineOnFunction =
        sp: isFn: at: x:
        if sp.inline && !isFn then fail at "'inline' can only appear on functions" else x;

      # ---- Declarations ----

      # Declaration specifiers at i -> { type; typedef; storage; register; inline; defs; tn; i; }.
      # storage is null, "static" or "extern"; register and inline tell that the keyword is
      # present (both are otherwise ignored); defs are the struct, union and enum definitions
      # met in the specifiers (nested ones first), and tn the scope with their enumerators
      # added. Qualifiers and the ignored attributes are skipped.
      specs =
        tn: i0:
        let
          first = tok i0;
          zero = {
            typedef = false;
            storage = null;
            register = false;
            inline = false;
            named = null;
            any = false;
            defs = [ ];
            inherit tn;
            void = 0;
            char = 0;
            short = 0;
            int = 0;
            long = 0;
            signed = 0;
            unsigned = 0;
            float = 0;
            double = 0;
          };
          go =
            i: acc:
            let
              t = tok i;
              x = t.text;
              storageTaken = acc.typedef || acc.storage != null || acc.register;
            in
            if t.kind == "keyword" then
              if hasAttr x qualifiers then
                go (i + 1) acc
              else if x == "typedef" then
                if acc.typedef then
                  fail t "duplicate 'typedef'"
                else if storageTaken then
                  fail t "multiple storage classes"
                else
                  go (i + 1) (acc // { typedef = true; })
              else if x == "static" || x == "extern" then
                if storageTaken then fail t "multiple storage classes" else go (i + 1) (acc // { storage = x; })
              else if x == "register" then
                if storageTaken then fail t "multiple storage classes" else go (i + 1) (acc // { register = true; })
              else if x == "inline" then
                go (i + 1) (acc // { inline = true; })
              else if x == "struct" || x == "union" || x == "enum" then
                let
                  tg = tagSpec acc.tn i;
                in
                if acc.any then
                  invalid
                else
                  go tg.i (
                    acc
                    // {
                      named = tg.type;
                      any = true;
                      defs = acc.defs ++ tg.defs;
                      inherit (tg) tn;
                    }
                  )
              else if builtins.elem x counted then
                go (i + 1) (
                  acc
                  // {
                    ${x} = acc.${x} + 1;
                    any = true;
                  }
                )
              else if hasAttr x rejected then
                unsupported t rejected.${x}
              else
                done i acc
            else if isAttr t then
              go (skipAttrs "'packed' outside a struct or union definition" i) acc
            else if !acc.any && isTypeName acc.tn t then
              go (i + 1) (
                acc
                // {
                  named = tn.${x};
                  any = true;
                }
              )
            else
              done i acc;
          done = i: acc: {
            type = baseType acc;
            inherit (acc)
              typedef
              storage
              register
              inline
              defs
              tn
              ;
            inherit i;
          };
          invalid = fail first "invalid combination of type specifiers";
          baseType =
            a:
            let
              total = a.void + a.char + a.short + a.int + a.long + a.signed + a.unsigned + a.float + a.double;
              sign = a.signed + a.unsigned;
            in
            if a.named != null then
              if total > 0 then invalid else a.named
            else if total == 0 then
              fail first "expected a type specifier but found ${describe first}"
            else if a.void > 0 then
              if total == 1 then { tag = "void"; } else invalid
            else if a.float > 0 then
              if total == 1 then { tag = "float"; } else invalid
            else if a.double > 0 then
              if a.double == 1 && a.long == 1 && total == 2 then
                unsupported first "long double"
              else if total == 1 then
                { tag = "double"; }
              else
                invalid
            else if a.short > 0 then
              if a.short > 1 || a.char > 0 || a.int > 1 || a.long > 0 || sign > 1 then
                invalid
              else
                { tag = if a.unsigned == 1 then "ushort" else "short"; }
            else if a.char > 0 then
              if a.char > 1 || a.int > 0 || a.long > 0 || sign > 1 then
                invalid
              else if a.signed == 1 then
                { tag = "schar"; }
              else if a.unsigned == 1 then
                { tag = "uchar"; }
              else
                { tag = "char"; }
            else if a.int > 1 || a.long > 2 || sign > 1 then
              invalid
            else if a.long == 2 then
              if a.unsigned == 1 then unsupported first "unsigned long long" else { tag = "llong"; }
            else if a.long == 1 then
              { tag = if a.unsigned == 1 then "ulong" else "long"; }
            else
              { tag = if a.unsigned == 1 then "uint" else "int"; };
          r = go i0 zero;
        in
        # Force the type so that specifier errors are raised here.
        builtins.seq r.type r;

      # `struct`, `union` or `enum` specifier at i (the keyword) -> { type; defs; tn; i; }.
      # Attributes may follow the keyword and the `}` of a definition; `packed` there makes
      # a struct or union definition packed.
      tagSpec =
        tn: i:
        let
          kw = tok i;
          lead = attributes (i + 1);
          tagTok = tok lead.i;
          hasTag = tagTok.kind == "ident";
          # In a preprocessed file, tokens of one macro expansion share a position, so the
          # index of the keyword makes the name unique.
          name =
            if hasTag then
              tagTok.text
            else if kw ? seq then
              "(anonymous at ${posText kw} #${toString i})"
            else
              "(anonymous at ${toString kw.line}:${toString kw.col})";
          j = if hasTag then lead.i + 1 else lead.i;
          type = {
            tag = kw.text;
            inherit name;
          };
          isEnum = kw.text == "enum";
          body = (if isEnum then enumBody else structBody) tn kw type (j + 1);
          trail = attributes body.i;
          attrs = lead.attrs ++ trail.attrs;
          onEnum = "'packed' on an enum";
          packedError = if isEnum then onEnum else null;
          def = body.def // (if isEnum then { } else { packed = hasPacked attrs; });
        in
        if isP j "{" then
          builtins.seq (checkAttrs packedError attrs) {
            inherit type;
            defs = body.nested ++ [ def ];
            inherit (body) tn;
            inherit (trail) i;
          }
        else if !hasTag then
          fail tagTok "expected a tag name or '{' after '${kw.text}' but found ${describe tagTok}"
        else
          builtins.seq
            (checkAttrs (
              if isEnum then onEnum else "'packed' on a ${kw.text} that is not defined here"
            ) lead.attrs)
            {
              inherit type tn;
              defs = [ ];
              i = j;
            };

      # Members of a struct or union after `{` -> { def; nested; tn; i; } with def its
      # definition node (without packed), nested the definitions in its members, and i
      # after `}`.
      structBody =
        tn: kw: type: i:
        let
          r = iterate memberDecl { inherit i tn; };
          fields = concatLists (map (m: m.fields) r.nodes);
        in
        if fields == [ ] then
          unsupported kw "empty ${kw.text}"
        else
          {
            def = mk kw kw.text {
              inherit (type) name;
              members = fields;
            };
            nested = concatLists (map (m: m.defs) r.nodes);
            inherit (r.s) tn;
            i = r.s.i + 1;
          };

      # Member declaration at s -> { node = { fields; defs; }; s; } or null at the `}`.
      memberDecl =
        s:
        let
          t = tok s.i;
          sp = specs s.tn s.i;
          r = memberDeclarators sp.tn sp sp.i;
        in
        if isP s.i "}" then
          null
        else if t.kind == "eof" then
          fail t "expected '}' but found end of input"
        else if !startsDecl s.tn s.i then
          fail t "expected a member declaration but found ${describe t}"
        else if sp.typedef || sp.storage != null || sp.register then
          fail t "storage class in a member declaration"
        else if isP sp.i ";" then
          unsupported t "anonymous struct member"
        else
          inlineOnFunction sp false t {
            node = {
              inherit (r) fields;
              inherit (sp) defs;
            };
            s = {
              inherit (r) i;
              inherit (sp) tn;
            };
          };
      memberDeclarators =
        tn: sp: i:
        let
          d = declarator tn "named" i;
          type = declType sp.type d;
          isBit = isP d.i ":";
          width = condExpr tn (d.i + 1);
          after = skipAttrs "'packed' on a member" (if isBit then width.i else d.i);
          field = mk d.nameTok "field" {
            inherit (d) name;
            inherit type;
            width = if isBit then width.node else null;
          };
          rest = memberDeclarators tn sp (after + 1);
        in
        if isP i ":" then
          unsupported (tok i) "unnamed bit-field"
        else if type.tag == "fn" then
          fail d.nameTok "field '${d.name}' declared as a function"
        else if isP after "," then
          {
            fields = [ field ] ++ rest.fields;
            inherit (rest) i;
          }
        else
          {
            fields = [ field ];
            i = expect after ";";
          };

      # Enumerators after `{` -> { def; nested = [ ]; tn; i; } with i after `}` (as
      # structBody).
      enumBody =
        tn: kw: type: i:
        let
          r = iterate enumerator { inherit i tn; };
        in
        if r.nodes == [ ] then
          fail (tok i) "expected an enumerator name but found ${describe (tok i)}"
        else
          {
            def = mk kw "enum" {
              inherit (type) name;
              consts = r.nodes;
            };
            nested = [ ];
            inherit (r.s) tn;
            i = r.s.i + 1;
          };

      # Enumerator at s -> { node; s; } or null at the `}`. Its name is in scope from the
      # next enumerator on.
      enumerator =
        s:
        let
          t = tok s.i;
          hasValue = isP (s.i + 1) "=";
          v = condExpr s.tn (s.i + 2);
          after = if hasValue then v.i else s.i + 1;
        in
        if isP s.i "}" then
          null
        else if t.kind != "ident" then
          fail t "expected an enumerator name but found ${describe t}"
        else
          {
            node = mk t "enumconst" {
              name = t.text;
              value = if hasValue then v.node else null;
            };
            s = {
              i =
                if isP after "," then
                  after + 1
                else if isP after "}" then
                  after
                else
                  fail (tok after) "expected ',' or '}' but found ${describe (tok after)}";
              tn = shadow s.tn t.text;
            };
          };

      # `*` (each optionally followed by qualifiers and attributes) -> { ptrs; i; }.
      pointers =
        i: k:
        let
          t = tok i;
        in
        if isP i "*" then
          pointers (i + 1) (k + 1)
        else if
          k > 0
          && (t.kind == "keyword" && hasAttr t.text qualifiers || t.kind == "ident" && t.text == "__restrict")
        then
          pointers (i + 1) k
        else if k > 0 && isAttr t then
          pointers (skipAttrs "'packed' on a declaration" i) k
        else
          {
            ptrs = k;
            inherit i;
          };

      # Index after the `)` that closes the `(` at i, called with d = 0 (d counts the open
      # parentheses); the index of the eof token when it is not closed.
      afterParens =
        i: d:
        if (tok i).kind == "eof" then
          i
        else if isP i "(" then
          afterParens (i + 1) (d + 1)
        else if !isP i ")" then
          afterParens (i + 1) d
        else if d == 1 then
          i + 1
        else
          afterParens (i + 1) (d - 1);

      # Declarator at i. mode: "named" (name required), "optional" (parameters) or
      # "abstract" (type names, no name). -> { name; nameTok; ops; i; } where ops are the
      # derivations in the order they apply to the specifier type (see declType), each
      # { op = "ptr"; tok; }, { op = "array"; len; tok; } (len an expression, or null for
      # `[]`) or { op = "fn"; params; variadic; tok; }. A declarator in parentheses nests:
      # the pointers before it and the suffixes after it apply first, then its own.
      declarator =
        tn: mode: i0:
        let
          p = pointers i0 0;
          t = tok p.i;
          hasName = t.kind == "ident" && !isAttr t && mode != "abstract";
          nested = !hasName && isP p.i "(" && opensDeclarator tn mode (p.i + 1);
          inner = declarator tn mode (p.i + 1);
          i1 =
            if hasName then
              p.i + 1
            else if nested then
              expect inner.i ")"
            else
              p.i;
          sfx = suffixes tn i1;
          own =
            genList (_: {
              op = "ptr";
              tok = tok i0;
            }) p.ptrs
            ++ builtins.foldl' (acc: o: [ o ] ++ acc) [ ] sfx.ops;
        in
        if nested then
          {
            inherit (inner) name nameTok;
            ops = own ++ inner.ops;
            inherit (sfx) i;
          }
        else if !hasName && mode == "named" then
          fail t "expected an identifier but found ${describe t}"
        else
          {
            name = if hasName then t.text else null;
            nameTok = t;
            ops = own;
            inherit (sfx) i;
          };

      # Whether the `(` before index j opens a nested declarator rather than a parameter
      # list (of an abstract or unnamed function declarator).
      opensDeclarator =
        tn: mode: j:
        let
          t = tok j;
        in
        mode == "named"
        || isP j "*"
        || isP j "("
        || isP j "["
        || (mode == "optional" && t.kind == "ident" && !isTypeName tn t && !isAttr t);

      # Array and function suffixes at i -> { ops; i; } with ops in source order.
      suffixes =
        tn: i:
        let
          empty = isP (i + 1) "]";
          len = condExpr tn (i + 1);
          afterDim = if empty then i + 2 else expect len.i "]";
          fn = paramList tn (i + 1);
          next = suffixes tn (if isP i "[" then afterDim else fn.i);
          op =
            if isP i "[" then
              {
                op = "array";
                len = if empty then null else len.node;
                tok = tok i;
              }
            else
              {
                op = "fn";
                inherit (fn) params variadic;
                tok = tok i;
              };
        in
        if isP i "[" || isP i "(" then
          {
            ops = [ op ] ++ next.ops;
            inherit (next) i;
          }
        else
          {
            ops = [ ];
            inherit i;
          };

      # Parameter list after `(` -> { params; variadic; i; } with i after `)`.
      paramList =
        tn: i:
        if isP i ")" then
          {
            params = [ ];
            variadic = false;
            i = i + 1;
          }
        else if isKw i "void" && isP (i + 1) ")" then
          {
            params = [ ];
            variadic = false;
            i = i + 2;
          }
        else if isP i "..." then
          fail (tok i) "ISO C requires a named parameter before '...'"
        else
          paramsFrom tn i;
      paramsFrom =
        tn: i:
        let
          p = param tn i;
          rest = paramsFrom tn (p.i + 1);
        in
        if isP i "..." then
          {
            params = [ ];
            variadic = true;
            i = expect (i + 1) ")";
          }
        else if isP p.i "," then
          {
            params = [ p.node ] ++ rest.params;
            inherit (rest) variadic i;
          }
        else
          {
            params = [ p.node ];
            variadic = false;
            i = expect p.i ")";
          };
      param =
        tn: i:
        let
          sp = specs tn i;
          d = declarator tn "optional" sp.i;
          at = if d.name != null then d.nameTok else tok i;
        in
        if !startsDecl tn i then
          fail (tok i) "expected a parameter declaration but found ${describe (tok i)}"
        else if sp.typedef then
          fail (tok i) "'typedef' in a parameter declaration"
        else if sp.storage != null then
          fail (tok i) "storage class in a parameter declaration"
        else if sp.defs != [ ] then
          unsupported (tok i) "type definition in a parameter declaration"
        else
          inlineOnFunction sp false (tok i) {
            node = mk at "param" {
              inherit (d) name;
              type = declType sp.type d;
            };
            i = skipAttrs "'packed' on a parameter" d.i;
          };

      # Names of params as ordinary identifiers in the scope tn.
      shadowAll = tn: names: builtins.foldl' shadow tn names;

      # File-scope declaration at s -> { node = [ items ]; s; } or null at the end.
      external =
        s:
        let
          inherit (s) i tn;
          sp = specs tn i;
        in
        if (tok i).kind == "eof" then
          null
        else if !startsDecl tn i then
          fail (tok i) "expected a declaration but found ${describe (tok i)}"
        else if isP sp.i ";" then
          builtins.seq (declaresTag sp i) {
            node = sp.defs;
            s = {
              i = sp.i + 1;
              inherit (sp) tn;
            };
          }
        else
          let
            r = externalDeclarators sp.tn sp sp.i true;
          in
          {
            node = sp.defs ++ r.node;
            inherit (r) s;
          };

      # A declaration without declarators must declare a struct, union or enum tag.
      declaresTag =
        sp: i:
        if
          builtins.elem sp.type.tag [
            "struct"
            "union"
            "enum"
          ]
        then
          true
        else
          fail (tok i) "declaration does not declare anything";

      # The declarator at i with the attributes after it -> the declarator with its type
      # (type) and with i after the attributes.
      declared =
        tn: sp: i:
        let
          d = declarator tn "named" i;
          type = declType sp.type d;
        in
        d
        // {
          inherit type;
          isFn = type.tag == "fn";
          i = skipAttrs "'packed' on a declaration" d.i;
        };

      # The proto node of a function declaration d (see `declared`) with the specifiers sp.
      protoNode =
        sp: d:
        mk d.nameTok "proto" {
          inherit (d) name;
          inherit (d.type) params variadic ret;
          inherit (sp) storage;
        };

      externalDeclarators =
        tn: sp: i: first:
        let
          d = declared tn sp i;
          inherit (d) type;
          at = d.nameTok;
          hasInit = isP d.i "=";
          init = initializer tn' (d.i + 1);
          next = if hasInit then init.i else d.i;
          item =
            if sp.typedef then
              if d.isFn then
                unsupported at "function type"
              else
                mk at "typedef" {
                  inherit (d) name;
                  inherit type;
                }
            else if !d.isFn then
              mk at "global" {
                inherit (d) name;
                inherit type;
                inherit (sp) storage;
                init = if hasInit then init.node else null;
              }
            else
              protoNode sp d;
          tn' = if sp.typedef then tn // { ${d.name} = type; } else shadow tn d.name;
          isDef = first && !sp.typedef && d.isFn && isP d.i "{";
          rest = externalDeclarators tn' sp (next + 1) false;
        in
        if sp.register then
          fail at "illegal storage class 'register' at file scope"
        else if isDef then
          inlineOnFunction sp d.isFn at (funcDef tn' sp d)
        else if hasInit && sp.typedef then
          fail (tok d.i) "typedef with an initializer"
        else if hasInit && d.isFn then
          fail (tok d.i) "illegal initializer"
        else
          inlineOnFunction sp d.isFn at (
            builtins.seq item (
              if isP next "," then
                {
                  node = [ item ] ++ rest.node;
                  inherit (rest) s;
                }
              else
                {
                  node = [ item ];
                  s = {
                    i = expect next ";";
                    tn = tn';
                  };
                }
            )
          );

      # Initializer at i (after `=`) -> { node; i; }: an expression or an "initlist".
      initializer = tn: i: if isP i "{" then initList tn i else assignExpr tn i;

      # `{ ... }` initializer list at i -> { node; i; } with i after `}`.
      initList =
        tn: i:
        let
          r = iterate (initItem tn) { i = i + 1; };
        in
        if r.nodes == [ ] then
          unsupported (tok i) "empty initializer list"
        else
          {
            node = mk (tok i) "initlist" { items = r.nodes; };
            i = r.s.i + 1;
          };
      initItem =
        tn: s:
        let
          x = initializer tn s.i;
        in
        if isP s.i "}" then
          null
        else if isP s.i "." || isP s.i "[" then
          unsupported (tok s.i) "designated initializer"
        else
          {
            inherit (x) node;
            s = {
              i =
                if isP x.i "," then
                  x.i + 1
                else if isP x.i "}" then
                  x.i
                else
                  fail (tok x.i) "expected ',' or '}' but found ${describe (tok x.i)}";
            };
          };

      funcDef =
        tn: sp: d:
        let
          inherit (d.type) params;
          unnamed = builtins.filter (p: p.name == null) params;
          body = compound (shadowAll tn (map (p: p.name) params)) d.i;
        in
        if d.type.variadic then
          unsupported d.nameTok "definition of a variadic function"
        else if unnamed != [ ] then
          fail (head unnamed) "parameter name omitted in a function definition"
        else
          {
            node = [
              (mk d.nameTok "func" {
                inherit (d) name;
                inherit params;
                inherit (d.type) ret;
                inherit (sp) storage;
                body = body.node;
              })
            ];
            s = {
              inherit (body) i;
              inherit tn;
            };
          };

      # Block-scope declaration at i (consumes the `;`) -> { node; i; tn; }.
      localDecl =
        tn: i:
        let
          sp = specs tn i;
          r =
            if isP sp.i ";" then
              builtins.seq (declaresTag sp i) {
                decls = [ ];
                i = sp.i + 1;
                inherit (sp) tn;
              }
            else
              localDeclarators sp.tn sp sp.i;
          # `struct T;` would declare a new tag hiding an outer one, which the checker does
          # not model.
          tagOnly = isP sp.i ";" && sp.defs == [ ] && (sp.type.tag == "struct" || sp.type.tag == "union");
        in
        if tagOnly then
          unsupported (tok i) "block-scope tag declaration"
        else
          {
            node = mk (tok i) "decl" { decls = sp.defs ++ r.decls; };
            inherit (r) i tn;
          };
      localDeclarators =
        tn: sp: i:
        let
          d = declared tn sp i;
          inherit (d) type;
          at = d.nameTok;
          tn' = if sp.typedef then tn // { ${d.name} = type; } else shadow tn d.name;
          hasInit = isP d.i "=";
          isList = hasInit && isP (d.i + 1) "{";
          init = if isList then initList tn' (d.i + 1) else assignExpr tn' (d.i + 1);
          next = if hasInit then init.i else d.i;
          item =
            if sp.typedef then
              mk at "typedef" {
                inherit (d) name;
                inherit type;
              }
            else if d.isFn then
              protoNode sp d
            else
              mk at "vardecl" {
                inherit (d) name;
                inherit type;
                inherit (sp) storage;
                init = if hasInit then init.node else null;
              };
          rest = localDeclarators tn' sp (next + 1);
        in
        inlineOnFunction sp d.isFn at (
          if sp.typedef && d.isFn then
            unsupported at "function type"
          else if d.isFn && (sp.storage == "static" || sp.register) then
            fail at "invalid storage class for the block-scope function '${d.name}'"
          else if hasInit && sp.typedef then
            fail (tok d.i) "typedef with an initializer"
          else if hasInit && d.isFn then
            fail (tok d.i) "illegal initializer"
          else if hasInit && sp.storage == "extern" then
            fail (tok d.i) "block-scope 'extern' declaration with an initializer"
          else if isList && sp.storage != "static" then
            unsupported (tok (d.i + 1)) "initializer list"
          else if isP next "," then
            {
              decls = [ item ] ++ rest.decls;
              inherit (rest) i tn;
            }
          else
            {
              decls = [ item ];
              i = expect next ";";
              tn = tn';
            }
        );

      # ---- Statements ----

      # `{ ... }` at i -> { node; i; }.
      compound =
        tn: i:
        let
          r = iterate blockItem {
            i = expect i "{";
            inherit tn;
          };
        in
        {
          node = mk (tok i) "block" { items = r.nodes; };
          i = r.s.i + 1;
        };
      blockItem =
        s:
        let
          d = localDecl s.tn s.i;
          st = stmt s.tn s.i;
        in
        if isP s.i "}" then
          null
        else if (tok s.i).kind == "eof" then
          fail (tok s.i) "expected '}' but found end of input"
        else if startsDecl s.tn s.i then
          {
            inherit (d) node;
            s = {
              inherit (d) i tn;
            };
          }
        else
          {
            inherit (st) node;
            s = {
              inherit (st) i;
              inherit (s) tn;
            };
          };

      # Parenthesized condition `( expr )` at i -> { node; i; }.
      parenExpr =
        tn: i:
        let
          e = expr tn (expect i "(");
        in
        {
          inherit (e) node;
          i = expect e.i ")";
        };

      stmt =
        tn: i:
        let
          t = tok i;
          x = t.text;
          node = mk t;
        in
        if t.kind == "punct" && x == "{" then
          compound tn i
        else if t.kind == "punct" && x == ";" then
          {
            node = node "empty" { };
            i = i + 1;
          }
        else if t.kind == "keyword" then
          if x == "if" then
            let
              c = parenExpr tn (i + 1);
              th = stmt tn c.i;
              hasElse = isKw th.i "else";
              el = stmt tn (th.i + 1);
            in
            {
              node = node "if" {
                cond = c.node;
                thenStmt = th.node;
                elseStmt = if hasElse then el.node else null;
              };
              i = if hasElse then el.i else th.i;
            }
          else if x == "while" then
            let
              c = parenExpr tn (i + 1);
              b = stmt tn c.i;
            in
            {
              node = node "while" {
                cond = c.node;
                body = b.node;
              };
              inherit (b) i;
            }
          else if x == "do" then
            let
              b = stmt tn (i + 1);
              c = parenExpr tn (expectKw b.i "while");
            in
            {
              node = node "do" {
                body = b.node;
                cond = c.node;
              };
              i = expect c.i ";";
            }
          else if x == "for" then
            forStmt tn i
          else if x == "return" then
            let
              e = expr tn (i + 1);
              hasExpr = !isP (i + 1) ";";
            in
            {
              node = node "return" { expr = if hasExpr then e.node else null; };
              i = expect (if hasExpr then e.i else i + 1) ";";
            }
          else if x == "break" || x == "continue" then
            {
              node = node x { };
              i = expect (i + 1) ";";
            }
          else if x == "switch" then
            let
              c = parenExpr tn (i + 1);
              b = stmt tn c.i;
            in
            {
              node = node "switch" {
                cond = c.node;
                body = b.node;
              };
              inherit (b) i;
            }
          else if x == "case" then
            let
              v = condExpr tn (i + 1);
              st = stmt tn (expect v.i ":");
            in
            {
              node = node "case" {
                value = v.node;
                stmt = st.node;
              };
              inherit (st) i;
            }
          else if x == "default" then
            let
              st = stmt tn (expect (i + 1) ":");
            in
            {
              node = node "default" { stmt = st.node; };
              inherit (st) i;
            }
          else if x == "goto" then
            unsupported t "'goto' statement"
          else if hasAttr x declKeywords then
            fail t "expected a statement but found a declaration"
          else
            exprStmt tn i
        else if t.kind == "ident" && isP (i + 1) ":" then
          unsupported t "label"
        else
          exprStmt tn i;

      expectKw =
        i: s: if isKw i s then i + 1 else fail (tok i) "expected '${s}' but found ${describe (tok i)}";

      exprStmt =
        tn: i:
        let
          e = expr tn i;
        in
        {
          node = mk (tok i) "expr" { expr = e.node; };
          i = expect e.i ";";
        };

      forStmt =
        tn: i:
        let
          i0 = expect (i + 1) "(";
          isDecl = startsDecl tn i0;
          d = localDecl tn i0;
          e = expr tn i0;
          init =
            if isP i0 ";" then
              {
                node = null;
                i = i0 + 1;
                inherit tn;
              }
            else if isDecl then
              d
            else
              {
                inherit (e) node;
                i = expect e.i ";";
                inherit tn;
              };
          ftn = init.tn;
          c = expr ftn init.i;
          cond =
            if isP init.i ";" then
              {
                node = null;
                i = init.i + 1;
              }
            else
              {
                inherit (c) node;
                i = expect c.i ";";
              };
          st = expr ftn cond.i;
          step =
            if isP cond.i ")" then
              {
                node = null;
                i = cond.i + 1;
              }
            else
              {
                inherit (st) node;
                i = expect st.i ")";
              };
          body = stmt ftn step.i;
        in
        {
          node = mk (tok i) "for" {
            init = init.node;
            cond = cond.node;
            step = step.node;
            body = body.node;
          };
          inherit (body) i;
        };

      # ---- Expressions ----

      # Expression, with the comma operator (left-associative) -> { node; i; }.
      expr = tn: i: commaRest tn (assignExpr tn i);
      commaRest =
        tn: lhs:
        let
          t = tok lhs.i;
          rhs = assignExpr tn (lhs.i + 1);
        in
        if isP lhs.i "," then
          commaRest tn {
            node = mk t "comma" {
              lhs = lhs.node;
              rhs = rhs.node;
            };
            inherit (rhs) i;
          }
        else
          lhs;

      assignExpr =
        tn: i:
        let
          lhs = condExpr tn i;
          t = tok lhs.i;
          rhs = assignExpr tn (lhs.i + 1);
        in
        if t.kind == "punct" && hasAttr t.text assignOps then
          {
            node = mk t "assign" {
              op = t.text;
              lhs = lhs.node;
              rhs = rhs.node;
            };
            inherit (rhs) i;
          }
        else
          lhs;

      condExpr =
        tn: i:
        let
          c = binary tn 1 i;
          th = expr tn (c.i + 1);
          el = condExpr tn (expect th.i ":");
        in
        if isP c.i "?" then
          {
            node = mk (tok c.i) "cond" {
              cond = c.node;
              thenExpr = th.node;
              elseExpr = el.node;
            };
            inherit (el) i;
          }
        else
          c;

      precOf = t: if t.kind == "punct" && hasAttr t.text binPrec then binPrec.${t.text} else 0;

      # Operators of precedence >= minPrec, starting with a unary operand at i.
      binary =
        tn: minPrec: i:
        climb tn minPrec (unary tn i);
      climb =
        tn: minPrec: lhs:
        let
          t = tok lhs.i;
          p = precOf t;
          rhs = binary tn (p + 1) (lhs.i + 1);
        in
        if p == 0 || p < minPrec then
          lhs
        else
          climb tn minPrec {
            node = mk t "binary" {
              op = t.text;
              lhs = lhs.node;
              rhs = rhs.node;
            };
            inherit (rhs) i;
          };

      # Unary and cast expressions.
      unary =
        tn: i:
        let
          t = tok i;
          x = t.text;
          operand = unary tn (i + 1);
          withOperand = kind: fields: {
            node = mk t kind ({ expr = operand.node; } // fields);
            inherit (operand) i;
          };
        in
        if t.kind == "punct" then
          if x == "++" || x == "--" then
            withOperand "prefix" { op = x; }
          else if x == "-" || x == "~" || x == "!" then
            withOperand "unary" { op = x; }
          else if x == "*" then
            withOperand "deref" { }
          else if x == "&" then
            withOperand "addr" { }
          else if x == "+" then
            unsupported t "unary '+'"
          else if x == "(" && startsType tn (i + 1) then
            castExpr tn i
          else
            postfix tn i
        else if t.kind == "keyword" && x == "sizeof" then
          sizeofExpr tn i
        else
          postfix tn i;

      # `sizeof ( type-name )` or `sizeof unary-expression` at i.
      sizeofExpr =
        tn: i:
        let
          isType = isP (i + 1) "(" && startsType tn (i + 2);
          ty = typeName tn (i + 2);
          close = expect ty.i ")";
          e = unary tn (i + 1);
        in
        if isType then
          if isP close "{" then
            unsupported (tok close) "compound literal"
          else
            {
              node = mk (tok i) "sizeoftype" { inherit (ty) type; };
              i = close;
            }
        else
          {
            node = mk (tok i) "sizeof" { expr = e.node; };
            inherit (e) i;
          };

      castExpr =
        tn: i:
        let
          ty = typeName tn (i + 1);
          close = expect ty.i ")";
          e = unary tn close;
        in
        if isP close "{" then
          unsupported (tok close) "compound literal"
        else
          {
            node = mk (tok i) "cast" {
              inherit (ty) type;
              expr = e.node;
            };
            inherit (e) i;
          };

      # Type name (in a cast) at i -> { type; i; }.
      typeName =
        tn: i:
        let
          sp = specs tn i;
          d = declarator tn "abstract" sp.i;
          type = declType sp.type d;
        in
        if sp.typedef then
          fail (tok i) "'typedef' in a type name"
        else if sp.storage != null || sp.register then
          fail (tok i) "storage class in a type name"
        else if sp.defs != [ ] then
          unsupported (tok i) "type definition in a type name"
        else if type.tag == "fn" then
          unsupported (tok sp.i) "function type"
        else
          inlineOnFunction sp false (tok i) {
            inherit type;
            inherit (d) i;
          };

      postfix =
        tn: i:
        let
          p = primary tn i;
        in
        postfixOps tn p;
      postfixOps =
        tn: e:
        let
          t = tok e.i;
          x = t.text;
          idx = expr tn (e.i + 1);
          args = argList tn (e.i + 1);
          member = tok (e.i + 1);
        in
        if t.kind != "punct" then
          e
        else if x == "[" then
          postfixOps tn {
            node = mk t "index" {
              base = e.node;
              index = idx.node;
            };
            i = expect idx.i "]";
          }
        else if x == "(" then
          if e.node.kind == "ident" then
            postfixOps tn {
              node = mk e.node "call" {
                inherit (e.node) name;
                args = args.list;
              };
              inherit (args) i;
            }
          else
            unsupported t "indirect call"
        else if x == "++" || x == "--" then
          postfixOps tn {
            node = mk t "postfix" {
              op = x;
              expr = e.node;
            };
            i = e.i + 1;
          }
        else if x == "." || x == "->" then
          if member.kind != "ident" then
            fail member "expected a member name but found ${describe member}"
          else
            postfixOps tn {
              node = mk t (if x == "." then "dot" else "arrow") {
                expr = e.node;
                name = member.text;
              };
              i = e.i + 2;
            }
        else
          e;

      # Arguments after `(` -> { list; i; } with i after `)`.
      argList =
        tn: i:
        if isP i ")" then
          {
            list = [ ];
            i = i + 1;
          }
        else
          argsFrom tn i;
      argsFrom =
        tn: i:
        let
          a = assignExpr tn i;
          rest = argsFrom tn (a.i + 1);
        in
        if isP a.i "," then
          {
            list = [ a.node ] ++ rest.list;
            inherit (rest) i;
          }
        else
          {
            list = [ a.node ];
            i = expect a.i ")";
          };

      primary =
        tn: i:
        let
          t = tok i;
          e = expr tn (i + 1);
        in
        if t.kind == "int" then
          {
            node = mk t "intlit" {
              inherit (t)
                value
                unsigned
                long
                text
                ;
            };
            i = i + 1;
          }
        else if t.kind == "char" then
          {
            node = mk t "charlit" { inherit (t) value text; };
            i = i + 1;
          }
        else if t.kind == "string" then
          {
            node = mk t "strlit" { inherit (t) bytes; };
            i = i + 1;
          }
        else if t.kind == "ident" then
          if isTypeName tn t then
            fail t "expected an expression but found type name '${t.text}'"
          else
            {
              node = mk t "ident" { name = t.text; };
              i = i + 1;
            }
        else if t.kind == "punct" && t.text == "(" then
          {
            inherit (e) node;
            i = expect e.i ")";
          }
        else
          fail t "expected an expression but found ${describe t}";

      # __builtin_va_list is predefined like a typedef name (see the header).
      top = iterate external {
        i = 0;
        tn = {
          __builtin_va_list = {
            tag = "valist";
          };
        };
      };
    in
    mk {
      line = 1;
      col = 1;
    } "unit" { items = concatLists top.nodes; };

  # Every check above sits on the path that decides the next token index, so errors
  # surface while the items are iterated; deepSeq makes that independent of laziness.
  parse = src: parseTokenList (L.lex src);

  # The unit node of the source src of the unit named name (cc/link.nix): as parse, but
  # every token and node also has file = name, so that errors are at
  # "<name>:<line>:<col>". Nothing else changes (anonymous tags and the identity of nodes
  # stay those of parse, as they have no seq).
  parseNamed = name: src: parseTokenList (map (t: t // { file = name; }) (L.lex src));

  # The unit node of a token list (as produced by cc/lex.nix lex or fromPp).
  parseTokenList =
    toks:
    let
      unit = parseTokens toks;
    in
    builtins.deepSeq unit unit;
in
{
  inherit parse parseNamed parseTokenList;
}
