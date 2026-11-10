# C code generator: typed syntax tree (cc/check.nix) -> Nix source.
#
# Entry point: emit : { funcs; data; } -> string. The output is the source of a function
#   { M, B, R }: { <C function name> = <Nix function>; ...; __data = <data>; }
# with M = lib/mem.nix, B = lib/bits.nix and R = cc/runtime.nix. It imports nothing, so
# it can be loaded from the store (cc/default.nix). __data describes the file-scope
# variables (cc/check.nix, "Data"):
#   { base; size; symbols = { <C name> = <address>; ... }; init = mem: <mem>; }
# init writes the initial values that are not 0 into a memory where the whole data area
# reads as 0; callers apply it before calling the functions. The translation is
# mechanical, with no optimization:
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
#   - A statement completes normally or abruptly by return, break (to the innermost loop
#     or switch) or continue (to the innermost loop). Functions, loops and if/else without
#     return, break or continue in them are translated as above. Otherwise the code of a
#     region (a function body, one iteration of a loop body, a switch section, a branch
#     joined into a set) is built in continuation-passing style: the statements after one
#     that may complete abruptly run only on its normal completion, in the form
#     `if <not normal> then <result of the region so far> else <rest>`.
#       - An if/else of which a branch cannot complete normally nests the rest of the
#         region inside the other branch. Otherwise the branches end in a join set with
#         mem, the variables assigned in them, st' (status: 0 normal, 1 return, 2 break,
#         3 continue) and ret' (the return value, on return), and the rest dispatches on
#         st'.
#       - Each construct consumes the completions aimed at it: a switch its break, a loop
#         its break and continue; return goes on to the function. In a loop body, break
#         sets exit, continue skips the rest of the body, and return sets exit and the
#         loop variables done' (true) and ret'. Neither runs the for step or the do/while
#         condition, which normal completion and continue do. Only a loop whose body
#         contains a return carries done' and ret'; the code after it tests done'.
#       - A switch binds its controlling value once, finds the section of the first
#         matching case (else default, else past the end) with an if chain, then runs the
#         sections in order, each one when its index is at least the found one and the
#         status is normal. Every section yields a set of mem, the variables assigned in
#         the sections, the variables declared at the top of the body (0 before their
#         declaration runs), and st' when a section may complete abruptly.
#       - A non-void function that reaches its end returns 0.
#   - Side effects in expressions (assignments, ++ and --, calls, stores) become let
#     bindings in C evaluation order; pure expressions stay nested. Operands are evaluated
#     left to right. An assignment to an object in memory (=, op=, ++ and --) evaluates,
#     as clang does, first the assigned value, then the address of the target in the
#     memory the value leaves, and op=, ++ and -- then read the old value at that address
#     in that memory: `g += h()` adds to the g that h leaves, and in `a[i()] = k()` k runs
#     before i. An assignment to a local variable evaluates only the value.
#   - Conditions are Nix booleans; a comparison is 0 or 1 only where its value is used.
#   - File-scope variables live in memory at fixed addresses, written as integer literals;
#     they are read and written like any memory through a pointer.
#   - Unsigned and pointer arithmetic and conversions wrap modulo 2^32 as in C.
#   - The results of +, -, *, unary - and << on int and long wrap to [-2^31, 2^31) with
#     `wrapInt` (R.wrapInt, bound once at the top), and so does signed / and % unless the
#     divisor is a constant other than -1. A +, -, * or unary - on int or long, or a
#     << by a constant, may take its operands unwrapped while the bound b of its own
#     result stays below 62, where b guarantees |value| <= 2^b: a wrapped value counts
#     31, + and - the larger operand bound plus 1, * the sum, unary - the operand bound,
#     and << k the operand bound plus k. Otherwise its unwrapped operands are wrapped
#     first. Every other use of a value (bindings, conditions, comparisons, / and %, >>,
#     bitwise operators, conversions, pointer arithmetic and indices, arguments, return
#     values, stores) takes it wrapped. long long does not wrap.
# Value representation: signed char, int, long and long long are signed Nix integers;
# plain char (unsigned, see cc/check.nix), the unsigned types and pointers are
# non-negative. Memory words are stored in the unsigned form.
#
# Generated names are `<C name>_<n>` (parameters `<C name>_0`) with n unique within a
# function, and `<C name>_fn` for functions, so they collide neither with each other nor
# with M, B, R, mem, wrapInt and the builtins the output uses. The attribute __data
# cannot clash with a C function, since identifiers starting with `__` are reserved in C.
# In the loop, join and switch sets a variable is its C name, with ' appended to mem and
# exit; the generated fields st', ret' and done' contain a ', so they cannot clash. A
# variable declared in a switch body that hides one the sections assign is `<C name>'<n>`.
let
  Ch = import ./check.nix;
  T = Ch.types;
  B = import ../lib/bits.nix;
  inherit (builtins)
    all
    any
    attrNames
    concatLists
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
    removeAttrs
    replaceStrings
    tail
    ;

  kindOf = x: x.kind or null;

  # ---- Nix code values ----
  # A code value is { code; prec; }: Nix source and the binding strength of its outermost
  # construct, 0 (a name or a non-negative number) to 10 (if, let).
  cv = prec: code: { inherit prec code; };
  atom = cv 0;
  isAtom = c: c.prec == 0;
  low = cv 10;
  # LLONG_MIN has no Nix literal (9223372036854775808 does not parse), so it is written
  # as a subtraction.
  llongMin = -9223372036854775807 - 1;
  num =
    n:
    if n == llongMin then
      sub (cv 2 "-9223372036854775807") (num 1)
    else
      cv (if n < 0 then 2 else 0) (toString n);
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
  # s = { n; mem; vars; names; old; retVoid; }: n numbers the next generated name; mem is
  # the current memory; vars maps a variable key to the code of its current value (a name
  # or a constant); names maps a key to the C name; old is the code of the target's value
  # while an assignment's value is emitted; retVoid tells that the function returns void.
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
    else if T.isU16 to then
      app "bitAnd" [
        c
        (num 65535)
      ]
    else if T.isS16 to then
      app "R.toS16" [ c ]
    else if T.isU8 to then
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
      half = app "M.loadHalf" [
        (atom mem)
        a
      ];
      word = app "M.loadWord" [
        (atom mem)
        a
      ];
    in
    if T.isU8 t then
      byte
    else if T.isS8 t then
      app "R.toS8" [ byte ]
    else if T.isU16 t then
      half
    else if T.isS16 t then
      app "R.toS16" [ half ]
    else if T.isU32 t then
      word
    else
      app "B.toSigned" [ word ];

  storeFn =
    t:
    let
      size = T.sizeOf t;
    in
    if size == 1 then
      "M.storeByte"
    else if size == 2 then
      "M.storeHalf"
    else
      "M.storeWord";

  # A value of type from stored as type t: storeByte keeps the low bits itself, a signed
  # value is cut to 16 bits for storeHalf (which takes the high byte of a half at an
  # address 3 mod 4 by division, so it needs a non-negative value), and a word is stored
  # in its unsigned form.
  encode =
    t: from: c:
    let
      size = T.sizeOf t;
    in
    if size == 1 || T.isUnsigned from then
      c
    else if size == 2 then
      app "bitAnd" [
        c
        (num 65535)
      ]
    else
      app "B.u32" [ c ];

  # ---- Expressions ----
  # expr s e -> { s; binds; c; } with binds the let bindings of the side effects of e
  # and c its value (null for void).

  pure = s: c: {
    inherit s c;
    binds = [ ];
  };
  mapC = r: f: r // { c = f r.c; };

  # The expressions es emitted left to right by f (expr or exprRaw).
  # -> { s; binds; cs; rs; } with rs the results of f.
  exprsWith =
    f: s: es:
    foldl'
      (
        acc: e:
        let
          r = f acc.s e;
        in
        {
          inherit (r) s;
          binds = acc.binds ++ r.binds;
          cs = acc.cs ++ [ r.c ];
          rs = acc.rs ++ [ r ];
        }
      )
      {
        inherit s;
        binds = [ ];
        cs = [ ];
        rs = [ ];
      }
      es;

  exprs = exprsWith expr;

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

  # The value of e, wrapped to the range of its type.
  expr =
    s: e:
    let
      k = e.kind;
    in
    if isRawOp e then
      wrapped (rawOp s e)
    else if k == "lit" then
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
    else if k == "cond" then
      condExpr s e
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

  # ---- Signed 32-bit wrapping ----
  # An unwrapped result is { s; binds; c; bound; } with bound null when c is wrapped (in
  # the range of its type), or the bound b (|c| <= 2^b) of an int or long value that is
  # not wrapped yet.

  wrapBound = 31;
  boundLimit = 62;

  wrapCode = c: app "wrapInt" [ c ];

  wrapped = r: removeAttrs r [ "bound" ] // { c = if r.bound == null then r.c else wrapCode r.c; };

  # Operations on int or long whose operands may be passed unwrapped: +, -, *, unary -
  # and << by a constant.
  isRawOp =
    e:
    T.isS32 e.type
    && (
      e.kind == "neg"
      ||
        e.kind == "binop"
        && (
          elem e.op [
            "+"
            "-"
            "*"
          ]
          || e.op == "<<" && constShift e != null
        )
    );

  # The value of e, unwrapped where e is a raw operation.
  exprRaw = s: e: if isRawOp e then rawOp s e else expr s e // { bound = null; };

  # The raw operation e on operands emitted by exprRaw; when the bound of its result
  # would reach boundLimit, the unwrapped operands are wrapped first.
  rawOp =
    s: e:
    let
      k = if e.kind == "binop" && e.op == "<<" then constShift e else null;
      operands =
        if e.kind == "neg" then
          [ e.expr ]
        else if k != null then
          [ e.lhs ]
        else
          [
            e.lhs
            e.rhs
          ];
      r = exprsWith exprRaw s operands;
      boundOf = x: if x.bound or null == null then wrapBound else x.bound;
      resultBound =
        rs:
        let
          bs = map boundOf rs;
          a = head bs;
        in
        if e.kind == "neg" then
          a
        else if k != null then
          a + k
        else if e.op == "*" then
          a + elemAt bs 1
        else
          (if a > elemAt bs 1 then a else elemAt bs 1) + 1;
      rs = if resultBound r.rs < boundLimit then r.rs else map wrapped r.rs;
      cs = map (x: x.c) rs;
      a = head cs;
    in
    {
      inherit (r) s binds;
      c =
        if e.kind == "neg" then
          neg a
        else if k == 0 then
          a
        else if k != null then
          mul a (num (B.pow2 k))
        else if e.op == "+" then
          add a (elemAt cs 1)
        else if e.op == "-" then
          sub a (elemAt cs 1)
        else
          mul a (elemAt cs 1);
      bound = resultBound rs;
    };

  # Signed / and % wrap their result (INT_MIN / -1 is INT_MIN), unless the divisor is a
  # constant other than -1.
  divWraps =
    e: T.isS32 e.type && (e.op == "/" || e.op == "%") && !(e.rhs.kind == "lit" && e.rhs.value != -1);

  # Shift amount of e when it is a constant the shift can be inlined for, otherwise null.
  # 2^63 is not a Nix integer: `long long << 63` (rejected by cc/check.nix when the amount
  # is a constant) is left to R.shlLL, and `>> 63` has its own case in arith.
  constShift =
    e:
    let
      r = e.rhs;
      limit =
        if e.type.tag != "llong" then
          32
        else if e.op == ">>" then
          64
        else
          63;
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
    combine s operands (
      s: cs:
      let
        o = arith s t op k cs;
      in
      if divWraps e then o // { c = wrapCode o.c; } else o
    );

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
    else if k == 63 then
      # Only long long reaches here: the result is the sign.
      ok (low "if ${(infixN 6 "<" a (num 0)).code} then -1 else 0")
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

  # The value is emitted first, then the address of the target in the memory the value
  # leaves, then the old value is read there (see the header). The value reads the old
  # value through s.old, whose code refers to the address and memory emitted after it;
  # only its strength (prec) is used while the value is emitted, so the lazy reference
  # does not loop.
  assignMem =
    s: e: want:
    let
      t = e.target.type;
      # The expression yields the new value (needed besides the store).
      newUsed = want && !e.post;
      # Unless the new value is used, the conversion to the target type is left to encode.
      node = if !newUsed && e.value.kind == "cast" then e.value.expr else e.value;
      v = expr (s // { old = oldC; }) node;
      a = expr (v.s // { inherit (s) old; }) e.target.expr;
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
      oldC = o.c;
      vb =
        if newUsed then
          share o.s "t" v.c
        else
          {
            inherit (o) s;
            inherit (v) c;
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
        v.binds
        ++ a.binds
        ++ ad.binds
        ++ o.binds
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

  # `c ? a : b`. The branches have no side effects (cc/check.nix), so they leave no
  # bindings and only the chosen one is evaluated.
  condExpr =
    s: e:
    let
      c = cond s e.cond false;
      a = expr c.s e.thenExpr;
      b = expr a.s e.elseExpr;
    in
    if a.binds != [ ] || b.binds != [ ] then
      throw "cc: internal error: side effect in a branch of '?:'"
    else
      {
        inherit (b) s;
        inherit (c) binds;
        c = low "if ${c.c.code} then ${a.c.code} else ${b.c.code}";
      };

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
    else if isLoop n then
      loopStmt s n
    else if k == "switch" then
      switchChain s n
    else
      throw "cc: internal error: unexpected statement '${k}'";

  isLoop =
    n:
    elem (kindOf n) [
      "while"
      "do"
      "for"
    ];

  # A while, do or for statement. -> { s; binds; name; } with name the loop's result.
  loopStmt =
    s: n:
    let
      i =
        if n.kind != "for" || n.init == null then
          {
            inherit s;
            binds = [ ];
          }
        else
          stmt s n.init;
      l = loop i.s {
        inherit (n) cond body;
        step = n.step or null;
        isDo = n.kind == "do";
      };
    in
    l // { binds = i.binds ++ l.binds; };

  # An uninitialized variable reads as 0, also inside its own initializer.
  declVar =
    s: d:
    let
      s1 = s // {
        names = s.names // {
          ${d.var.key} = d.var.name;
        };
        vars = s.vars // {
          ${d.var.key} = "0";
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
      # The loop carries done' and ret' when a return in its body leaves the function.
      returns = (exits l.body) ? return;
      # The end of an iteration after the body, normal or by continue: the for step, or the
      # do/while condition setting exit. -> { s; binds; code; }
      next =
        st:
        if l.isDo then
          let
            c = cond st l.cond true;
          in
          {
            inherit (c) s binds;
            code = update c.s [ "exit = ${c.c.code};" ];
          }
        else if l.step == null then
          {
            s = st;
            binds = [ ];
            code = update st [ ];
          }
        else
          let
            r = effect st l.step;
          in
          {
            inherit (r) s binds;
            code = update r.s [ ];
          };
      leave = st: extra: {
        s = st;
        binds = [ ];
        code = update st ([ "exit = true;" ] ++ extra);
      };
      handlers = {
        continue = next;
        break = st: leave st [ ];
        return =
          st: c: leave st ([ "done' = true;" ] ++ (if c == null then [ ] else [ "ret' = ${c.code};" ]));
      };
      # The body from state s0 followed by next. -> { s; binds; code; }
      bodyThen = s0: stmtK handlers s0 l.body next;
      always = "(_: true)";
      gen =
        if l.isDo || l.cond == null then
          let
            b = bodyThen inner;
          in
          {
            cond = always;
            body = renderLet b.binds b.code;
            inherit (b) s;
          }
        else if !hasEffects l.cond then
          let
            c = cond inner l.cond false;
            b = bodyThen c.s;
          in
          {
            cond = "(${v}: ${c.c.code})";
            body = renderLet b.binds b.code;
            inherit (b) s;
          }
        else
          # The condition's side effects stay when it fails, so it is tested in the body.
          let
            c = cond inner l.cond false;
            b = bodyThen c.s;
          in
          {
            cond = always;
            body = renderLet c.binds "if ${c.c.code} then\n  ${indent (renderLet b.binds b.code)}\nelse\n  ${update c.s [ "exit = true;" ]}";
            inherit (b) s;
          };
      res = fresh (s // { inherit (gen.s) n; }) "l";
      init = concatStringsSep " " (
        [ "mem = ${s.mem};" ]
        ++ map (k: "${at k} = ${s.vars.${k}};") carried
        ++ (if !returns then [ ] else [ "done' = false;" ] ++ (if s.retVoid then [ ] else [ "ret' = 0;" ]))
      );
    in
    {
      inherit (res) name;
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

  # ---- Abrupt completion (see the header) ----
  # A region is emitted by stmtK handlers s n k -> { s; binds; code; }, the code of the
  # region from the statement n on being `renderLet binds code`; only s.n of the returned
  # state is used further. k : state -> { s; binds; code; } is the rest of the region after
  # a normal completion of n, called at most once. handlers = { return; break; continue; }
  # end the region on an abrupt completion: `return st c` (c the value, null in a void
  # function), `break st` and `continue st`, each -> { s; binds; code; }.

  abruptKinds = [
    "return"
    "break"
    "continue"
  ];
  statusOf = {
    return = 1;
    break = 2;
    continue = 3;
  };

  # The abrupt completions that can leave the statement n: a set with the attributes
  # return, break and continue that apply.
  exits =
    n:
    let
      k = kindOf n;
      merged = foldl' (acc: x: acc // exits x) { };
    in
    if elem k abruptKinds then
      { ${k} = true; }
    else if k == "block" then
      merged n.items
    else if k == "if" then
      merged [
        n.thenStmt
        n.elseStmt
      ]
    else if isLoop n then
      (if (exits n.body) ? return then { return = true; } else { })
    else if k == "switch" then
      removeAttrs (merged (concatLists n.sections)) [ "break" ]
    else
      { };

  # Whether the statement n can complete normally; false when every path through it ends
  # in return, break or continue.
  canNormal =
    n:
    let
      k = n.kind;
    in
    if elem k abruptKinds then
      false
    else if k == "block" then
      all canNormal n.items
    else if k == "if" then
      n.elseStmt == null || canNormal n.thenStmt || canNormal n.elseStmt
    else
      true;

  # Whether running x may rebind the memory: stores, calls and loops do.
  touchesMem =
    x:
    Ch.collect (
      y:
      elem (kindOf y) [
        "call"
        "while"
        "do"
        "for"
      ]
      || kindOf y == "assign" && y.target.kind != "var"
    ) (_: false) x != [ ];

  # The result r of the first part of a region followed by the code o of the rest.
  andThen = r: o: o // { binds = r.binds ++ o.binds; };

  stmtK =
    handlers: s: n: k:
    let
      kind = n.kind;
    in
    if exits n == { } then
      let
        r = stmt s n;
      in
      andThen r (k r.s)
    else if kind == "return" then
      let
        r = if n.expr == null then pure s null else expr s n.expr;
      in
      andThen r (handlers.return r.s r.c)
    else if kind == "break" || kind == "continue" then
      handlers.${kind} s
    else if kind == "block" then
      seqK handlers s n.items k
    else if kind == "if" then
      ifK handlers s n k
    else if kind == "switch" then
      switchK handlers s n k
    else
      loopK handlers s n k;

  # The statements ns in sequence: the leading ones that cannot complete abruptly stay
  # plain bindings, and the rest follows the first one that can.
  seqK =
    handlers: s: ns: k:
    let
      count = length ns;
      firstAbrupt = i: if i == count || exits (elemAt ns i) != { } then i else firstAbrupt (i + 1);
      split = firstAbrupt 0;
      pre = seqStmts stmt s (genList (elemAt ns) split);
      rest = genList (i: elemAt ns (split + 1 + i)) (count - split - 1);
    in
    andThen pre (
      if split == count then
        k pre.s
      else
        stmtK handlers pre.s (elemAt ns split) (st: seqK handlers st rest k)
    );

  # `if c then <th> else <el>` of two region results.
  ifCode =
    c: th: el:
    "if ${c.code} then\n  ${indent (renderLet th.binds th.code)}\nelse\n  ${indent (renderLet el.binds el.code)}";

  ifK =
    handlers: s: n: k:
    let
      c = cond s n.cond false;
      nests = !canNormal n.thenStmt || n.elseStmt != null && !canNormal n.elseStmt;
    in
    andThen c ((if nests then ifNested else ifJoin) handlers c.s c.c n k);

  # A branch cannot complete normally, so the rest k follows inside the other one.
  ifNested =
    handlers: s1: c: n: k:
    let
      th = stmtK handlers s1 n.thenStmt k;
      s2 = s1 // {
        inherit (th.s) n;
      };
      el = if n.elseStmt == null then k s2 else stmtK handlers s2 n.elseStmt k;
    in
    {
      inherit (el) s;
      binds = [ ];
      code = ifCode c th el;
    };

  # Both branches can complete normally: they end in a join set, then the rest dispatches.
  ifJoin =
    handlers: s1: c: n: k:
    let
      branches = [
        n.thenStmt
        n.elseStmt
      ];
      assigned = assignedKeys branches;
      keys = filter (key: elem key assigned) (attrNames s1.vars);
      memChanged = touchesMem branches;
      at = key: attrName s1.names.${key};
      j = joinRegion memChanged keys at true;
      th = stmtK j.handlers s1 n.thenStmt j.end;
      s2 = s1 // {
        inherit (th.s) n;
      };
      el = if n.elseStmt == null then j.end s2 else stmtK j.handlers s2 n.elseStmt j.end;
      f = fresh (s1 // { inherit (el.s) n; }) "if";
      d = dispatch handlers (joined f.s f.name memChanged keys at) f.name (exits n) k;
    in
    andThen {
      binds = [
        {
          inherit (f) name;
          code = ifCode c th el;
        }
      ];
    } d;

  # The state s reading mem (when memChanged) and the variables keys from the set name.
  joined =
    s: name: memChanged: keys: at:
    s
    // {
      mem = if memChanged then "${name}.mem" else s.mem;
      vars =
        s.vars
        // listToAttrs (
          map (key: {
            name = key;
            value = "${name}.${at key}";
          }) keys
        );
    };

  # The end and handlers of a region that yields a set of mem (when memChanged) and the
  # variables keys of the state, with st' when withStatus and ret' on a return with a value.
  joinRegion =
    memChanged: keys: at: withStatus:
    let
      set = st: extra: {
        s = st;
        binds = [ ];
        code = "{ ${
          concatStringsSep " " (
            (if memChanged then [ "mem = ${st.mem};" ] else [ ])
            ++ map (key: "${at key} = ${st.vars.${key}};") keys
            ++ extra
          )
        } }";
      };
      status = code: if withStatus then [ "st' = ${toString code};" ] else [ ];
    in
    {
      end = st: set st (status 0);
      handlers = {
        return =
          st: c: set st (status statusOf.return ++ (if c == null then [ ] else [ "ret' = ${c.code};" ]));
        break = st: set st (status statusOf.break);
        continue = st: set st (status statusOf.continue);
      };
    };

  # After the set name with status st': each completion in ex (as from exits) goes to its
  # handler, and the normal one (and any other) to k.
  dispatch =
    handlers: s: name: ex: k:
    let
      go =
        kinds: st:
        if kinds == [ ] then
          k st
        else
          let
            kind = head kinds;
            h =
              if kind == "return" then
                handlers.return st (if st.retVoid then null else atom "${name}.ret'")
              else
                handlers.${kind} st;
            rest = go (tail kinds) (st // { inherit (h.s) n; });
          in
          {
            inherit (rest) s;
            binds = [ ];
            code = ifCode (atom "${name}.st' == ${toString statusOf.${kind}}") h rest;
          };
    in
    go (filter (kind: ex ? ${kind}) abruptKinds) s;

  # A loop whose body contains a return: after it, done' tells whether the return left it.
  loopK =
    handlers: s: n: k:
    let
      l = loopStmt s n;
      h = handlers.return l.s (if s.retVoid then null else atom "${l.name}.ret'");
      o = k (l.s // { inherit (h.s) n; });
    in
    {
      inherit (o) s;
      inherit (l) binds;
      code = ifCode (atom "${l.name}.done'") h o;
    };

  # A switch that a return or a continue (to an enclosing loop) can leave: after its
  # sections, which consume its own break, dispatch passes these on. A switch that only its
  # own break can leave early completes normally and is a plain statement (switchChain).
  switchK =
    handlers: s: n: k:
    let
      w = switchChain s n;
    in
    andThen w (dispatch handlers w.s w.name (exits n) k);

  # The switch n run up to the end of its last section. -> { s; binds; name; } with name
  # the set of the last section (null when there is none).
  switchChain =
    s: n:
    let
      x = expr s n.cond;
      xs = share x.s "sw" x.c;
      sections = n.sections;
      count = length sections;
      fallback = if n.default == null then count else n.default;
      cases = n.cases;
      # The chain is built from the last case backwards, so the first case is tested first.
      position = foldl' (
        acc: i:
        let
          case = elemAt cases (length cases - 1 - i);
        in
        low "if ${
          (infixN 7 "==" xs.c (num case.value)).code
        } then ${toString case.section} else ${acc.code}"
      ) (num fallback) (genList (i: i) (length cases));
      ps = share xs.s "pos" position;
      declared = concatMap (item: if item.kind == "decl" then map (d: d.var) item.vars else [ ]) (
        n.skipped ++ concatLists sections
      );
      s0 = ps.s // {
        vars = ps.s.vars // listToAttrs (map (var: nameValue var.key "0") declared);
        names = ps.s.names // listToAttrs (map (var: nameValue var.key var.name) declared);
      };
      assigned = assignedKeys sections;
      keys = filter (key: elem key assigned) (attrNames ps.s.vars) ++ map (var: var.key) declared;
      memChanged = touchesMem sections;
      withStatus = any (item: exits item != { }) (concatLists sections);
      attrs = uniqueAttrs s0.names keys;
      at = key: attrs.${key};
      j = joinRegion memChanged keys at withStatus;
      step =
        acc: i:
        let
          prev = acc.name;
          sIn = if prev == null then acc.s else joined acc.s prev memChanged keys at;
          guard =
            (if prev != null && withStatus then "${prev}.st' == 0 && " else "")
            + "${ps.c.code} <= ${toString i}";
          body = seqK j.handlers sIn (elemAt sections i) j.end;
          skip =
            if prev == null then
              j.end acc.s
            else
              {
                binds = [ ];
                code = prev;
              };
          f = fresh (acc.s // { inherit (body.s) n; }) "w";
        in
        {
          s = acc.s // {
            inherit (f.s) n;
          };
          inherit (f) name;
          binds = acc.binds ++ [
            {
              inherit (f) name;
              code = ifCode (atom guard) body skip;
            }
          ];
        };
      chain = foldl' step {
        s = s0;
        name = null;
        binds = [ ];
      } (genList (i: i) count);
    in
    if count == 0 || keys == [ ] && !memChanged && !withStatus then
      {
        s = s0;
        binds = x.binds ++ xs.binds;
        name = null;
      }
    else
      {
        s = joined chain.s chain.name memChanged keys at;
        binds = x.binds ++ xs.binds ++ ps.binds ++ chain.binds;
        inherit (chain) name;
      };

  nameValue = name: value: { inherit name value; };

  # The attribute names of the variables keys in a set (attrName of the C name), unique: a
  # name already taken by an earlier key becomes `<C name>'<position>`. -> { <key> = <name>; }
  uniqueAttrs =
    names: keys:
    (foldl'
      (
        acc: i:
        let
          key = elemAt keys i;
          plain = attrName names.${key};
          name = if elem plain acc.taken then "${names.${key}}'${toString i}" else plain;
        in
        {
          taken = acc.taken ++ [ name ];
          attrs = acc.attrs // {
            ${key} = name;
          };
        }
      )
      {
        taken = [ ];
        attrs = { };
      }
      (genList (i: i) (length keys))
    ).attrs;

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
        retVoid = T.isVoid f.ret;
      };
      result =
        mem: c:
        if T.isVoid f.ret then
          mem
        else
          "{ ${if mem == "mem" then "inherit mem;" else "mem = ${mem};"} ret = ${c.code}; }";
      end = st: c: {
        s = st;
        binds = [ ];
        code = result st.mem c;
      };
      unexpected = kind: _: throw "cc: internal error: '${kind}' leaves the function";
      handlers = {
        return = end;
        break = unexpected "break";
        continue = unexpected "continue";
      };
      body = stmtK handlers s0 f.body (st: end st (num 0));
      signature = concatStringsSep " " ([ "mem:" ] ++ map (v: "${v.name}_0:") params);
    in
    "  ${f.name}_fn =\n    ${indent (indent "${signature}\n${renderLet body.binds body.code}")};\n";

  # ---- Data ----

  # The __data attribute (see the header); init stores [ address size value ] triples
  # with R.initData.
  dataAttr =
    d:
    let
      symbols = concatStringsSep "" (
        map (x: "      ${quoteAttr x.name} = ${toString x.addr};\n") d.symbols
      );
      writes = concatStringsSep "" (
        map (w: "      [ ${toString w.addr} ${toString w.size} ${toString w.value} ]\n") d.inits
      );
    in
    "  __data = {\n"
    + "    base = ${toString d.base};\n"
    + "    size = ${toString d.size};\n"
    + "    symbols = ${if d.symbols == [ ] then "{ }" else "{\n${symbols}    }"};\n"
    + "    init = mem: ${if d.inits == [ ] then "mem" else "R.initData mem [\n${writes}    ]"};\n"
    + "  };\n";

  emit =
    checked:
    "{ M, B, R }:\nlet\n  inherit (builtins) bitAnd bitOr bitXor div;\n  inherit (R) wrapInt;\n"
    + concatStringsSep "" (map func checked.funcs)
    + "in\n{\n"
    + concatStringsSep "" (map (f: "  ${quoteAttr f.name} = ${f.name}_fn;\n") checked.funcs)
    + dataAttr checked.data
    + "}\n";
in
{
  inherit emit;
}
