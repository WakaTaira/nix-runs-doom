# C code generator: typed syntax tree (cc/check.nix) -> Nix source.
#
# Entry point: emit : { funcs; } -> string. The output is the source of a function
#   { M, B, R }: { <C function name> = <Nix function>; ... }
# with M = lib/mem.nix, B = lib/bits.nix and R = cc/runtime.nix. It imports nothing, so
# it can be loaded from the store (cc/default.nix). The translation is mechanical, with
# no optimization:
#   - A C function becomes `mem: <params>:` returning the new memory, or { mem; ret; }
#     when it returns a value.
#   - Locals become let bindings, with a new name for each assignment. Assigning a plain
#     name or a non-negative constant only renames.
#   - Every loop becomes `R.loop cond body vars`. vars holds mem and the variables that
#     are declared outside the loop and assigned in it; the others are read from the
#     enclosing scope. A do/while loop, and a loop whose condition has side effects,
#     tests inside the body and sets `exit`.
#   - if/else becomes an attribute set of mem and the variables either branch changes,
#     which the following code reads.
#   - Side effects in expressions (assignments, ++ and --, calls, stores) become let
#     bindings in C evaluation order; pure expressions stay nested.
#   - Conditions are Nix booleans; a comparison is 0 or 1 only where its value is used.
#   - Values wrap modulo 2^32 only where C wraps them (unsigned and pointer arithmetic,
#     conversions); signed arithmetic does not wrap.
# Value representation: char, signed char, int, long and long long are signed Nix
# integers; unsigned types and pointers are non-negative. Memory words are stored in
# the unsigned form.
#
# Generated names are `<C name>_<n>` (parameters `<C name>_0`) with n unique within a
# function, and `<C name>_fn` for functions, so they collide neither with each other nor
# with M, B, R, mem and the builtins the output uses.
let
  Ch = import ./check.nix;
  T = Ch.types;
  B = import ../lib/bits.nix;
  inherit (builtins)
    attrNames
    concatMap
    concatStringsSep
    elem
    elemAt
    filter
    foldl'
    genList
    head
    length
    listToAttrs
    map
    replaceStrings
    ;

  kindOf = x: x.kind or null;

  # ---- Nix code values ----
  # A code value is { code; prec; }: Nix source and the binding strength of its outermost
  # construct, 0 (a name or a non-negative number) to 10 (if, let).
  cv = prec: code: { inherit prec code; };
  atom = cv 0;
  isAtom = c: c.prec == 0;
  low = cv 10;
  num = n: cv (if n < 0 then 2 else 0) (toString n);
  wrap = max: c: if c.prec <= max then c.code else "(${c.code})";
  app = f: args: cv 1 (concatStringsSep " " ([ f ] ++ map (wrap 0) args));
  # Left-associative and non-associative infix operators of strength p.
  infixL =
    p: op: a: b:
    cv p "${wrap p a} ${op} ${wrap (p - 1) b}";
  infixN =
    p: op: a: b:
    cv p "${wrap (p - 1) a} ${op} ${wrap (p - 1) b}";
  neg = a: cv 2 "-${wrap 1 a}";
  mul = infixL 3 "*";
  add = infixL 4 "+";
  sub = infixL 4 "-";

  indent = replaceStrings [ "\n" ] [ "\n  " ];

  # let block of binds ([ { name; code; } ]) around the expression source result.
  renderLet =
    binds: result:
    if binds == [ ] then
      result
    else
      "let\n"
      + concatStringsSep "" (map (b: "  ${b.name} = ${indent b.code};\n") binds)
      + "in\n"
      + result;

  nixKeywords = [
    "assert"
    "else"
    "if"
    "in"
    "inherit"
    "let"
    "or"
    "rec"
    "then"
    "with"
  ];
  quoteAttr = name: if elem name nixKeywords then ''"${name}"'' else name;
  # Attribute name of a variable in the loop and branch sets, where mem and exit are taken.
  attrName = name: if name == "mem" || name == "exit" then "${name}'" else quoteAttr name;

  # ---- Emitter state ----
  # s = { n; mem; vars; names; old; }: n numbers the next generated name; mem is the
  # current memory; vars maps a variable key to the code of its current value (a name or a
  # constant); names maps a key to the C name; old is the code of the target's value while
  # an assignment's value is emitted.
  fresh = s: base: {
    name = "${base}_${toString s.n}";
    s = s // {
      n = s.n + 1;
    };
  };

  setVar =
    s: var: c:
    let
      f = fresh s var.name;
      bind =
        name: st:
        st
        // {
          vars = st.vars // {
            ${var.key} = name;
          };
        };
    in
    if isAtom c then
      {
        s = bind c.code s;
        binds = [ ];
      }
    else
      {
        s = bind f.name f.s;
        binds = [
          {
            inherit (f) name;
            inherit (c) code;
          }
        ];
      };

  # c bound to a new name in the enclosing let unless it is an atom. -> { s; binds; c; }
  share =
    s: base: c:
    let
      f = fresh s base;
    in
    if isAtom c then
      {
        inherit s c;
        binds = [ ];
      }
    else
      {
        inherit (f) s;
        binds = [
          {
            inherit (f) name;
            inherit (c) code;
          }
        ];
        c = atom f.name;
      };

  # f applied to the code values cs, each non-atom first bound by an inline let (so that
  # an operand used twice is computed once). -> { s; c; }
  shareInline =
    s: cs: f:
    let
      r =
        foldl'
          (
            acc: c:
            if isAtom c then
              acc // { as = acc.as ++ [ c ]; }
            else
              let
                x = fresh acc.s "t";
              in
              {
                inherit (x) s;
                as = acc.as ++ [ (atom x.name) ];
                bs = acc.bs ++ [ "${x.name} = ${c.code};" ];
              }
          )
          {
            inherit s;
            as = [ ];
            bs = [ ];
          }
          cs;
      body = f r.as;
    in
    {
      inherit (r) s;
      c = if r.bs == [ ] then body else low "let ${concatStringsSep " " r.bs} in ${body.code}";
    };

  # ---- Types to code ----

  # Conversion of a value of type from to type to.
  convert =
    from: to: c:
    if T.fits from to then
      c
    else if T.isS32 to then
      app "B.toSigned" [ (if T.isU32 from then c else app "B.u32" [ c ]) ]
    else if T.isU32 to then
      app "B.u32" [ c ]
    else if to.tag == "uchar" then
      app "bitAnd" [
        c
        (num 255)
      ]
    else
      app "R.toS8" [ c ];

  load =
    mem: t: a:
    let
      byte = app "M.loadByte" [
        (atom mem)
        a
      ];
      word = app "M.loadWord" [
        (atom mem)
        a
      ];
    in
    if t.tag == "uchar" then
      byte
    else if T.isS8 t then
      app "R.toS8" [ byte ]
    else if T.isU32 t then
      word
    else
      app "B.toSigned" [ word ];

  storeFn = t: if T.sizeOf t == 1 then "M.storeByte" else "M.storeWord";

  # A value of type from stored as type t: storeByte keeps the low 8 bits itself, and a
  # word is stored in its unsigned form.
  encode =
    t: from: c:
    if T.sizeOf t == 1 || T.isUnsigned from then c else app "B.u32" [ c ];

  # ---- Expressions ----
  # expr s e -> { s; binds; c; } with binds the let bindings of the side effects of e
  # and c its value (null for void).

  pure = s: c: {
    inherit s c;
    binds = [ ];
  };
  mapC = r: f: r // { c = f r.c; };

  exprs =
    s: es:
    foldl'
      (
        acc: e:
        let
          r = expr acc.s e;
        in
        {
          inherit (r) s;
          binds = acc.binds ++ r.binds;
          cs = acc.cs ++ [ r.c ];
        }
      )
      {
        inherit s;
        binds = [ ];
        cs = [ ];
      }
      es;

  # The operands es emitted left to right, then combined by f s cs -> { s; c; }.
  combine =
    s: es: f:
    let
      r = exprs s es;
      o = f r.s r.cs;
    in
    {
      inherit (o) s c;
      inherit (r) binds;
    };

  expr =
    s: e:
    let
      k = e.kind;
    in
    if k == "lit" then
      pure s (num e.value)
    else if k == "var" then
      pure s (atom s.vars.${e.var.key})
    else if k == "old" then
      pure s s.old
    else if k == "cast" then
      if T.isVoid e.type then
        expr s e.expr // { c = null; }
      else
        mapC (expr s e.expr) (convert e.expr.type e.type)
    else if k == "neg" then
      mapC (expr s e.expr) (
        c:
        if T.isUnsigned e.type then
          app "B.sub" [
            (num 0)
            c
          ]
        else
          neg c
      )
    else if k == "bnot" then
      mapC (expr s e.expr) (c: sub (num (if T.isUnsigned e.type then B.mask32 else -1)) c)
    else if
      elem k [
        "not"
        "cmp"
        "logand"
        "logor"
      ]
    then
      mapC (cond s e false) (c: low "if ${c.code} then 1 else 0")
    else if k == "binop" then
      binop s e
    else if k == "ptradd" then
      ptrAdd s e
    else if k == "ptrdiff" then
      combine s [ e.lhs e.rhs ] (
        s: cs:
        let
          d = app "B.toSigned" [ (app "B.sub" cs) ];
        in
        {
          inherit s;
          c =
            if e.size == 1 then
              d
            else
              app "div" [
                d
                (num e.size)
              ];
        }
      )
    else if k == "deref" then
      let
        a = expr s e.expr;
      in
      a // { c = load a.s.mem e.type a.c; }
    else if k == "call" then
      call s e
    else if k == "assign" then
      assign s e true
    else
      throw "cc: internal error: unexpected expression '${k}'";

  # Shift amount of e when it is a constant the shift can be inlined for, otherwise null.
  constShift =
    e:
    let
      r = e.rhs;
      limit = if e.type.tag == "llong" then 63 else 32;
    in
    if r.kind == "lit" && r.value >= 0 && r.value < limit then r.value else null;

  binop =
    s: e:
    let
      t = e.type;
      op = e.op;
      u = T.isUnsigned t;
      k = if op == "<<" || op == ">>" then constShift e else null;
      # B.add and B.sub wrap their result, so the conversion of a narrower signed operand
      # to unsigned is left to them.
      peel =
        n:
        if
          u && (op == "+" || op == "-") && n.kind == "cast" && (T.isS32 n.expr.type || T.isS8 n.expr.type)
        then
          n.expr
        else
          n;
      operands =
        if k == null then
          [
            (peel e.lhs)
            (peel e.rhs)
          ]
        else
          [ e.lhs ];
    in
    combine s operands (s: cs: arith s t op k cs);

  arith =
    s: t: op: k: cs:
    let
      u = T.isUnsigned t;
      ll = t.tag == "llong";
      a = head cs;
      b = elemAt cs 1;
      ok = c: { inherit s c; };
      p = B.pow2 k;
    in
    if op == "+" then
      ok (if u then app "B.add" cs else add a b)
    else if op == "-" then
      ok (if u then app "B.sub" cs else sub a b)
    else if op == "*" then
      ok (if u then app "B.mul" cs else mul a b)
    else if op == "/" then
      ok (app "div" cs)
    else if op == "%" then
      shareInline s cs (
        xs:
        let
          x = head xs;
          y = elemAt xs 1;
        in
        sub x (
          mul y (
            app "div" [
              x
              y
            ]
          )
        )
      )
    else if op == "&" then
      ok (app "bitAnd" cs)
    else if op == "|" then
      ok (app "bitOr" cs)
    else if op == "^" then
      ok (app "bitXor" cs)
    else if k == null then
      ok (
        app (
          if op == "<<" then
            (
              if u then
                "B.shl"
              else if ll then
                "R.shlLL"
              else
                "R.shlInt"
            )
          else if u then
            "B.srl"
          else if ll then
            "R.sraLL"
          else
            "R.sraInt"
        ) cs
      )
    else if k == 0 then
      ok a
    else if op == "<<" then
      ok (if u then app "B.u32" [ (mul a (num p)) ] else mul a (num p))
    else if u then
      ok (
        app "div" [
          a
          (num p)
        ]
      )
    else
      # Floor division by 2^k (Nix div truncates toward zero).
      shareInline s [ a ] (
        xs:
        let
          x = head xs;
        in
        app "div" [
          (sub x (
            app "bitAnd" [
              x
              (num (p - 1))
            ]
          ))
          (num p)
        ]
      );

  ptrAdd =
    s: e:
    let
      f = if e.op == "+" then "B.add" else "B.sub";
      offset = e.index.value * e.size;
    in
    if e.index.kind == "lit" then
      mapC (expr s e.ptr) (
        p:
        if offset == 0 then
          p
        else
          app f [
            p
            (num offset)
          ]
      )
    else
      combine s [ e.ptr e.index ] (
        s: cs: {
          inherit s;
          c = app f [
            (head cs)
            (if e.size == 1 then elemAt cs 1 else mul (elemAt cs 1) (num e.size))
          ];
        }
      );

  call =
    s: e:
    let
      r = exprs s e.args;
      isVoid = T.isVoid e.type;
      f = fresh r.s (if isVoid then "mem" else "r");
      code = app "${e.name}_fn" ([ (atom r.s.mem) ] ++ r.cs);
    in
    {
      s = f.s // {
        mem = if isVoid then f.name else "${f.name}.mem";
      };
      binds = r.binds ++ [
        {
          inherit (f) name;
          inherit (code) code;
        }
      ];
      c = if isVoid then null else atom "${f.name}.ret";
    };

  hasOld = e: Ch.collect (x: kindOf x == "old") (x: kindOf x == "assign") e != [ ];

  # want: the value of the assignment is used.
  assign =
    s: e: want:
    if e.target.kind == "var" then assignVar s e else assignMem s e want;

  assignVar =
    s: e:
    let
      var = e.target.var;
      old = atom s.vars.${var.key};
      v = expr (s // { inherit old; }) e.value;
      b = setVar (v.s // { inherit (s) old; }) var v.c;
    in
    {
      inherit (b) s;
      binds = v.binds ++ b.binds;
      c = if e.post then old else atom b.s.vars.${var.key};
    };

  assignMem =
    s: e: want:
    let
      t = e.target.type;
      a = expr s e.target.expr;
      # The address is used twice when the value reads the target.
      ad =
        if hasOld e.value then
          share a.s "p" a.c
        else
          {
            inherit (a) s c;
            binds = [ ];
          };
      oldLoad = load ad.s.mem t ad.c;
      o =
        if e.post && want then
          share ad.s "o" oldLoad
        else
          {
            inherit (ad) s;
            c = oldLoad;
            binds = [ ];
          };
      # The expression yields the new value (needed besides the store).
      newUsed = want && !e.post;
      # Unless the new value is used, the conversion to the target type is left to encode.
      node = if !newUsed && e.value.kind == "cast" then e.value.expr else e.value;
      v = expr (o.s // { old = o.c; }) node;
      vb =
        if newUsed then
          share v.s "t" v.c
        else
          {
            inherit (v) s c;
            binds = [ ];
          };
      m = fresh vb.s "mem";
      store = app (storeFn t) [
        (atom vb.s.mem)
        ad.c
        (encode t node.type vb.c)
      ];
    in
    {
      s = m.s // {
        mem = m.name;
        inherit (s) old;
      };
      binds =
        a.binds
        ++ ad.binds
        ++ o.binds
        ++ v.binds
        ++ vb.binds
        ++ [
          {
            inherit (m) name;
            inherit (store) code;
          }
        ];
      c = if e.post then o.c else vb.c;
    };

  flipped = {
    "<" = ">=";
    ">" = "<=";
    "<=" = ">";
    ">=" = "<";
    "==" = "!=";
    "!=" = "==";
  };

  # Boolean code of e in a condition context, negated when negated.
  # -> { s; binds; c; }
  cond =
    s: e: negated:
    let
      k = e.kind;
    in
    if k == "cmp" then
      combine s [ e.lhs e.rhs ] (
        s: cs:
        let
          op = if negated then flipped.${e.op} else e.op;
        in
        {
          inherit s;
          c = infixN (if op == "==" || op == "!=" then 7 else 6) op (head cs) (elemAt cs 1);
        }
      )
    else if k == "not" then
      cond s e.expr (!negated)
    else if k == "logand" || k == "logor" then
      let
        l = cond s e.lhs negated;
        r = cond l.s e.rhs negated;
        isAnd = (k == "logand") != negated;
      in
      {
        inherit (r) s;
        binds = l.binds ++ r.binds;
        c = if isAnd then infixL 8 "&&" l.c r.c else infixL 9 "||" l.c r.c;
      }
    else
      mapC (expr s e) (c: infixN 7 (if negated then "==" else "!=") c (num 0));

  # Expression evaluated for its side effects only. -> { s; binds; }
  effect =
    s: e:
    let
      r =
        if e.kind == "assign" then
          assign s e false
        else if e.kind == "cast" && T.isVoid e.type then
          effect s e.expr
        else
          expr s e;
    in
    {
      inherit (r) s binds;
    };

  # ---- Statements ----
  # stmt s n -> { s; binds; }

  seqStmts =
    f: s: ns:
    foldl'
      (
        acc: n:
        let
          r = f acc.s n;
        in
        {
          inherit (r) s;
          binds = acc.binds ++ r.binds;
        }
      )
      {
        inherit s;
        binds = [ ];
      }
      ns;

  stmt =
    s: n:
    let
      k = n.kind;
    in
    if k == "block" then
      seqStmts stmt s n.items
    else if k == "decl" then
      seqStmts declVar s n.vars
    else if k == "expr" then
      effect s n.expr
    else if k == "if" then
      ifStmt s n
    else if k == "while" then
      loop s {
        inherit (n) cond body;
        step = null;
        isDo = false;
      }
    else if k == "do" then
      loop s {
        inherit (n) cond body;
        step = null;
        isDo = true;
      }
    else if k == "for" then
      let
        i =
          if n.init == null then
            {
              inherit s;
              binds = [ ];
            }
          else
            stmt s n.init;
        l = loop i.s {
          inherit (n) cond body step;
          isDo = false;
        };
      in
      {
        inherit (l) s;
        binds = i.binds ++ l.binds;
      }
    else
      throw "cc: internal error: unexpected statement '${k}'";

  # An uninitialized variable reads as 0.
  declVar =
    s: d:
    let
      s1 = s // {
        names = s.names // {
          ${d.var.key} = d.var.name;
        };
      };
      v = expr s1 d.init;
      b = setVar v.s d.var v.c;
    in
    if d.init == null then
      setVar s1 d.var (num 0)
    else
      {
        inherit (b) s;
        binds = v.binds ++ b.binds;
      };

  ifStmt =
    s: n:
    let
      c = cond s n.cond false;
      s1 = c.s;
      th = stmt s1 n.thenStmt;
      el =
        if n.elseStmt == null then
          {
            s = s1 // {
              inherit (th.s) n;
            };
            binds = [ ];
          }
        else
          stmt (s1 // { inherit (th.s) n; }) n.elseStmt;
      changed = k: th.s.vars.${k} != s1.vars.${k} || el.s.vars.${k} != s1.vars.${k};
      keys = filter changed (attrNames s1.vars);
      memChanged = th.s.mem != s1.mem || el.s.mem != s1.mem;
      at = k: attrName s1.names.${k};
      fields =
        st:
        (if memChanged then [ "mem = ${st.mem};" ] else [ ]) ++ map (k: "${at k} = ${st.vars.${k}};") keys;
      branch = r: renderLet r.binds "{ ${concatStringsSep " " (fields r.s)} }";
      f = fresh (s1 // { inherit (el.s) n; }) "if";
      code = "if ${c.c.code} then\n  ${indent (branch th)}\nelse\n  ${indent (branch el)}";
    in
    if keys == [ ] && !memChanged then
      {
        s = s1 // {
          inherit (el.s) n;
        };
        inherit (c) binds;
      }
    else
      {
        s = f.s // {
          mem = if memChanged then "${f.name}.mem" else s1.mem;
          vars =
            s1.vars
            // listToAttrs (
              map (k: {
                name = k;
                value = "${f.name}.${at k}";
              }) keys
            );
        };
        binds = c.binds ++ [
          {
            inherit (f) name;
            inherit code;
          }
        ];
      };

  assignedKeys =
    x:
    map (a: a.target.var.key) (
      Ch.collect (y: kindOf y == "assign" && y.target.kind == "var") (_: false) x
    );

  hasEffects =
    e:
    Ch.collect (
      x:
      elem (kindOf x) [
        "assign"
        "call"
      ]
    ) (_: false) e != [ ];

  # l = { cond; body; step; isDo; } with cond and step possibly null.
  loop =
    s: l:
    let
      assigned = assignedKeys [
        l.cond
        l.body
        l.step
      ];
      carried = filter (k: elem k assigned) (attrNames s.vars);
      at = k: attrName s.names.${k};
      lv = fresh s "v";
      v = lv.name;
      inner = lv.s // {
        mem = "${v}.mem";
        vars =
          s.vars
          // listToAttrs (
            map (k: {
              name = k;
              value = "${v}.${at k}";
            }) carried
          );
      };
      update =
        st: extra:
        let
          fields =
            (if st.mem != inner.mem then [ "mem = ${st.mem};" ] else [ ])
            ++ concatMap (
              k: if st.vars.${k} != inner.vars.${k} then [ "${at k} = ${st.vars.${k}};" ] else [ ]
            ) carried
            ++ extra;
        in
        if fields == [ ] then v else "${v} // { ${concatStringsSep " " fields} }";
      bodyAndStep =
        s0:
        let
          b = stmt s0 l.body;
          st =
            if l.step == null then
              {
                inherit (b) s;
                binds = [ ];
              }
            else
              effect b.s l.step;
        in
        {
          inherit (st) s;
          binds = b.binds ++ st.binds;
        };
      always = "(_: true)";
      gen =
        if l.isDo then
          let
            b = stmt inner l.body;
            c = cond b.s l.cond true;
          in
          {
            cond = always;
            body = renderLet (b.binds ++ c.binds) (update c.s [ "exit = ${c.c.code};" ]);
            inherit (c) s;
          }
        else if l.cond == null then
          let
            b = bodyAndStep inner;
          in
          {
            cond = always;
            body = renderLet b.binds (update b.s [ ]);
            inherit (b) s;
          }
        else if !hasEffects l.cond then
          let
            c = cond inner l.cond false;
            b = bodyAndStep c.s;
          in
          {
            cond = "(${v}: ${c.c.code})";
            body = renderLet b.binds (update b.s [ ]);
            inherit (b) s;
          }
        else
          # The condition's side effects stay when it fails, so it is tested in the body.
          let
            c = cond inner l.cond false;
            b = bodyAndStep c.s;
          in
          {
            cond = always;
            body = renderLet c.binds "if ${c.c.code} then\n  ${
              indent (renderLet b.binds (update b.s [ ]))
            }\nelse\n  ${update c.s [ "exit = true;" ]}";
            inherit (b) s;
          };
      res = fresh (s // { inherit (gen.s) n; }) "l";
      init = concatStringsSep " " ([ "mem = ${s.mem};" ] ++ map (k: "${at k} = ${s.vars.${k}};") carried);
    in
    {
      s = res.s // {
        mem = "${res.name}.mem";
        vars =
          s.vars
          // listToAttrs (
            map (k: {
              name = k;
              value = "${res.name}.${at k}";
            }) carried
          );
      };
      binds = [
        {
          inherit (res) name;
          code = "R.loop ${gen.cond} (\n  ${indent "${v}:\n${gen.body}"}\n) { ${init} }";
        }
      ];
    };

  # ---- Functions ----

  func =
    f:
    let
      params = f.params;
      s0 = {
        n = 1;
        mem = "mem";
        old = null;
        vars = listToAttrs (
          map (v: {
            name = v.key;
            value = "${v.name}_0";
          }) params
        );
        names = listToAttrs (
          map (v: {
            name = v.key;
            value = v.name;
          }) params
        );
      };
      items = f.body.items;
      count = length items;
      last = elemAt items (count - 1);
      ret = if count > 0 && last.kind == "return" then last else null;
      body = seqStmts stmt s0 (if ret == null then items else genList (elemAt items) (count - 1));
      r = if ret == null || ret.expr == null then pure body.s null else expr body.s ret.expr;
      mem = r.s.mem;
      result =
        if T.isVoid f.ret then
          mem
        else
          "{ ${if mem == "mem" then "inherit mem;" else "mem = ${mem};"} ret = ${r.c.code}; }";
      signature = concatStringsSep " " ([ "mem:" ] ++ map (v: "${v.name}_0:") params);
    in
    "  ${f.name}_fn =\n    ${indent (indent "${signature}\n${renderLet (body.binds ++ r.binds) result}")};\n";

  emit =
    checked:
    "{ M, B, R }:\nlet\n  inherit (builtins) bitAnd bitOr bitXor div;\n"
    + concatStringsSep "" (map func checked.funcs)
    + "in\n{\n"
    + concatStringsSep "" (map (f: "  ${quoteAttr f.name} = ${f.name}_fn;\n") checked.funcs)
    + "}\n";
in
{
  inherit emit;
}
