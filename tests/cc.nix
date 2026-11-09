# Tests for the C compiler front end: the lexer (cc/lex.nix) and the parser
# (cc/parse.nix). Expressions are compared through a compact prefix rendering.
let
  Lx = import ../cc/lex.nix;
  P = import ../cc/parse.nix;
  inherit (builtins)
    concatStringsSep
    elemAt
    filter
    head
    length
    map
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

  # The M0 spike C (docs: bench/spike), with the address macros written as casts.
  spikeC = ''
    typedef unsigned char byte;
    typedef int fixed_t;

    fixed_t FixedMul(fixed_t a, fixed_t b) { return ((long long)a * b) >> 16; }

    void R_DrawColumn(byte *dest, const byte *src, const byte *cmap,
                      fixed_t frac, fixed_t step, int count) {
      do { *dest = cmap[src[(frac >> 16) & 127]]; dest += 320; frac += step; } while (--count);
    }

    void R_DrawSpan(byte *dest, const byte *src, const byte *cmap,
                    fixed_t xfrac, fixed_t yfrac, fixed_t xstep, fixed_t ystep, int count) {
      do {
        int spot = ((yfrac >> 10) & 4032) + ((xfrac >> 16) & 63);
        *dest++ = cmap[src[spot]];
        xfrac += xstep; yfrac += ystep;
      } while (--count);
    }

    /* params: [0]=frames, [1]=columns, [2]=spans, [3]=muls */
    void unit(const int *params) {
      for (int f = 0; f < params[0]; f++) {
        for (int x = 0; x < params[1]; x++)
          R_DrawColumn((byte *)0x00110000 + x, (byte *)0x00121000, (byte *)0x00120000,
                       x << 12, 0x8000, 200);
        for (int y = 0; y < params[2]; y++)
          R_DrawSpan((byte *)0x00110000 + y * 320 + 160, (byte *)0x00122000,
                     (byte *)0x00120000, y << 14, y << 16, 0x10000, 0x400, 160);
        unsigned s = 0;
        for (int i = 0; i < params[3]; i++) s += FixedMul(i * 7919, 0x12345 + i);
        *(unsigned *)0x00123000 += s;
      }
    }
  '';
  spikeFuncs = filter (i: i.kind == "func") (P.parse spikeC).items;
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
]
