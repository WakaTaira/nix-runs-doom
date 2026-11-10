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
# mechanical, except for the loop driver and the cached reads described below:
#   - A C function becomes `mem: <params>:` returning the new memory, or { mem; ret; }
#     when it returns a value.
#   - Locals become let bindings, with a new name for each assignment. Assigning a plain
#     name or a non-negative constant only renames.
#   - A loop becomes `R.loop cond body vars`, or `R.loopDo body vars` (no condition to
#     call) when it is a do/while loop, has no condition, has a condition that is a
#     constant other than 0, or has a condition with side effects. vars holds mem and the
#     variables that are declared outside the loop and assigned in it; the others are read
#     from the enclosing scope. A do/while loop, and a loop whose condition has side
#     effects, tests inside the body and sets `exit`.
#   - A loop that contains no loop and no call caches its scalar reads at constant
#     addresses (file-scope variables, constant indices, members): each pair of address
#     and type (a key) that no store at a constant address in the loop overlaps becomes a
#     variable in vars, read on entry (after the for initialization) from the memory
#     there, and its reads use that variable. Every other store (address a, s bytes) is
#     followed by `hit_<n> = <test>`, which detects an overlap modulo 2^32 with the byte
#     ranges of the keys, merged where they touch or overlap: for each range [k, k + n),
#     `bitAnd (a - k) 4294967295 < n || bitAnd (k - a) 4294967295 < s`, without the
#     second term when s is 1, the ranges joined by ||. When a hit holds, every key reads
#     again from the memory. A read of a key after such stores in the same iteration binds
#     `g_<n> = if <hits> then <load> else <value>` for each key, and so does a join set
#     (as a field); otherwise the end of the iteration adds
#     `// (if <hits> then { <key> = <load>; ... } else { })` to the loop update, with the
#     hits since the start of the iteration joined by ||. The cached values are versioned
#     like mem: the join sets of if/else and switch carry them wherever mem may change,
#     every way out of an iteration passes them on, and they are dropped after the loop.
#   - Such a loop runs in bulk, `if <entry test> then <bulk form> else <loop>`, when its
#     typed tree shows all of the following (otherwise it is emitted as above). Invariants
#     are constants, variables declared before the loop that it does not assign, and the
#     cached reads, combined without side effects; invariants that only the entry test or
#     the values after the loop may evaluate must be safe (no / or % but by a constant
#     other than 0, no shift but by a constant).
#       A. No break, continue, return or switch.
#       B. A count form, giving the number N of iterations and a requirement: with n an
#          int variable assigned nowhere else in the loop, `do B while (n--)` (N = n0 + 1,
#          n0 >= 0), `while (n--)` or `for (...; n--; ...)` (N = n0, n0 >= 0),
#          `do B while (--n)` (N = n0, n0 >= 1), `while (--n)` or `for (...; --n; ...)`
#          (N = n0 - 1, n0 >= 1); with i an int induction variable stepping by +1 and e an
#          int invariant, `i < e` (N = max(0, e - i0)) or `i <= e` (N = max(0, e - i0 + 1),
#          e < 2^31 - 1), by -1, `i > e` or `i >= e` likewise, in a while or for loop
#          (e op i is turned around). Every form requires N <= 2^24.
#       C. Every other variable declared before the loop and assigned in it is an
#          induction variable or a temporary. An induction variable (int, unsigned or a
#          pointer) is assigned exactly once, on every iteration (not in a branch of if or
#          ?:, nor on the right of && or ||), by ++, --, += c, -= c, v = v + c or
#          v = v - c, with c invariant of type int, unsigned or narrower (scaled by the
#          element size for a pointer); its value at the start of iteration k is
#          v0 + k * step, wrapped to its type. A temporary is assigned on every iteration
#          before any read of it in the iteration.
#       D. Exactly one store: a plain 1-byte `=` in the body, run on every iteration, at
#          an address a0 + k * d (modulo 2^32) with d >= 1 a constant: the address is
#          built from induction variables with constant steps, safe invariants, + and -,
#          pointer arithmetic and casts between 32-bit integers and pointers.
#       E. Every load is at a constant address (the cached reads), at an invariant
#          pointer plus an index known to lie in [0, U] (constants; unsigned char and
#          short values; & with a constant or two known operands; | and ^; >> of unsigned
#          by a constant; + below 2^31; widening casts; int and unsigned variables whose
#          only assignment in the loop is a plain one or an initializer in the body, run
#          on every iteration before the load), or at a0' + k * d' with d' >= 0 a constant
#          (as in D).
#     One iteration is walked in evaluation order for C to E (`while` and `for`:
#     condition, body, step; `do`: body, condition). The entry test is the requirement
#     of B and N <= 2^24 and, when N >= 1, that the write range [a0, a0 + (N - 1) * d] and
#     every read range lie below 2^32 and do not overlap; a read range is the merged range
#     of the cached reads, [b, b + U * size + s - 1] for an index, or
#     [a0', a0' + (N - 1) * d' + s - 1], with s the size read. The bulk form computes the
#     stored values with `builtins.genList` over k from one iteration emitted with the
#     variables at the start of iteration k (n is n0 - k) and every read from the memory on
#     entry, writes them with M.storeRun (d = 1) or M.storeStride, and yields the
#     variables after the loop: induction variables v0 + N * step, n -1 after n-- and 0
#     after --n, and temporaries their value at the end of iteration N - 1 (their value on
#     entry when N is 0). The same iteration at k = 0 gives a0 and a0'. In the bulk
#     form, the address of a load at an invariant pointer plus an index in [0, U] is
#     `base + index * size` without wrapping, since the entry test has checked that it
#     stays below 2^32; other addresses wrap as in the loop. The function of k given to
#     genList, and the copy of the iteration that gives a0, a0' and the temporaries,
#     keep only the bindings that their result uses, directly or through other kept
#     bindings (identifiers in the emitted code; the others would never be evaluated).
#       Such a load of one byte with an element size of 1 (a table of char, signed char
#       or unsigned char) and a read range of U + 1 <= 16384 bytes is a page read. A
#       bulk form with page reads computes the values as
#       `if N >= T then builtins.genList <paged> N else builtins.genList <leaf> N`, two
#       copies of the iteration: <paged> with every page read as
#       `builtins.elemAt (builtins.elemAt pg (div p 256)) (bitAnd p 255)`, p = off + index
#       (bound by an inline let), and <leaf> with every page read as
#       `M.leafByte lv (lo + index)`, each followed by the same conversion as the load.
#       For each read range, `pg = M.readPages <mem on entry> <base> <U + 1>` (the leaves of
#       256 bytes that the range touches, as lazy lists of bytes) and
#       `off = bitAnd <base> 255` are bound once, by a let around the genList of <paged>,
#       and `lv = M.readLeaves <mem on entry> <base> <U + 1>` (the same leaves as a lazy
#       list of leaf sets) and `lo = bitAnd <base> 255` by a let around the genList of
#       <leaf>, with base the name or constant bound for the entry test; reads whose base
#       and length are both the same share them. Only their own copy refers to them, so
#       they are evaluated only when the entry test holds and N >= 1, where
#       base + U < 2^32 holds. T = max(32, 8 * L) with L the largest div U 256 + 2 (the
#       leaves a read range may touch) among the page reads: a leaf costs 256 lazy
#       elements, so a large table read a few times stays with <leaf>.
#       Every other load, the store, the values after the loop and the loop when the
#       entry test fails are emitted as without page reads, and so is a bulk form
#       without them.
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
# variable declared in a switch body that hides one the sections assign is `<C name>'<n>`,
# and a cached read is `g'<address>'<type tag>`.
let
  Ch = import ./check.nix;
  T = Ch.types;
  B = import ../lib/bits.nix;
  inherit (builtins)
    all
    any
    attrNames
    attrValues
    bitAnd
    concatLists
    concatMap
    concatStringsSep
    div
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
    sort
    substring
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
  # s = { n; mem; vars; names; old; retVoid; cached; bulk; bulkLoads; bulkStore;
  # bulkForms; bulkPages; }: n numbers the next generated name; mem is the current memory;
  # vars maps a variable key to the code of its current value (a name or a constant);
  # names maps a key to the C name; old is the code of the target's value while an
  # assignment's value is emitted; retVoid tells that the function returns void; cached
  # lists the cached reads of the enclosing loop (see "Cached reads"); bulk tells that the
  # iteration of a bulk loop is emitted, which records its loads in bulkLoads and its
  # store in bulkStore, with bulkForms the forms of the read ranges of its loads in order
  # and bulkPages, when its body reads pages, the names of the pages of each load or null
  # (see "Bulk loops").
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
        key = readKey e;
      in
      if key != null && s.vars ? ${key} then
        readCached s key
      else if s.bulk then
        let
          pg = bulkPage s e;
        in
        if pg != null then
          pagedLoad s e pg
        else
          bulkLoad (if bulkIndexed s e then indexAddr s e.expr else a) e
      else
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
      # The address is used twice when the value reads the target, or when the store is
      # checked against the cached reads (see refreshCache).
      ad =
        if hasOld e.value || checksCache s e.target then
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
      r = refreshCache (
        m.s
        // {
          mem = m.name;
          inherit (s) old;
        }
      ) e.target ad.c;
    in
    if s.bulk then
      # The iteration of a bulk loop records its store instead (see "Bulk loops").
      {
        s = vb.s // {
          bulkStore = {
            addr = ad.c;
            value = encode t node.type vb.c;
          };
        };
        binds = v.binds ++ a.binds ++ ad.binds ++ o.binds ++ vb.binds;
        c = if e.post then o.c else vb.c;
      }
    else
      {
        inherit (r) s;
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
          ]
          ++ r.binds;
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
      # A cached read in a branch must not bind, so the entries are settled before.
      st = settleFor c.s [
        e.thenExpr
        e.elseExpr
      ];
      a = expr st.s e.thenExpr;
      b = expr a.s e.elseExpr;
    in
    if a.binds != [ ] || b.binds != [ ] then
      throw "cc: internal error: side effect in a branch of '?:'"
    else
      {
        inherit (b) s;
        binds = c.binds ++ st.binds;
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

  # ---- Cached reads (see the header) ----
  # An entry is { key; attr; addr; type; size; }: the read of the scalar type at the
  # constant address addr. Inside the loop that caches it, s.cached lists the entries
  # (empty elsewhere), s.names.${key} = attr is the name of an entry in the loop and join
  # sets, and its value is given by s.vars.${key}, the code of its base (its value at some
  # earlier point), together with s.hits, the overlap tests (atoms) of the checked stores
  # since that point, shared by all entries. With no hits the value is the base; otherwise
  # it is the value in the current memory when a hit holds (after the last store that hits,
  # no store touches a cached byte), else the base. Reading an entry, or joining it into a
  # set, settles it: the value is bound and becomes the new base, and hits is emptied.

  # The key of a read of type t at the constant address addr. It contains ', which the
  # keys of variables (`<name>@<line>:<col>`) do not.
  cacheKey = addr: t: "'${toString addr}'${t.tag}";
  isCacheKey = key: substring 0 1 key == "'";

  # A read or store at a constant address.
  atConst = x: kindOf x == "deref" && x.expr.kind == "lit";

  # The key of the read e (a "deref" node) when its address is a constant, otherwise null.
  readKey = e: if e.expr.kind == "lit" then cacheKey e.expr.value e.type else null;

  # Whether the bytes [a, a + s) and [k, k + n) overlap, with addresses modulo 2^32.
  overlaps =
    a: s: k: n:
    bitAnd (k - a) B.mask32 < s || bitAnd (a - k) B.mask32 < n;

  # A loop caches reads only when it contains no loop and no call.
  cachesReads = parts: Ch.collect (x: isLoop x || kindOf x == "call") (_: false) parts == [ ];

  # The entries of a loop of parts (condition, body and step): its reads at constant
  # addresses, except those that a store at a constant address in it overlaps.
  cacheEntries =
    parts:
    let
      reads = Ch.collect atConst (_: false) parts;
      stores = map (x: x.target) (
        Ch.collect (x: kindOf x == "assign" && atConst x.target) (_: false) parts
      );
      overlapsRead = r: w: overlaps w.expr.value (T.sizeOf w.type) r.expr.value (T.sizeOf r.type);
      kept = filter (r: !any (overlapsRead r) stores) reads;
      entry =
        r:
        let
          key = cacheKey r.expr.value r.type;
        in
        nameValue key {
          inherit key;
          attr = "g${key}";
          addr = r.expr.value;
          inherit (r) type;
          size = T.sizeOf r.type;
        };
    in
    if cachesReads parts then attrValues (listToAttrs (map entry kept)) else [ ];

  # The value of the entry c read from mem.
  loadEntry = mem: c: load mem c.type (num c.addr);

  # The load e at the address a (emitted) in the iteration of a bulk loop: read from the
  # memory as usual, and recorded with its address (see "Bulk loops").
  bulkLoad =
    a: e:
    a
    // {
      s = a.s // {
        bulkLoads = a.s.bulkLoads ++ [
          {
            node = e;
            addr = a.c;
          }
        ];
      };
      c = load a.s.mem e.type a.c;
    };

  # Whether the load e in the iteration of a bulk loop has the read range of an invariant
  # pointer plus an index in [0, U] (form "index", see loadRegion). The loads are recorded
  # in evaluation order, so its position follows the loads before it and those in its
  # address (all of them at addresses other than constants: the others are cached).
  bulkIndexed =
    s: e:
    let
      at = bulkAt s e;
    in
    e.expr.kind == "ptradd"
    && e.expr.op == "+"
    && at < length s.bulkForms
    && elemAt s.bulkForms at == "index";

  # The position of the load e among the recorded loads of the iteration (see bulkIndexed).
  bulkAt =
    s: e:
    length s.bulkLoads
    + length (Ch.collect (x: kindOf x == "deref" && x.expr.kind != "lit") (_: false) e.expr);

  # The names { pages; off; byLeaf; } of the page read of the load e in the iteration of a bulk
  # loop, or null when it is not one (see "Bulk loops").
  bulkPage =
    s: e:
    let
      at = bulkAt s e;
    in
    if bulkIndexed s e && at < length s.bulkPages then elemAt s.bulkPages at else null;

  # The load e of one byte at an invariant pointer plus an index, read from the pages pg
  # (see bulkPage): byte p = off + index of the read range is element bitAnd p 255 of leaf
  # div p 256 of the lists of bytes, or `M.leafByte <leaves> p` when pg.byLeaf. The
  # pointer is emitted as well, so that the loads recorded in it keep their order, but its
  # value is not used: pg holds the same invariant, bound on entry. The load is recorded
  # like bulkLoad does. -> { s; binds; c; }
  pagedLoad =
    s: e: pg:
    let
      r = exprs s [
        e.expr.ptr
        e.expr.index
      ];
      p = add (atom pg.off) (elemAt r.cs 1);
      q = if pg.byLeaf then leafRead r.s pg p else listRead r.s pg p;
    in
    {
      s = q.s // {
        bulkLoads = q.s.bulkLoads ++ [
          {
            node = e;
            addr = null;
          }
        ];
      };
      inherit (r) binds;
      c = if T.isS8 e.type then app "R.toS8" [ q.c ] else q.c;
    };

  # Byte p of the leaf sets pg.pages. -> { s; c; }
  leafRead = s: pg: p: {
    inherit s;
    c = app "M.leafByte" [
      (atom pg.pages)
      p
    ];
  };

  # Byte p of the lists of bytes pg.pages, with p bound by an inline let. -> { s; c; }
  listRead =
    s: pg: p:
    shareInline s [ p ] (
      ps:
      app "builtins.elemAt" [
        (app "builtins.elemAt" [
          (atom pg.pages)
          (app "div" [
            (head ps)
            (num 256)
          ])
        ])
        (app "bitAnd" [
          (head ps)
          (num 255)
        ])
      ]
    );

  # The address p (a "ptradd" node) of such a load as `base + index * size`, without
  # wrapping: the base is a pointer (unsigned form, below 2^32), the index lies in [0, U],
  # and the bulk form runs only when base + U * size + s - 1 < 2^32. -> { s; binds; c; }
  indexAddr =
    s: p:
    let
      r = exprs s [
        p.ptr
        p.index
      ];
      idx = elemAt r.cs 1;
    in
    {
      inherit (r) s binds;
      c = add (head r.cs) (if p.size == 1 then idx else mul idx (num p.size));
    };

  entryOf = s: key: head (filter (c: c.key == key) s.cached);

  # Whether a store to target is checked against the cached entries at run time: its
  # address is not a constant (one that is, is checked by refreshCache when emitted).
  checksCache = s: target: s.cached != [ ] && target.expr.kind != "lit";

  # The current value of the entry c (see above), as a code value.
  cachedValue =
    s: c:
    if s.hits == [ ] then
      atom s.vars.${c.key}
    else
      low "if ${concatStringsSep " || " s.hits} then ${(loadEntry s.mem c).code} else ${s.vars.${c.key}}";

  # The code of the current value of the variable or entry key, as a join set takes it.
  varCode = s: key: if isCacheKey key then (cachedValue s (entryOf s key)).code else s.vars.${key};

  # The state s with the entries settled: each value bound to a new name, which becomes its
  # base. -> { s; binds; }
  settle =
    s:
    let
      step =
        acc: c:
        let
          f = fresh acc.s "g";
        in
        {
          s = f.s // {
            vars = f.s.vars // {
              ${c.key} = f.name;
            };
          };
          binds = acc.binds ++ [
            {
              inherit (f) name;
              inherit (cachedValue s c) code;
            }
          ];
        };
      r = foldl' step {
        inherit s;
        binds = [ ];
      } s.cached;
    in
    if s.hits == [ ] then
      {
        inherit s;
        binds = [ ];
      }
    else
      r
      // {
        s = r.s // {
          hits = [ ];
        };
      };

  # The cached read key. -> { s; binds; c; }
  readCached =
    s: key:
    let
      r = settle s;
    in
    r // { c = atom r.s.vars.${key}; };

  # s settled when the expressions es read an entry; used before the branches of ?:,
  # which must not bind.
  settleFor =
    s: es:
    if s.hits != [ ] && any (r: s.vars ? ${readKey r}) (Ch.collect atConst (_: false) es) then
      settle s
    else
      {
        inherit s;
        binds = [ ];
      };

  # The byte ranges of the entries cs in address order, those that touch or overlap merged:
  # [ { addr; size; } ].
  cacheRanges =
    cs:
    let
      sorted = sort (x: y: x.addr < y.addr) cs;
      step =
        acc: c:
        let
          last = elemAt acc (length acc - 1);
          end = last.addr + last.size;
          cEnd = c.addr + c.size;
        in
        if acc != [ ] && c.addr <= end then
          genList (i: elemAt acc i) (length acc - 1)
          ++ [
            {
              inherit (last) addr;
              size = (if cEnd > end then cEnd else end) - last.addr;
            }
          ]
        else
          acc
          ++ [
            {
              inherit (c) addr size;
            }
          ];
    in
    foldl' step [ ] sorted;

  # Run-time test that the store of size bytes at the address a (an atom) overlaps one of
  # the ranges of the entries cs: per range [k, k + n), a in it, or (size > 1) k in
  # [a, a + size), modulo 2^32.
  overlapCode =
    a: size: cs:
    let
      below =
        x: y: n:
        infixN 6 "<" (app "bitAnd" [
          (sub x y)
          (num B.mask32)
        ]) (num n);
      tests = concatMap (
        r: [ (below a (num r.addr) r.size) ] ++ (if size == 1 then [ ] else [ (below (num r.addr) a size) ])
      ) (cacheRanges cs);
    in
    cv 9 (concatStringsSep " || " (map (x: wrap 8 x) tests));

  # The state after a store to target at the address a, with s.mem the memory after the
  # store. A store that may overlap an entry adds its run-time test, bound once, to hits.
  # A store to a constant address never overlaps a cached key: the loop excludes such
  # entries, so the state is returned as is. -> { s; binds; }
  refreshCache =
    s: target: a:
    let
      size = T.sizeOf target.type;
      constant = target.expr.kind == "lit";
      f = fresh s "hit";
    in
    if s.cached == [ ] || constant then
      {
        inherit s;
        binds = [ ];
      }
    else
      {
        s = f.s // {
          hits = s.hits ++ [ f.name ];
        };
        binds = [
          {
            inherit (f) name;
            inherit (overlapCode a size s.cached) code;
          }
        ];
      };

  # The cached keys a join set carries besides the assigned variables: all of them when
  # the joined code may store (memChanged).
  cacheJoinKeys = s: memChanged: if memChanged then map (c: c.key) s.cached else [ ];

  # The hits of a state that reads the variables keys from a join set: none when the set
  # carries the entries (it holds their settled values).
  hitsAfterJoin = s: keys: if any isCacheKey keys then [ ] else s.hits;

  # The tail of a loop's update set for the entries in state st: entries whose base is
  # still the one the iteration started with are added only when a hit holds,
  # `// (if <hits> then { <attr> = <value in st.mem>; ... } else { })`; otherwise every
  # entry is a field. -> { fields; tail; }
  cacheUpdate =
    inner: st:
    let
      cs = st.cached;
      unchanged = all (c: st.vars.${c.key} == inner.vars.${c.key}) cs;
      loads = concatStringsSep " " (map (c: "${c.attr} = ${(loadEntry st.mem c).code};") cs);
    in
    if cs == [ ] || unchanged && st.hits == [ ] then
      {
        fields = [ ];
        tail = "";
      }
    else if unchanged then
      {
        fields = [ ];
        tail = " // (if ${concatStringsSep " || " st.hits} then { ${loads} } else { })";
      }
    else
      {
        fields = map (c: "${c.attr} = ${(cachedValue st c).code};") cs;
        tail = "";
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
              inherit (th.s) n bulkLoads;
            };
            binds = [ ];
          }
        else
          stmt (s1 // { inherit (th.s) n bulkLoads; }) n.elseStmt;
      changed = k: varCode th.s k != varCode s1 k || varCode el.s k != varCode s1 k;
      # The entries share their hits, so they join all together or not at all.
      cacheKeys = map (c: c.key) s1.cached;
      keys =
        filter (k: !isCacheKey k && changed k) (attrNames s1.vars)
        ++ (if any changed cacheKeys then cacheKeys else [ ]);
      memChanged = th.s.mem != s1.mem || el.s.mem != s1.mem;
      at = k: attrName s1.names.${k};
      fields =
        st:
        (if memChanged then [ "mem = ${st.mem};" ] else [ ]) ++ map (k: "${at k} = ${varCode st k};") keys;
      branch = r: renderLet r.binds "{ ${concatStringsSep " " (fields r.s)} }";
      # The loads of the branches stay recorded in a bulk iteration (see "Bulk loops").
      f = fresh (s1 // { inherit (el.s) n bulkLoads; }) "if";
      code = "if ${c.c.code} then\n  ${indent (branch th)}\nelse\n  ${indent (branch el)}";
    in
    if keys == [ ] && !memChanged then
      {
        s = s1 // {
          inherit (el.s) n bulkLoads;
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
          hits = hitsAfterJoin s1 keys;
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
      parts = [
        l.cond
        l.body
        l.step
      ];
      assigned = assignedKeys parts;
      carried = filter (k: elem k assigned) (attrNames s.vars);
      cached = cacheEntries parts;
      lv = fresh s "v";
      v = lv.name;
      inner = lv.s // {
        mem = "${v}.mem";
        vars =
          s.vars
          // listToAttrs (
            map (k: {
              name = k;
              value = "${v}.${attrName s.names.${k}}";
            }) carried
          )
          // listToAttrs (map (c: nameValue c.key "${v}.${c.attr}") cached);
        names = s.names // listToAttrs (map (c: nameValue c.key c.attr) cached);
        inherit cached;
        hits = [ ];
      };
      at = k: attrName inner.names.${k};
      update =
        st: extra:
        let
          cu = cacheUpdate inner st;
          fields =
            (if st.mem != inner.mem then [ "mem = ${st.mem};" ] else [ ])
            ++ concatMap (
              k: if st.vars.${k} != inner.vars.${k} then [ "${at k} = ${st.vars.${k}};" ] else [ ]
            ) carried
            ++ cu.fields
            ++ extra;
        in
        (if fields == [ ] then v else "${v} // { ${concatStringsSep " " fields} }") + cu.tail;
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
      # A condition that is a constant other than 0 is never tested.
      alwaysTrue = l.cond != null && l.cond.kind == "lit" && l.cond.value != 0;
      gen =
        if l.isDo || l.cond == null || alwaysTrue then
          let
            b = bodyThen inner;
          in
          {
            driver = "R.loopDo";
            body = renderLet b.binds b.code;
            inherit (b) s;
          }
        else if !hasEffects l.cond then
          let
            c = cond inner l.cond false;
            b = bodyThen c.s;
          in
          {
            driver = "R.loop (${v}: ${c.c.code})";
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
            driver = "R.loopDo";
            body = renderLet c.binds "if ${c.c.code} then\n  ${indent (renderLet b.binds b.code)}\nelse\n  ${update c.s [ "exit = true;" ]}";
            inherit (b) s;
          };
      res = fresh (s // { inherit (gen.s) n; }) "l";
      # The cached values start from the memory after the for initialization.
      init = concatStringsSep " " (
        [ "mem = ${s.mem};" ]
        ++ map (k: "${at k} = ${s.vars.${k}};") carried
        ++ map (c: "${c.attr} = ${(loadEntry s.mem c).code};") cached
        ++ (if !returns then [ ] else [ "done' = false;" ] ++ (if s.retVoid then [ ] else [ "ret' = 0;" ]))
      );
      code = "${gen.driver} (\n  ${indent "${v}:\n${gen.body}"}\n) { ${init} }";
      plan = bulkPlan s l carried cached;
      bulk = bulkCode s l carried plan res.s;
    in
    {
      inherit (res) name;
      s = (if plan == null then res.s else bulk.s) // {
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
      binds =
        if plan == null then
          [
            {
              inherit (res) name;
              inherit code;
            }
          ]
        else
          bulk.binds
          ++ [
            {
              inherit (res) name;
              code = "if ${bulk.ok} then\n  ${indent bulk.set}\nelse\n  ${indent code}";
            }
          ];
    };

  # ---- Bulk loops (see the header) ----
  # bulkPlan checks the conditions on the typed tree of a loop, walking one iteration in
  # the evaluation order of the emitter (iterEvents); bulkCode emits the entry test and
  # the bulk form.

  int32Tags = [
    "int"
    "uint"
    "long"
    "ulong"
  ];
  word32Tags = int32Tags ++ [ "ptr" ];
  inductionTags = [
    "int"
    "uint"
    "ptr"
  ];
  # The types of the amount of an induction step: int, unsigned and the narrower integers.
  amountTags = [
    "int"
    "uint"
    "char"
    "schar"
    "uchar"
    "short"
    "ushort"
  ];
  tagIn = tags: t: elem t.tag tags;
  # The largest count of a bulk loop: it keeps the products of the entry test and of the
  # induction values below 2^62.
  bulkMax = 16777216;
  pow31 = 2147483648;
  pow32 = 4294967296;

  # Whether e is loop invariant: without side effects, it reads only constants, variables
  # of s (declared before the loop) that the loop does not assign (assigned), and memory at
  # constant addresses (cached reads; a bulk loop stores to no constant address).
  isInvariant =
    s: assigned: e:
    Ch.collect (
      x:
      let
        k = kindOf x;
      in
      elem k [
        "assign"
        "call"
        "old"
      ]
      || k == "var" && (!(s.vars ? ${x.var.key}) || elem x.var.key assigned)
      || k == "deref" && x.expr.kind != "lit"
    ) (_: false) e == [ ];

  # Whether evaluating e cannot fail: no / or % by anything but a constant other than 0,
  # and no shift by anything but a constant. The entry test and the values after the loop
  # evaluate such invariants even where the loop would not.
  isSafe =
    e:
    Ch.collect (
      x:
      kindOf x == "binop"
      && (
        elem x.op [
          "/"
          "%"
        ]
        && !(x.rhs.kind == "lit" && x.rhs.value != 0)
        ||
          elem x.op [
            "<<"
            ">>"
          ]
          && x.rhs.kind != "lit"
      )
    ) (_: false) e == [ ];

  # The events of the expression e in the evaluation order of the emitter, each
  # { ev; must; part; }: ev is "read" (key) or "assign" (key, node) of a variable, "load"
  # (node) or "store" (node) of memory, or "other" (a call). must tells that the event
  # happens whenever its part (cond, body or step) runs: it is not in a branch of ?: or on
  # the right of && or ||. old is the key of the variable that an "old" node reads, null
  # when the target is in memory.
  exprEvents =
    must: part: old: e:
    let
      k = kindOf e;
      go = exprEvents must part old;
      maybe = exprEvents false part old;
      ev = x: [ (x // { inherit must part; }) ];
    in
    if k == "lit" then
      [ ]
    else if k == "var" then
      ev {
        ev = "read";
        key = e.var.key;
      }
    else if k == "old" then
      (
        if old == null then
          [ ]
        else
          ev {
            ev = "read";
            key = old;
          }
      )
    else if
      elem k [
        "cast"
        "neg"
        "bnot"
        "not"
      ]
    then
      go e.expr
    else if
      elem k [
        "binop"
        "cmp"
        "ptrdiff"
      ]
    then
      go e.lhs ++ go e.rhs
    else if k == "logand" || k == "logor" then
      go e.lhs ++ maybe e.rhs
    else if k == "cond" then
      go e.cond ++ maybe e.thenExpr ++ maybe e.elseExpr
    else if k == "ptradd" then
      go e.ptr ++ go e.index
    else if k == "deref" then
      go e.expr
      ++ ev {
        ev = "load";
        node = e;
      }
    else if k == "assign" && e.target.kind == "var" then
      exprEvents must part e.target.var.key e.value
      ++ ev {
        ev = "assign";
        key = e.target.var.key;
        node = e;
      }
    else if k == "assign" then
      exprEvents must part null e.value
      ++ go e.target.expr
      ++ ev {
        ev = "store";
        node = e;
      }
    else
      ev { ev = "other"; };

  # The events of the statement n of a loop body (see exprEvents). A declaration with an
  # initializer adds "decl" (key, node = { var; init; }) after the initializer; any
  # statement but a block, a declaration, an expression or an if is "other".
  stmtEvents =
    must: n:
    let
      k = n.kind;
      ex = exprEvents must "body" null;
      other = [
        {
          ev = "other";
          inherit must;
          part = "body";
        }
      ];
      decl =
        d:
        if d.init == null then
          [ ]
        else
          ex d.init
          ++ [
            {
              ev = "decl";
              key = d.var.key;
              node = d;
              inherit must;
              part = "body";
            }
          ];
    in
    if k == "block" then
      concatMap (stmtEvents must) n.items
    else if k == "decl" then
      concatMap decl n.vars
    else if k == "expr" then
      ex n.expr
    else if k == "if" then
      ex n.cond
      ++ stmtEvents false n.thenStmt
      ++ (if n.elseStmt == null then [ ] else stmtEvents false n.elseStmt)
    else
      other;

  # The events of one iteration of the loop l: condition, body and step, or body and
  # condition for do/while.
  iterEvents =
    l:
    let
      c = if l.cond == null then [ ] else exprEvents true "cond" null l.cond;
      b = stmtEvents true l.body;
      st = if l.step == null then [ ] else exprEvents true "step" null l.step;
    in
    if l.isDo then b ++ c else c ++ b ++ st;

  # The count form of the loop l, or null:
  #   { kind = "down"; key; post; }   the condition n-- (post) or --n of an int n
  #   { kind = "up"; key; op; e; }    the condition i op e of a while or for loop, with op
  #                                   one of < <= > >=, i an int variable and e an int
  #                                   invariant (e op i is turned around)
  countForm =
    invariant: l:
    let
      c = l.cond;
      v = c.value;
      flip = {
        "<" = ">";
        ">" = "<";
        "<=" = ">=";
        ">=" = "<=";
      };
      intVar = x: x.kind == "var" && x.type.tag == "int";
      bound = x: x.type.tag == "int" && invariant x;
      up = i: op: e: {
        kind = "up";
        key = i.var.key;
        inherit op e;
      };
    in
    if c == null then
      null
    else if
      c.kind == "assign"
      && c.target.kind == "var"
      && c.type.tag == "int"
      && v.kind == "binop"
      && v.op == "-"
      && v.lhs.kind == "old"
      && v.rhs.kind == "lit"
      && v.rhs.value == 1
    then
      {
        kind = "down";
        key = c.target.var.key;
        inherit (c) post;
      }
    else if l.isDo || c.kind != "cmp" || !(flip ? ${c.op}) then
      null
    else if intVar c.lhs && bound c.rhs then
      up c.lhs c.op c.rhs
    else if intVar c.rhs && bound c.lhs then
      up c.rhs flip.${c.op} c.lhs
    else
      null;

  # The assignment a to the variable key as an induction step, or null:
  # { type; sign; amount; scale; coef; } adds sign * amount * scale to the variable of
  # type, modulo 2^32; coef is that increment (|coef| < 2^32) when amount is a constant,
  # otherwise null. The forms are ++, --, += and -= (with an int or unsigned variable, a
  # step of int, unsigned or a narrower type; with a pointer, an int or unsigned index),
  # and v = v + c and v = v - c.
  inductionStep =
    invariant: key: a:
    let
      self = x: x.kind == "old" || x.kind == "var" && x.var.key == key;
      selfIn = x: self x || x.kind == "cast" && tagIn word32Tags x.type && self x.expr;
      amountOk = x: invariant x && tagIn amountTags (if x.kind == "cast" then x.expr.type else x.type);
      signOf = op: if op == "+" then 1 else -1;
      v = if a.value.kind == "cast" then a.value.expr else a.value;
      p = a.value;
      step =
        sign: amount: scale:
        let
          raw = sign * amount.value * scale;
        in
        if amount.kind != "lit" && !isSafe amount then
          null
        else
          {
            inherit (a) type;
            inherit sign amount scale;
            coef =
              if amount.kind != "lit" then
                null
              else if raw > -pow32 && raw < pow32 then
                raw
              else
                bitAnd raw B.mask32;
          };
    in
    if T.isPtr a.type then
      (
        if
          p.kind == "ptradd"
          && self p.ptr
          && tagIn [
            "int"
            "uint"
          ] p.index.type
          && amountOk p.index
        then
          step (signOf p.op) p.index p.size
        else
          null
      )
    else if
      v.kind == "binop"
      && elem v.op [
        "+"
        "-"
      ]
      && tagIn [
        "int"
        "uint"
      ] v.type
      && selfIn v.lhs
      && amountOk v.rhs
    then
      step (signOf v.op) v.rhs 1
    else
      null;

  # The constant d with e = e0 + k * d (modulo 2^32) in iteration k, or null: e is built
  # from induction variables with constant steps (ind), safe invariants, + and - on 32-bit
  # integers, pointer arithmetic with a 32-bit index, and casts between 32-bit integers and
  # pointers.
  linCoef =
    invariant: ind: e:
    let
      k = kindOf e;
      sub = linCoef invariant ind;
      both =
        x: y: f:
        if x == null || y == null then null else f x y;
      stepCoef = key: if ind ? ${key} then ind.${key}.coef else null;
    in
    if invariant e then
      (if isSafe e then 0 else null)
    else if k == "var" then
      stepCoef e.var.key
    else if k == "assign" && e.target.kind == "var" then
      stepCoef e.target.var.key
    else if k == "cast" && tagIn word32Tags e.type && tagIn word32Tags e.expr.type then
      sub e.expr
    else if
      k == "binop"
      && elem e.op [
        "+"
        "-"
      ]
      && tagIn int32Tags e.type
    then
      both (sub e.lhs) (sub e.rhs) (x: y: if e.op == "+" then x + y else x - y)
    else if k == "ptradd" && tagIn int32Tags e.index.type then
      both (sub e.ptr) (sub e.index) (x: y: if e.op == "+" then x + y * e.size else x - y * e.size)
    else
      null;

  # The smallest 2^k - 1 that is at least x >= 0.
  lowMask =
    x:
    let
      go = m: if m >= x then m else go (m * 2 + 1);
    in
    go 0;

  # The bound U of an index e that lies in [0, U], or null. env maps the variables with a
  # known range at this point; pure tells that the index has no side effects (otherwise its
  # variables have no range). A bound of 2^32 or more counts as none: such an index
  # cannot pass the entry test, and sums and products of larger bounds would overflow at
  # compile time.
  idxRange =
    env: pure: e:
    let
      u = idxBound env pure e;
    in
    if u != null && u < pow32 then u else null;

  # The bound of e by the rules above, before idxRange limits it.
  idxBound =
    env: pure: e:
    let
      k = kindOf e;
      sub = idxRange env pure;
    in
    if k == "lit" then
      (if e.value >= 0 then e.value else null)
    else if (k == "deref" || k == "cast") && T.isU8 e.type then
      255
    else if (k == "deref" || k == "cast") && T.isU16 e.type then
      65535
    else if
      k == "cast" && T.isInteger e.type && T.isInteger e.expr.type && T.fits e.expr.type e.type
    then
      sub e.expr
    else if k == "var" then
      (if pure && env ? ${e.var.key} then env.${e.var.key} else null)
    else if k == "binop" then
      binopRange e (sub e.lhs) (sub e.rhs)
    else
      null;

  # The bound of the binop e with the bounds l and r (or null) of its operands.
  binopRange =
    e: l: r:
    let
      op = e.op;
      known = l != null && r != null;
      litOk = x: x.kind == "lit" && x.value >= 0;
      c = e.rhs.value;
    in
    if op == "&" then
      (
        if known then
          (if l < r then l else r)
        else if litOk e.rhs then
          r
        else if litOk e.lhs then
          l
        else
          null
      )
    else if op == "|" || op == "^" then
      (if known then lowMask (if l > r then l else r) else null)
    else if op == ">>" then
      (
        if
          tagIn [
            "uint"
            "ulong"
          ] e.type
          && e.rhs.kind == "lit"
          && c >= 0
          && c <= 31
        then
          (if l != null then div l (B.pow2 c) else div pow32 (B.pow2 c) - 1)
        else
          null
      )
    else if op == "+" then
      (if known && l + r < pow31 then l + r else null)
    else
      null;

  # The read range of the load e (a "deref" node at an address other than a constant) at
  # a point where env holds the variable ranges, or null:
  #   { form = "index"; node; base; span; }      [base, base + span] with base invariant
  #   { form = "linear"; node; coef; size; }     [a0, a0 + (N - 1) * coef + size - 1] with
  #                                              a0 the address in iteration 0
  loadRegion =
    invariant: ind: env: e:
    let
      a = e.expr;
      size = T.sizeOf e.type;
      u =
        if a.kind == "ptradd" && a.op == "+" && invariant a.ptr && isSafe a.ptr then
          idxRange env (!hasEffects a.index) a.index
        else
          null;
      d = linCoef invariant ind a;
    in
    if u != null then
      {
        form = "index";
        node = e;
        base = a.ptr;
        span = u * a.size + size - 1;
      }
    else if d != null && d >= 0 then
      {
        form = "linear";
        node = e;
        coef = d;
        inherit size;
      }
    else
      null;

  # The variable range that the assignment or declaration event x sets in env, as a set:
  # the range of its value (below 2^31) when x is the only one to an int or unsigned
  # variable in the loop, a plain assignment or an initializer, in the body and run on
  # every iteration.
  rangeAfter =
    events: env: x:
    let
      isAssign = x.ev == "assign";
      t = if isAssign then x.node.type else x.node.var.type;
      value = if isAssign then x.node.value else x.node.init;
      plain = !isAssign || !x.node.post && !hasOld x.node.value;
      sets = filter (y: (y.ev == "assign" || y.ev == "decl") && y.key == x.key) events;
      u = idxRange env (!hasEffects value) value;
    in
    if
      x.must
      && x.part == "body"
      && tagIn [
        "int"
        "uint"
      ] t
      && plain
      && length sets == 1
      && u != null
      && u < pow31
    then
      { ${x.key} = u; }
    else
      { };

  # The read ranges (loadRegion) of the loads at addresses other than constants among
  # events, in order.
  loadRegions =
    invariant: ind: events:
    (foldl'
      (
        acc: x:
        if x.ev == "load" && x.node.expr.kind != "lit" then
          acc // { regions = acc.regions ++ [ (loadRegion invariant ind acc.env x.node) ]; }
        else if x.ev == "assign" || x.ev == "decl" then
          acc // { env = acc.env // rangeAfter events acc.env x; }
        else
          acc
      )
      {
        env = { };
        regions = [ ];
      }
      events
    ).regions;

  # The plan of the bulk form of the loop l entered in state s with the carried variables
  # and cached reads of `loop`, or null when the loop does not qualify:
  # { count; ind; temps; coef; regions; cached; } with count the count form, ind the
  # induction steps by key, temps the keys of the temporaries, coef the constant step of
  # the store address and regions the read ranges (loadRegions).
  bulkPlan =
    s: l: carried: cached:
    let
      parts = [
        l.cond
        l.body
        l.step
      ];
      invariant = isInvariant s (assignedKeys parts);
      events = iterEvents l;
      count = countForm invariant l;
      assignsOf = key: filter (x: x.ev == "assign" && x.key == key) events;
      others = filter (key: count.kind != "down" || key != count.key) carried;
      stepOf =
        key:
        let
          as = assignsOf key;
          a = head as;
        in
        if length as == 1 && a.must && tagIn inductionTags a.node.type then
          inductionStep invariant key a.node
        else
          null;
      ind = listToAttrs (
        concatMap (
          key:
          let
            st = stepOf key;
          in
          if st == null then [ ] else [ (nameValue key st) ]
        ) others
      );
      temps = filter (key: !(ind ? ${key})) others;
      isTemp =
        key:
        let
          uses = filter (x: (x.ev == "read" || x.ev == "assign") && x.key == key) events;
        in
        uses != [ ] && (head uses).ev == "assign" && (head uses).must;
      countOk =
        if count.kind == "down" then
          length (assignsOf count.key) == 1
        else
          (ind.${count.key}.coef or null) == (
            if
              elem count.op [
                "<"
                "<="
              ]
            then
              1
            else
              -1
          );
      stores = filter (x: x.ev == "store") events;
      store = head stores;
      target = store.node.target;
      coef = linCoef invariant ind target.expr;
      storeOk =
        length stores == 1
        && store.must
        && store.part == "body"
        && !store.node.post
        && !hasOld store.node.value
        && T.sizeOf target.type == 1
        && target.expr.kind != "lit"
        && coef != null
        && coef >= 1;
      regions = loadRegions invariant ind events;
    in
    if
      cachesReads parts
      && count != null
      && !any (x: x.ev == "other") events
      && countOk
      && all isTemp temps
      && storeOk
      && all (r: r != null) regions
    then
      {
        inherit
          count
          ind
          temps
          coef
          regions
          cached
          ;
      }
    else
      null;

  # c bound to a fresh name of base after the bindings of acc = { s; binds; }, unless it
  # is an atom. -> { s; binds; c; }
  bindIn =
    acc: base: c:
    let
      f = fresh acc.s base;
    in
    if isAtom c then
      acc // { inherit c; }
    else
      {
        inherit (f) s;
        binds = acc.binds ++ [
          {
            inherit (f) name;
            inherit (c) code;
          }
        ];
        c = atom f.name;
      };

  # The invariant e emitted in the state sE and bound after acc (see bindIn).
  emitIn =
    sE: acc: base: e:
    let
      r = expr (sE // { inherit (acc.s) n; }) e;
    in
    bindIn {
      s = acc.s // {
        inherit (r.s) n;
      };
      binds = acc.binds ++ r.binds;
    } base r.c;

  # The count N of the bulk loop (the count form p.count) and the requirement of its form,
  # bound after acc. -> acc // { req; } with c the code of N and req that of the
  # requirement (null when there is none).
  countCode =
    s: l: sE: p: acc:
    let
      cf = p.count;
      v0 = atom s.vars.${cf.key};
      down =
        if l.isDo && cf.post then
          add v0 (num 1)
        else if !l.isDo && !cf.post then
          sub v0 (num 1)
        else
          v0;
      eb = emitIn sE acc "e" cf.e;
      e = eb.c;
      diff =
        {
          "<" = sub e v0;
          "<=" = add (sub e v0) (num 1);
          ">" = sub v0 e;
          ">=" = add (sub v0 e) (num 1);
        }
        .${cf.op};
      db = bindIn eb "d" diff;
      upTotal = low "if ${db.c.code} > 0 then ${db.c.code} else 0";
      upReq =
        if cf.op == "<=" then
          infixN 6 "<" e (num 2147483647)
        else if cf.op == ">=" then
          infixN 6 ">" e (num (-2147483648))
        else
          null;
    in
    if cf.kind == "down" then
      bindIn acc "cnt" down // { req = infixN 6 ">=" v0 (num (if cf.post then 0 else 1)); }
    else
      bindIn db "cnt" upTotal // { req = upReq; };

  # Page reads (see the header). The longest read range read by pages, and the constants of
  # the threshold T = max(pageMinCount, pageLeafCost * L) on the count: below it the
  # setup of the pages costs more than it saves.
  pageMaxLen = 16384;
  pageMinCount = 32;
  pageLeafCost = 8;

  # Whether the read range r of the plan is read by pages: an invariant pointer plus an
  # index (form "index") of one byte at an element size of 1, at most pageMaxLen bytes
  # long. Its length is then U + 1 = span + 1.
  pageable =
    r:
    r.form == "index" && T.sizeOf r.node.type == 1 && r.node.expr.size == 1 && r.span + 1 <= pageMaxLen;

  # The two ways of reading pages: from N >= T on as lists of bytes (M.readPages), below
  # T as leaf sets read byte by byte with M.leafByte (M.readLeaves). fn is the function
  # that reads the range, list and off the bases of the names bound for it.
  byPages = {
    fn = "M.readPages";
    list = "pg";
    off = "off";
    byLeaf = false;
  };
  byLeaves = {
    fn = "M.readLeaves";
    list = "lv";
    off = "lo";
    byLeaf = true;
  };

  # The page reads of the plan p of a loop entered in state s, read the way `how` (byPages
  # or byLeaves) and bound after `after` (= { s; binds; }), with bases the code of the
  # base bound for the entry test of each read range (null for "linear"). The reads with
  # the same base and length share their bindings `<list> = <fn> <mem> <base> <length>`
  # and `<off> = bitAnd <base> 255`. -> { s; binds; names; leaves; } with names the
  # { pages; off; byLeaf; } of each read range, or null when it is not read by pages, and
  # leaves the largest L = div U 256 + 2.
  pageReads =
    how: s: p: bases: after:
    foldl'
      (
        acc: i:
        let
          r = elemAt p.regions i;
          base = elemAt bases i;
          len = r.span + 1;
          key = "${base.code} ${toString len}";
          pf = fresh acc.s how.list;
          of = fresh pf.s how.off;
          own = {
            pages = pf.name;
            off = of.name;
            inherit (how) byLeaf;
          };
          leaves = div r.span 256 + 2;
        in
        if !pageable r then
          acc // { names = acc.names ++ [ null ]; }
        else if acc.groups ? ${key} then
          acc // { names = acc.names ++ [ acc.groups.${key} ]; }
        else
          {
            inherit (of) s;
            binds = acc.binds ++ [
              {
                name = pf.name;
                inherit
                  (app how.fn [
                    (atom s.mem)
                    base
                    (num len)
                  ])
                  code
                  ;
              }
              {
                name = of.name;
                inherit
                  (app "bitAnd" [
                    base
                    (num 255)
                  ])
                  code
                  ;
              }
            ];
            groups = acc.groups // {
              ${key} = own;
            };
            names = acc.names ++ [ own ];
            leaves = if leaves > acc.leaves then leaves else acc.leaves;
          }
      )
      {
        inherit (after) s binds;
        groups = { };
        names = [ ];
        leaves = 0;
      }
      (genList (i: i) (length p.regions));

  # The names that occur as identifiers (letters, digits, _, ' and -, not starting with a
  # digit, ' or -) in the Nix source code, as a set of names.
  identsOf =
    code:
    listToAttrs (
      map (x: nameValue (head x) true) (
        filter builtins.isList (builtins.split "([A-Za-z_][A-Za-z0-9_'-]*)" code)
      )
    );

  # The bindings of binds that the source result uses, directly or through other kept
  # bindings, in their order. A binding refers only to those before it, so one pass from
  # the last one suffices; bindings are lazy, so leaving out the others keeps the value.
  liveBinds =
    binds: result:
    let
      count = length binds;
      step =
        acc: i:
        let
          b = elemAt binds (count - 1 - i);
        in
        if acc.need ? ${b.name} then
          {
            need = acc.need // identsOf b.code;
            kept = [ b ] ++ acc.kept;
          }
        else
          acc;
    in
    (foldl' step {
      need = identsOf result;
      kept = [ ];
    } (genList (i: i) count)).kept;

  # The bulk form of the loop l entered in state s (see the header) from the plan p, with
  # names numbered from st0 (a state like s). -> { s; binds; ok; set; } with ok the name of
  # the entry test and set the code of the result: mem and the carried variables, as the
  # loop yields them.
  bulkCode =
    s: l: carried: p: st0:
    let
      mask = num B.mask32;
      wrapTo =
        t: c:
        if t.tag == "int" then
          wrapCode c
        else
          app "bitAnd" [
            c
            mask
          ];
      isN = key: p.count.kind == "down" && key == p.count.key;
      # The cached reads, loaded once from the memory on entry.
      cache =
        foldl'
          (
            acc: c:
            let
              b = bindIn acc "g" (loadEntry s.mem c);
            in
            b
            // {
              vars = acc.vars // {
                ${c.key} = b.c.code;
              };
            }
          )
          {
            s = st0;
            binds = [ ];
            vars = { };
          }
          p.cached;
      sE = s // {
        vars = s.vars // cache.vars;
      };
      # The step of each induction variable modulo 2^32, a constant or bound on entry.
      steps =
        foldl'
          (
            acc: key:
            let
              x = p.ind.${key};
              r = expr (sE // { inherit (acc.s) n; }) x.amount;
              scaled = if x.scale == 1 then r.c else mul r.c (num x.scale);
              b =
                bindIn
                  {
                    s = acc.s // {
                      inherit (r.s) n;
                    };
                    binds = acc.binds ++ r.binds;
                  }
                  "inc"
                  (
                    app "bitAnd" [
                      (if x.sign < 0 then neg scaled else scaled)
                      mask
                    ]
                  );
            in
            if x.coef != null then
              acc
              // {
                codes = acc.codes // {
                  ${key} = num x.coef;
                };
              }
            else
              b
              // {
                codes = acc.codes // {
                  ${key} = b.c;
                };
              }
          )
          {
            inherit (cache) s binds;
            codes = { };
          }
          (attrNames p.ind);
      cnt = countCode s l sE p steps;
      total = cnt.c;
      # The variables at the start of iteration k: the induction variables v0 + k * step
      # and n0 - k; a temporary keeps its value on entry, which the iteration never reads.
      kf = fresh cnt.s "k";
      k = atom kf.name;
      start =
        foldl'
          (
            acc: key:
            let
              v0 = atom s.vars.${key};
              code = if isN key then sub v0 k else wrapTo p.ind.${key}.type (add v0 (mul k steps.codes.${key}));
              f = fresh acc.s s.names.${key};
            in
            if elem key p.temps then
              acc
            else
              {
                inherit (f) s;
                binds = acc.binds ++ [
                  {
                    inherit (f) name;
                    inherit (code) code;
                  }
                ];
                vars = acc.vars // {
                  ${key} = f.name;
                };
              }
          )
          {
            inherit (kf) s;
            binds = [ ];
            vars = { };
          }
          carried;
      # One iteration in evaluation order, every read from the memory on entry; the store
      # and the loads are recorded instead of emitted.
      sb = start.s // {
        inherit (s) mem;
        vars = s.vars // cache.vars // start.vars;
        cached = [ ];
        hits = [ ];
        bulk = true;
        bulkLoads = [ ];
        bulkStore = null;
        bulkForms = map (r: r.form) p.regions;
      };
      seq2 =
        f: g: st:
        let
          x = f st;
          y = g x.s;
        in
        {
          inherit (y) s;
          binds = x.binds ++ y.binds;
        };
      none = st: {
        s = st;
        binds = [ ];
      };
      condPart = st: if l.cond == null then none st else cond st l.cond false;
      bodyPart = st: stmt st l.body;
      stepPart = st: if l.step == null then none st else effect st l.step;
      iterFrom =
        st: if l.isDo then seq2 bodyPart condPart st else seq2 (seq2 condPart bodyPart) stepPart st;
      iter = iterFrom sb;
      store = iter.s.bulkStore;
      loads = iter.s.bulkLoads;
      indices = genList (i: i) (length p.regions);
      sameNode = a: b: a.line == b.line && a.col == b.col;
      matches =
        it:
        it.s.bulkStore != null
        && length it.s.bulkLoads == length p.regions
        && all (i: sameNode (elemAt it.s.bulkLoads i).node (elemAt p.regions i).node) indices;
      recorded = matches iter;
      # A function of k with the bindings of the iteration it that result uses around it.
      atKOf = it: result: "${kf.name}:\n${renderLet (liveBinds (start.binds ++ it.binds) result) result}";
      atK = atKOf iter;
      attrOf = key: attrName s.names.${key};
      linear = filter (i: (elemAt p.regions i).form == "linear") indices;
      bkSet =
        "{ "
        + concatStringsSep " " (
          [ "a' = ${store.addr.code};" ]
          ++ map (i: "r'${toString i} = ${(elemAt loads i).addr.code};") linear
          ++ map (key: "${attrOf key} = ${iter.s.vars.${key}};") p.temps
        )
        + " }";
      bk = bindIn {
        s = st0 // {
          inherit (iter.s) n;
        };
        inherit (cnt) binds;
      } "bk" (low (atK bkSet));
      b0 = bindIn bk "b0" (app bk.c.code [ (num 0) ]);
      a0 = atom "${b0.c.code}.a'";
      last = sub total (num 1);
      wb = bindIn b0 "whi" (add a0 (mul last (num p.coef)));
      whi = wb.c;
      below = c: infixN 6 "<" c (num pow32);
      rangeTest =
        lo: hi: "${(below hi).code} && (${(infixN 6 "<" whi lo).code} || ${(infixN 6 ">" a0 hi).code})";
      regions =
        foldl'
          (
            acc: i:
            let
              r = elemAt p.regions i;
              lb = emitIn sE acc "lo" r.base;
              lo = atom "${b0.c.code}.r'${toString i}";
              hi = add lo (add (mul last (num r.coef)) (num (r.size - 1)));
            in
            if r.form == "index" then
              lb
              // {
                tests = acc.tests ++ [ (rangeTest lb.c (add lb.c (num r.span))) ];
                bases = acc.bases ++ [ lb.c ];
              }
            else
              acc
              // {
                tests = acc.tests ++ [ (rangeTest lo hi) ];
                bases = acc.bases ++ [ null ];
              }
          )
          (
            wb
            // {
              tests = map (r: rangeTest (num r.addr) (num (r.addr + r.size - 1))) (cacheRanges p.cached);
              bases = [ ];
            }
          )
          indices;
      okCode = concatStringsSep " && " (
        (if cnt.req == null then [ ] else [ cnt.req.code ])
        ++ [
          "${total.code} <= ${toString bulkMax}"
          "(${total.code} == 0 || ${(below whi).code}${
            concatStringsSep "" (map (x: " && (${x})") regions.tests)
          })"
        ]
      );
      ok = bindIn regions "ok" (low okCode);
      # The pages are bound in the branch that reads them, so that a loop below the
      # threshold does not allocate them.
      pages = pageReads byPages s p regions.bases {
        inherit (ok) s;
        binds = [ ];
      };
      paged = any (x: x != null) pages.names;
      # The iteration again, with the page reads, numbered after the pages.
      iterP = iterFrom (
        sb
        // {
          inherit (pages.s) n;
          bulkPages = pages.names;
        }
      );
      # Below the threshold the same reads come from the leaves, bound in that branch and
      # numbered after iterP; so is the iteration that reads them.
      leaves = pageReads byLeaves s p regions.bases {
        s = st0 // {
          inherit (iterP.s) n;
        };
        binds = [ ];
      };
      iterL = iterFrom (
        sb
        // {
          inherit (leaves.s) n;
          bulkPages = leaves.names;
        }
      );
      genOf = it: "builtins.genList (\n  ${indent (atKOf it it.s.bulkStore.value.code)}\n) ${total.code}";
      threshold =
        if pageLeafCost * pages.leaves > pageMinCount then pageLeafCost * pages.leaves else pageMinCount;
      vals =
        if paged then
          bindIn
            {
              s = st0 // {
                inherit (iterL.s) n;
              };
              inherit (ok) binds;
            }
            "vals"
            (
              low "if ${total.code} >= ${toString threshold} then\n  ${indent (renderLet pages.binds (genOf iterP))}\nelse\n  ${indent (renderLet leaves.binds (genOf iterL))}"
            )
        else
          bindIn ok "vals" (low (genOf iter));
      write =
        if p.coef == 1 then
          app "M.storeRun" [
            (atom s.mem)
            a0
            total
            vals.c
          ]
        else
          app "M.storeStride" [
            (atom s.mem)
            a0
            (num p.coef)
            total
            vals.c
          ];
      final =
        key:
        if isN key then
          num (if p.count.post then -1 else 0)
        else if elem key p.temps then
          low "if ${total.code} == 0 then ${s.vars.${key}} else (${bk.c.code} (${(sub total (num 1)).code})).${attrOf key}"
        else
          wrapTo p.ind.${key}.type (add (atom s.vars.${key}) (mul total steps.codes.${key}));
      set =
        "{ "
        + concatStringsSep " " (
          [ "mem = if ${total.code} == 0 then ${s.mem} else ${write.code};" ]
          ++ map (key: "${attrOf key} = ${(final key).code};") carried
        )
        + " }";
    in
    if !recorded || paged && !(matches iterP && matches iterL) then
      throw "cc: internal error: the bulk iteration does not match its plan"
    else
      {
        s = st0 // {
          inherit (vals.s) n;
        };
        inherit (vals) binds;
        ok = ok.c.code;
        inherit set;
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
      memChanged = touchesMem branches;
      keys = filter (key: elem key assigned) (attrNames s1.vars) ++ cacheJoinKeys s1 memChanged;
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
      hits = hitsAfterJoin s keys;
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
            ++ map (key: "${at key} = ${varCode st key};") keys
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
      memChanged = touchesMem sections;
      keys =
        filter (key: elem key assigned) (attrNames ps.s.vars)
        ++ map (var: var.key) declared
        ++ cacheJoinKeys ps.s memChanged;
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
        cached = [ ];
        hits = [ ];
        bulk = false;
        bulkLoads = [ ];
        bulkStore = null;
        bulkForms = [ ];
        bulkPages = [ ];
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
