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
    bitAnd
    bitXor
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

  # ---- Data: file-scope variables, arrays, structs, enums ----
  # Expected addresses and values follow C and clang's ilp32 layout, worked out by hand.

  base = 4194304; # the default dataBase, 0x00400000

  # The compiled functions of src (loaded with loadFn) and the memory with its data
  # initialized (__data.init applied to empty memory).
  loadData =
    loadFn: src:
    let
      f = loadFn src;
    in
    {
      inherit f;
      mem = f.__data.init M.empty;
    };
  # Result ({ mem; ret; }) of fn of src called on the initialized data.
  dcall =
    src: fn: args:
    let
      d = loadData Cc.load src;
    in
    foldl' (g: a: g a) (d.f.${fn} d.mem) args;
  dret =
    src: fn: args:
    (dcall src fn args).ret;
  # The string s contains needle.
  contains = needle: s: builtins.replaceStrings [ needle ] [ "" ] s != s;
  # The __data.symbols of src, relative to base.
  offsetsOf =
    src: names:
    let
      syms = (Cc.load src).__data.symbols;
    in
    map (n: syms.${n} - base) names;

  dataSrc = ''
    char c; int i; short s; char d; int *p;
    int g = 5;
    int arr[4] = { 1, 2, 3 };
    int m[2][3] = { { 1, 2, 3 }, { 4, 5, 6 } };
    int *pa = &arr[2];
    int *pn = arr;
    int *pg = &g;
    int zero;
    int readScalar(void) { return g; }
    int writeScalar(int v) { g = v; return g * 2; }
    int readArr(int k) { return arr[k]; }
    int writeArr(int k, int v) { arr[k] = v; return arr[0] + arr[1] + arr[2] + arr[3]; }
    int readM(int k, int j) { return m[k][j]; }
    int writeM(int v) { m[1][2] = v; return m[1][2] * 10 + m[0][0]; }
    int viaPtr(void) { p = &i; *p = 42; return i; }
    int initAddrs(void) { return *pa * 100 + pn[1] * 10 + *pg; }
    int uninit(void) { return zero + c + i + s + d + (p == 0); }
  '';

  shortSrc = ''
    short gs; unsigned short gu;
    int narrowS(int v) { short x = v; return x; }
    int narrowU(int v) { unsigned short x = v; return x; }
    int storeS(int v) { gs = v; return gs; }
    int storeU(int v) { gu = v; return gu; }
    int param(short x) { return x; }
    int callParam(int v) { return param(v); }
    int casts(int v) { return (unsigned short)v + (short)v; }
    int readThrough(short *q) { return *q; }
  '';

  enumRunSrc = ''
    enum color { RED, GREEN = 5, BLUE, LAST = BLUE * 2 };
    int table[LAST] = { RED, GREEN, BLUE };
    enum color paint = BLUE;
    enum sign { MINUS = -1, PLUS = 1 };
    int values(void) { return RED * 1000 + GREEN * 100 + BLUE * 10 + LAST; }
    int size(void) { return sizeof table; }
    int initialized(void) { return table[1] * 10 + table[2] + paint; }
    int unsignedEnum(void) { enum color c = RED; return c - 1 > 0; }
    int signedEnum(void) { enum sign x = MINUS; return x < 0; }
    int shadowed(int GREEN) { return GREEN; }
  '';

  structRunSrc = ''
    struct pt { char tag; int x; short y; };
    struct box { struct pt lo, hi; unsigned char name[3]; };
    struct node { int v; struct node *next; };
    struct pt pts[3] = { { 'a', 1, 2 }, { 'b', 3, 4 } };
    struct box bx = { { 'l', 10, 11 }, { 'h', 20, 21 }, { 7, 8, 9 } };
    struct node n3 = { 3, 0 }, n2 = { 2, &n3 }, n1 = { 1, &n2 };
    int offsets(void) {
      return ((char *)&pts[0].x - (char *)pts) * 100 + ((char *)&pts[0].y - (char *)pts) * 10
        + sizeof(struct pt);
    }
    int dot(int k) { return pts[k].x * 10 + pts[k].y; }
    int arrow(void) { struct pt *q = &pts[1]; q->x = 9; return pts[1].x + q->tag; }
    int nested(void) { return bx.hi.x + bx.lo.y + bx.name[2]; }
    int nestedWrite(void) { struct box *b = &bx; b->hi.y = 5; b->name[0] = 1; return bx.hi.y * 10 + bx.name[0]; }
    int sizes(void) { return sizeof(struct box) * 100 + sizeof bx.name * 10 + sizeof pts / sizeof pts[0]; }
    int walk(void) { int t = 0; for (struct node *q = &n1; q; q = q->next) t = t * 10 + q->v; return t; }
    int relink(void) {
      n1.next = &n3; n3.v = 7;
      int t = 0;
      for (struct node *q = &n1; q; q = q->next) t = t * 10 + q->v;
      return t;
    }
  '';

  addrSrc = ''
    int g = 6;
    int a[4] = { 10, 20, 30, 40 };
    struct s { int x; int m; } sv = { 1, 2 };
    int deref(int *q) { return *q; }
    int sum(int *q, int n) { int t = 0; for (int i = 0; i < n; i++) t += q[i]; return t; }
    int addrG(void) { return deref(&g); }
    int addrElem(int i) { return deref(&a[i]); }
    int addrMember(void) { return deref(&sv.m); }
    int addrArrow(void) { struct s *q = &sv; int *r = &q->m; *r = 5; return sv.m; }
    int derefAddr(void) { return *&g; }
    int arrayArg(void) { return sum(a, 4); }
    int arrayParam(int q[], int n) { return q[n - 1]; }
    int arrayParamCall(void) { return arrayParam(a, 3); }
    int addrEq(void) { return (&a[1] == a + 1) + (&*a == a) * 10; }
  '';

  sizeofSrc = ''
    int g; short h[5]; struct t { char c; short s; } v;
    unsigned sz(int k) {
      return k == 0 ? sizeof(short) : k == 1 ? sizeof h : k == 2 ? sizeof(struct t)
        : k == 3 ? sizeof v.s : k == 4 ? sizeof(int *[3]) : sizeof g;
    }
    int isUnsigned(void) { return sizeof(int) - 5 > 0; }
  '';

  condSrc = ''
    int pick(int x, int a, int b) { return x ? a : b; }
    int sign(int x) { return x < 0 ? -1 : x > 0 ? 1 : 0; }
    unsigned common(int x) { return x ? 1u : -1; }
    int inCond(int x) { int r = 0; if (x ? x - 1 : 1) r = 5; return r; }
    int ptrs(int x, int *p) { int *q = x ? p : 0; return q == 0; }
  '';

  charLitSrc = "int lit(int k) { return k == 0 ? 'a' : k == 1 ? '\\n' : k == 2 ? '\\0' : k == 3 ? '\\\\' : '\\''; } int add(int x) { return x + 'A'; }";

  # ---- return, break, continue and switch ----
  # Expected values follow the C semantics, worked out by hand.

  jumpSrc = ''
    int retIf(int x) { if (x > 0) return 1; return 2; }
    int retBoth(int x) { if (x) return 10; else return 20; }
    int retLoop(int n) { for (int i = 0; i < n; i++) { if (i * i > 20) return i; } return -1; }
    int retNested(int n) {
      for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
          if (i * j == 12) return i * 100 + j;
      return 0;
    }
    int retDo(int n) { int i = 0; do { if (i == n) return i * 10; i++; } while (1); }
    int retEffCond(int n) { while (n-- > 0) { if (n == 2) return 100 + n; } return n; }
    int retStore(int *p, int x) { *p = 1; if (x) return 5; *p = 2; return 6; }
    void retVoid(int *p, int x) { *p = 1; if (x) return; *p = 2; }
    void retVoidLoop(int *p, int n) { for (int i = 0; i < n; i++) { if (i == 2) return; p[i] = i + 1; } }
    int fallOff(int x) { if (x) return 7; }
    int noReturn(int x) { x = x + 1; }
    int joinRet(int x) { int r = 0; if (x > 0) { r = 1; if (x > 10) return 99; r = 2; } else r = 3; return r; }
    int whileBreak(int n) { int i = 0; while (1) { if (i >= n) break; i++; } return i; }
    int whileCont(int n) { int i = 0, s = 0; while (i < n) { i++; if (i % 2) continue; s += i; } return s; }
    int effCondBreak(int n) { while (n-- > 0) { if (n == 2) break; } return n; }
    int doBreak(int n) { int i = 0; do { if (i == n) break; i++; } while (i < 100); return i; }
    int doCont(int n) { int i = 0, s = 0; do { i++; if (i % 3) continue; s += i; } while (i < n); return s; }
    int doContCond(int n) { int i = 0, c = 0; do { c++; continue; } while (++i < n); return c * 100 + i; }
    int forBreak(int n) { int i; for (i = 0; i < 100; i++) { if (i == n) break; } return i; }
    int forCont(int n) { int s = 0; for (int i = 0; i < n; i++) { if (i % 2) continue; s += i; } return s; }
    int nestedBreak(int n) {
      int c = 0;
      for (int i = 0; i < n; i++) { for (int j = 0; j < n; j++) { if (j == i) break; c++; } }
      return c;
    }
    int forBreakFirst(void) { int i = 0; for (; i < 3; i++) { break; } return i; }
    int doBreakFirst(void) { int i = 0; do { break; } while (++i < 1); return i; }
    int joinLoop(int n) {
      int s = 0;
      for (int i = 0; i < n; i++) {
        if (i % 2) { s += 1; if (i == 5) break; s += 10; }
        else { s += 100; if (i == 4) continue; s += 1000; }
        s += 10000;
      }
      return s;
    }
  '';
  jumpFns = Cc.load jumpSrc;
  # Result ({ mem; ret; } or the memory) of fn of jumpSrc on memory mem.
  jumpCall =
    mem: fn: args:
    foldl' (f: a: f a) (jumpFns.${fn} mem) args;
  jumpRet = fn: args: (jumpCall M.empty fn args).ret;

  switchRunSrc = ''
    enum color { RED, GREEN = 5, BLUE };
    int k = 1;
    int sw(int x) {
      int r = 0;
      switch (x) {
      case 1: r = 10; break;
      case 2: r = 20;
      case 3: r += 3; break;
      case 4: case 5: r = 45; break;
      default: r = -1;
      }
      return r;
    }
    int defFirst(int x) { int r = 0; switch (x) { default: r = 100; case 1: r += 1; break; case 2: r = 2; } return r; }
    int defMiddle(int x) { int r = 0; switch (x) { case 1: r = 1; break; default: r = 50; break; case 2: r = 2; } return r; }
    int noMatch(int x) { int r = 7; switch (x) { case 1: r = 1; } return r; }
    int swRet(int x) { switch (x) { case 1: return 11; case 2: x = 5; break; } return x * 2; }
    int swLoop(int n) {
      int s = 0;
      for (int i = 0; i < n; i++) {
        switch (i % 3) { case 0: continue; case 1: s += 10; break; default: s += 1; }
        s += 100;
      }
      return s;
    }
    int swLoopRet(int n) {
      for (int i = 0; ; i++) { switch (i) { case 5: return i * 3; default: break; } if (i > n) break; }
      return -1;
    }
    int nested(int a, int b) {
      int r = 0;
      switch (a) {
      case 1: switch (b) { case 1: r = 11; break; default: r = 19; } r += 100; break;
      case 2: r = 2;
      }
      return r;
    }
    int labels(int c) { switch (c) { case RED: return 1; case GREEN: return 2; case BLUE: return 3; case 'a': return 4; } return 0; }
    int once(void) { int r = 0; switch (k++) { case 1: r = 1; break; case 2: r = 2; break; default: r = 3; } return r * 10 + k; }
    int decl(int x) { int r = 0; switch (x) { case 1: r = 1; int t = r + 5; r = t; case 2: t = 7; r += t; } return r; }
    int shadow(int x) { int y = 1; switch (x) { case 1: y = 2; int y = 3; y += 1; case 2: y = 9; } return y; }
    unsigned char narrow(unsigned char c) { switch (c) { case 200: return 1; case 255: return 2; } return 0; }
  '';
  switchFns = Cc.load switchRunSrc;
  swRet = fn: args: (foldl' (f: a: f a) (switchFns.${fn} (switchFns.__data.init M.empty)) args).ret;

  # Number of occurrences of needle in s.
  countIn = needle: s: length (filter isList (builtins.split needle s));

  # ---- Review fixes ----

  # Order of an assignment to memory: the value, then the target's address, then its old
  # value (clang 21, riscv32).
  orderSrc = ''
    int g; int arr[4]; int i;
    int h(void) { g = 10; return 1; }
    int k(void) { i = 2; return 7; }
    int idx(void) { return i; }
    int f1(void) { g = 1; g += h(); return g; }
    int f2(void) { i = 0; arr[idx()] = k(); return arr[0]; }
    int f2at(void) { i = 0; arr[idx()] = k(); return arr[2]; }
    int f3(void) { i = 0; arr[2] = 5; arr[idx()] += k(); return arr[2] * 100 + arr[0]; }
    int f4(void) { i = 0; arr[i] = k(); return arr[0]; }
    int f5(void) { g = 1; g = g + h(); return g; }
    int used(void) { g = 1; int r = (g += h()); return r * 100 + g; }
    int postUsed(void) { g = 1; int r = g++ + h(); return r * 100 + g; }
    int postTarget(void) { int *p = arr; arr[0] = 0; *p++ = k(); return (p - arr) * 100 + arr[0]; }
    int local(void) { int x = 1; x += h(); return x; }
  '';
  orderRet = fn: dret orderSrc fn [ ];

  # The bytes at a and a + 1 after storing the int v through a short pointer at a.
  halfBytes =
    a: v:
    let
      m = callWith M.empty "void f(short *p, int v) { *p = v; }" "f" [
        a
        v
      ];
    in
    [
      (M.loadByte m a)
      (M.loadByte m (a + 1))
    ];

  lexThrows = src: !(tryEval (Lx.lex src)).success;

  switchKindsSrc = ''
    int onlyBreak(int x) { int r = 0; switch (x) { case 1: r = 1; break; default: r = 2; } return r; }
    int withReturn(int x) { switch (x) { case 1: return 5; default: break; } return 0; }
    int withContinue(int n) {
      int s = 0;
      for (int i = 0; i < n; i++) { switch (i) { case 1: continue; default: break; } s += i; }
      return s;
    }
  '';
  # The source of the generated function fn of switchKindsSrc.
  switchKindsCode =
    fn:
    let
      parts = builtins.split "\n  [A-Za-z]+_fn =\n" (Cc.compile switchKindsSrc);
      names = [
        "onlyBreak"
        "withReturn"
        "withContinue"
      ];
      at = n: if elemAt names n == fn then n else at (n + 1);
    in
    elemAt parts (2 * (at 0 + 1));

  # ---- Unconditional loop driver and cached reads ----
  # Expected values follow the C semantics, worked out by hand.

  # The source of the generated function fn in the compiled src (up to the next function).
  fnCodeWith =
    compileFn: src: fn:
    let
      parts = builtins.split "\n  ([A-Za-z_][A-Za-z0-9_]*)_fn =\n" (compileFn src);
      at = i: if elemAt parts (2 * i + 1) == [ fn ] then elemAt parts (2 * i + 2) else at (i + 1);
    in
    at 0;
  fnCode = fnCodeWith Cc.compile;

  loopDoSrc = ''
    int doW(int n) { int s = 0; do { s += n; } while (--n > 0); return s; }
    int forEver(int n) { int i = 0; for (;;) { if (i == n) break; i++; } return i; }
    int whileOne(int n) { int i = 0; while (1) { i += 3; if (i > n) return i; } }
    int preDec(int n) { int k = 0; while (--n) k += 2; return k; }
    int whileLess(int n) { int i = 0, s = 0; while (i < n) { s += i; i++; } return s; }
  '';

  # Globals at base + 0 (g), 4 (h), 8 (hs), 10 (hc), 12 (arr), 24 (limit), 28 (a2), 32 (b2).
  cacheSrc = ''
    int g; int h; short hs; signed char hc; int arr[3]; int limit; int a2; int b2;
    int id(int x) { return x; }
    int byteAt(int k, int n, int which) {
      unsigned char *p = (unsigned char *)&g + k;
      int before = 0, after = 0;
      g = 0;
      for (int i = 0; i < n; i++) { before += g; *p = i + 1; after += g; }
      return which ? after : before;
    }
    int straddleWord(int which) {
      int *p = (int *)((unsigned char *)&a2 + 2);
      int ra = 0, rb = 0;
      for (int i = 0; i < 1; i++) { ra = a2; rb = b2; *p = 0x01020304; ra = a2; rb = b2; }
      return which ? rb : ra;
    }
    int straddleHalf(int which) {
      unsigned short *p = (unsigned short *)((unsigned char *)&a2 + 3);
      int ra = 0, rb = 0;
      for (int i = 0; i < 1; i++) { ra = a2; rb = b2; *p = 0x0506; ra = a2; rb = b2; }
      return which ? rb : ra;
    }
    int signedReload(int n) {
      unsigned char *p = (unsigned char *)&hs;
      unsigned char *q = (unsigned char *)&hc;
      int s = 0, t = 0;
      for (int i = 0; i < n; i++) { s = hs; t = hc; p[1] = 0x80; q[0] = 0xff; s = hs; t = hc; }
      return s * 1000 + t;
    }
    int noOverlap(int n) {
      unsigned char *lo = (unsigned char *)&g - 1;
      unsigned char *hi = (unsigned char *)&g + 4;
      int s = 0;
      g = 7;
      for (int i = 0; i < n; i++) { *lo = 0xff; *hi = i; s += g; }
      return s * 100 + h;
    }
    int compound(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) { *p += 1; s += g; } return s; }
    int postInc(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) { (*p)++; s += g; } return s; }
    int inCond(int n) { int *p = &g; int s = 0, i = 0; g = 0; while ((*p = i) < n) { s += g; i++; } return s * 100 + g; }
    int inStep(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; *p = ++i) s += g; return s * 100 + g; }
    int inDoCond(int n) { int *p = &g; int s = 0, i = 0; g = 0; do { s += g; } while ((*p = ++i) < n); return s * 100 + g; }
    int inTernary(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) s += (*p = i) ? g * 10 : g + 100; return s; }
    int inAnd(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) { if ((*p = i) && g > 1) s += g; } return s; }
    int joinIf(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) { if (i == 1) *p = 5; s += g; } return s; }
    int joinIfBreak(int n) {
      int *p = &g; int s = 0; g = 0;
      for (int i = 0; i < n; i++) { if (i == 1) { *p = 5; if (n == 0) break; } s += g; }
      return s;
    }
    int joinSwitch(int n) {
      int *p = &g; int s = 0; g = 1;
      for (int i = 0; i < n; i++) { switch (i) { case 0: *p = 2; break; default: ; } s += g; }
      return s;
    }
    int contAfter(int n) {
      int *p = &g; int s = 0; g = 0;
      for (int i = 0; i < n; i++) { s += g; if (i % 2 == 0) { *p = g + 10; continue; } s += 1000; }
      return s;
    }
    int breakAfter(int n) {
      int *p = &g; int s = 0; g = 0;
      for (int i = 0; i < n; i++) { s += g; if (i == 2) { *p = 42; break; } *p = g + 1; }
      return g * 100 + s;
    }
    int retAfter(int n) {
      int *p = &g; g = 1;
      for (int i = 0; i < n; i++) { if (g == 1 && i == 1) { *p = 9; return g; } }
      return -1;
    }
    int constStore(int n) { int s = 0; for (int i = 0; i < n; i++) { g = i; s += g; } return s; }
    int constElem(int n) {
      int s = 0; arr[0] = 100;
      for (int i = 0; i < n; i++) { arr[1] = i * 2; s += arr[1] + arr[0]; }
      return s;
    }
    int withCall(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) { *p = id(i); s += g; } return s; }
    int outer(int n) {
      int *p = &g; int s = 0; g = 0;
      for (int i = 0; i < n; i++) { s += g; *p = i + 1; for (int j = 0; j < 2; j++) s += j; }
      return s;
    }
    int limitCond(int n) {
      int *p = &limit; int i = 0; limit = n;
      while (i < limit) { i++; if (i == 2) *p = 4; }
      return i;
    }
    int twoStores(int n) {
      int *p = &g; int *q = &h; int s = 0; g = 0;
      for (int i = 0; i < n; i++) { s += g; *p = i + 5; *q = 0; }
      return s * 100 + g;
    }
    int ternaryAfter(int n) { int *p = &g; int s = 0; g = 0; for (int i = 0; i < n; i++) { *p = i + 1; s += i ? g : 100; } return s; }
    int pendIf(int n) { int *p = &g; int s = 0, t = 0; g = 0; for (int i = 0; i < n; i++) { *p = i + 1; if (i & 1) t++; s += g; } return s * 10 + t; }
    int pendJoin(int n) { int *p = &g; int s = 0, t = 0; g = 0; for (int i = 0; i < n; i++) { *p = i + 1; if (i & 1) { t++; if (t == 5) continue; } s += g; } return s * 10 + t; }
    int pendSwitch(int n) { int *p = &g; int s = 0, t = 0; g = 0; for (int i = 0; i < n; i++) { *p = i + 1; switch (i) { case 0: t++; break; case 1: continue; default: t += 2; } s += g; } return s * 10 + t; }
  '';
  cacheRet = fn: args: dret cacheSrc fn args;
  cacheSyms = (Cc.load cacheSrc).__data.symbols;
  # The generated fn of cacheSrc caches the read of type tag at the address of the global
  # name.
  cachesIn =
    fn: name: tag:
    contains "g'${toString cacheSyms.${name}}'${tag}" (fnCode cacheSrc fn);

  # The data at address 0: g is at 0.
  wrapSrc0 = ''
    int g;
    int wrapHalf(unsigned a, int n) {
      unsigned short *p = (unsigned short *)a;
      int s = 0; g = 0;
      for (int i = 0; i < n; i++) { s = g; *p = 0x0102; s = g; }
      return s;
    }
    int wrapWord(unsigned a, int n) {
      unsigned *p = (unsigned *)a;
      int s = 0; g = 0;
      for (int i = 0; i < n; i++) { s = g; *p = 0x04030201; s = g; }
      return s;
    }
  '';
  wrapRet0 =
    fn: args:
    let
      d = loadData (Cc.loadWith { dataBase = 0; }) wrapSrc0;
    in
    (foldl' (f: a: f a) (d.f.${fn} d.mem) args).ret;

  # In the draw input, the loop of fn reads the pointer at the address of the global name
  # through its cached value, and loads it only for the initial value (from mem, the
  # memory at the call) and in the set added to the update when the store hits; no
  # re-read is bound per entry. The bulk form of the loop loads it once more on entry.
  drawCacheCase =
    fn: name:
    let
      code = fnCode Cc.examples.draw.src fn;
      k = toString (Cc.load Cc.examples.draw.src).__data.symbols.${name};
    in
    t "cc cache: ${fn} reads ${name} through the cached value"
      [
        (countIn "M\\.loadWord [A-Za-z0-9_.]+ ${k}([^0-9]|$)" code)
        (contains "g'${k}'ptr = M.loadWord mem ${k};" code)
        (countIn "// \\(if hit_[0-9]+ then \\{[^}]* g'${k}'ptr = M\\.loadWord mem_[0-9]+ ${k};[^}]*} else \\{ }\\)" code)
        (countIn "B\\.add [A-Za-z0-9_]+\\.g'${k}'ptr " code)
        (countIn "g_[0-9]+ = if" code)
        (countIn "g_[0-9]+ = M\\.loadWord mem ${k};" code)
      ]
      [
        3
        true
        1
        1
        0
        1
      ];

  # The right-hand sides of the overlap tests (`hit_<n> = <test>;`) in code.
  hitTests = code: map head (filter isList (builtins.split "hit_[0-9]+ = ([^;]*);" code));

  # Globals at base + 0 (a), 4 (b), 8 (pad), 24 (c), 28 (hs), 30 (hc). The stores go
  # through a pointer parameter, so the address in the tests is p_0.
  rangeSrc = ''
    int a; int b; int pad[4]; int c; short hs; signed char hc;
    int adjWord(int *p, int n) { int s = 0; for (int i = 0; i < n; i++) { *p = i; s += a + b; } return s; }
    int adjByte(unsigned char *p, int n) { int s = 0; for (int i = 0; i < n; i++) { *p = i; s += a + b; } return s; }
    int adjHalf(unsigned short *p, int n) { int s = 0; for (int i = 0; i < n; i++) { *p = i * 257; s += a + b; } return s; }
    int farWord(int *p, int n) { int s = 0; for (int i = 0; i < n; i++) { *p = i; s += a + c; } return s; }
    int mixedByte(unsigned char *p, int n) { int s = 0; for (int i = 0; i < n; i++) { *p = i; s += c + hs + hc; } return s; }
  '';
  rangeRet = fn: args: dret rangeSrc fn args;
  rangeHits = fn: hitTests (fnCode rangeSrc fn);

  # ---- Bulk loops ----
  # Expected values follow the C semantics, worked out by hand. Each function writes
  # bytes from d on and returns the loop variables in a form that tells them apart. The
  # functions starting with x are outside the conditions of the bulk form.
  bulkSrc = ''
    int g = 16;
    int id(int x) { return x; }
    int doPost(unsigned char *d, int n) { unsigned char *p = d; do { *p++ = n; } while (n--); return n * 1000 + (p - d); }
    int whilePost(unsigned char *d, int n) { unsigned char *p = d; while (n--) *p++ = n; return n * 1000 + (p - d); }
    int forPost(unsigned char *d, int n) { unsigned char *p = d; for (; n--; p++) *p = n + 1; return n * 1000 + (p - d); }
    int doPre(unsigned char *d, int n) { unsigned char *p = d; do { *p++ = n; } while (--n); return n * 1000 + (p - d); }
    int whilePre(unsigned char *d, int n) { unsigned char *p = d; while (--n) *p++ = n; return n * 1000 + (p - d); }
    int forPre(unsigned char *d, int n) { unsigned char *p = d; for (; --n; ) *p++ = n; return n * 1000 + (p - d); }
    int lt(unsigned char *d, int a, int e) { int i; for (i = a; i < e; i++) d[i - a] = i; return i; }
    int le(unsigned char *d, int a, int e) { int i = a; while (i <= e) { *d++ = i; i++; } return i; }
    int gt(unsigned char *d, int a, int e) { int i; for (i = a; e < i; i--) *d++ = i; return i; }
    int ge(unsigned char *d, int a, int e) { int i; for (i = a; i >= e; --i) *d++ = i; return i; }
    int steps(unsigned char *d, int n, int c, int w) {
      int a = 5, b = 100, x = 7, y = 9, z = 1, m = 50;
      unsigned u = 4294967294u;
      int *q = (int *)16;
      while (n--) { *d++ = a + b + u; a++; b -= 3; x += c; y = y - c; z = z + 2; ++u; q += 2; m--; }
      return w == 0 ? a : w == 1 ? b : w == 2 ? x : w == 3 ? y : w == 4 ? z : w == 5 ? (int)u : w == 6 ? (int)q : m;
    }
    int wrapI(unsigned char *d, int n) { int x = 7; while (n--) { *d++ = x >> 24; x += 0x7fffffff; } return x; }
    int stride4(int *q, int n) { int i = 0; while (n--) { *(unsigned char *)q = i + 1; q++; i++; } return (int)q; }
    int temps(unsigned char *d, int n) { int t = 77, i = 10; while (n--) { t = i * 3; *d++ = t; i++; } return t; }
    int afterCond(unsigned char *d, int n) { int t = -1; while (n--) { t = n; *d++ = t + 10; } return t * 100 + n; }
    int doAfter(unsigned char *d, int n) { int t = -1; do { t = n; *d++ = t; } while (n--); return t * 100 + n; }
    int lut(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[i & 7] + 1; i++; } return i; }
    int copy(unsigned char *d, unsigned char *s, int n) { while (n--) *d++ = *s++; return 0; }
    int glob(unsigned char *d, int n) { int i = 0; while (n--) { *d++ = g + i + 1; i++; } return g; }
    int rShift(unsigned char *d, unsigned char *t, int n) { unsigned u = 0; while (n--) { *d++ = t[u >> 29]; u += 0x20000000u; } return 0; }
    int rOr(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[(i & 3) | (i & 4)]; i++; } return 0; }
    int rByte(unsigned char *d, unsigned char *t, unsigned char *s, int n) { while (n--) *d++ = t[*s++]; return 0; }
    int rSum(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[(i & 3) + (i & 4)]; i++; } return 0; }
    int rVar(unsigned char *d, unsigned char *t, int n) { int i = 0, k = 42; while (n--) { k = i & 7; *d++ = t[k]; i++; } return k; }
    int rDecl(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { int k = i & 7; *d++ = t[k]; i++; } return i; }
    int linIdx(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[i]; i++; } return i; }
    int ifRead(unsigned char *d, unsigned char *t, int n, int c) { int x; while (n--) { x = 7; if (c) x = t[n & 3]; *d++ = x; } return x; }
    int elseRead(unsigned char *d, unsigned char *t, int n, int c) { int x; while (n--) { x = 7; if (c) x = 5; else x = t[n & 3]; *d++ = x; } return x; }
    int bothRead(unsigned char *d, unsigned char *t, int n, int c) { int x; while (n--) { x = 7; if (c) x = t[n & 3]; else x = t[(n + 1) & 3] + 100; *d++ = x; } return x; }
    int bigIdx(unsigned char *d, unsigned char *t, int n, long long w) { while (n--) *d++ = t[(w + n) & 0x7fffffffffffffffLL]; return 0; }
    int bigSum(unsigned char *d, unsigned char *t, int n, long long w) { while (n--) *d++ = t[((w + n) & 0x7fffffffffffffffLL) + (w & 0x7fffffffffffffffLL)]; return 0; }
    int xDiv(unsigned char *d, int n, int x, int y) { int i = 0; while (n--) { d[i + x / y] = i; i++; } return i; }
    int xFits(unsigned char *d, unsigned char *t, int n) { unsigned u = 0; while (n--) { *d++ = t[(int)(u >> 1)]; u += 2; } return 0; }
    int wordAt(unsigned char *d, unsigned char *s, int n) { int r = 0; while (n--) { r = *(int *)s; *d++ = (r >> 24) + 1; } return r; }
    int words(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = (((int *)t)[i & 3] >> 24) + 1; i++; } return 0; }
    int xTmp(unsigned char *d, int n) { int t = -1; while (n--) { if (n & 1) t = n; *d++ = t; } return t; }
    int xTwice(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { int k = i & 7; k = i; *d++ = t[k]; i++; } return i; }
    int xSra(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[i >> 29]; i++; } return 0; }
    int xDown(unsigned char *d, unsigned char *s, int n) { while (n--) *d++ = *s--; return 0; }
    int xRange(unsigned char *d, unsigned char *t, int n) { int x; while (n--) { x = n * 3; *d++ = t[x]; } return 0; }
    int xBreak(unsigned char *d, int n) { while (n--) { if (n == 1) break; *d++ = n; } return n; }
    int xTwo(unsigned char *d, int n) { while (n--) { *d++ = n; *d++ = n + 10; } return 0; }
    int xIf(unsigned char *d, int n) { while (n--) { if (n & 1) *d = n; d++; } return 0; }
    int xWide(short *d, int n) { while (n--) *d++ = n; return 0; }
    int xCompound(unsigned char *d, int n) { while (n--) *d++ += n; return 0; }
    int xNeg(unsigned char *d, int n) { while (n--) *d-- = n; return 0; }
    int xZero(unsigned char *d, int n) { while (n--) { *d = n + 5; d += 0; } return 0; }
    int xVar(unsigned char *d, int n, int s) { while (n--) { *d = n + 5; d += s; } return 0; }
    int xIfStep(unsigned char *d, int n) { int i = 0; while (n--) { *d++ = i; if (n & 1) i++; } return i; }
    int xPrev(unsigned char *d, int n) { int s = 0; while (n--) { s += n; *d++ = s; } return s; }
    int xMul(unsigned char *d, int n) { for (int x = 1; n--; x *= 2) *d++ = x; return 0; }
    int xLong(unsigned char *d, int n) { int v = 3; while (n--) { *d++ = v; v += 4611686018427387904LL; } return v; }
    int xInStep(unsigned char *d, int n) { for (; n--; *d++ = n) {} return 0; }
    int xCall(unsigned char *d, int n) { while (n--) *d++ = id(n); return 0; }
    int xNest(unsigned char *d, int n) { for (int r = 0; r < 2; r++) { unsigned char *p = d + r * 8; int m = n; while (m--) *p++ = r + 1; } return 0; }
  '';
  # The functions of bulkSrc, loaded with M.storeRun and M.storeStride wrapped to also set
  # the word at bulkMark (an address no test uses otherwise): it tells that the bulk form
  # wrote (which it does only for N >= 1).
  bulkMark = 4026531840;
  markedM = M // {
    storeRun =
      m: a: n: vals:
      M.storeWord (M.storeRun m a n vals) bulkMark 1;
    storeStride =
      m: a: stride: n: vals:
      M.storeWord (M.storeStride m a stride n vals) bulkMark 1;
  };
  bulkFns = import (builtins.toFile "cc-bulk.nix" (Cc.compile bulkSrc)) {
    M = markedM;
    inherit B;
    R = import ../cc/runtime.nix;
  };
  # mem with the bytes bs stored from address a on.
  withBytes =
    mem: a: bs:
    foldl' (m: i: M.storeByte m (B.u32 (a + i)) (elemAt bs i)) mem (genList (i: i) (length bs));
  # fn of bulkSrc called with args on mem: [ <return value> <the n bytes from a on, the
  # addresses modulo 2^32> <whether the bulk form wrote> ].
  bulkOn =
    mem: fn: args: a: n:
    let
      r = foldl' (f: x: f x) (bulkFns.${fn} (bulkFns.__data.init mem)) args;
    in
    [
      r.ret
      (genList (i: M.loadByte r.mem (B.u32 (a + i))) n)
      (M.loadWord r.mem bulkMark == 1)
    ];
  bulkCall = bulkOn M.empty;
  # The write buffer and the table of the tests, and memory with 9 in the first 8 bytes of
  # the buffer (filled) and with the table t[j] = 10 * j + 10 for j < 8 (tabled).
  buf = 4096;
  tab = 8192;
  filled = withBytes M.empty buf (genList (_: 9) 8);
  tabled = withBytes M.empty tab (genList (j: 10 * j + 10) 8);
  bulkFilled = bulkOn filled;
  bulkTabled = bulkOn tabled;
  # The bulk store that the generated fn of bulkSrc contains: "run", "stride" or "none".
  bulkWrite =
    fn:
    let
      code = fnCode bulkSrc fn;
    in
    if contains "M.storeRun" code then
      "run"
    else if contains "M.storeStride" code then
      "stride"
    else
      "none";
  bulkCandidates = [
    "doPost"
    "whilePost"
    "forPost"
    "doPre"
    "whilePre"
    "forPre"
    "lt"
    "le"
    "gt"
    "ge"
    "steps"
    "wrapI"
    "temps"
    "afterCond"
    "doAfter"
    "lut"
    "copy"
    "glob"
    "rShift"
    "rOr"
    "rByte"
    "rSum"
    "rVar"
    "rDecl"
    "linIdx"
    "ifRead"
    "elseRead"
    "bothRead"
    "wordAt"
    "words"
  ];
  bulkExcluded = [
    "xRange"
    "xBreak"
    "xTwo"
    "xIf"
    "xWide"
    "xCompound"
    "xNeg"
    "xZero"
    "xVar"
    "xIfStep"
    "xPrev"
    "xMul"
    "xLong"
    "xInStep"
    "xCall"
    "bigIdx"
    "bigSum"
    "xDiv"
    "xFits"
    "xTmp"
    "xTwice"
    "xSra"
    "xDown"
  ];
  # The return values of steps for n = 3 iterations with the step c: a, b, x, y, z, u, q
  # and m.
  stepsRets =
    d: n: c:
    genList (
      w:
      head (
        bulkCall "steps" [
          d
          n
          c
          w
        ] d 0
      )
    ) 8;
  # The table { 10, 11, 12, 13 } of the if tests, and the word 0x04030201 of wordAt.
  quad = withBytes M.empty tab [
    10
    11
    12
    13
  ];
  quadWord = withBytes M.empty tab [
    1
    2
    3
    4
  ];
  # The bytes of rByte: the table with t[255] = 99, and the indices 0, 3, 255 at 12288.
  byteMem = withBytes (withBytes tabled (tab + 255) [ 99 ]) 12288 [
    0
    3
    255
  ];

  # ---- Page reads of bulk loops ----
  # Expected values follow the C semantics: each function writes byte k (k < N) from the
  # table values below, worked out per iteration. fill and copy have no table read.
  pageSrc = ''
    int colmap(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[i & 63]; i++; } return i; }
    int dbl(unsigned char *d, unsigned char *t, unsigned char *c, int n) { int i = 0; while (n--) { *d++ = c[t[i & 63]]; i++; } return 0; }
    int big(unsigned char *d, unsigned char *t, int n) { unsigned u = 0; while (n--) { *d++ = t[u & 0xfff]; u += 37; } return 0; }
    int sgn(unsigned char *d, signed char *t, int n) { int i = 0; while (n--) { *d++ = (t[i & 7] >> 1) + 64; i++; } return 0; }
    int twice(unsigned char *d, unsigned char *t, int n) { int i = 0; while (n--) { *d++ = t[i & 63] + t[(i + 5) & 63]; i++; } return 0; }
    int two(unsigned char *d, unsigned char *t, unsigned char *c, int n) { int i = 0; while (n--) { *d++ = t[i & 63] ^ c[i & 127]; i++; } return 0; }
    int branch(unsigned char *d, unsigned char *t, int n, int c) { int x; while (n--) { x = 7; if (c) x = t[n & 63]; *d++ = x; } return x; }
    int tern(unsigned char *d, unsigned char *t, int n, int c) { int i = 0; while (n--) { *d++ = c ? t[i & 63] : 5; i++; } return 0; }
    int huge(unsigned char *d, unsigned char *t, int n) { unsigned u = 0; while (n--) { *d++ = t[u & 0x7fff]; u += 1000; } return 0; }
    int wide(unsigned char *d, short *t, int n) { int i = 0; while (n--) { *d++ = t[i & 7] + 3; i++; } return 0; }
    int zero(unsigned char *d, unsigned char *t, int n) { while (n--) *d++ = t[n & 63]; return n; }
    int fill(unsigned char *d, int n) { while (n--) *d++ = 42; return 0; }
    int copy(unsigned char *d, unsigned char *s, int n) { while (n--) *d++ = *s++; return 0; }
  '';
  pageCode = fnCode pageSrc;
  # The functions of pageSrc with the marked bulk stores (see bulkFns), and with a
  # M.readPages that fails when it is called.
  pageFnsWith =
    m:
    import (builtins.toFile "cc-page.nix" (Cc.compile pageSrc)) {
      M = m;
      inherit B;
      R = import ../cc/runtime.nix;
    };
  pageFns = pageFnsWith markedM;
  unpagedFns = pageFnsWith (
    markedM
    // {
      readPages =
        _: _: _:
        throw "readPages was called";
    }
  );
  # fn of pageSrc called with args on mem: [ <return value> <the n bytes from a on>
  # <whether the bulk form wrote> ] (see bulkOn).
  pageOnWith =
    fns: mem: fn: args: a: n:
    let
      r = foldl' (f: x: f x) (fns.${fn} mem) args;
    in
    [
      r.ret
      (genList (i: M.loadByte r.mem (B.u32 (a + i))) n)
      (M.loadWord r.mem bulkMark == 1)
    ];
  pageOn = pageOnWith pageFns;
  # Whether fn of pageSrc runs with the failing M.readPages.
  runsUnpaged =
    mem: fn: args:
    let
      r = pageOnWith unpagedFns mem fn args 0 0;
    in
    (tryEval (builtins.deepSeq r r)).success;
  # The write buffer of the page tests, apart from the tables.
  pbuf = 40960;
  # The tables: f (64 bytes) at 0x10f0, crossing the leaf at 0x1100; h (256 bytes) at
  # 0x2080 and g (128 bytes) at 0x2080, crossing the leaf at 0x2100; q (4096 bytes) at
  # 0x3010; p (32768 bytes) at 0x10000; the signed bytes sb (8) at 0x10fc and the shorts
  # sh (8) at 0x10f0.
  tf = 4336;
  tc = 8320;
  tq = 12304;
  tp = 65536;
  tfOf = j: bitAnd (j * 7 + 3) 255;
  thOf = j: bitAnd (j * 5 + 11) 255;
  tgOf = j: bitAnd (j * 13 + 1) 255;
  tqOf = j: bitAnd (j * 31 + j / 64) 255;
  tpOf = j: bitAnd (j * 3 + j / 256) 255;
  fMem = withBytes M.empty tf (genList tfOf 64);
  fhMem = withBytes fMem tc (genList thOf 256);
  fgMem = withBytes fMem tc (genList tgOf 128);
  qMem = M.storeRun M.empty tq 4096 (genList tqOf 4096);
  pMem = M.storeRun M.empty tp 32768 (genList tpOf 32768);
  sbMem = withBytes M.empty 4348 [
    200
    10
    255
    128
    127
    0
    1
    129
  ];
  shMem = foldl' (m: j: M.storeHalf m (tf + 2 * j) (bitAnd (elemAt shorts j) 65535)) M.empty (
    genList (j: j) 8
  );
  shorts = [
    (-2)
    300
    1000
    (-300)
    5
    32767
    (-32768)
    0
  ];
  # The counts of the value tests: around the threshold 32, and a long loop.
  pageCounts = [
    1
    31
    32
    33
    300
  ];
  # [ ret bytes wrote ] for each count n, with args n of fn.
  pageRuns =
    mem: fn: args:
    map (n: pageOn mem fn (args n) pbuf n) pageCounts;
  pageWant =
    ret: byte:
    map (n: [
      (ret n)
      (genList (byte n) n)
      true
    ]) pageCounts;

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

  # File-scope variables
  (t "cc data: addresses in declaration order, aligned for their types"
    (offsetsOf dataSrc [
      "c"
      "i"
      "s"
      "d"
      "p"
      "g"
      "arr"
      "m"
    ])
    [
      0
      4
      8
      10
      12
      16
      20
      36
    ]
  )
  (t "cc data: size and base"
    {
      inherit ((Cc.load dataSrc).__data) base size;
    }
    {
      inherit base;
      size = 76;
    }
  )
  (t "cc data: dataBase moves the variables"
    (
      let
        d = loadData (Cc.loadWith { dataBase = 5242880; }) dataSrc;
      in
      {
        inherit (d.f.__data) base;
        g = d.f.__data.symbols.g;
        read = (d.f.readScalar d.mem).ret;
        addrs = (d.f.initAddrs d.mem).ret;
      }
    )
    {
      base = 5242880;
      g = 5242896;
      read = 5;
      addrs = 325;
    }
  )
  (t "cc data: a variable is read at its address literal" (contains "M.loadWord mem 4194304" (
    Cc.compile "int g; int f(void) { return g; }"
  )) true)
  (t "cc data: init stores only the values that are not 0"
    (contains "init = mem: R.initData mem [\n      [ 4194308 4 5 ]\n    ];" (
      Cc.compile "int a[3] = { 0, 5, 0 };"
    ))
    true
  )
  (t "cc data: no variables leave memory as it is"
    ((Cc.load "int f(void) { return 0; }").__data.init M.empty)
    M.empty
  )
  (t "cc run: scalar global read and write"
    [
      (dret dataSrc "readScalar" [ ])
      (dret dataSrc "writeScalar" [ 7 ])
    ]
    [
      5
      14
    ]
  )
  (t "cc run: array global read and write"
    [
      (map (k: dret dataSrc "readArr" [ k ]) [
        0
        2
        3
      ])
      (dret dataSrc "writeArr" [
        3
        10
      ])
    ]
    [
      [
        1
        3
        0
      ]
      16
    ]
  )
  (t "cc run: two-dimensional array read and write"
    [
      (dret dataSrc "readM" [
        1
        2
      ])
      (dret dataSrc "readM" [
        0
        1
      ])
      (dret dataSrc "writeM" [ 9 ])
    ]
    [
      6
      2
      91
    ]
  )
  (t "cc run: pointer global" (dret dataSrc "viaPtr" [ ]) 42)
  (t "cc run: initializers &a[2], array name and &g" (dret dataSrc "initAddrs" [ ]) 325)
  (t "cc run: uninitialized globals are 0" (dret dataSrc "uninit" [ ]) 1)
  (t "cc run: brace elision and a length from the initializer"
    [
      (dret "int m[2][2] = { 1, 2, 3, 4 }; int f(void) { return m[1][0] * 10 + m[0][1]; }" "f" [ ])
      (dret "int a[] = { 1, 2, 3, 4, 5 }; int f(void) { return sizeof a; }" "f" [ ])
    ]
    [
      32
      20
    ]
  )
  (t "cc run: extern declaration before the definition" (dret
    "extern int a[]; int f(void) { return a[2]; } int a[3] = { 1, 2, 3 };"
    "f"
    [ ]
  ) 3)
  (t "cc run: static at file scope" (dret "static int g = 4; int f(void) { return g; }" "f" [ ]) 4)
  (t "cc run: initializer with constant arithmetic and casts" (dret ''
    int a[3]; int *p = a + 2; unsigned char *b = (unsigned char *)0x00110000 + 1;
    int k = 2147483647 + 1 > 0 ? 1 : (int)(sizeof a) - 1;
    int f(void) { return (p - a) * 1000 + ((unsigned)b - 0x00110000) * 100 + k; }
  '' "f" [ ]) 2111)

  # short and unsigned short
  (t "cc run: short and unsigned short truncate"
    (map (args: dret shortSrc (head args) (elemAt args 1)) [
      [
        "narrowS"
        [ 40000 ]
      ]
      [
        "narrowS"
        [ (-1) ]
      ]
      [
        "narrowU"
        [ (-1) ]
      ]
      [
        "narrowU"
        [ 70000 ]
      ]
    ])
    [
      (-25536)
      (-1)
      65535
      4464
    ]
  )
  (t "cc run: short globals store 2 bytes and sign-extend"
    (
      let
        r = dcall shortSrc "storeS" [ (-1) ];
      in
      {
        s = r.ret;
        u = dret shortSrc "storeU" [ (-2) ];
        word = M.loadWord r.mem base;
      }
    )
    {
      s = -1;
      u = 65534;
      word = 65535;
    }
  )
  (t "cc run: short parameter, cast and read through a pointer"
    [
      (dret shortSrc "callParam" [ 40000 ])
      (dret shortSrc "casts" [ 98304 ])
      ((callWith (wordsAt [ 4294901759 ]) shortSrc "readThrough" [ 4096 ]).ret)
      ((callWith (wordsAt [ 4294901759 ]) shortSrc "readThrough" [ 4098 ]).ret)
    ]
    [
      (-25536)
      0
      (-1) # low half of 0xfffeffff
      (-2) # high half
    ]
  )

  # enum
  (t "cc run: enum constants, explicit and implicit" (dret enumRunSrc "values" [ ]) 572)
  (t "cc run: enum constant as an array length and in initializers"
    [
      (dret enumRunSrc "size" [ ])
      (dret enumRunSrc "initialized" [ ])
    ]
    [
      48
      62
    ]
  )
  (t "cc run: enum type is unsigned without negative enumerators"
    [
      (dret enumRunSrc "unsignedEnum" [ ])
      (dret enumRunSrc "signedEnum" [ ])
    ]
    [
      1
      1
    ]
  )
  (t "cc run: a parameter hides an enum constant" (dret enumRunSrc "shadowed" [ 8 ]) 8)

  # struct
  (t "cc run: member offsets and size with padding" (dret structRunSrc "offsets" [ ]) 492)
  (t "cc data: struct array layout"
    (offsetsOf structRunSrc [
      "pts"
      "bx"
      "n3"
      "n2"
      "n1"
    ])
    [
      0
      36
      64
      72
      80
    ]
  )
  (t "cc run: . on a struct array element" (dret structRunSrc "dot" [ 1 ]) 34)
  (t "cc run: -> reads and writes" (dret structRunSrc "arrow" [ ]) 107)
  (t "cc run: nested struct and array member"
    [
      (dret structRunSrc "nested" [ ])
      (dret structRunSrc "nestedWrite" [ ])
    ]
    [
      40
      51
    ]
  )
  (t "cc run: sizeof of structs and members" (dret structRunSrc "sizes" [ ]) 2833)
  (t "cc run: following self-referential pointers"
    [
      (dret structRunSrc "walk" [ ])
      (dret structRunSrc "relink" [ ])
    ]
    [
      123
      17
    ]
  )

  # & and arrays as pointers
  (t "cc run: &g, &a[i], &s.m, &p->m and *&g"
    [
      (dret addrSrc "addrG" [ ])
      (dret addrSrc "addrElem" [ 2 ])
      (dret addrSrc "addrMember" [ ])
      (dret addrSrc "addrArrow" [ ])
      (dret addrSrc "derefAddr" [ ])
    ]
    [
      6
      30
      2
      5
      6
    ]
  )
  (t "cc run: an array name passed as a pointer"
    [
      (dret addrSrc "arrayArg" [ ])
      (dret addrSrc "arrayParamCall" [ ])
    ]
    [
      100
      30
    ]
  )
  (t "cc run: &a[1] is a + 1 and &*a is a" (dret addrSrc "addrEq" [ ]) 11)
  (t "cc compile: constant addresses fold"
    [
      (contains "ret = 4194328;" (
        Cc.compile "int a[4]; struct { int x; int y; } s; int *f(void) { return &a[2] + 4; }"
      ))
      (contains "ret = 4194324;" (
        Cc.compile "int a[4]; struct { int x; int y; } s; int *f(void) { return &s.y; }"
      ))
    ]
    [
      true
      true
    ]
  )

  # sizeof, ?: and character literals
  (t "cc run: sizeof of types, arrays, structs and expressions"
    (map (k: dret sizeofSrc "sz" [ k ]) (genList (k: k) 6))
    [
      2
      10
      4
      2
      12
      4
    ]
  )
  (t "cc run: sizeof is unsigned" (dret sizeofSrc "isUnsigned" [ ]) 1)
  (t "cc run: ?: picks a branch"
    [
      (ret condSrc "pick" [
        1
        2
        3
      ])
      (ret condSrc "pick" [
        0
        2
        3
      ])
      (map (x: ret condSrc "sign" [ x ]) [
        (-5)
        0
        7
      ])
    ]
    [
      2
      3
      [
        (-1)
        0
        1
      ]
    ]
  )
  (t "cc run: ?: converts to the common type" (ret condSrc "common" [ 0 ]) 4294967295)
  (t "cc run: ?: as a condition"
    (map (x: ret condSrc "inCond" [ x ]) [
      0
      1
      2
    ])
    [
      5
      0
      5
    ]
  )
  (t "cc run: ?: with a null pointer branch" (ret condSrc "ptrs" [
    0
    4096
  ]) 1)
  (t "cc run: character literals"
    [
      (map (k: ret charLitSrc "lit" [ k ]) (genList (k: k) 5))
      (ret charLitSrc "add" [ 1 ])
    ]
    [
      [
        97
        10
        0
        92
        39
      ]
      66
    ]
  )

  # return
  (t "cc run: return inside an if"
    (map (x: jumpRet "retIf" [ x ]) [
      1
      0
    ])
    [
      1
      2
    ]
  )
  (t "cc run: return in both branches of an if/else"
    (map (x: jumpRet "retBoth" [ x ]) [
      1
      0
    ])
    [
      10
      20
    ]
  )
  (t "cc run: return inside a loop"
    (map (n: jumpRet "retLoop" [ n ]) [
      10
      3
    ])
    [
      5
      (-1)
    ]
  )
  (t "cc run: return from the inner of nested loops"
    (map (n: jumpRet "retNested" [ n ]) [
      10
      3
    ])
    [
      206
      0
    ]
  )
  (t "cc run: return inside a do/while" (jumpRet "retDo" [ 4 ]) 40)
  (t "cc run: return in a loop whose condition has side effects"
    (map (n: jumpRet "retEffCond" [ n ]) [
      5
      1
    ])
    [
      102
      (-1)
    ]
  )
  (t "cc run: statements after a return do not run"
    (map
      (
        x:
        let
          r = jumpCall M.empty "retStore" [
            4096
            x
          ];
        in
        [
          r.ret
          (M.loadWord r.mem 4096)
        ]
      )
      [
        1
        0
      ]
    )
    [
      [
        5
        1
      ]
      [
        6
        2
      ]
    ]
  )
  (t "cc run: return; in the middle of a void function"
    (map
      (
        x:
        M.loadWord (jumpCall M.empty "retVoid" [
          4096
          x
        ]) 4096
      )
      [
        1
        0
      ]
    )
    [
      1
      2
    ]
  )
  (t "cc run: return; in a loop of a void function"
    (
      let
        m = jumpCall M.empty "retVoidLoop" [
          4096
          5
        ];
      in
      map (i: M.loadWord m (4096 + 4 * i)) [
        0
        1
        2
      ]
    )
    [
      1
      2
      0
    ]
  )
  (t "cc run: a non-void function that reaches its end returns 0"
    [
      (jumpRet "fallOff" [ 1 ])
      (jumpRet "fallOff" [ 0 ])
      (jumpRet "noReturn" [ 3 ])
    ]
    [
      7
      0
      0
    ]
  )
  (t "cc run: return from a branch joined with the other"
    (map (x: jumpRet "joinRet" [ x ]) [
      5
      20
      (-1)
    ])
    [
      2
      99
      3
    ]
  )

  # break and continue
  (t "cc run: break and continue in while"
    [
      (jumpRet "whileBreak" [ 4 ])
      (jumpRet "whileCont" [ 6 ])
    ]
    [
      4
      12
    ]
  )
  (t "cc run: break in a loop whose condition has side effects" (jumpRet "effCondBreak" [ 5 ]) 2)
  (t "cc run: break and continue in do/while"
    [
      (jumpRet "doBreak" [ 7 ])
      (jumpRet "doCont" [ 10 ])
    ]
    [
      7
      18
    ]
  )
  (t "cc run: continue in do/while evaluates the condition" (jumpRet "doContCond" [ 3 ]) 303)
  (t "cc run: break and continue in for (continue runs the step)"
    [
      (jumpRet "forBreak" [ 9 ])
      (jumpRet "forCont" [ 7 ])
    ]
    [
      9
      12
    ]
  )
  (t "cc run: break leaves only the inner loop" (jumpRet "nestedBreak" [ 5 ]) 10)
  (t "cc run: break skips the for step" (jumpRet "forBreakFirst" [ ]) 0)
  (t "cc run: break skips the do/while condition" (jumpRet "doBreakFirst" [ ]) 0)
  (t "cc run: break and continue from branches joined with the other" (jumpRet "joinLoop" [
    10
  ]) 42323)

  # switch
  (t "cc run: switch matches, falls through and breaks"
    (map (x: swRet "sw" [ x ]) [
      1
      2
      3
      4
      5
      9
    ])
    [
      10
      23
      3
      45
      45
      (-1)
    ]
  )
  (t "cc run: default first, in the middle and with no match"
    [
      (map (x: swRet "defFirst" [ x ]) [
        1
        2
        7
      ])
      (map (x: swRet "defMiddle" [ x ]) [
        1
        2
        3
      ])
      (map (x: swRet "noMatch" [ x ]) [
        1
        5
      ])
    ]
    [
      [
        1
        2
        101
      ]
      [
        1
        2
        50
      ]
      [
        1
        7
      ]
    ]
  )
  (t "cc run: default last"
    (map (x: swRet "sw" [ x ]) [
      0
      (-3)
    ])
    [
      (-1)
      (-1)
    ]
  )
  (t "cc run: return inside a switch"
    (map (x: swRet "swRet" [ x ]) [
      1
      2
      3
    ])
    [
      11
      10
      6
    ]
  )
  (t "cc run: continue in a switch reaches the loop, break does not leave it" (swRet "swLoop" [
    6
  ]) 422)
  (t "cc run: return from a switch in a loop"
    (map (n: swRet "swLoopRet" [ n ]) [
      10
      2
    ])
    [
      15
      (-1)
    ]
  )
  (t "cc run: nested switch"
    (map (ab: swRet "nested" ab) [
      [
        1
        1
      ]
      [
        1
        5
      ]
      [
        2
        1
      ]
      [
        3
        1
      ]
    ])
    [
      111
      119
      2
      0
    ]
  )
  (t "cc run: enum constants and character literals as case labels"
    (map (c: swRet "labels" [ c ]) [
      0
      5
      6
      97
      1
    ])
    [
      1
      2
      3
      4
      0
    ]
  )
  (t "cc run: the controlling expression runs once" (swRet "once" [ ]) 12)
  (t "cc run: a variable declared in a section is seen by the next one"
    (map (x: swRet "decl" [ x ]) [
      1
      2
      3
    ])
    [
      13
      7
      0
    ]
  )
  (t "cc run: a declaration in a switch body hides an outer variable"
    (map (x: swRet "shadow" [ x ]) [
      1
      2
    ])
    [
      2
      1
    ]
  )
  (t "cc run: switch on unsigned char"
    (map (c: swRet "narrow" [ c ]) [
      200
      255
      1
    ])
    [
      1
      2
      0
    ]
  )
  (t "cc run: empty switch" (ret "int f(int x) { switch (x) { } return x; }" "f" [ 3 ]) 3)

  # Generated code of loops without return, break or continue
  (t "cc compile: a loop without return, break or continue carries no done' or ret'"
    (
      let
        code = Cc.compile "int f(int n) { int s = 0; for (int i = 0; i < n; i++) s += i; return s; }";
      in
      map (x: contains x code) [
        "done'"
        "ret'"
        "st'"
      ]
    )
    [
      false
      false
      false
    ]
  )
  (t "cc compile: only the loop that contains the return carries done' and ret'"
    (
      let
        code = Cc.compile ''
          int f(int n) {
            int s = 0;
            for (int i = 0; i < n; i++) s += i;
            while (n) { if (n == 4) break; n--; }
            for (int i = 0; i < n; i++) if (i == 3) return s;
            return 0;
          }
        '';
      in
      [
        (countIn "done' = false;" code)
        (countIn "ret' = 0;" code)
        (countIn "R.loop" code)
      ]
    )
    [
      1
      1
      3
    ]
  )

  # Outside the subset and type errors
  (t "cc compile: case inside an if throws"
    (compileThrows "void f(int x) { switch (x) { case 1: if (x) case 2: ; } }")
    true
  )
  (t "cc compile: case in a loop or an inner block of a switch throws"
    (map compileThrows [
      "void f(int x) { switch (x) { case 1: while (x) { case 2: ; } } }"
      "void f(int x) { switch (x) { case 1: { case 2: ; } } }"
    ])
    [
      true
      true
    ]
  )
  (t "cc compile: case or default outside a switch throws"
    (map compileThrows [
      "void f(int x) { case 1: x = 2; }"
      "void f(int x) { default: x = 2; }"
    ])
    [
      true
      true
    ]
  )
  (t "cc compile: switch whose body is not a block throws"
    (compileThrows "void f(int x) { switch (x) case 1: x = 2; }")
    true
  )
  (t "cc compile: break outside a loop or switch throws"
    (map compileThrows [
      "void f(void) { break; }"
      "void f(int x) { if (x) break; }"
    ])
    [
      true
      true
    ]
  )
  (t "cc compile: continue outside a loop throws"
    (map compileThrows [
      "void f(void) { continue; }"
      "void f(int x) { switch (x) { case 1: continue; } }"
    ])
    [
      true
      true
    ]
  )
  (t "cc compile: duplicate case values and default labels throw"
    (map compileThrows [
      "void f(int x) { switch (x) { case 1: case 1: ; } }"
      "void f(int x) { switch (x) { case 1: case 4294967297LL: ; } }"
      "void f(int x) { switch (x) { default: ; default: ; } }"
    ])
    [
      true
      true
      true
    ]
  )
  (t "cc compile: switch on a pointer throws" (compileThrows "void f(int *p) { switch (p) { } }")
    true
  )
  (t "cc compile: goto throws" (compileThrows "void f(void) { goto x; x: ; }") true)
  (t "cc compile: &x throws" (compileThrows "void f(int x) { int *p = &x; }") true)
  (t "cc compile: block-scope struct throws" (compileThrows "void f(void) { struct s { int a; } x; }")
    true
  )
  (t "cc compile: case throws" (compileThrows "void f(int x) { if (x) case 1: ; }") true)
  (t "cc compile: member access through a non-struct pointer throws"
    (compileThrows "struct s; int f(int *p) { return p->a; }")
    true
  )
  (t "cc compile: local array throws" (compileThrows "void f(void) { int a[3]; }") true)
  (t "cc compile: union throws" (compileThrows "union u { int a; }; int f(void) { return 0; }") true)
  (t "cc compile: struct assignment throws"
    (compileThrows "struct s { int a; }; struct s x, y; void f(void) { x = y; }")
    true
  )
  (t "cc compile: struct passed or returned by value throws"
    (map compileThrows [
      "struct s { int a; }; void f(struct s x) { }"
      "struct s { int a; }; struct s f(void);"
    ])
    [
      true
      true
    ]
  )
  (t "cc compile: long long in a global variable, array or struct throws"
    (map compileThrows [
      "long long g;"
      "long long g[2];"
      "struct s { int a; long long b; };"
    ])
    [
      true
      true
      true
    ]
  )
  (t "cc compile: extern variable without a definition throws"
    (compileThrows "extern int g; int f(void) { return g; }")
    true
  )
  (t "cc compile: side effect in a branch of ?: throws"
    (compileThrows "int f(int x) { return x ? x++ : 0; }")
    true
  )
  (t "cc compile: excess initializer elements throw" (compileThrows "int a[2] = { 1, 2, 3 };") true)
  (t "cc compile: non-constant initializer throws" (compileThrows "int g; int h = g;") true)
  (t "cc compile: two initialized definitions throw" (compileThrows "int g = 1; int g = 2;") true)
  (t "cc compile: member of an incomplete struct throws"
    (compileThrows "struct s; int f(struct s *p) { return p->a; }")
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
  # Review fixes
  (t "cc order: g += h() reads g after h" (orderRet "f1") 11)
  (t "cc order: arr[idx()] = k() calls k before idx"
    [
      (orderRet "f2")
      (orderRet "f2at")
    ]
    [ 0 7 ]
  )
  (t "cc order: arr[idx()] += k() reads the element k selects" (orderRet "f3") 1200)
  (t "cc order: arr[i] = k() indexes with the i k leaves" (orderRet "f4") 0)
  (t "cc order: g = g + h() reads g before h" (orderRet "f5") 2)
  (t "cc order: used results of g += h() and g++ + h()"
    [
      (orderRet "used")
      (orderRet "postUsed")
    ]
    [ 1111 210 ]
  )
  (t "cc order: *p++ = k() stores k() at the old p" (orderRet "postTarget") 107)
  (t "cc order: compound assignment to a local" (orderRet "local") 2)
  (t "cc store: a signed value through a short pointer is cut to 16 bits"
    [
      (halfBytes 4099 (-300))
      (halfBytes 4099 (-2))
      (halfBytes 4098 (-300))
      (halfBytes 4099 65535)
    ]
    [
      [
        212
        254
      ]
      [
        254
        255
      ]
      [
        212
        254
      ]
      [
        255
        255
      ]
    ]
  )
  (t "cc compile: long long constant shifts out of range throw"
    (map compileThrows [
      "long long f(long long x) { return x << 64; }"
      "long long f(long long x) { return x >> 64; }"
      "long long f(long long x) { return x << -1; }"
      "long long f(long long x) { return x >> -1; }"
      "long long f(long long x) { return x << 63; }"
      "long long f(long long x) { x <<= 63; return x; }"
      "long long f(void) { return 1LL << 63; }"
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
  (t "cc run: long long constant shifts in range"
    (
      let
        f = Cc.load "long long l(long long x) { return x << 62; } long long r(long long x) { return x >> 63; } long long m(long long x) { return x << 32; }";
      in
      [
        (f.l M.empty 1).ret
        (f.r M.empty (-5)).ret
        (f.m M.empty 3).ret
      ]
    )
    [
      4611686018427387904
      (-1)
      12884901888
    ]
  )
  (t "cc run: the operand of sizeof is not a side effect in ?:, && and ||"
    (
      let
        src = ''
          int c(int x) { int r = x ? sizeof(x++) : 0; return r * 10 + x; }
          int a(int x, int y) { return x && sizeof(y++); }
          int o(int x, int y) { return x || sizeof(y--); }
        '';
      in
      [
        (ret src "c" [ 3 ])
        (ret src "c" [ 0 ])
        (ret src "a" [
          1
          2
        ])
        (ret src "a" [
          0
          2
        ])
        (ret src "o" [
          0
          2
        ])
      ]
    )
    [
      43
      0
      1
      0
      1
    ]
  )
  (t "cc lex: prefixed character literals throw"
    (map lexThrows [
      "x = L'a';"
      "x = u'a';"
      "x = U'\\n';"
    ])
    [
      true
      true
      true
    ]
  )
  (t "cc lex: L, u and U alone stay identifiers" (texts "L + u * U - 'a' xL") [
    "L"
    "+"
    "u"
    "*"
    "U"
    "-"
    "'a'"
    "xL"
    ""
  ])
  (t "cc compile: data that ends above 2^32 throws, data that ends at 2^32 does not"
    [
      (compileThrows "int a; int b;")
      (!(tryEval (Cc.compileWith { dataBase = 4294967288; } "int a; int b;")).success)
      (!(tryEval (Cc.compileWith { dataBase = 4294967288; } "int a; int b; int c;")).success)
      (!(tryEval (Cc.compileWith { dataBase = 4294967292; } "char a[5];")).success)
    ]
    [
      false
      false
      true
      true
    ]
  )
  (t "cc emit: a switch passes on only the return and continue that leave it"
    (map
      (fn: [
        (contains "st' == 1" (switchKindsCode fn))
        (contains "st' == 3" (switchKindsCode fn))
      ])
      [
        "onlyBreak"
        "withReturn"
        "withContinue"
      ]
    )
    [
      [
        false
        false
      ]
      [
        true
        false
      ]
      [
        false
        true
      ]
    ]
  )
  (t "cc run: switches that break, return and continue"
    [
      (ret switchKindsSrc "onlyBreak" [ 1 ])
      (ret switchKindsSrc "onlyBreak" [ 3 ])
      (ret switchKindsSrc "withReturn" [ 1 ])
      (ret switchKindsSrc "withReturn" [ 2 ])
      (ret switchKindsSrc "withContinue" [ 4 ])
    ]
    [
      1
      2
      5
      0
      5
    ]
  )
  (t "cc parse: pointer to array declarators throw"
    (map throws [
      "int (*p)[4];"
      "int (**q)[2][3];"
      "int f(void) { return sizeof(int (*)[4]); }"
    ])
    [
      true
      true
      true
    ]
  )
  # Unconditional loop driver
  (t "cc run: loops driven by R.loopDo"
    [
      (ret loopDoSrc "doW" [ 4 ])
      (ret loopDoSrc "forEver" [ 5 ])
      (ret loopDoSrc "whileOne" [ 10 ])
      (ret loopDoSrc "preDec" [ 4 ])
      (ret loopDoSrc "whileLess" [ 5 ])
    ]
    [
      10
      5
      12
      6
      10
    ]
  )
  (t "cc emit: do/while, for (;;), while (1) and a condition with side effects use R.loopDo"
    (map
      (fn: [
        (contains "R.loop " (fnCode loopDoSrc fn))
        (contains "R.loopDo" (fnCode loopDoSrc fn))
      ])
      [
        "doW"
        "forEver"
        "whileOne"
        "preDec"
        "whileLess"
      ]
    )
    [
      [
        false
        true
      ]
      [
        false
        true
      ]
      [
        false
        true
      ]
      [
        false
        true
      ]
      [
        true
        false
      ]
    ]
  )
  # Cached reads of constant addresses
  (drawCacheCase "R_DrawColumn" "dc_source")
  (drawCacheCase "R_DrawColumn" "dc_colormap")
  (drawCacheCase "R_DrawSpan" "ds_source")
  (drawCacheCase "R_DrawSpan" "ds_colormap")
  (t "cc cache: the loops of the overlap tests cache their reads"
    [
      (cachesIn "byteAt" "g" "int")
      (cachesIn "straddleWord" "a2" "int")
      (cachesIn "straddleWord" "b2" "int")
      (cachesIn "signedReload" "hs" "short")
      (cachesIn "signedReload" "hc" "schar")
      (cachesIn "compound" "g" "int")
      (cachesIn "joinSwitch" "g" "int")
      (cachesIn "limitCond" "limit" "int")
    ]
    [
      true
      true
      true
      true
      true
      true
      true
      true
    ]
  )
  (t "cc cache: a byte store through a pointer is seen in the same and the next iteration"
    (map
      (k: [
        (cacheRet "byteAt" [
          k
          2
          0
        ])
        (cacheRet "byteAt" [
          k
          2
          1
        ])
      ])
      [
        0
        1
        2
        3
      ]
    )
    [
      [
        1
        3
      ]
      [
        256
        768
      ]
      [
        65536
        196608
      ]
      [
        16777216
        50331648
      ]
    ]
  )
  (t "cc cache: unaligned word and half stores over two adjacent globals"
    [
      (cacheRet "straddleWord" [ 0 ])
      (cacheRet "straddleWord" [ 1 ])
      (cacheRet "straddleHalf" [ 0 ])
      (cacheRet "straddleHalf" [ 1 ])
    ]
    [
      50593792
      258
      100663296
      5
    ]
  )
  (t "cc cache: stores that wrap around 2^32 onto a global at address 0"
    [
      (wrapRet0 "wrapHalf" [
        4294967295
        1
      ])
      (wrapRet0 "wrapWord" [
        4294967293
        1
      ])
      (wrapRet0 "wrapHalf" [
        4294967294
        1
      ])
      (wrapRet0 "wrapWord" [
        4294967292
        1
      ])
    ]
    [
      1
      4
      0
      0
    ]
  )
  (t "cc cache: re-read short and signed char globals are sign-extended" (cacheRet "signedReload" [
    2
  ]) (-32768001))
  (t "cc cache: stores next to a global leave its cached value" (cacheRet "noOverlap" [ 3 ]) 2102)
  (t "cc cache: stores by op=, ++, in conditions, in the for step, ?: and &&"
    [
      (cacheRet "compound" [ 3 ])
      (cacheRet "postInc" [ 3 ])
      (cacheRet "inCond" [ 3 ])
      (cacheRet "inStep" [ 3 ])
      (cacheRet "inDoCond" [ 3 ])
      (cacheRet "inTernary" [ 3 ])
      (cacheRet "inAnd" [ 4 ])
    ]
    [
      6
      6
      303
      303
      303
      130
      5
    ]
  )
  (t "cc cache: re-read values survive if, switch, continue, break and return"
    [
      (cacheRet "joinIf" [ 3 ])
      (cacheRet "joinIfBreak" [ 3 ])
      (cacheRet "joinSwitch" [ 2 ])
      (cacheRet "contAfter" [ 3 ])
      (cacheRet "breakAfter" [ 5 ])
      (cacheRet "retAfter" [ 3 ])
    ]
    [
      10
      10
      4
      1020
      4203
      9
    ]
  )
  (t "cc cache: a read that a store at a constant address overlaps is not cached"
    [
      (cacheRet "constStore" [ 4 ])
      (cacheRet "constElem" [ 3 ])
      (cachesIn "constStore" "g" "int")
      (contains "g'${toString (cacheSyms.arr + 4)}'int" (fnCode cacheSrc "constElem"))
      (contains "g'${toString cacheSyms.arr}'int" (fnCode cacheSrc "constElem"))
    ]
    [
      6
      306
      false
      false
      true
    ]
  )
  (t "cc cache: a loop with a call and the outer loop of a nest do not cache"
    [
      (cacheRet "withCall" [ 4 ])
      (cacheRet "outer" [ 3 ])
      (cachesIn "withCall" "g" "int")
      (cachesIn "outer" "g" "int")
    ]
    [
      6
      6
      false
      false
    ]
  )
  (t "cc cache: a loop whose condition reads a global it stores through a pointer stops" (cacheRet
    "limitCond"
    [ 10 ]
  ) 4)
  (t "cc cache: overlap tests merge touching ranges; a byte store tests only its address"
    (map rangeHits [
      "adjWord"
      "adjByte"
      "adjHalf"
      "farWord"
      "mixedByte"
    ])
    [
      [ "bitAnd (p_0 - 4194304) 4294967295 < 8 || bitAnd (4194304 - p_0) 4294967295 < 4" ]
      [ "bitAnd (p_0 - 4194304) 4294967295 < 8" ]
      [ "bitAnd (p_0 - 4194304) 4294967295 < 8 || bitAnd (4194304 - p_0) 4294967295 < 2" ]
      [
        "bitAnd (p_0 - 4194304) 4294967295 < 4 || bitAnd (4194304 - p_0) 4294967295 < 4 || bitAnd (p_0 - 4194328) 4294967295 < 4 || bitAnd (4194328 - p_0) 4294967295 < 4"
      ]
      [ "bitAnd (p_0 - 4194328) 4294967295 < 7" ]
    ]
  )
  (t "cc cache: stores inside, at the edges of and outside the merged ranges"
    [
      (rangeRet "adjWord" [
        (base + 4)
        3
      ])
      (rangeRet "adjWord" [
        (base + 8)
        3
      ])
      (rangeRet "adjByte" [
        (base + 7)
        3
      ])
      (rangeRet "adjByte" [
        (base - 1)
        3
      ])
      (rangeRet "adjHalf" [
        (base - 1)
        3
      ])
      (rangeRet "adjHalf" [
        (base + 7)
        3
      ])
      (rangeRet "adjHalf" [
        (base - 2)
        3
      ])
      (rangeRet "farWord" [
        (base + 24)
        3
      ])
      (rangeRet "farWord" [
        (base + 12)
        3
      ])
      (rangeRet "farWord" [
        base
        3
      ])
      (rangeRet "mixedByte" [
        (base + 30)
        3
      ])
      (rangeRet "mixedByte" [
        (base + 29)
        3
      ])
      (rangeRet "mixedByte" [
        (base + 31)
        3
      ])
    ]
    [
      3
      0
      50331648
      0
      3
      50331648
      0
      3
      0
      3
      3
      768
      0
    ]
  )
  (t "cc cache: two checked stores without a later read add the re-read under either hit"
    [
      (cacheRet "twoStores" [ 2 ])
      (countIn "// \\(if hit_[0-9]+ \\|\\| hit_[0-9]+ then \\{" (fnCode cacheSrc "twoStores"))
      (countIn "g_[0-9]+ = if" (fnCode cacheSrc "twoStores"))
    ]
    [
      506
      1
      0
    ]
  )
  (t "cc cache: a pending overlap test survives joins of if, continue and switch"
    [
      (cacheRet "pendIf" [ 3 ])
      (cacheRet "pendJoin" [ 3 ])
      (cacheRet "pendSwitch" [ 3 ])
    ]
    [
      61
      61
      43
    ]
  )
  (t "cc cache: a read in a branch of ?: after a store sees the stored value" (cacheRet "ternaryAfter"
    [ 3 ]
  ) 105)

  # Bulk loops: where the bulk form is emitted
  (t "cc bulk: the column loop of draw writes with storeStride, the span loop with storeRun"
    [
      (contains "M.storeStride" (fnCode Cc.examples.draw.src "R_DrawColumn"))
      (contains "M.storeRun" (fnCode Cc.examples.draw.src "R_DrawSpan"))
    ]
    [ true true ]
  )
  (t "cc bulk: loops within the conditions get a bulk store" (map bulkWrite (
    bulkCandidates ++ [ "stride4" ]
  )) (map (_: "run") bulkCandidates ++ [ "stride" ]))
  (t "cc bulk: loops outside the conditions get none" (map bulkWrite bulkExcluded) (
    map (_: "none") bulkExcluded
  ))
  (t "cc bulk: only the inner loop of a nest is a bulk loop"
    [
      (countIn "M\\.storeRun" (fnCode bulkSrc "xNest"))
      (bulkCall "xNest" [ buf 3 ] buf 11)
    ]
    [
      1
      [
        0
        [
          1
          1
          1
          0
          0
          0
          0
          0
          2
          2
          2
        ]
        true
      ]
    ]
  )

  # Bulk loops: the count forms (values written from the counter, n * 1000 + bytes written)
  (t "cc bulk: do ... while (n--) runs n0 + 1 times and leaves n = -1"
    [
      (bulkFilled "doPost" [ buf 0 ] buf 2)
      (bulkFilled "doPost" [ buf 3 ] buf 5)
      (bulkCall "doPost" [ 4294967294 2 ] 4294967294 3)
    ]
    [
      [
        (-999)
        [
          0
          9
        ]
        true
      ]
      [
        (-996)
        [
          3
          2
          1
          0
          9
        ]
        true
      ]
      [
        (-997)
        [
          2
          1
          0
        ]
        false
      ]
    ]
  )
  (t "cc bulk: while (n--) runs n0 times and leaves n = -1"
    [
      (bulkFilled "whilePost" [ buf 0 ] buf 2)
      (bulkFilled "whilePost" [ buf 1 ] buf 2)
      (bulkFilled "whilePost" [ buf 3 ] buf 4)
    ]
    [
      [
        (-1000)
        [
          9
          9
        ]
        false
      ]
      [
        (-999)
        [
          0
          9
        ]
        true
      ]
      [
        (-997)
        [
          2
          1
          0
          9
        ]
        true
      ]
    ]
  )
  (t "cc bulk: for (; n--; p++) runs n0 times and leaves n = -1"
    [
      (bulkFilled "forPost" [ buf 0 ] buf 1)
      (bulkFilled "forPost" [ buf 3 ] buf 4)
    ]
    [
      [
        (-1000)
        [ 9 ]
        false
      ]
      [
        (-997)
        [
          3
          2
          1
          9
        ]
        true
      ]
    ]
  )
  (t "cc bulk: do ... while (--n) runs n0 times and leaves n = 0"
    [
      (bulkFilled "doPre" [ buf 1 ] buf 2)
      (bulkFilled "doPre" [ buf 3 ] buf 4)
      (bulkCall "doPre" [ 4294967295 2 ] 4294967295 2)
    ]
    [
      [
        1
        [
          1
          9
        ]
        true
      ]
      [
        3
        [
          3
          2
          1
          9
        ]
        true
      ]
      [
        2
        [
          2
          1
        ]
        false
      ]
    ]
  )
  (t "cc bulk: while (--n) and for (; --n; ) run n0 - 1 times and leave n = 0"
    [
      (bulkFilled "whilePre" [ buf 1 ] buf 1)
      (bulkFilled "whilePre" [ buf 2 ] buf 2)
      (bulkFilled "whilePre" [ buf 4 ] buf 4)
      (bulkFilled "forPre" [ buf 4 ] buf 4)
      (bulkCall "forPre" [ 4294967295 3 ] 4294967295 2)
    ]
    [
      [
        0
        [ 9 ]
        false
      ]
      [
        1
        [
          1
          9
        ]
        true
      ]
      [
        3
        [
          3
          2
          1
          9
        ]
        true
      ]
      [
        3
        [
          3
          2
          1
          9
        ]
        true
      ]
      [
        2
        [
          2
          1
        ]
        false
      ]
    ]
  )
  (t "cc bulk: i < e runs max(0, e - i0) times and leaves i = i0 + N"
    [
      (bulkFilled "lt" [ buf 0 3 ] buf 4)
      (bulkFilled "lt" [ buf 5 5 ] buf 1)
      (bulkFilled "lt" [ buf 7 2 ] buf 1)
      (bulkFilled "lt" [ buf 4 5 ] buf 2)
      (bulkFilled "lt" [
        buf
        (-2)
        1
      ] buf 4)
      (bulkCall "lt" [ 4294967295 0 2 ] 4294967295 2)
    ]
    [
      [
        3
        [
          0
          1
          2
          9
        ]
        true
      ]
      [
        5
        [ 9 ]
        false
      ]
      [
        7
        [ 9 ]
        false
      ]
      [
        5
        [
          4
          9
        ]
        true
      ]
      [
        1
        [
          254
          255
          0
          9
        ]
        true
      ]
      [
        2
        [
          0
          1
        ]
        false
      ]
    ]
  )
  (t "cc bulk: i <= e runs max(0, e - i0 + 1) times"
    [
      (bulkFilled "le" [ buf 1 3 ] buf 4)
      (bulkFilled "le" [ buf 3 2 ] buf 1)
      (bulkFilled "le" [
        buf
        (-1)
        (-1)
      ] buf 2)
      (bulkCall "le" [ 4294967295 1 2 ] 4294967295 2)
    ]
    [
      [
        4
        [
          1
          2
          3
          9
        ]
        true
      ]
      [
        3
        [ 9 ]
        false
      ]
      [
        0
        [
          255
          9
        ]
        true
      ]
      [
        3
        [
          1
          2
        ]
        false
      ]
    ]
  )
  (t "cc bulk: e < i (i > e) and i >= e count down"
    [
      (bulkFilled "gt" [ buf 3 0 ] buf 4)
      (bulkFilled "gt" [ buf 0 0 ] buf 1)
      (bulkFilled "ge" [ buf 2 0 ] buf 4)
      (bulkFilled "ge" [
        buf
        (-5)
        (-4)
      ] buf 1)
      (bulkCall "ge" [ 4294967295 1 0 ] 4294967295 2)
    ]
    [
      [
        0
        [
          3
          2
          1
          9
        ]
        true
      ]
      [
        0
        [ 9 ]
        false
      ]
      [
        (-1)
        [
          2
          1
          0
          9
        ]
        true
      ]
      [
        (-5)
        [ 9 ]
        false
      ]
      [
        (-1)
        [
          1
          0
        ]
        false
      ]
    ]
  )

  # Bulk loops: induction variables and temporaries
  (t
    "cc bulk: ++, --, += and -= (constant and variable), v = v + c, v = v - c, pointer and unsigned steps"
    [
      (bulkFilled "steps" [ buf 3 5 0 ] buf 4)
      (stepsRets buf 3 5)
      (stepsRets buf 0 5)
    ]
    [
      [
        8
        [
          103
          102
          101
          9
        ]
        true
      ]
      [
        8
        91
        22
        (-6)
        7
        1
        40
        47
      ]
      [
        5
        100
        7
        9
        1
        (-2)
        16
        50
      ]
    ]
  )
  (t
    "cc bulk: an int induction variable that wraps around keeps its value per iteration and after the loop"
    [
      (stepsRets buf 3 2147483647)
      (stepsRets 4294967295 3 2147483647)
      (bulkCall "steps" [ 4294967295 3 2147483647 0 ] 4294967295 3)
      (bulkFilled "wrapI" [ buf 4 ] buf 5)
      (bulkCall "wrapI" [ 4294967294 4 ] 4294967294 4)
    ]
    [
      [
        8
        91
        (-2147483644)
        (-2147483636)
        7
        1
        40
        47
      ]
      [
        8
        91
        (-2147483644)
        (-2147483636)
        7
        1
        40
        47
      ]
      [
        8
        [
          103
          102
          101
        ]
        false
      ]
      [
        3
        [
          0
          128
          0
          128
          9
        ]
        true
      ]
      [
        3
        [
          0
          128
          0
          128
        ]
        false
      ]
    ]
  )
  (t "cc bulk: an int pointer step writes with a stride of 4"
    [
      (bulkCall "stride4" [ buf 3 ] buf 9)
      (bulkCall "stride4" [ 4294967288 3 ] 4294967288 9)
    ]
    [
      [
        4108
        [
          1
          0
          0
          0
          2
          0
          0
          0
          3
        ]
        true
      ]
      [
        4
        [
          1
          0
          0
          0
          2
          0
          0
          0
          3
        ]
        false
      ]
    ]
  )
  (t "cc bulk: a temporary keeps its last value, or its value on entry when N = 0"
    [
      (bulkFilled "temps" [ buf 3 ] buf 4)
      (bulkFilled "temps" [ buf 0 ] buf 1)
    ]
    [
      [
        36
        [
          30
          33
          36
          9
        ]
        true
      ]
      [
        77
        [ 9 ]
        false
      ]
    ]
  )
  (t "cc bulk: an iteration sees n after the condition's n--"
    [
      (bulkFilled "afterCond" [ buf 3 ] buf 4)
      (bulkFilled "afterCond" [ buf 0 ] buf 1)
      (bulkFilled "doAfter" [ buf 2 ] buf 4)
      (bulkFilled "doAfter" [ buf 0 ] buf 2)
    ]
    [
      [
        (-1)
        [
          12
          11
          10
          9
        ]
        true
      ]
      [
        (-101)
        [ 9 ]
        false
      ]
      [
        (-1)
        [
          2
          1
          0
          9
        ]
        true
      ]
      [
        (-1)
        [
          0
          9
        ]
        true
      ]
    ]
  )

  # Bulk loops: overlaps of the write range with the read ranges
  (t
    "cc bulk: a write range on the last byte of a table runs the loop, one byte past it the bulk form"
    [
      (bulkTabled "lut" [
        (tab + 7)
        tab
        9
      ] (tab + 7) 9)
      (bulkTabled "lut" [
        (tab + 8)
        tab
        9
      ] (tab + 8) 9)
    ]
    [
      [
        9
        [
          11
          21
          31
          41
          51
          61
          71
          12
          11
        ]
        false
      ]
      [
        9
        [
          11
          21
          31
          41
          51
          61
          71
          81
          11
        ]
        true
      ]
    ]
  )
  (t
    "cc bulk: a write range on the first byte of a table runs the loop, one byte before it the bulk form"
    [
      (bulkTabled "lut" [
        (tab - 8)
        tab
        9
      ] (tab - 8) 9)
      (bulkTabled "lut" [
        (tab - 9)
        tab
        9
      ] (tab - 9) 9)
    ]
    [
      [
        9
        [
          11
          21
          31
          41
          51
          61
          71
          81
          11
        ]
        false
      ]
      [
        9
        [
          11
          21
          31
          41
          51
          61
          71
          81
          11
        ]
        true
      ]
    ]
  )
  (t "cc bulk: an overlapping forward copy runs the loop and copies like C"
    [
      (bulkOn
        (withBytes M.empty tab [
          1
          2
          3
          4
          5
        ])
        "copy"
        [
          (tab + 1)
          tab
          4
        ]
        tab
        5
      )
      (bulkOn
        (withBytes M.empty tab [
          1
          2
          3
          4
          5
        ])
        "copy"
        [
          (tab + 3)
          tab
          4
        ]
        tab
        7
      )
      (bulkOn
        (withBytes M.empty tab [
          1
          2
          3
          4
          5
        ])
        "copy"
        [
          (tab + 4)
          tab
          4
        ]
        tab
        8
      )
      (bulkOn
        (withBytes M.empty tab [
          1
          2
          3
          4
          5
        ])
        "copy"
        [
          (tab + 5)
          tab
          4
        ]
        tab
        9
      )
    ]
    [
      [
        0
        [
          1
          1
          1
          1
          1
        ]
        false
      ]
      [
        0
        [
          1
          2
          3
          1
          2
          3
          1
        ]
        false
      ]
      [
        0
        [
          1
          2
          3
          4
          1
          2
          3
          4
        ]
        true
      ]
      [
        0
        [
          1
          2
          3
          4
          5
          1
          2
          3
          4
        ]
        true
      ]
    ]
  )
  (t "cc bulk: a write range over a cached global runs the loop, which re-reads it"
    [
      (bulkCall "glob" [ base 3 ] base 4)
      (bulkCall "glob" [
        (base - 2)
        3
      ] (base - 2) 3)
      (bulkCall "glob" [
        (base - 3)
        3
      ] (base - 3) 3)
      (bulkCall "glob" [
        (base + 4)
        3
      ] (base + 4) 3)
      (bulkCall "glob" [ buf 3 ] buf 3)
    ]
    [
      [
        1315601
        [
          17
          19
          20
          0
        ]
        false
      ]
      [
        19
        [
          17
          18
          19
        ]
        false
      ]
      [
        16
        [
          17
          18
          19
        ]
        true
      ]
      [
        16
        [
          17
          18
          19
        ]
        true
      ]
      [
        16
        [
          17
          18
          19
        ]
        true
      ]
    ]
  )

  # Bulk loops: ranges that reach 2^32
  (t "cc bulk: a write range whose last byte is at 2^32 runs the loop, one below it the bulk form"
    [
      (bulkCall "whilePost" [ 4294967294 3 ] 4294967294 3)
      (bulkCall "whilePost" [ 4294967293 3 ] 4294967293 3)
    ]
    [
      [
        (-997)
        [
          2
          1
          0
        ]
        false
      ]
      [
        (-997)
        [
          2
          1
          0
        ]
        true
      ]
    ]
  )
  (t "cc bulk: a read range that reaches 2^32 runs the loop, which wraps the addresses"
    [
      (bulkOn (withBytes M.empty 4294967294 [
        7
        8
        9
      ]) "copy" [ buf 4294967294 3 ] buf 3)
      (bulkOn (withBytes M.empty 4294967293 [
        6
        7
        8
      ]) "copy" [ buf 4294967293 3 ] buf 3)
      (bulkOn (withBytes M.empty 4294967292 [
        1
        2
        3
        4
        5
        6
        7
        8
      ]) "lut" [ buf 4294967292 8 ] buf 8)
      (bulkOn (withBytes M.empty 4294967288 [
        1
        2
        3
        4
        5
        6
        7
        8
      ]) "lut" [ buf 4294967288 8 ] buf 8)
    ]
    [
      [
        0
        [
          7
          8
          9
        ]
        false
      ]
      [
        0
        [
          6
          7
          8
        ]
        true
      ]
      [
        8
        [
          2
          3
          4
          5
          6
          7
          8
          9
        ]
        false
      ]
      [
        8
        [
          2
          3
          4
          5
          6
          7
          8
          9
        ]
        true
      ]
    ]
  )

  # Bulk loops: index ranges (a write range on the last byte of the table tells that the
  # range reaches it)
  (t "cc bulk: the range of unsigned >> c"
    [
      (bulkTabled "rShift" [ buf tab 9 ] buf 9)
      (bulkTabled "rShift" [
        (tab + 7)
        tab
        9
      ] (tab + 7) 9)
    ]
    [
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          80
          10
        ]
        true
      ]
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          10
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: the range of | is the smallest 2^k - 1 above both operands"
    [
      (bulkTabled "rOr" [ buf tab 9 ] buf 9)
      (bulkTabled "rOr" [
        (tab + 7)
        tab
        9
      ] (tab + 7) 9)
    ]
    [
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          80
          10
        ]
        true
      ]
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          10
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: the range of + is the sum of the operands' ranges"
    [
      (bulkTabled "rSum" [ buf tab 9 ] buf 9)
      (bulkTabled "rSum" [
        (tab + 7)
        tab
        9
      ] (tab + 7) 9)
    ]
    [
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          80
          10
        ]
        true
      ]
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          10
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: the range of an unsigned char read is 255"
    [
      (bulkOn byteMem "rByte" [ buf tab 12288 3 ] buf 3)
      (bulkOn byteMem "rByte" [
        (tab + 255)
        tab
        12288
        3
      ] (tab + 255) 3)
    ]
    [
      [
        0
        [
          10
          40
          99
        ]
        true
      ]
      [
        0
        [
          10
          40
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: a variable assigned once before the read has the range of its value"
    [
      (bulkTabled "rVar" [ buf tab 10 ] buf 10)
      (bulkTabled "rVar" [
        (tab + 7)
        tab
        9
      ] (tab + 7) 9)
      (bulkTabled "rVar" [ buf tab 0 ] buf 1)
      (bulkTabled "rDecl" [ buf tab 10 ] buf 10)
      (bulkTabled "rDecl" [
        (tab + 7)
        tab
        9
      ] (tab + 7) 9)
    ]
    [
      [
        1
        [
          10
          20
          30
          40
          50
          60
          70
          80
          10
          20
        ]
        true
      ]
      [
        0
        [
          10
          20
          30
          40
          50
          60
          70
          10
          10
        ]
        false
      ]
      [
        42
        [ 0 ]
        false
      ]
      [
        10
        [
          10
          20
          30
          40
          50
          60
          70
          80
          10
          20
        ]
        true
      ]
      [
        9
        [
          10
          20
          30
          40
          50
          60
          70
          10
          10
        ]
        false
      ]
    ]
  )

  # Bulk loops: addresses of the bulk form's loads
  (t "cc bulk: the draw loads at a table plus a bounded index add without wrapping in the bulk form"
    (map
      (
        fn:
        let
          code = fnCode Cc.examples.draw.src fn;
        in
        [
          (countIn "M\\.loadByte mem \\(B\\.add" code)
          (countIn "M\\.loadByte mem \\(g_[0-9]+ \\+ " code)
        ]
      )
      [
        "R_DrawColumn"
        "R_DrawSpan"
      ]
    )
    [
      [
        0
        2
      ]
      [
        0
        2
      ]
    ]
  )
  (t "cc bulk: a load at a table plus an induction variable keeps the wrapping add"
    [
      (contains "M.loadByte mem (B.add t_0 " (fnCode bulkSrc "linIdx"))
      (contains "M.loadByte mem (t_0 + M.loadByte mem s_" (fnCode bulkSrc "rByte"))
      (bulkTabled "linIdx" [ buf tab 3 ] buf 3)
      (bulkTabled "linIdx" [
        (tab + 2)
        tab
        3
      ] (tab + 2) 3)
    ]
    [
      true
      true
      [
        3
        [
          10
          20
          30
        ]
        true
      ]
      [
        3
        [
          10
          20
          10
        ]
        false
      ]
    ]
  )

  # Bulk loops: review fixes
  (t "cc bulk: a load in a branch of if is recorded in order and checked on entry"
    [
      (bulkOn quad "ifRead" [ buf tab 5 1 ] buf 5)
      (bulkOn quad "ifRead" [ buf tab 5 0 ] buf 5)
      (bulkOn quad "elseRead" [ buf tab 5 0 ] buf 5)
      (bulkOn quad "elseRead" [ buf tab 5 1 ] buf 5)
      (bulkOn quad "bothRead" [ buf tab 5 1 ] buf 5)
      (bulkOn quad "bothRead" [ buf tab 5 0 ] buf 5)
      (bulkOn quad "ifRead" [
        (tab + 3)
        tab
        5
        1
      ] (tab + 3) 5)
    ]
    [
      [
        10
        [
          10
          13
          12
          11
          10
        ]
        true
      ]
      [
        7
        [
          7
          7
          7
          7
          7
        ]
        true
      ]
      [
        10
        [
          10
          13
          12
          11
          10
        ]
        true
      ]
      [
        5
        [
          5
          5
          5
          5
          5
        ]
        true
      ]
      [
        10
        [
          10
          13
          12
          11
          10
        ]
        true
      ]
      [
        111
        [
          111
          110
          113
          112
          111
        ]
        true
      ]
      [
        10
        [
          10
          10
          12
          11
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: an index bound of 2^32 or more is no range, and the loop compiles"
    [
      (bulkTabled "bigIdx" [ buf tab 3 0 ] buf 3)
      (bulkTabled "bigSum" [ buf tab 3 0 ] buf 3)
    ]
    [
      [
        0
        [
          30
          20
          10
        ]
        false
      ]
      [
        0
        [
          30
          20
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: the entry test holds the requirements of the count forms and the count limit"
    [
      (contains "n_0 >= 0 && " (fnCode bulkSrc "doPost"))
      (contains "n_0 >= 0 && " (fnCode bulkSrc "whilePost"))
      (contains "n_0 >= 1 && " (fnCode bulkSrc "doPre"))
      (contains "n_0 >= 1 && " (fnCode bulkSrc "whilePre"))
      (contains "e_0 < 2147483647 && " (fnCode bulkSrc "le"))
      (contains "e_0 > -2147483648 && " (fnCode bulkSrc "ge"))
      (map (fn: countIn " <= 16777216 && " (fnCode bulkSrc fn)) bulkCandidates)
    ]
    [
      true
      true
      true
      true
      true
      true
      (map (_: 1) bulkCandidates)
    ]
  )
  (t
    "cc bulk: a division by a variable in the store address keeps the loop, which does not divide when N = 0"
    [
      (bulkCall "xDiv" [ buf 0 1 0 ] buf 1)
      (bulkCall "xDiv" [ buf 3 4 2 ] buf 5)
    ]
    [
      [
        0
        [ 0 ]
        false
      ]
      [
        3
        [
          0
          0
          0
          1
          2
        ]
        false
      ]
    ]
  )
  (t "cc bulk: a narrowing cast of a bounded value has no range"
    (bulkTabled "xFits" [ buf tab 3 ] buf 3)
    [
      0
      [
        10
        20
        30
      ]
      false
    ]
  )
  (t "cc bulk: a read range ends at the last byte of a wider read"
    [
      (bulkOn quadWord "wordAt" [
        (tab + 3)
        tab
        2
      ] (tab + 3) 2)
      (bulkOn quadWord "wordAt" [
        (tab + 4)
        tab
        2
      ] (tab + 4) 2)
      (bulkTabled "words" [
        (tab + 15)
        tab
        4
      ] (tab + 15) 4)
      (bulkTabled "words" [
        (tab + 16)
        tab
        4
      ] (tab + 16) 4)
    ]
    [
      [
        84083201
        [
          5
          6
        ]
        false
      ]
      [
        67305985
        [
          5
          5
        ]
        true
      ]
      [
        0
        [
          41
          81
          1
          42
        ]
        false
      ]
      [
        0
        [
          41
          81
          1
          1
        ]
        true
      ]
    ]
  )
  (t
    "cc bulk: an assignment in if, a second assignment, a signed >> and a decreasing read keep the loop"
    [
      (bulkFilled "xTmp" [ buf 3 ] buf 4)
      (bulkTabled "xTwice" [ buf tab 3 ] buf 3)
      (bulkTabled "xSra" [ buf tab 3 ] buf 3)
      (bulkTabled "xDown" [
        buf
        (tab + 2)
        3
      ] buf 3)
    ]
    [
      [
        1
        [
          255
          1
          1
          9
        ]
        false
      ]
      [
        3
        [
          10
          20
          30
        ]
        false
      ]
      [
        0
        [
          10
          10
          10
        ]
        false
      ]
      [
        0
        [
          30
          20
          10
        ]
        false
      ]
    ]
  )
  (t "cc bulk: for (; n--; p++), e < i and i >= e with N = 1"
    [
      (bulkFilled "forPost" [ buf 1 ] buf 2)
      (bulkFilled "gt" [ buf 1 0 ] buf 2)
      (bulkFilled "ge" [ buf 0 0 ] buf 2)
    ]
    [
      [
        (-999)
        [
          1
          9
        ]
        true
      ]
      [
        0
        [
          1
          9
        ]
        true
      ]
      [
        (-1)
        [
          0
          9
        ]
        true
      ]
    ]
  )

  # Bulk loops: loops outside the conditions keep the values of C
  (t "cc bulk: an index without a known range, break, two stores, a store in if"
    [
      (bulkTabled "xRange" [ buf tab 3 ] buf 3)
      (bulkFilled "xBreak" [ buf 3 ] buf 2)
      (bulkFilled "xTwo" [ buf 3 ] buf 6)
      (bulkFilled "xIf" [ buf 3 ] buf 3)
    ]
    [
      [
        0
        [
          70
          40
          10
        ]
        false
      ]
      [
        1
        [
          2
          9
        ]
        false
      ]
      [
        0
        [
          2
          12
          1
          11
          0
          10
        ]
        false
      ]
      [
        0
        [
          9
          1
          9
        ]
        false
      ]
    ]
  )
  (t "cc bulk: a 2-byte store, a compound store, steps -1, 0 and not constant"
    [
      (bulkFilled "xWide" [ buf 3 ] buf 6)
      (bulkFilled "xCompound" [ buf 3 ] buf 3)
      (bulkFilled "xNeg" [
        (buf + 2)
        3
      ] buf 4)
      (bulkFilled "xZero" [ buf 3 ] buf 2)
      (bulkFilled "xVar" [ buf 3 2 ] buf 6)
    ]
    [
      [
        0
        [
          2
          0
          1
          0
          0
          0
        ]
        false
      ]
      [
        0
        [
          11
          10
          9
        ]
        false
      ]
      [
        0
        [
          0
          1
          2
          9
        ]
        false
      ]
      [
        0
        [
          5
          9
        ]
        false
      ]
      [
        0
        [
          7
          9
          6
          9
          5
          9
        ]
        false
      ]
    ]
  )
  (t
    "cc bulk: a step in if, a variable that reads its previous value, x *= 2, a long long step, a store in the step, a call"
    [
      (bulkFilled "xIfStep" [ buf 3 ] buf 4)
      (bulkFilled "xPrev" [ buf 3 ] buf 4)
      (bulkFilled "xMul" [ buf 3 ] buf 4)
      (bulkFilled "xLong" [ buf 3 ] buf 4)
      (bulkFilled "xInStep" [ buf 3 ] buf 4)
      (bulkFilled "xCall" [ buf 3 ] buf 4)
    ]
    [
      [
        1
        [
          0
          0
          1
          9
        ]
        false
      ]
      [
        3
        [
          2
          3
          3
          9
        ]
        false
      ]
      [
        0
        [
          1
          2
          4
          9
        ]
        false
      ]
      [
        3
        [
          3
          3
          3
          9
        ]
        false
      ]
      [
        0
        [
          2
          1
          0
          9
        ]
        false
      ]
      [
        0
        [
          2
          1
          0
          9
        ]
        false
      ]
    ]
  )

  # Page reads of bulk loops: where they are emitted
  (t "cc page: the draw loops read their tables by pages, from 32 and 136 iterations on"
    (map
      (
        fn:
        let
          code = fnCode Cc.examples.draw.src fn;
        in
        [
          (countIn "M\\.readPages mem" code)
          (countIn " >= 32 then" code)
          (countIn " >= 136 then" code)
        ]
      )
      [
        "R_DrawColumn"
        "R_DrawSpan"
      ]
    )
    [
      [
        2
        1
        0
      ]
      [
        2
        0
        1
      ]
    ]
  )
  (t "cc page: reads of one table share their pages, other tables and wide or long ones do not"
    (map (fn: countIn "M\\.readPages" (pageCode fn)) [
      "colmap"
      "dbl"
      "big"
      "sgn"
      "twice"
      "two"
      "branch"
      "tern"
      "huge"
      "wide"
      "zero"
      "fill"
      "copy"
    ])
    [
      1
      2
      1
      1
      1
      2
      1
      1
      0
      0
      1
      0
      0
    ]
  )
  (t "cc page: a 4096-byte table sets the threshold to 136, a 64-byte one to 32"
    [
      (contains " >= 136 then" (pageCode "big"))
      (contains " >= 32 then" (pageCode "colmap"))
    ]
    [
      true
      true
    ]
  )

  # Page reads of bulk loops: values
  (t "cc page: a table at 0x10f0 that crosses a leaf, and one at 0x1001"
    [
      (pageRuns fMem "colmap" (n: [
        pbuf
        tf
        n
      ]))
      (pageRuns (withBytes M.empty 4097 (genList tfOf 64)) "colmap" (n: [
        pbuf
        4097
        n
      ]))
    ]
    [
      (pageWant (n: n) (_: k: tfOf (bitAnd k 63)))
      (pageWant (n: n) (_: k: tfOf (bitAnd k 63)))
    ]
  )
  (t "cc page: a table indexed by a byte read from another table (U = 255)" (pageRuns fhMem "dbl"
    (n: [
      pbuf
      tf
      tc
      n
    ])
  ) (pageWant (_: 0) (_: k: thOf (tfOf (bitAnd k 63)))))
  (t "cc page: a 4096-byte table (U = 4095) around its threshold of 136"
    (map (n: pageOn qMem "big" [ pbuf tq n ] pbuf n) (
      pageCounts
      ++ [
        135
        136
        137
      ]
    ))
    (
      map
        (n: [
          0
          (genList (k: tqOf (bitAnd (37 * k) 4095)) n)
          true
        ])
        (
          pageCounts
          ++ [
            135
            136
            137
          ]
        )
    )
  )
  (t "cc page: signed char values are sign-extended"
    (pageRuns sbMem "sgn" (n: [
      pbuf
      4348
      n
    ]))
    (
      pageWant (_: 0) (
        _: k:
        elemAt [
          36
          69
          63
          0
          127
          64
          64
          0
        ] (bitAnd k 7)
      )
    )
  )
  (t "cc page: one table read twice in an iteration, and two tables"
    [
      (pageRuns fMem "twice" (n: [
        pbuf
        tf
        n
      ]))
      (pageRuns fgMem "two" (n: [
        pbuf
        tf
        tc
        n
      ]))
    ]
    [
      (pageWant (_: 0) (_: k: bitAnd (tfOf (bitAnd k 63) + tfOf (bitAnd (k + 5) 63)) 255))
      (pageWant (_: 0) (_: k: bitXor (tfOf (bitAnd k 63)) (tgOf (bitAnd k 127))))
    ]
  )
  (t "cc page: table reads in a branch of if and of ?:"
    [
      (pageRuns fMem "branch" (n: [
        pbuf
        tf
        n
        1
      ]))
      (pageRuns fMem "branch" (n: [
        pbuf
        tf
        n
        0
      ]))
      (pageRuns fMem "tern" (n: [
        pbuf
        tf
        n
        1
      ]))
      (pageRuns fMem "tern" (n: [
        pbuf
        tf
        n
        0
      ]))
    ]
    [
      (pageWant (_: 3) (n: k: tfOf (bitAnd (n - 1 - k) 63)))
      (pageWant (_: 7) (_: _: 7))
      (pageWant (_: 0) (_: k: tfOf (bitAnd k 63)))
      (pageWant (_: 0) (_: _: 5))
    ]
  )
  (t "cc page: a table longer than 16384 bytes and a table of shorts are read as before"
    [
      (pageRuns pMem "huge" (n: [
        pbuf
        tp
        n
      ]))
      (pageRuns shMem "wide" (n: [
        pbuf
        tf
        n
      ]))
    ]
    [
      (pageWant (_: 0) (_: k: tpOf (bitAnd (1000 * k) 32767)))
      (pageWant (_: 0) (
        _: k:
        elemAt [
          1
          47
          235
          215
          8
          2
          3
          3
        ] (bitAnd k 7)
      ))
    ]
  )
  (t "cc page: a table ending at 2^32 - 1 runs in bulk, one byte later the loop wraps"
    [
      (pageOn (withBytes M.empty 4294967232 (genList tfOf 64)) "colmap" [ pbuf 4294967232 40 ] pbuf 40)
      (pageOn (withBytes M.empty 4294967233 (genList tfOf 64)) "colmap" [ pbuf 4294967233 40 ] pbuf 40)
    ]
    [
      [
        40
        (genList (k: tfOf k) 40)
        true
      ]
      [
        40
        (genList (k: tfOf k) 40)
        false
      ]
    ]
  )
  (t "cc page: a write range over the table runs the loop, which reads the stored bytes"
    (pageOn fMem "colmap" [
      (tf + 10)
      tf
      40
    ] (tf + 10) 40)
    [
      40
      (genList (k: tfOf (k - 10 * (k / 10))) 40)
      false
    ]
  )
  (t "cc page: N = 0 with a table across 2^32 neither reads nor writes"
    (pageOn M.empty "zero" [
      pbuf
      4294967280
      0
    ] pbuf 1)
    [
      (-1)
      [ 0 ]
      false
    ]
  )
  (t "cc page: the pages are read only from the threshold on, in bulk, and for N >= 1"
    [
      (runsUnpaged fMem "colmap" [
        pbuf
        tf
        31
      ])
      (runsUnpaged fMem "colmap" [
        pbuf
        tf
        32
      ])
      (runsUnpaged qMem "big" [
        pbuf
        tq
        135
      ])
      (runsUnpaged qMem "big" [
        pbuf
        tq
        136
      ])
      (runsUnpaged fMem "colmap" [
        (tf + 10)
        tf
        40
      ])
      (runsUnpaged M.empty "zero" [
        pbuf
        4294967280
        0
      ])
    ]
    [
      true
      false
      true
      false
      true
      true
    ]
  )
]
