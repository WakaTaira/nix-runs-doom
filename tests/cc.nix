# Tests for the C compiler: the lexer (cc/lex.nix) and the parser (cc/parse.nix), with
# expressions compared through a compact prefix rendering, and the type checker and code
# generator (cc/check.nix, cc/emit.nix) through small C functions compiled with cc.load
# and run.
let
  Lx = import ../cc/lex.nix;
  P = import ../cc/parse.nix;
  Cc = import ../cc;
  B = import ../lib/bits.nix;
  M = import ../lib/mem.nix;
  inherit (builtins)
    concatStringsSep
    elemAt
    filter
    foldl'
    genList
    head
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
    else
      throw "show: ${k}";
  showType = ty: if ty.tag == "ptr" then showType ty.to + "*" else ty.tag;

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
  '';

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

  # Parser: outside the subset
  (t "cc parse: switch throws" (throws "void f(int x) { switch (x) { } }") true)
  (t "cc parse: struct throws" (throws "struct s { int a; };") true)
  (t "cc parse: &x throws" (throws "void f(int x) { int *p = &x; }") true)
  (t "cc parse: global variable throws" (throws "int g;") true)

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
  (t "cc run: plain char is signed" (ret charSrc "plainChar" [ 256 ]) (-1))

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

  # Outside the subset and type errors
  (t "cc compile: switch throws" (compileThrows "void f(int x) { switch (x) { } }") true)
  (t "cc compile: struct throws" (compileThrows "struct s { int a; };") true)
  (t "cc compile: &x throws" (compileThrows "void f(int x) { int *p = &x; }") true)
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
