# C parser: source string -> syntax tree (hand-written recursive descent; binary
# operators by precedence climbing). Typedef names are tracked per scope, so a
# declaration and an expression or a cast are told apart as in C.
#
# Entry point: parse : string -> unit node. Errors are thrown as
# "cc: <line>:<col>: <message>", and as "cc: <line>:<col>: unsupported: <what>" for valid
# C outside the supported subset.
#
# Syntax tree
# -----------
# Every node is an attribute set with `kind` (a string) and the 1-based `line` and `col`
# of the token given below. Fields not listed do not exist. Lists keep source order.
#
# Types are plain values, not nodes (no position), so they compare with ==. Typedef names
# are already resolved to the type they stand for, and `const` is dropped:
#   { tag = <base>; }                one of "void", "char", "schar" (signed char),
#                                    "uchar", "int", "uint", "long", "ulong", "llong"
#   { tag = "ptr"; to = <type>; }    pointer
# `unsigned` and `unsigned int` are "uint"; `signed`, `signed int` and `int` are "int";
# `long int` and `signed long` are "long"; `long long` (with optional `int`/`signed`) is
# "llong". Specifiers may come in any order.
#
# Translation unit (line 1, col 1):
#   { kind = "unit"; items = [ <typedef | proto | func> ]; }
#
# File-scope items (position: the declared name):
#   { kind = "typedef"; name; type; }
#   { kind = "proto"; name; ret = <type>; params = [ <param> ]; }
#   { kind = "func"; name; ret = <type>; params = [ <param> ]; body = <block>; }
#   One declaration may declare several names (`int f(int), g(void);`); each becomes
#   its own item. A parameter list `()` or `(void)` gives params = [ ].
#
# Parameter (position: the name, or the first specifier token if unnamed):
#   { kind = "param"; name = <string or null>; type; }
#   name is null only in a proto; every param of a func has a name.
#
# Statements (position: the first token of the statement):
#   { kind = "block"; items = [ <statement> ]; }
#   { kind = "decl"; decls = [ <vardecl | typedef> ]; }      a block-scope declaration
#   { kind = "expr"; expr; }                                  expression statement
#   { kind = "empty"; }                                       `;`
#   { kind = "if"; cond; thenStmt; elseStmt = <statement or null>; }
#   { kind = "while"; cond; body; }
#   { kind = "do"; body; cond; }
#   { kind = "for"; init; cond; step; body; }
#       init is null, a "decl" statement or an expression; cond and step are an
#       expression or null.
#   { kind = "return"; expr = <expression or null>; }
#
# Block-scope declarators (position: the declared name):
#   { kind = "vardecl"; name; type; init = <expression or null>; }
#   { kind = "typedef"; name; type; }
#
# Expressions:
#   { kind = "intlit"; value; unsigned; long; text; }     literal; position: the literal
#       value is a non-negative integer, unsigned a bool (u/U suffix), long 0, 1 or 2
#       (no suffix, l/L, ll/LL), text the literal as written. `-1` is a "unary" node.
#   { kind = "ident"; name; }                              variable; position: the name
#   { kind = "call"; name; args = [ <expression> ]; }      direct call; position: the name
#   { kind = "cast"; type; expr; }                         position: the `(`
#   { kind = "unary"; op; expr; }                          op: "-" "~" "!"; position: op
#   { kind = "deref"; expr; }                              `*e`; position: the `*`
#   { kind = "index"; base; index; }                       `base[index]`; position: `[`
#   { kind = "prefix"; op; expr; }                         op: "++" "--"; position: op
#   { kind = "postfix"; op; expr; }                        op: "++" "--"; position: op
#   { kind = "binary"; op; lhs; rhs; }                     position: the operator
#       op: "*" "/" "%" "+" "-" "<<" ">>" "<" ">" "<=" ">=" "==" "!=" "&" "^" "|" "&&" "||"
#   { kind = "assign"; op; lhs; rhs; }                     position: the operator
#       op: "=" "*=" "/=" "%=" "+=" "-=" "<<=" ">>=" "&=" "^=" "|="
# Parentheses leave no node. Binary operators are left-associative and assignment is
# right-associative, with C precedence (from loosest): ||, &&, |, ^, &, == !=,
# < > <= >=, << >>, + -, * / %; then casts and prefix operators; then postfix operators.
#
# Left to the type checker: lvalue checks, the types of literals, implicit conversions,
# calls to undeclared functions, `return` placement, and side effects on the right of
# && and ||.
let
  L = import ./lex.nix;
  inherit (builtins)
    concatLists
    elemAt
    genericClosure
    genList
    hasAttr
    length
    listToAttrs
    map
    ;

  fail = t: msg: throw "cc: ${toString t.line}:${toString t.col}: ${msg}";
  unsupported = t: what: fail t "unsupported: ${what}";
  describe = t: if t.kind == "eof" then "end of input" else "'${t.text}'";

  mk =
    t: kind: fields:
    {
      inherit kind;
      inherit (t) line col;
    }
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
    "int"
    "long"
    "signed"
    "unsigned"
  ];
  # Declaration keywords outside the subset, with the description used in the error.
  rejected = {
    short = "short";
    float = "floating-point type";
    double = "floating-point type";
    struct = "struct";
    union = "union";
    enum = "enum";
    volatile = "volatile";
    restrict = "restrict";
    _Bool = "_Bool";
    _Complex = "_Complex";
    static = "storage class 'static'";
    extern = "storage class 'extern'";
    auto = "storage class 'auto'";
    register = "storage class 'register'";
    inline = "inline";
  };
  # Keywords that can start a type name.
  typeKeywords = setOf (
    counted
    ++ [
      "const"
      "short"
      "float"
      "double"
      "struct"
      "union"
      "enum"
      "volatile"
      "restrict"
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
  wrapPtrs = ty: k: if k == 0 then ty else wrapPtrs (ptrTo ty) (k - 1);

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
        (t.kind == "keyword" && hasAttr t.text declKeywords) || isTypeName tn t;

      # ---- Declarations ----

      # Declaration specifiers at i -> { type; typedef; i; }.
      specs =
        tn: i0:
        let
          first = tok i0;
          zero = {
            typedef = false;
            named = null;
            any = false;
            void = 0;
            char = 0;
            int = 0;
            long = 0;
            signed = 0;
            unsigned = 0;
          };
          go =
            i: acc:
            let
              t = tok i;
              x = t.text;
            in
            if t.kind == "keyword" then
              if x == "const" then
                go (i + 1) acc
              else if x == "typedef" then
                if acc.typedef then fail t "duplicate 'typedef'" else go (i + 1) (acc // { typedef = true; })
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
            else if !acc.any && isTypeName tn t then
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
            inherit (acc) typedef;
            inherit i;
          };
          invalid = fail first "invalid combination of type specifiers";
          baseType =
            a:
            let
              total = a.void + a.char + a.int + a.long + a.signed + a.unsigned;
              sign = a.signed + a.unsigned;
            in
            if a.named != null then
              if total > 0 then invalid else a.named
            else if total == 0 then
              fail first "expected a type specifier but found ${describe first}"
            else if a.void > 0 then
              if total == 1 then { tag = "void"; } else invalid
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

      # `*` (each optionally followed by `const`) -> { ptrs; i; }.
      pointers =
        i: k:
        if isP i "*" then
          pointers (i + 1) (k + 1)
        else if isKw i "const" && k > 0 then
          pointers (i + 1) k
        else
          {
            ptrs = k;
            inherit i;
          };

      # Declarator at i. mode: "named" (name required), "optional" (parameters) or
      # "abstract" (type names, no name). -> { name; nameTok; ptrs; params; i; } where
      # params is null unless this declares a function.
      declarator =
        tn: mode: i0:
        let
          p = pointers i0 0;
          t = tok p.i;
          hasName = t.kind == "ident" && mode != "abstract";
          i1 = if hasName then p.i + 1 else p.i;
          base = {
            name = if hasName then t.text else null;
            nameTok = t;
            inherit (p) ptrs;
          };
          fn = paramList tn (i1 + 1);
          afterFn = tok fn.i;
        in
        if !hasName && isP p.i "(" then
          if isP (p.i + 1) "*" then
            unsupported t "function pointer"
          else if mode != "named" && (isP (p.i + 1) ")" || startsDecl tn (p.i + 1)) then
            unsupported t "function type"
          else
            unsupported t "parenthesized declarator"
        else if !hasName && mode == "named" then
          fail t "expected an identifier but found ${describe t}"
        else if isP i1 "[" then
          unsupported (tok i1) "array declarator"
        else if isP i1 "(" then
          if isP fn.i "(" || isP fn.i "[" then
            unsupported afterFn "function returning a function or an array"
          else
            base
            // {
              inherit (fn) params i;
            }
        else
          base
          // {
            params = null;
            i = i1;
          };

      # Parameter list after `(` -> { params; i; } with i after `)`.
      paramList =
        tn: i:
        if isP i ")" then
          {
            params = [ ];
            i = i + 1;
          }
        else if isKw i "void" && isP (i + 1) ")" then
          {
            params = [ ];
            i = i + 2;
          }
        else
          paramsFrom tn i;
      paramsFrom =
        tn: i:
        let
          p = param tn i;
          rest = paramsFrom tn (p.i + 1);
        in
        if isP i "..." then
          unsupported (tok i) "variadic function"
        else if isP p.i "," then
          {
            params = [ p.node ] ++ rest.params;
            inherit (rest) i;
          }
        else
          {
            params = [ p.node ];
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
        else if d.params != null then
          unsupported d.nameTok "function pointer"
        else
          {
            node = mk at "param" {
              inherit (d) name;
              type = wrapPtrs sp.type d.ptrs;
            };
            inherit (d) i;
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
        else
          externalDeclarators tn sp sp.i true;

      externalDeclarators =
        tn: sp: i: first:
        let
          d = declarator tn "named" i;
          type = wrapPtrs sp.type d.ptrs;
          at = d.nameTok;
          item =
            if sp.typedef then
              if d.params != null then
                unsupported at "function type"
              else
                mk at "typedef" {
                  inherit (d) name;
                  inherit type;
                }
            else if d.params == null then
              unsupported at "global variable"
            else
              mk at "proto" {
                inherit (d) name params;
                ret = type;
              };
          tn' = if sp.typedef then tn // { ${d.name} = type; } else shadow tn d.name;
          isDef = first && !sp.typedef && d.params != null && isP d.i "{";
          rest = externalDeclarators tn' sp (d.i + 1) false;
        in
        if isDef then
          funcDef tn' d type
        else
          builtins.seq item (
            if isP d.i "," then
              {
                node = [ item ] ++ rest.node;
                inherit (rest) s;
              }
            else
              {
                node = [ item ];
                s = {
                  i = expect d.i ";";
                  tn = tn';
                };
              }
          );

      funcDef =
        tn: d: ret:
        let
          unnamed = builtins.filter (p: p.name == null) d.params;
          body = compound (shadowAll tn (map (p: p.name) d.params)) d.i;
        in
        if unnamed != [ ] then
          fail (builtins.head unnamed) "parameter name omitted in a function definition"
        else
          {
            node = [
              (mk d.nameTok "func" {
                inherit (d) name params;
                inherit ret;
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
          r = localDeclarators tn sp sp.i;
        in
        {
          node = mk (tok i) "decl" { decls = r.decls; };
          inherit (r) i tn;
        };
      localDeclarators =
        tn: sp: i:
        let
          d = declarator tn "named" i;
          type = wrapPtrs sp.type d.ptrs;
          at = d.nameTok;
          tn' = if sp.typedef then tn // { ${d.name} = type; } else shadow tn d.name;
          hasInit = isP d.i "=";
          init = assignExpr tn' (d.i + 1);
          next = if hasInit then init.i else d.i;
          item =
            if sp.typedef then
              mk at "typedef" {
                inherit (d) name;
                inherit type;
              }
            else
              mk at "vardecl" {
                inherit (d) name;
                inherit type;
                init = if hasInit then init.node else null;
              };
          rest = localDeclarators tn' sp (next + 1);
        in
        if d.params != null then
          unsupported at "block-scope function declaration"
        else if hasInit && sp.typedef then
          fail (tok d.i) "typedef with an initializer"
        else if hasInit && isP (d.i + 1) "{" then
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
          };

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
          else if
            builtins.elem x [
              "break"
              "continue"
              "goto"
              "switch"
              "case"
              "default"
            ]
          then
            unsupported t "'${x}' statement"
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

      # Full expression (no comma operator) -> { node; i; }.
      expr =
        tn: i:
        let
          e = assignExpr tn i;
        in
        if isP e.i "," then unsupported (tok e.i) "comma operator" else e;

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
          e = binary tn 1 i;
        in
        if isP e.i "?" then unsupported (tok e.i) "conditional operator" else e;

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
            unsupported t "address-of operator"
          else if x == "+" then
            unsupported t "unary '+'"
          else if x == "(" && startsType tn (i + 1) then
            castExpr tn i
          else
            postfix tn i
        else if t.kind == "keyword" && x == "sizeof" then
          unsupported t "sizeof"
        else
          postfix tn i;

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
        in
        if sp.typedef then
          fail (tok i) "'typedef' in a type name"
        else if d.params != null then
          unsupported (tok sp.i) "function type"
        else
          {
            type = wrapPtrs sp.type d.ptrs;
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
          unsupported t "member access"
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

      top = iterate external {
        i = 0;
        tn = { };
      };
    in
    mk {
      line = 1;
      col = 1;
    } "unit" { items = concatLists top.nodes; };

  # Every check above sits on the path that decides the next token index, so errors
  # surface while the items are iterated; deepSeq makes that independent of laziness.
  parse =
    src:
    let
      unit = parseTokens (L.lex src);
    in
    builtins.deepSeq unit unit;
in
{
  inherit parse;
}
