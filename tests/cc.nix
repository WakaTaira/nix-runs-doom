# Tests for the C compiler: the lexer (cc/lex.nix) and the parser (cc/parse.nix), with
# expressions compared through a compact prefix rendering, and the type checker and code
# generator (cc/check.nix, cc/emit.nix) through small C functions compiled with cc.load
# and run.
let
  Lx = import ../cc/lex.nix;
  P = import ../cc/parse.nix;
  Ch = import ../cc/check.nix;
  Cc = import ../cc;
  B = import ../lib/bits.nix;
  M = import ../lib/mem.nix;
  inherit (builtins)
    all
    attrNames
    concatMap
    concatStringsSep
    elem
    elemAt
    filter
    foldl'
    genList
    head
    isAttrs
    isList
    length
    map
    substring
    tryEval
    ;

  t = name: got: expected: { inherit name got expected; };

  toks = src: Lx.lex src;
  texts = src: map (k: k.text) (toks src);
  posOf = k: "${toString k.line}:${toString k.col}";

  # Prefix rendering of an expression node.
  show =
    e:
    let
      k = e.kind;
    in
    if k == "intlit" then
      toString e.value
    else if k == "ident" then
      e.name
    else if k == "binary" || k == "assign" then
      "(${e.op} ${show e.lhs} ${show e.rhs})"
    else if k == "unary" then
      "(${e.op} ${show e.expr})"
    else if k == "prefix" then
      "(pre${e.op} ${show e.expr})"
    else if k == "postfix" then
      "(post${e.op} ${show e.expr})"
    else if k == "deref" then
      "(deref ${show e.expr})"
    else if k == "index" then
      "(index ${show e.base} ${show e.index})"
    else if k == "cast" then
      "(cast ${showType e.type} ${show e.expr})"
    else if k == "call" then
      "(call ${e.name}${concatStringsSep "" (map (a: " " + show a) e.args)})"
    else if k == "dot" then
      "(. ${show e.expr} ${e.name})"
    else if k == "arrow" then
      "(-> ${show e.expr} ${e.name})"
    else if k == "addr" then
      "(& ${show e.expr})"
    else if k == "sizeof" then
      "(sizeof ${show e.expr})"
    else if k == "sizeoftype" then
      "(sizeof ${showType e.type})"
    else if k == "cond" then
      "(? ${show e.cond} ${show e.thenExpr} ${show e.elseExpr})"
    else if k == "charlit" then
      "(char ${toString e.value})"
    else if k == "initlist" then
      "{${concatStringsSep "," (map show e.items)}}"
    else
      throw "show: ${k}";
  # Types: pointers as a suffix `*`, arrays as a prefix `[len]` (outermost first).
  showType =
    ty:
    if ty.tag == "ptr" then
      showType ty.to + "*"
    else if ty.tag == "array" then
      "[${if ty.len == null then "" else show ty.len}]${showType ty.of}"
    else if ty.tag == "struct" || ty.tag == "enum" then
      "${ty.tag} ${ty.name}"
    else
      ty.tag;

  # Prefix rendering of a statement node.
  showStmt =
    st:
    let
      k = st.kind;
    in
    if k == "case" then
      "(case ${show st.value} ${showStmt st.stmt})"
    else if k == "default" then
      "(default ${showStmt st.stmt})"
    else if k == "break" || k == "continue" then
      k
    else if k == "expr" then
      show st.expr
    else if k == "empty" then
      ";"
    else if k == "block" then
      "{${concatStringsSep " " (map showStmt st.items)}}"
    else if k == "switch" then
      "(switch ${show st.cond} ${showStmt st.body})"
    else if k == "while" then
      "(while ${show st.cond} ${showStmt st.body})"
    else if k == "if" then
      "(if ${show st.cond} ${showStmt st.thenStmt}${
        if st.elseStmt == null then "" else " " + showStmt st.elseStmt
      })"
    else
      throw "showStmt: ${k}";

  # Body statements of the last function in src.
  lastBody =
    src:
    let
      items = (P.parse src).items;
    in
    (elemAt items (length items - 1)).body.items;

  # The expression of `e;` inside a function with int a, b, c and int *p in scope.
  exprOf = e: (head (lastBody "void f(int a, int b, int c, int *p) { ${e}; }")).expr;
  parsed = e: show (exprOf e);

  throws = src: !(tryEval (P.parse src)).success;

  hex = elemAt (toks "x = 0x1F + 0xffU + 10l + 7LL + 5ul;") 2;
  lits = filter (k: k.kind == "int") (toks "x = 0x1F + 0xffU + 10l + 7LL + 5ul;");
  litInfo = k: {
    inherit (k) value unsigned long;
  };

  commented = toks "a /* one\n two */ b // three\n  c";

  typedefSrc = ''
    typedef unsigned char byte;
    void f(byte *x) {
      byte *y = (byte *)x;
      y = (byte *)0x00110000 + 1;
    }
  '';
  typedefBody = lastBody typedefSrc;
  yDecl = head (head typedefBody).decls;

  # The M0 spike C (bench/spike), with the address macros written as casts.
  spikeC = import ../cc/examples/spike.nix;
  spikeFuncs = filter (i: i.kind == "func") (P.parse spikeC).items;

  # ---- Slice 2 syntax ----

  items = src: (P.parse src).items;
  # Declarations of the declaration statements of the last function in src.
  bodyDecls = src: concatMap (st: st.decls) (lastBody src);

  # The fields of a struct item, as [ name type ].
  fieldsOf =
    s:
    map (f: [
      f.name
      (showType f.type)
    ]) s.members;

  structSrc = ''
    typedef struct node {
      int v;
      struct node *next;
      struct pair { short lo, hi; } pair;
      unsigned char name[8];
    } node_t;
    node_t *head;
  '';
  structItems = items structSrc;
  anonItems = items "typedef struct { int a; } anon_t;";

  enumSrc = ''
    enum color { RED, GREEN = 5, BLUE, };
    enum color paint;
  '';
  enumItems = items enumSrc;

  globalSrc = ''
    int a, *b = 0, c[2] = { 1, 2, };
    extern int d[2][3];
    static unsigned short e = 'x';
    int m[2][2] = { { 1 }, { 2, 3 } };
  '';
  # A global item as [ name type storage init ], with "-" for null.
  showGlobal = g: [
    g.name
    (showType g.type)
    (if g.storage == null then "-" else g.storage)
    (if g.init == null then "-" else show g.init)
  ];

  switchSrc = ''
    void f(int x) {
      while (x) { if (x) break; else continue; }
      switch (x) {
      case 1:
      case 2: x = 3; break;
      default: x = 4;
      }
      if (x) case 5: ;
    }
  '';

  # Every node (attribute set with a kind) in a value; types are searched too.
  nodesIn =
    x:
    if isList x then
      concatMap nodesIn x
    else if isAttrs x then
      (if x ? kind then [ x ] else [ ]) ++ concatMap (k: nodesIn x.${k}) (attrNames x)
    else
      [ ];
  slice2Tree = P.parse (
    structSrc
    + enumSrc
    + globalSrc
    + switchSrc
    + ''
      int g(node_t *n) {
        return n->pair.lo ? sizeof(int[3]) : sizeof n->v + (int)&n->name[0] + 'a' + n[0].v;
      }
    ''
  );
  slice2Nodes = nodesIn slice2Tree;
  newKinds = [
    "struct"
    "field"
    "enum"
    "enumconst"
    "global"
    "initlist"
    "break"
    "continue"
    "switch"
    "case"
    "default"
    "dot"
    "arrow"
    "addr"
    "sizeof"
    "sizeoftype"
    "cond"
    "charlit"
  ];

  # ---- Compile and run ----

  # Call the C function fn of src with the given arguments on memory mem.
  callWith =
    mem: src: fn: args:
    foldl' (f: a: f a) ((Cc.load src).${fn} mem) args;
  # Return value of fn on empty memory.
  ret =
    src: fn: args:
    (callWith M.empty src fn args).ret;
  compileThrows = src: !(tryEval (Cc.compile src)).success;

  # Memory with the words ws at address 0x1000 onwards.
  wordsAt =
    ws: foldl' (m: i: M.storeWord m (4096 + 4 * i) (elemAt ws i)) M.empty (genList (i: i) (length ws));

  shiftSrc = ''
    int sra(int x) { return x >> 4; }
    int sraVar(int x, int n) { return x >> n; }
    long long sraLL(long long x) { return x >> 40; }
    int shl(int x) { return x << 3; }
    int sign63(long long x) { return x >> 63; }
    int sign63Var(long long x, int n) { return x >> n; }
  '';

  llongMinSrc = "int f(void) { long long x = ~9223372036854775807; return x < 0; }";

  scopeSrc = "int g(int a, int b) { int x = a; { int x = x + b; a = x; } return a; }";

  unsignedSrc = ''
    unsigned add(unsigned a, unsigned b) { return a + b; }
    unsigned mul(unsigned a, unsigned b) { return a * b; }
    unsigned below(void) { unsigned x = 0; x = x - 1; return x; }
    int mixed(int a) { return a < 1u; }
    int divs(int a, int b) { return a / b * 100 + a % b; }
  '';

  charSrc = ''
    int narrow(int v) { unsigned char c = v; return c; }
    int store(unsigned char *p, int v) { *p = v; return *p; }
    int signedRead(unsigned char *p) { *p = 200; signed char *q = (signed char *)p; return *q; }
    int plainChar(char *p) { *p = 255; return *p; }
    int plainRead(unsigned char *p) { *p = 200; char *q = (char *)p; return *q; }
    int plainNarrow(int v) { char c = v; return c; }
  '';

  ptrSrc = ''
    unsigned step(int *p) { return (unsigned)(p + 3); }
    int same(int *p, int i) { return p[i] == *(p + i) && i[p] == p[i]; }
    int sum(int *p, int n) {
      for (int i = 0; i < n; i++) *(p + i) = i * 10;
      int s = 0;
      for (int i = 0; i < n; i++) s += p[i];
      return s;
    }
    int diff(int *p) { int *q = p + 5; return q - p; }
  '';

  incSrc = ''
    int post(int x) { int y = x++; return y * 100 + x; }
    int pre(int x) { int y = ++x; return y * 100 + x; }
    int postDec(int x) { int y = x--; return y * 100 + x; }
    int fill(unsigned char *d) {
      unsigned char *e = d;
      *d++ = 1;
      *d++ = 2;
      *d++ = *e + 4;
      return d - e;
    }
    int countdown(int n) { int k = 0; while (--n) k++; return k; }
    int postLoop(int n) { int k = 0; while (n--) k += 2; return k * 100 + n; }
    int incMem(int *p) { int a = (*p)++; int b = ++*p; return a * 100 + b * 10 + *p; }
  '';

  controlSrc = ''
    int compound(int x) {
      x += 3; x *= 4; x -= 2; x /= 3; x %= 5; x <<= 2; x >>= 1; x &= 6; x |= 9; x ^= 3;
      return x;
    }
    int ptrCompound(int *p) { p += 2; p -= 1; return *p; }
    int sgn(int x) { int r; if (x < 0) r = -1; else if (x > 0) r = 1; else r = 0; return r; }
    int triangle(int n) {
      int s = 0;
      for (int i = 0; i < n; i++)
        for (int j = 0; j <= i; j++)
          s += j;
      return s;
    }
    int doWhile(int n) { int k = 0; do { k += n; n--; } while (n > 0); return k; }
    int collatz(int n) {
      int c = 0;
      while (n > 1) { if (n % 2) n = 3 * n + 1; else n = n / 2; c++; }
      return c;
    }
    int big(int n) { int s = 0; for (int i = 1; i <= n; i++) s += i; return s; }
    int logic(int a, int b) { return (a && b) * 100 + (a || b) * 10 + !a; }
    int compare(int a, int b) { return (a < b) + (a == b) * 2 + (a >= b) * 4; }
    int sq(int x) { return x * x; }
    int add2(int a, int b) { return a + b; }
    int chain(int x) { return add2(sq(x), sq(x + 1)); }
    void put(int *p, int v) { *p = v; }
    int putBoth(int *p) { put(p, 5); put(p + 1, -6); return p[0] + p[1]; }
  '';

  # ---- Signed 32-bit wrapping and constant expressions ----

  intMax = 2147483647;
  intMin = -2147483648;

  wrapSrc = ''
    int add(int a, int b) { return a + b; }
    int sub(int a, int b) { return a - b; }
    int mul(int a, int b) { return a * b; }
    int quot(int a, int b) { return a / b; }
    int rem(int a, int b) { return a % b; }
    int negate(int a) { return -a; }
    int shl24(int x) { return x << 24; }
    int postInc(int i) { int j = i++; return i; }
    int incMem(int *p) { (*p)++; return *p; }
    int mix(int a, int b, int c, int d) { return a + b * c - d; }
    int mixWrapped(int a, int b, int c, int d) { int t = b * c; t = a + t; t = t - d; return t; }
    int mul3(int a, int b, int c) { return a * b * c; }
    int diffMul(int a, int b, int c) { return (a - b) * c; }
    int index30(int *p, int x) { return p[x << 30]; }
    int folded(void) { return 2147483647 + 1; }
    long long wide(long long a) { return a + 1; }
  '';
  wrapRet = fn: args: ret wrapSrc fn args;

  # Number of wrapInt applications in the compiled src.
  wrapCount = src: length (filter isList (builtins.split "wrapInt \\(" (Cc.compile src)));

  # A constant expression evaluated in the scope of exprOf, as { type; value; }.
  constWith =
    hooks: e:
    let
      x = Ch.constExpr hooks (exprOf e);
    in
    {
      type = x.type.tag;
      inherit (x) value;
    };
  constOf = constWith Ch.noConstHooks;
  constThrows =
    e:
    !(tryEval (
      let
        x = constOf e;
      in
      builtins.deepSeq x x
    )).success;
  constHooks = {
    ident =
      name:
      if name == "RED" then
        {
          type = {
            tag = "int";
          };
          value = 5;
        }
      else
        null;
    sizeOf = n: if n.kind == "sizeoftype" && n.type.tag == "int" then 4 else null;
  };

  fixmulSrc = import ../cc/examples/spike.nix;
  fixmul =
    a: b:
    B.u32 (
      ret fixmulSrc "FixedMul" [
        a
        b
      ]
    );
in
[
  # Lexer
  (t "cc lex: hex literal"
    {
      inherit (hex) kind text value;
    }
    {
      kind = "int";
      text = "0x1F";
      value = 31;
    }
  )
  (t "cc lex: integer suffixes" (map litInfo lits) [
    {
      value = 31;
      unsigned = false;
      long = 0;
    }
    {
      value = 255;
      unsigned = true;
      long = 0;
    }
    {
      value = 10;
      unsigned = false;
      long = 1;
    }
    {
      value = 7;
      unsigned = false;
      long = 2;
    }
    {
      value = 5;
      unsigned = true;
      long = 1;
    }
  ])
  (t "cc lex: multi-character operators" (texts "a>>=b++&&c<<=d") [
    "a"
    ">>="
    "b"
    "++"
    "&&"
    "c"
    "<<="
    "d"
    ""
  ])
  (t "cc lex: operator kinds" (map (k: k.kind) (toks "x >>= 1")) [
    "ident"
    "punct"
    "int"
    "eof"
  ])
  (t "cc lex: keyword" (head (toks "unsigned u")).kind "keyword")
  (t "cc lex: comments dropped" (map (k: k.text) commented) [
    "a"
    "b"
    "c"
    ""
  ])
  (t "cc lex: line and column" (map posOf commented) [
    "1:1"
    "2:9"
    "3:3"
    "3:4"
  ])
  (t "cc lex: preprocessor directive throws" (!(tryEval (toks "#define X 1")).success) true)
  (t "cc lex: string literal throws" (!(tryEval (toks "f(\"s\")")).success) true)

  # Parser: precedence and associativity
  (t "cc parse: a - b - c is left-associative" (parsed "a - b - c") "(- (- a b) c)")
  (t "cc parse: * binds tighter than +" (parsed "a + b * c") "(+ a (* b c))")
  (t "cc parse: = is right-associative" (parsed "a = b = c") "(= a (= b c))")
  (t "cc parse: *p++ applies ++ first" (parsed "*p++") "(deref (post++ p))")
  (t "cc parse: shifts below additive" (parsed "a << b + c") "(<< a (+ b c))")
  (t "cc parse: & below ==" (parsed "a & b == c") "(& a (== b c))")
  (t "cc parse: && below |, || below &&" (parsed "a || b && c | a") "(|| a (&& b (| c a)))")
  (t "cc parse: compound assignment" (parsed "a += b <<= c") "(+= a (<<= b c))")
  (t "cc parse: unary and postfix" (parsed "-a[b]-- + !~--c")
    "(+ (- (post-- (index a b))) (! (~ (pre-- c))))"
  )
  (t "cc parse: call" (parsed "f(a, b + 1)") "(call f a (+ b 1))")
  (t "cc parse: binary position is the operator" (posOf (exprOf "a + b")) "1:41")

  # Parser: typedef names
  (t "cc parse: declaration starting with a typedef name"
    {
      inherit (yDecl) kind name;
      type = showType yDecl.type;
    }
    {
      kind = "vardecl";
      name = "y";
      type = "uchar*";
    }
  )
  (t "cc parse: cast to a typedef pointer" (show yDecl.init) "(cast uchar* x)")
  (t "cc parse: cast of a literal binds tighter than +" (show (elemAt typedefBody 1)
    .expr) "(= y (+ (cast uchar* 1114112) 1))")
  (t "cc parse: parameter shadows a typedef name" (show (head (
    lastBody "typedef int t; void f(int t) { t * 2; }"
  )).expr) "(* t 2)")
  (t "cc parse: specifier order" (showType (head (head (
    lastBody "void f(void) { long unsigned int x; }"
  )).decls).type) "ulong")

  # Parser: the M0 spike C
  (t "cc parse: spike C has 4 functions" (map (f: f.name) spikeFuncs) [
    "FixedMul"
    "R_DrawColumn"
    "R_DrawSpan"
    "unit"
  ])

  # Lexer: character literals
  (t "cc lex: character literals"
    (map (k: [
      k.kind
      k.value
    ]) (filter (k: k.kind == "char") (toks "'a' '\\n' '\\0' '\\\\' '\\'' ' '")))
    [
      [
        "char"
        97
      ]
      [
        "char"
        10
      ]
      [
        "char"
        0
      ]
      [
        "char"
        92
      ]
      [
        "char"
        39
      ]
      [
        "char"
        32
      ]
    ]
  )
  (t "cc lex: character literal position" (posOf (elemAt (toks "x = '\\''") 2)) "1:5")
  (t "cc lex: multi-character literal throws" (!(tryEval (toks "'ab'")).success) true)
  (t "cc lex: octal escape throws" (!(tryEval (toks "'\\012'")).success) true)
  (t "cc lex: unterminated character literal throws" (!(tryEval (toks "'a")).success) true)

  # Parser: types
  (t "cc parse: short and unsigned short"
    (map (d: showType d.type) (
      bodyDecls "void f(void) { short a; unsigned short b; short int c; signed short d; unsigned short int e; }"
    ))
    [
      "short"
      "ushort"
      "short"
      "short"
      "ushort"
    ]
  )
  (t "cc parse: struct definitions come before the declaration that uses them"
    (map (i: [
      i.kind
      i.name
    ]) structItems)
    [
      [
        "struct"
        "pair"
      ]
      [
        "struct"
        "node"
      ]
      [
        "typedef"
        "node_t"
      ]
      [
        "global"
        "head"
      ]
    ]
  )
  (t "cc parse: struct members (self-referential pointer, nested struct, array)"
    (fieldsOf (elemAt structItems 1))
    [
      [
        "v"
        "int"
      ]
      [
        "next"
        "struct node*"
      ]
      [
        "pair"
        "struct pair"
      ]
      [
        "name"
        "[8]uchar"
      ]
    ]
  )
  (t "cc parse: struct member declarators share the specifiers" (fieldsOf (head structItems)) [
    [
      "lo"
      "short"
    ]
    [
      "hi"
      "short"
    ]
  ])
  (t "cc parse: typedef of a struct refers to it by tag"
    (map (i: showType i.type) (genList (k: elemAt structItems (k + 2)) 2))
    [
      "struct node"
      "struct node*"
    ]
  )
  (t "cc parse: anonymous struct gets a name no identifier can have"
    {
      name = (head anonItems).name;
      same = (head anonItems).name == (elemAt anonItems 1).type.name;
    }
    {
      name = "(anonymous at 1:9)";
      same = true;
    }
  )
  (t "cc parse: enum constants, explicit and implicit"
    (map (c: [
      c.kind
      c.name
      (if c.value == null then "-" else show c.value)
    ]) (head enumItems).consts)
    [
      [
        "enumconst"
        "RED"
        "-"
      ]
      [
        "enumconst"
        "GREEN"
        "5"
      ]
      [
        "enumconst"
        "BLUE"
        "-"
      ]
    ]
  )
  (t "cc parse: enum type refers to the tag" (showType (elemAt enumItems 1).type) "enum color")
  (t "cc parse: enum constant shadows a typedef name" (show (head (
    lastBody "typedef int RED; enum { RED }; void f(void) { RED * 2; }"
  )).expr) "(* RED 2)")
  (t "cc parse: array declarators"
    (map (d: showType d.type) (bodyDecls "void f(void) { int m[2][3], *q[4], n[1 + 1]; }"))
    [
      "[2][3]int"
      "[4]int*"
      "[(+ 1 1)]int"
    ]
  )
  (t "cc parse: array parameters keep their array type"
    (map (p: showType p.type) (head (items "void f(int a[], char b[4]);")).params)
    [
      "[]int"
      "[4]char"
    ]
  )

  # Parser: declarations
  (t "cc parse: file-scope variables with initializers and storage classes"
    (map showGlobal (items globalSrc))
    [
      [
        "a"
        "int"
        "-"
        "-"
      ]
      [
        "b"
        "int*"
        "-"
        "0"
      ]
      [
        "c"
        "[2]int"
        "-"
        "{1,2}"
      ]
      [
        "d"
        "[2][3]int"
        "extern"
        "-"
      ]
      [
        "e"
        "ushort"
        "static"
        "(char 120)"
      ]
      [
        "m"
        "[2][2]int"
        "-"
        "{{1},{2,3}}"
      ]
    ]
  )
  (t "cc parse: initializer with an address and an array name"
    (map showGlobal (items "int t[2]; int *p = &t[1], *q = t;"))
    [
      [
        "t"
        "[2]int"
        "-"
        "-"
      ]
      [
        "p"
        "int*"
        "-"
        "(& (index t 1))"
      ]
      [
        "q"
        "int*"
        "-"
        "t"
      ]
    ]
  )
  (t "cc parse: static and extern functions"
    (map (i: i.kind) (items "static int f(void) { return 0; } extern int g(int);"))
    [
      "func"
      "proto"
    ]
  )
  (t "cc parse: block-scope struct definition and array"
    (map (d: d.kind) (bodyDecls "void f(void) { struct s { int a; } x, y[2]; }"))
    [
      "struct"
      "vardecl"
      "vardecl"
    ]
  )

  # Parser: statements
  (t "cc parse: break and continue" (showStmt (
    head (lastBody switchSrc)
  )) "(while x {(if x break continue)})")
  (t "cc parse: switch with case and default labels" (showStmt (
    elemAt (lastBody switchSrc) 1
  )) "(switch x {(case 1 (case 2 (= x 3))) break (default (= x 4))})")
  (t "cc parse: case outside a switch body is still a label" (showStmt (
    elemAt (lastBody switchSrc) 2
  )) "(if x (case 5 ;))")

  # Parser: expressions
  (t "cc parse: member access" (parsed "p->a.b[1]") "(index (. (-> p a) b) 1)")
  (t "cc parse: address-of" (parsed "*&a + (a & b)") "(+ (deref (& a)) (& a b))")
  (t "cc parse: address of an element" (parsed "&p[1]") "(& (index p 1))")
  (t "cc parse: sizeof an expression binds like a prefix operator" (parsed "sizeof a + 1")
    "(+ (sizeof a) 1)"
  )
  (t "cc parse: sizeof a parenthesized expression" (parsed "sizeof (a) * sizeof *p")
    "(* (sizeof a) (sizeof (deref p)))"
  )
  (t "cc parse: sizeof a type name" (parsed "sizeof(unsigned short) + sizeof(int *[3])")
    "(+ (sizeof ushort) (sizeof [3]int*))"
  )
  (t "cc parse: ?: is right-associative" (parsed "a ? b : c ? a : b") "(? a b (? c a b))")
  (t "cc parse: ?: below ||, above =" (parsed "a = b || c ? a = b : c")
    "(= a (? (|| b c) (= a b) c))"
  )
  (t "cc parse: character literals" (parsed "'a' + '\\n' - '\\0' + '\\\\' + '\\''")
    "(+ (+ (- (+ (char 97) (char 10)) (char 0)) (char 92)) (char 39))"
  )

  # Parser: positions
  (t "cc parse: every slice-2 node kind occurs in the sample" (filter (
    k: !(elem k (map (n: n.kind) slice2Nodes))
  ) newKinds) [ ])
  (t "cc parse: every node has a line and a column" (all (n: n ? line && n ? col) slice2Nodes) true)
  (t "cc parse: positions of new nodes"
    (map posOf [
      (exprOf "a ? b : c")
      (exprOf "a.b")
      (exprOf "&a")
      (exprOf "sizeof a")
      (head (items "  struct s { int a; };"))
      (head (items "int x, y = 1;"))
    ])
    [
      "1:41"
      "1:40"
      "1:39"
      "1:39"
      "1:3"
      "1:5"
    ]
  )

  # Parser: outside the subset
  (t "cc parse: goto throws" (throws "void f(void) { goto x; }") true)
  (t "cc parse: union throws" (throws "union u { int a; };") true)
  (t "cc parse: bit-field throws" (throws "struct s { int a : 3; };") true)
  (t "cc parse: function pointer declarator throws" (throws "void (*fp)(int);") true)
  (t "cc parse: variadic function throws" (throws "int f(int a, ...);") true)
  (t "cc parse: comma operator throws" (throws "void f(int a) { a = 1, 2; }") true)
  (t "cc parse: floating-point type throws" (throws "float x;") true)
  (t "cc parse: string literal throws" (throws "int f(void) { return g(\"s\"); }") true)
  (t "cc parse: designated initializer throws" (throws "int a[2] = { [1] = 2 };") true)
  (t "cc parse: block-scope static throws" (throws "void f(void) { static int x; }") true)
  (t "cc parse: declaration without a declarator throws" (throws "int;") true)

  # Code generation: output shape
  (t "cc compile: output starts with the argument set" (substring 0 12
    Cc.examples.spike.nix
  ) "{ M, B, R }:")
  (t "cc compile: output has no import" (builtins.match ".*import.*" Cc.examples.spike.nix) null)

  # Shifts
  (t "cc run: negative int >> floors"
    (map (x: ret shiftSrc "sra" [ x ]) [
      (-33)
      (-1)
      33
    ])
    [
      (-3)
      (-1)
      2
    ]
  )
  (t "cc run: variable int >> floors" (ret shiftSrc "sraVar" [
    (-33)
    4
  ]) (-3))
  (t "cc run: long long >> floors" (ret shiftSrc "sraLL" [ (-1099511627777) ]) (-2))
  (t "cc run: int << multiplies" (ret shiftSrc "shl" [ (-5) ]) (-40))
  (t "cc run: long long >> 63 yields the sign"
    (map (x: ret shiftSrc "sign63" [ x ]) [
      (-5)
      5
    ])
    [
      (-1)
      0
    ]
  )
  (t "cc run: variable long long >> 63 yields the sign"
    (map
      (
        x:
        ret shiftSrc "sign63Var" [
          x
          63
        ]
      )
      [
        (-5)
        5
      ]
    )
    [
      (-1)
      0
    ]
  )

  # Constants and scopes
  (t "cc run: constant folded to LLONG_MIN" (ret llongMinSrc "f" [ ]) 1)
  (t "cc run: initializer sees the declared name, not the outer one" (ret scopeSrc "g" [
    7
    100
  ]) 100)

  # Unsigned and signed arithmetic
  (t "cc run: unsigned + wraps" (ret unsignedSrc "add" [
    4294967295
    2
  ]) 1)
  (t "cc run: unsigned * wraps" (ret unsignedSrc "mul" [
    65536
    65537
  ]) 65536)
  (t "cc run: unsigned 0 - 1 wraps" (ret unsignedSrc "below" [ ]) 4294967295)
  (t "cc run: int < unsigned compares as unsigned"
    (map (a: ret unsignedSrc "mixed" [ a ]) [
      (-1)
      0
    ])
    [
      0
      1
    ]
  )
  (t "cc run: signed / and % truncate" (ret unsignedSrc "divs" [
    (-7)
    2
  ]) (-301))

  # char conversions
  (t "cc run: unsigned char assignment truncates"
    (map (v: ret charSrc "narrow" [ v ]) [
      300
      (-1)
    ])
    [
      44
      255
    ]
  )
  (t "cc run: unsigned char store truncates" (ret charSrc "store" [
    256
    4660
  ]) 52)
  (t "cc run: unsigned char store leaves the next byte" (M.loadWord
    (callWith M.empty charSrc "store" [
      256
      4660
    ]).mem
    256
  ) 52)
  (t "cc run: signed char read sign-extends" (ret charSrc "signedRead" [ 256 ]) (-56))
  (t "cc run: plain char is unsigned" (ret charSrc "plainChar" [ 256 ]) 255)
  (t "cc run: plain char read zero-extends" (ret charSrc "plainRead" [ 256 ]) 200)
  (t "cc run: plain char assignment truncates to unsigned"
    (map (v: ret charSrc "plainNarrow" [ v ]) [
      300
      (-1)
    ])
    [
      44
      255
    ]
  )

  # Pointers
  (t "cc run: int * + 3 adds 12" (ret ptrSrc "step" [ 4096 ]) 4108)
  (t "cc run: p[i] is *(p + i)" ((callWith
    (wordsAt [
      10
      20
      30
      40
    ])
    ptrSrc
    "same"
    [
      4096
      2
    ]
  ).ret
  ) 1)
  (t "cc run: store through *(p + i), read through p[i]" (ret ptrSrc "sum" [
    4096
    5
  ]) 100)
  (t "cc run: pointer difference counts elements" (ret ptrSrc "diff" [ 4096 ]) 5)

  # ++ and --
  (t "cc run: postfix ++ yields the old value" (ret incSrc "post" [ 3 ]) 304)
  (t "cc run: prefix ++ yields the new value" (ret incSrc "pre" [ 3 ]) 404)
  (t "cc run: postfix -- yields the old value" (ret incSrc "postDec" [ 3 ]) 302)
  (t "cc run: *d++ = x stores at the old address"
    (
      let
        r = callWith M.empty incSrc "fill" [ 256 ];
      in
      {
        inherit (r) ret;
        word = M.loadWord r.mem 256;
      }
    )
    {
      ret = 3;
      word = 328193; # bytes 1, 2, 5
    }
  )
  (t "cc run: while (--n)" (ret incSrc "countdown" [ 5 ]) 4)
  (t "cc run: while (n--) keeps the last decrement" (ret incSrc "postLoop" [ 3 ]) 599)
  (t "cc run: ++ and -- on memory" ((callWith (wordsAt [ 7 ]) incSrc "incMem" [ 4096 ]).ret) 799)

  # Statements and calls
  (t "cc run: compound assignments" (ret controlSrc "compound" [ 7 ]) 14)
  (t "cc run: pointer compound assignments" ((callWith (wordsAt [
    10
    20
    30
  ]) controlSrc "ptrCompound" [ 4096 ]).ret
  ) 20)
  (t "cc run: if/else chain"
    (map (x: ret controlSrc "sgn" [ x ]) [
      (-5)
      0
      7
    ])
    [
      (-1)
      0
      1
    ]
  )
  (t "cc run: nested for loops" (ret controlSrc "triangle" [ 5 ]) 20)
  (t "cc run: do/while runs at least once"
    (map (n: ret controlSrc "doWhile" [ n ]) [
      4
      0
    ])
    [
      10
      0
    ]
  )
  (t "cc run: while with if/else inside" (ret controlSrc "collatz" [ 6 ]) 8)
  (t "cc run: loop over several chunks" (ret controlSrc "big" [ 1000 ]) 500500)
  (t "cc run: && || ! as values"
    (map (p: ret controlSrc "logic" p) [
      [
        3
        0
      ]
      [
        0
        0
      ]
      [
        2
        5
      ]
    ])
    [
      10
      1
      110
    ]
  )
  (t "cc run: comparisons as values"
    (map (p: ret controlSrc "compare" p) [
      [
        1
        2
      ]
      [
        2
        2
      ]
      [
        3
        2
      ]
    ])
    [
      1
      6
      4
    ]
  )
  (t "cc run: chained calls" (ret controlSrc "chain" [ 3 ]) 25)
  (t "cc run: void calls thread memory" (ret controlSrc "putBoth" [ 4096 ]) (-1))

  # FixedMul, the cases of the fixmul instruction (tests/xdoom.nix)
  (t "cc run: FixedMul 3.0 * 2.0" (fixmul 196608 131072) 393216)
  (t "cc run: FixedMul -3.0 * 2.0" (fixmul (-196608) 131072) (B.u32 (-393216)))
  (t "cc run: FixedMul -1 * 1 floors to -1" (fixmul (-1) 1) 4294967295)
  (t "cc run: FixedMul INT_MAX * INT_MAX" (fixmul 2147483647 2147483647) 4294901760)

  # Signed 32-bit wrapping (expected values: C with -fwrapv, 32-bit two's complement)
  (t "cc run: INT_MAX + 1 wraps" (wrapRet "add" [
    intMax
    1
  ]) intMin)
  (t "cc run: INT_MIN - 1 wraps" (wrapRet "sub" [
    intMin
    1
  ]) intMax)
  (t "cc run: INT_MIN / -1 is INT_MIN" (wrapRet "quot" [
    intMin
    (-1)
  ]) intMin)
  (t "cc run: 7 / -1 is -7" (wrapRet "quot" [
    7
    (-1)
  ]) (-7))
  (t "cc run: INT_MIN % -1 is 0" (wrapRet "rem" [
    intMin
    (-1)
  ]) 0)
  (t "cc run: 200 << 24 wraps" (wrapRet "shl24" [ 200 ]) (-939524096))
  (t "cc run: 46341 * 46341 wraps" (wrapRet "mul" [
    46341
    46341
  ]) (-2147479015))
  (t "cc run: -INT_MIN is INT_MIN" (wrapRet "negate" [ intMin ]) intMin)
  (t "cc run: i++ past INT_MAX wraps" (wrapRet "postInc" [ intMax ]) intMin)
  (t "cc run: ++ on memory past INT_MAX wraps"
    (
      let
        r = callWith (wordsAt [ intMax ]) wrapSrc "incMem" [ 4096 ];
      in
      {
        inherit (r) ret;
        word = M.loadWord r.mem 4096;
      }
    )
    {
      ret = intMin;
      word = 2147483648;
    }
  )
  (t "cc run: a + b * c - d unwrapped in between equals wrapping every step"
    (map
      (args: [
        (wrapRet "mix" args)
        (wrapRet "mixWrapped" args)
      ])
      [
        [
          intMax
          65536
          65536
          (-5)
        ]
        [
          intMin
          46341
          (-46341)
          intMax
        ]
      ]
    )
    [
      [
        (-2147483644)
        (-2147483644)
      ]
      [
        2147479016
        2147479016
      ]
    ]
  )
  (t "cc run: a * b * c past the bound wraps in between"
    (map (wrapRet "mul3") [
      [
        65537
        65537
        65537
      ]
      [
        (-2147483647)
        intMax
        3
      ]
      [
        intMin
        intMin
        intMin
      ]
    ])
    [
      196609
      (-3)
      0
    ]
  )
  (t "cc run: (a - b) * c past the bound wraps in between" (wrapRet "diffMul" [
    intMax
    intMin
    intMax
  ]) (-2147483647))
  (t "cc run: INT_MIN * INT_MIN at run time is 0" (wrapRet "mul" [
    intMin
    intMin
  ]) 0)
  (t "cc run: index x << 30 is wrapped (x = 2^30 reads p[0])" ((callWith
    (wordsAt [
      77
      88
    ])
    wrapSrc
    "index30"
    [
      4096
      1073741824
    ]
  ).ret
  ) 77)
  (t "cc run: long long does not wrap" (wrapRet "wide" [ intMax ]) 2147483648)
  (t "cc run: a constant expression folds with wrapping" (wrapRet "folded" [ ]) intMin)

  # Where wrapInt is applied (generated code)
  (t "cc compile: wrapInt is bound once at the top" (length (
    filter isList (builtins.split "inherit \\(R\\) wrapInt;" Cc.examples.spike.nix)
  )) 1)
  (t "cc compile: a + b - c + d wraps once"
    (wrapCount "int f(int a, int b, int c, int d) { return a + b - c + d; }")
    1
  )
  (t "cc compile: a + b * c - d wraps b * c (bound 62) and the result"
    (wrapCount "int f(int a, int b, int c, int d) { return a + b * c - d; }")
    2
  )
  (t "cc compile: a * b * c wraps a * b and the result"
    (wrapCount "int f(int a, int b, int c) { return a * b * c; }")
    2
  )
  (t "cc compile: (a << 20) + b leaves a << 20 unwrapped"
    (wrapCount "int f(int a, int b) { return (a << 20) + b; }")
    1
  )
  (t "cc compile: an operand of a comparison is wrapped"
    (wrapCount "int f(int a, int b) { return a + b < a; }")
    1
  )
  (t "cc compile: a pointer index is wrapped"
    (wrapCount "int f(int *p, int x) { return p[x << 30]; }")
    1
  )
  (t "cc compile: / by a constant other than -1 does not wrap"
    (wrapCount "int f(int a) { return a / 2 + a % 3; }")
    1
  )
  (t "cc compile: / and % by -1 or a variable wrap"
    (map wrapCount [
      "int f(int a) { return a / -1; }"
      "int f(int a, int b) { return a % b; }"
    ])
    [
      1
      1
    ]
  )
  (t "cc compile: unsigned and long long arithmetic do not wrap"
    (wrapCount "unsigned f(unsigned a, long long b) { return a * a + (unsigned)(b * b + 1); }")
    0
  )
  (t "cc compile: a constant expression folds to a literal"
    (wrapCount "int f(void) { return (2147483647 + 1) * 3 - (200 << 24); }")
    0
  )
  (t "cc compile: constant shift by 32 throws" (compileThrows "int f(int x) { return x << 32; }")
    true
  )
  (t "cc compile: constant shift by a negative amount throws"
    (compileThrows "unsigned f(unsigned x) { return x >> -1; }")
    true
  )

  # Integer constant expressions (cc/check.nix constExpr)
  (t "cc const: INT_MAX + 1" (constOf "2147483647 + 1") {
    type = "int";
    value = intMin;
  })
  (t "cc const: INT_MIN - 1" (constOf "-2147483647 - 1 - 1") {
    type = "int";
    value = intMax;
  })
  (t "cc const: INT_MIN / -1 and INT_MIN % -1"
    (map constOf [
      "(-2147483647 - 1) / -1"
      "(-2147483647 - 1) % -1"
    ])
    [
      {
        type = "int";
        value = intMin;
      }
      {
        type = "int";
        value = 0;
      }
    ]
  )
  (t "cc const: 200 << 24, 46341 * 46341, -INT_MIN"
    (map (e: (constOf e).value) [
      "200 << 24"
      "46341 * 46341"
      "-(-2147483647 - 1)"
    ])
    [
      (-939524096)
      (-2147479015)
      intMin
    ]
  )
  (t "cc const: unsigned wraps modulo 2^32"
    (map constOf [
      "0xffffffff + 1"
      "0u - 1"
      "0x80000000u * 2"
      "0xffffffffu << 31"
    ])
    [
      {
        type = "uint";
        value = 0;
      }
      {
        type = "uint";
        value = 4294967295;
      }
      {
        type = "uint";
        value = 0;
      }
      {
        type = "uint";
        value = 2147483648;
      }
    ]
  )
  (t "cc const: long long does not wrap" (constOf "(long long)2147483647 + 1") {
    type = "llong";
    value = 2147483648;
  })
  (t "cc const: casts convert"
    (map constOf [
      "(unsigned char)300"
      "(signed char)200"
      "(int)4294967295u"
    ])
    [
      {
        type = "uchar";
        value = 44;
      }
      {
        type = "schar";
        value = -56;
      }
      {
        type = "int";
        value = -1;
      }
    ]
  )
  (t "cc const: >> floors and / truncates"
    (map (e: (constOf e).value) [
      "-7 >> 1"
      "-7 / 2"
      "-7 % 2"
      "0x80000000u >> 31"
    ])
    [
      (-4)
      (-3)
      (-1)
      1
    ]
  )
  (t "cc const: comparisons use the usual conversions"
    (map (e: (constOf e).value) [
      "-1 < 0u"
      "-1 < 0"
      "3 == 3"
    ])
    [
      0
      1
      1
    ]
  )
  (t "cc const: ! && || ?:"
    (map constOf [
      "!0 + (3 && 0) * 10 + (0 || 2) * 100"
      "1 ? 2 : 3u"
      "0 ? -1 : 5"
    ])
    [
      {
        type = "int";
        value = 101;
      }
      {
        type = "uint";
        value = 2;
      }
      {
        type = "int";
        value = 5;
      }
    ]
  )
  (t "cc const: character literals"
    (map (e: (constOf e).value) [
      "'a' + 1"
      "'\\n'"
      "'\\0'"
    ])
    [
      98
      10
      0
    ]
  )
  (t "cc const: names and sizes come from the hooks"
    (map (constWith constHooks) [
      "RED + 1"
      "sizeof(int) * 2"
    ])
    [
      {
        type = "int";
        value = 6;
      }
      {
        type = "uint";
        value = 8;
      }
    ]
  )
  (t "cc const: non-constant operands throw"
    (map constThrows [
      "a + 1"
      "*p"
      "RED"
      "sizeof(int)"
      "1 / 0"
      "1 << 32"
      "(int *)0 == 0"
    ])
    [
      true
      true
      true
      true
      true
      true
      true
    ]
  )

  # Outside the subset and type errors
  (t "cc compile: switch throws" (compileThrows "void f(int x) { switch (x) { } }") true)
  (t "cc compile: struct throws" (compileThrows "struct s { int a; };") true)
  (t "cc compile: &x throws" (compileThrows "void f(int x) { int *p = &x; }") true)
  (t "cc compile: global variable throws" (compileThrows "int g;") true)
  (t "cc compile: enum throws" (compileThrows "enum e { A };") true)
  (t "cc compile: block-scope struct throws" (compileThrows "void f(void) { struct s { int a; } x; }")
    true
  )
  (t "cc compile: break throws" (compileThrows "void f(int x) { while (x) break; }") true)
  (t "cc compile: case throws" (compileThrows "void f(int x) { if (x) case 1: ; }") true)
  (t "cc compile: member access throws" (compileThrows "struct s; int f(int *p) { return p->a; }")
    true
  )
  (t "cc compile: ?: throws" (compileThrows "int f(int x) { return x ? 1 : 2; }") true)
  (t "cc compile: sizeof throws" (compileThrows "int f(void) { return sizeof(int); }") true)
  (t "cc compile: character literal throws" (compileThrows "int f(void) { return 'a'; }") true)
  (t "cc compile: short parameter throws" (compileThrows "int f(short x) { return 0; }") true)
  (t "cc compile: short local with an initializer throws"
    (compileThrows "void f(void) { short s = 0; }")
    true
  )
  (t "cc compile: local array throws" (compileThrows "void f(void) { int a[3]; }") true)
  (t "cc compile: cast to unsigned short throws"
    (compileThrows "int f(int x) { return (unsigned short)x; }")
    true
  )
  (t "cc compile: return before the end throws"
    (compileThrows "int f(int x) { if (x) return 1; return 0; }")
    true
  )
  (t "cc compile: side effect right of && throws" (compileThrows "int f(int x) { return x && x++; }")
    true
  )
  (t "cc compile: call right of || throws"
    (compileThrows "int g(void) { return 1; } int f(int x) { return x || g(); }")
    true
  )
  (t "cc compile: 8-byte memory access throws"
    (compileThrows "long long f(long long *p) { return *p; }")
    true
  )
  (t "cc compile: undeclared identifier throws" (compileThrows "int f(void) { return y; }") true)
  (t "cc compile: undeclared function throws" (compileThrows "int f(void) { return g(); }") true)
  (t "cc compile: call to a declared but undefined function throws"
    (compileThrows "int g(void); int f(void) { return g(); }")
    true
  )
  (t "cc compile: assignment to a non-lvalue throws" (compileThrows "void f(int x) { x + 1 = 2; }")
    true
  )
  (t "cc compile: argument count mismatch throws"
    (compileThrows "int g(int a) { return a; } int f(void) { return g(1, 2); }")
    true
  )
  (t "cc compile: int to pointer without a cast throws"
    (compileThrows "void f(int x) { int *p = x; }")
    true
  )
]
