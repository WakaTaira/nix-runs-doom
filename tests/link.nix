# Tests for the linker of the Nix C compiler (cc/link.nix, cc.linkSources, cc.linkFiles)
# and the link mode of the checker (cc/check.nix). Units are small C sources; expected
# values follow C and the placement rules of cc/link.nix, worked out by hand. Errors are
# checked to be thrown (tryEval does not show the message); each sits next to a valid
# variant of the same input. The number in a test name is the one of the work order.
let
  Cc = import ../cc;
  Ch = import ../cc/check.nix;
  H = import ../lib/hostcall.nix;
  Lk = import ../cc/link.nix;
  Lx = import ../cc/lex.nix;
  P = import ../cc/parse.nix;
  M = import ../lib/mem.nix;
  B = import ../lib/bits.nix;
  inherit (builtins)
    attrNames
    concatStringsSep
    deepSeq
    elemAt
    filter
    foldl'
    genList
    hasAttr
    head
    length
    map
    match
    tail
    tryEval
    ;

  t = name: got: expected: { inherit name got expected; };

  base = 4194304; # the default dataBase, 0x00400000

  u = name: src: { inherit name src; };
  lk = units: Cc.linkSources { inherit units; };
  lkWith = args: units: Cc.linkSources (args // { inherit units; });
  throws = x: !(tryEval (deepSeq x x)).success;
  passes = x: (tryEval (deepSeq x x)).success;
  compileThrows = src: !(tryEval (Cc.compile src)).success;
  contains = needle: s: builtins.replaceStrings [ needle ] [ "" ] s != s;

  # The return values of the calls ([ fn arg ... ]) of the linked program l, made in order
  # on one memory, starting from __init; null for a void function.
  runCalls = l: calls: (afterCalls l calls).rets;
  # The same calls -> { mem; rets; } with mem the memory after them.
  afterCalls =
    l: calls:
    let
      step =
        st: c:
        let
          r = foldl' (g: a: g a) (l.${head c} st.mem) (tail c);
        in
        if r ? ret then
          {
            inherit (r) mem;
            rets = st.rets ++ [ r.ret ];
          }
        else
          {
            mem = r;
            rets = st.rets ++ [ null ];
          };
    in
    foldl' step {
      mem = l.__init M.empty;
      rets = [ ];
    } calls;
  # The output (stdout and stderr) of the default host after the calls.
  outOf = l: calls: (afterCalls l calls).mem.host.out;
  ret =
    l: fn: args:
    head (runCalls l [ ([ fn ] ++ args) ]);

  readOf = files: n: files.${n} or null;

  # ---- Inputs ----

  callSrcA = ''
    int sq(int x);
    void put(int v);
    int get(void);
    int odd(int n);
    int run(int x) { put(sq(x)); return get() + 1; }
    int even(int n) { if (n == 0) return 1; return odd(n - 1); }
  '';
  callSrcB = ''
    static int last;
    int sq(int x) { return x * x; }
    void put(int v) { last = v; }
    int get(void) { return last; }
    int even(int n);
    int odd(int n) { if (n == 0) return 0; return even(n - 1); }
  '';
  calls = lk [
    (u "a" callSrcA)
    (u "b" callSrcB)
  ];

  externVar = lk [
    (u "a" "extern int g; void set(int v) { g = v; } int *addrA(void) { return &g; }")
    (u "b" "int g = 3; int get(void) { return g; } int *addrB(void) { return &g; }")
  ];

  arrays = lk [
    (u "a" ''
      struct pt { int x; int y; };
      extern int a[];
      extern struct pt p;
      extern int b[4];
      int sumA(void) { int s = 0; for (int i = 0; i < 4; i++) s += a[i]; return s; }
      int px(void) { return p.x * 10 + p.y; }
      int b3(void) { return b[3]; }
    '')
    (u "b" ''
      struct pt { int x; int y; };
      int a[4] = { 1, 2, 3, 4 };
      struct pt p = { 3, 4 };
      int b[] = { 5, 6, 7, 8 };
    '')
  ];

  inits = lk [
    (u "a" ''
      extern int g;
      extern int arr[];
      int *pg = &g;
      int *pa = &arr[2];
      int rd(void) { return *pg + *pa; }
    '')
    (u "b" ''
      int g = 5;
      int arr[4] = { 1, 2, 30, 4 };
      extern int *pg;
      int viaB(void) { return *pg; }
    '')
  ];

  staticVars = lk [
    (u "a" "static int c = 1; int incA(void) { return ++c; }")
    (u "b" "static int c = 100; int incB(void) { return ++c; }")
    (u "c" "int c = 50; int getC(void) { return c; }")
    (u "d" "extern int c; int getD(void) { return c; }")
  ];

  staticFuncs = lk [
    (u "a" "static int f(void) { return 1; } int fa(void) { return f(); }")
    (u "b" "static int f(void) { return 2; } int fb(void) { return f(); }")
    (u "c" "int f(void) { return 3; }")
    (u "d" "int f(void); int fd(void) { return f(); }")
  ];

  staticLocals = lk [
    (u "a" "static int k(void) { static int n = 0; return ++n; } int ka(void) { return k(); }")
    (u "b" "static int k(void) { static int n = 10; return ++n; } int kb(void) { return k(); }")
  ];

  strings = lk [
    (u "a" ''char *sa(void) { return "hi"; } int la(void) { char *s = "hi"; return s[0] + s[1]; }'')
    (u "b" ''char *sb(void) { return "hi"; } char *sc(void) { return "yo"; }'')
  ];

  # A host with functions of its own, a variable, and state in mem.host.
  testHost = {
    funcs =
      { symbols, dataEnd }:
      {
        twice = {
          nargs = 1;
          call = w: args: {
            world = w;
            ret = B.u32 (2 * head args);
          };
        };
        bump = {
          nargs = 0;
          call = w: _: {
            world = w // {
              n = w.n + 1;
            };
            ret = w.n;
          };
        };
        minus1 = {
          nargs = 0;
          call = w: _: {
            world = w;
            ret = 4294967295;
          };
        };
        umax = {
          nargs = 0;
          call = w: _: {
            world = w;
            ret = 4294967295;
          };
        };
        poke = {
          nargs = 1;
          call = w: args: {
            world = w // {
              mem = M.storeWord w.mem symbols.hv (head args);
            };
            ret = 0;
          };
        };
        where = {
          nargs = 0;
          call = w: _: {
            world = w;
            ret = dataEnd;
          };
        };
        # Returns its argument and keeps it in the state.
        echo = {
          nargs = 1;
          call = w: args: {
            world = w // {
              last = head args;
            };
            ret = head args;
          };
        };
        vh = {
          nargs = 1;
          variadic = true;
          call = w: args: va: {
            world = w // {
              seen = va;
            };
            ret = head args + length va;
          };
        };
      };
    data = [
      {
        name = "hv";
        size = 4;
        align = 4;
      }
      {
        name = "unused";
        size = 4;
        align = 4;
      }
    ];
    init = _: { n = 10; };
  };
  withHost = lkWith { host = testHost; };
  hosted = withHost [
    (u "a" ''
      int twice(int);
      int bump(void);
      int minus1(void);
      unsigned umax(void);
      void poke(int);
      int where(void);
      extern int hv;
      char pad = 1;
      int ta(void) { return twice(-3); }
      int ba(void) { return bump(); }
      int m1(void) { return minus1(); }
      unsigned um(void) { return umax(); }
      void pk(int v) { poke(v); }
      int rdhv(void) { return hv; }
      int wh(void) { return where(); }
    '')
    (u "b" "int bump(void); int bb(void) { return bump(); }")
  ];

  # The value that f returns when the host function echo, declared with the return type
  # rt, returns the argument arg.
  echoAs =
    rt: arg:
    ret (withHost [
      (u "a" "${rt} echo(int); int f(void) { return echo(${arg}); }")
    ]) "f" [ ];

  # ---- The default host ----

  # The C files srcs (by name) linked with the default host, with the headers of
  # lib/hostcall.nix (ccHeaderFiles) for #include <...>.
  withStd = withStdWith { };
  withStdWith =
    args: srcs:
    Cc.linkFiles (
      args
      // {
        files = attrNames srcs;
        read = n: srcs.${n} or H.ccHeaderFiles.${n} or null;
        includePaths = [ "" ];
      }
    );
  # The output of the function run of a single file src linked with the default host.
  printed = src: outOf (withStd { "a.c" = src; }) [ [ "run" ] ];

  libcUse = withStd {
    "a.c" = ''
      #include <string.h>
      #include <stdlib.h>
      #include <ctype.h>
      #include <stdio.h>
      #include <errno.h>
      char buf[8];
      int t_strlen(void) { return strlen("hello"); }
      int t_strcmp(void) { return strcmp("abc", "abd"); }
      int t_abs(void) { return abs(-5); }
      int t_toupper(void) { return toupper('q'); }
      int t_memcpy(void) { memcpy(buf, "xyz", 4); return buf[1]; }
      int t_memset(void) { memset(buf, -1, 4); return buf[0] + buf[3] + (buf[4] == 0); }
      void *m1(void) { return malloc(16); }
      void say(void) { puts("hi"); putchar('!'); }
      int nofile(void) { return (fopen("nope.txt", "r") == 0) * 10 + errno; }
    '';
    "b.c" = ''
      #include <stdlib.h>
      void *m2(void) { return malloc(16); }
    '';
  };

  platformSrc = ''
    void DG_SleepMs(unsigned ms);
    unsigned DG_GetTicksMs(void);
    void DG_DrawFrame(void);
    unsigned char *DG_ScreenBuffer;
    unsigned colors[256];
    unsigned char screen[64000];
    unsigned ticks(void) { DG_SleepMs(30); DG_SleepMs(12); return DG_GetTicksMs(); }
    void draw(void) {
      DG_ScreenBuffer = screen;
      screen[0] = 7;
      screen[63999] = 9;
      colors[7] = 0x00112233;
      DG_DrawFrame();
    }
  '';
  platform = lk [ (u "a" platformSrc) ];
  drawn = (afterCalls platform [ [ "draw" ] ]).mem.host;

  # The host state across bulk writes (storeRun and storeStride).
  bulk = lk [
    (u "a" ''
      void *malloc(unsigned n);
      int putchar(int c);
      char small[64];
      char big[4096];
      void *ma(void) { return malloc(4); }
      void pa(void) { putchar('a'); }
      void run(int n) { for (int i = 0; i < n; i++) small[i] = i; }
      void stride(int n) { int j = 0; for (int i = 0; i < n; i++) { big[j] = 1; j += 320; } }
      void pb(void) { putchar('b'); }
    '')
  ];
  bulkRun = afterCalls bulk [
    [ "ma" ]
    [ "pa" ]
    [
      "run"
      64
    ]
    [
      "stride"
      12
    ]
    [ "pb" ]
    [ "ma" ]
  ];

  exiting = lk [
    (u "a" ''
      void exit(int status);
      int f(int x) { if (x) exit(3); return 2; }
    '')
  ];

  # ---- Variadic calls ----

  # The output of printf over the formats and arguments of run in a single unit.
  printfSrc = body: ''
    #include <stdio.h>
    ${body}
  '';
  formats = printed (printfSrc ''
    char name[8] = "abc";
    void run(void) {
      long long big = 7;
      unsigned u = 3000000000u;
      char c = 200;
      signed char sc = -3;
      short s = -300;
      unsigned short us = 65535;
      big = big * 1000000000;
      printf("plain\n");
      printf("%lld %lld %llx %lld %llx\n", 5LL, -5LL, 0x123456789LL, big, -1LL);
      printf("%d %u %x\n", -1, -1, -1);
      printf("%u %d\n", u, u);
      printf("%d %d %d %d\n", c, sc, s, us);
      printf("%p %s|%s %c%%\n", (void *)0x1234, "lit", name, 'Z');
      printf("[%5d][%-4d][%05d][%.3d][%3s][%.2s]\n", 42, 7, -42, 5, "ab", "xyz");
    }
  '');

  order = printed (printfSrc ''
    int i = 1;
    int f(void) { return i * 10; }
    void run(void) {
      int k = 5;
      printf("%d %d\n", i++, f());
      printf("%d %d %d\n", k++, k++, k);
      i = 9;
      printf("%d\n", i);
    }
  '');

  # Locals in memory as the buffers and targets of host calls, and a unit whose frames are
  # placed as in a single file.
  frameIo = withStd {
    "a.c" = ''
      #include <stdio.h>
      int sn(char *out) {
        char buf[16];
        int n = snprintf(buf, sizeof buf, "<%d:%s>", 42, "ok");
        int i;
        for (i = 0; i <= n; i++) out[i] = buf[i];
        return n;
      }
      int sc(void) { int a; unsigned x; sscanf(" 17 ab", "%d %x", &a, &x); return a * 1000 + x; }
    '';
  };
  frameUnitSrc = ''
    int f(int v) { static int s; int a[2]; int *p = &v; a[v & 1] = *p; return a[v & 1] + s; }
    int g(void) { struct { int x; char c[3]; } q; q.x = 3; q.c[2] = 4; return q.x + q.c[2]; }
  '';
  frameUnit = lk [ (u "a" frameUnitSrc) ];
  # Initializers of locals as the format, the arguments and the buffer of a host call.
  frameInitIo = withStd {
    "a.c" = ''
      #include <stdio.h>
      int fm(char *out, int k) {
        char fmt[] = "<%d|%s>";
        char *w[2] = { "no", "yes" };
        char buf[12] = { 0 };
        int n = snprintf(buf, sizeof buf, fmt, k, w[1]);
        int i;
        for (i = 0; i < 12; i++) out[i] = buf[i];
        return n;
      }
    '';
  };

  strio = withStd {
    "a.c" = ''
      #include <stdio.h>
      char b[8];
      int a;
      unsigned x;
      int sn(void) { return snprintf(b, 4, "%d", 12345); }
      void err(void) { fprintf(stderr, "e%d;", 1); fprintf(stdout, "o%d;", 2); }
      int sc(void) { return sscanf(" 17 ab", "%d %x", &a, &x); }
      int ra(void) { return a; }
      unsigned rx(void) { return x; }
    '';
  };

  loops = withStd {
    "a.c" = ''
      #include <stdio.h>
      void run(void) { for (int i = 0; i < 3; i++) printf("%d,", i); }
      int ok(int x) { return x && printf("y") > 0; }
    '';
  };

  # A unit whose layout uses a variable it does not define, through folded constants and
  # an initializer.
  layoutSrc = ''
    extern int x;
    extern int arr[];
    int h(int);
    static int s(void) { return 2; }
    int *p = &x + 1;
    int v = 3;
    unsigned f(void) { return 1 + (unsigned)&x; }
    int g(void) {
      extern char c[4];
      int k(char);
      if ((unsigned)&x ? 1 : 0) return arr[1] + c[0] + h(2) + k(1) + s() + sizeof x;
      return 0;
    }
  '';
  layoutCheck = Ch.checkWith {
    dataBase = base;
    link.externAddr = n: throw "externAddr ${n}";
  } (P.parse layoutSrc);

  # A unit whose switch conditions and sizeof operands fold the address of a variable it
  # imports; the placement depends on their types only.
  foldedSrc = ''
    extern int x;
    char a[sizeof(1 + (unsigned)&x)];
    int s1(void) { switch ((unsigned)&x + 1) { case 1: return 1; default: return 2; } }
    int s2(void) { switch ((unsigned)&x ? 1 : 0) { case 1: return 3; } return 4; }
    int s3(void) { static char b[sizeof((unsigned)&x * 2)]; return sizeof a + sizeof b; }
  '';
  folded = lk [
    (u "a" foldedSrc)
    (u "b" "int x;")
  ];
  foldedCheck = Ch.checkWith {
    dataBase = base;
    link.externAddr = n: throw "externAddr ${n}";
  } (P.parse foldedSrc);

  # sizeof operands where an imported address folds to a null pointer constant.
  nullFoldSrc = ''
    extern int x;
    char a[sizeof(1 ? &x : ((unsigned)&x & 0))];
    int f(void) { static char b[sizeof(1 ? &x : ((unsigned)&x * 0))]; return sizeof a + sizeof b; }
  '';
  nullFoldCheck = Ch.checkWith {
    dataBase = base;
    link.externAddr = n: throw "externAddr ${n}";
  } (P.parse nullFoldSrc);

  # The shared header of two files, with an anonymous struct; a.c has tokens before it,
  # so the token indices of the struct differ between the units.
  boxFiles = {
    "h.h" = "typedef struct { int v; } box_t;\nextern box_t *cur;\nint getv(void);\n";
    "a.c" = "int pad;\n#include \"h.h\"\nbox_t b0 = { 7 };\nbox_t *cur = &b0;\n";
    "b.c" = "#include \"h.h\"\nint getv(void) { return cur->v; }\n";
    "c.c" = "typedef struct { int v; } box_t;\nbox_t b0 = { 7 };\nbox_t *cur = &b0;\n";
  };
  linkBox =
    files:
    Cc.linkFiles {
      inherit files;
      read = readOf boxFiles;
    };

  # Two anonymous structs of one macro expansion share a position; a.c and b.c use
  # different ones under the same name.
  pairFiles = {
    "h.h" = "#define T2 typedef struct { int a; } s1_t; typedef struct { char c; } s2_t;\nT2\n";
    "a.c" = "#include \"h.h\"\nextern s1_t g;\nint f(void) { return g.a; }\n";
    "b.c" = "#include \"h.h\"\ns2_t g;\n";
  };
  linkPair = Cc.linkFiles {
    files = [
      "a.c"
      "b.c"
    ];
    read = readOf pairFiles;
  };

  ptFiles = {
    "pt.h" = "typedef struct pt { int x; int y; } pt_t;\nextern pt_t origin;\nint norm1(pt_t *p);\n";
    "a.c" = "#include \"pt.h\"\npt_t origin = { 2, 3 };\nint norm1(pt_t *p) { return p->x + p->y; }\n";
    "b.c" = "#include \"pt.h\"\nint useB(void) { return norm1(&origin); }\n";
  };
  pts = Cc.linkFiles {
    files = [
      "a.c"
      "b.c"
    ];
    read = readOf ptFiles;
  };

  orderA = u "a" "extern int gb; char c1 = 1; int fa(void) { return c1 + gb; }";
  orderB = u "b" "int gb = 20; extern char c1; int fb(void) { return gb * c1; }";
  orderC = u "c" "char c3[3] = { 1, 2, 3 }; int fc(void) { return c3[2]; }";
  forward = lk [
    orderA
    orderB
    orderC
  ];
  backward = lk [
    orderC
    orderB
    orderA
  ];
  orderRets =
    l:
    runCalls l [
      [ "fa" ]
      [ "fb" ]
      [ "fc" ]
    ];

  # 4 units of 1,000 variables each; the first reads two of the others.
  scaleUnit =
    k:
    u "u${toString k}" (
      concatStringsSep "" (genList (i: "int u${toString k}_g${toString i} = ${toString i};\n") 1000)
      + (
        if k == 0 then
          "extern int u3_g999; extern int u1_g500; int probe(void) { return u3_g999 + u1_g500; }"
        else
          ""
      )
    );
  scale = lk (genList scaleUnit 4);

  undefined = lkWith { allowUndefined = true; } [
    (u "a" ''
      extern int u;
      extern char buf[];
      extern int w;
      char c = 1;
      int h(int);
      int getu(void) { return u; }
      void setu(int v) { u = v; }
      int callh(void) { return h(1); }
      int one(void) { return 1; }
      char *pbuf(void) { return buf; }
    '')
  ];
  undefinedArrays = lkWith { allowUndefined = true; } [
    (u "a" "extern int arr[]; int ra(void) { return arr[0]; }")
    (u "b" "extern int arr[4]; int rb(void) { return arr[3]; }")
  ];

  shape = lk [
    (u "a" "static int s = 1; int e = 2; int f(void) { static int k; return k + s; }")
    (u "b" "int e2;")
  ];
in
[
  (t "cc link 1: calls between units (void and value) and mutual recursion"
    (runCalls calls [
      [
        "run"
        6
      ]
      [
        "even"
        10
      ]
      [
        "even"
        7
      ]
      [
        "odd"
        7
      ]
    ])
    [
      37
      1
      0
      1
    ]
  )
  (t "cc link 2: an extern variable defined in another unit"
    [
      (runCalls externVar [
        [ "get" ]
        [
          "set"
          9
        ]
        [ "get" ]
      ])
      (ret externVar "addrA" [ ] == ret externVar "addrB" [ ])
      (ret externVar "addrA" [ ] == externVar.__data.symbols.g)
    ]
    [
      [
        3
        null
        9
      ]
      true
      true
    ]
  )
  (t "cc link 3: extern arrays without and with a length, and an extern struct"
    (runCalls arrays [
      [ "sumA" ]
      [ "px" ]
      [ "b3" ]
    ])
    [
      10
      34
      8
    ]
  )
  (t "cc link 4: initializers with the addresses of another unit's variable and element"
    (runCalls inits [
      [ "rd" ]
      [ "viaB" ]
    ])
    [
      35
      5
    ]
  )
  (t "cc link 5: static variables of the same name, and one named like an external one"
    [
      (runCalls staticVars [
        [ "incA" ]
        [ "incB" ]
        [ "incA" ]
        [ "getC" ]
        [ "getD" ]
      ])
      (staticVars.__data.symbols.c == staticVars.__data.units.c.symbols.c)
    ]
    [
      [
        2
        101
        3
        50
        50
      ]
      true
    ]
  )
  (t "cc link 6: static functions of the same name, and one named like an external one"
    [
      (runCalls staticFuncs [
        [ "fa" ]
        [ "fb" ]
        [ "fd" ]
        [ "f" ]
      ])
      (contains "f = f_fn" staticFuncs.__units.a.nix)
      (contains "f = f_fn" staticFuncs.__units.c.nix)
    ]
    [
      [
        1
        2
        3
        3
      ]
      false
      true
    ]
  )
  (t "cc link 7: static locals of the same name in static functions of the same name"
    [
      (runCalls staticLocals [
        [ "ka" ]
        [ "ka" ]
        [ "kb" ]
        [ "ka" ]
        [ "kb" ]
      ])
      (map
        (n: length (filter (s: match ".*'.*" s != null) (attrNames staticLocals.__data.units.${n}.symbols)))
        [
          "a"
          "b"
        ]
      )
    ]
    [
      [
        1
        2
        11
        3
        12
      ]
      [
        1
        1
      ]
    ]
  )
  (t "cc link 8: string literals of both units, shared only within a unit"
    (
      let
        mem = strings.__init M.empty;
        sb = (strings.sb mem).ret;
      in
      [
        (ret strings "la" [ ])
        (ret strings "sa" [ ] == sb)
        (map (i: M.loadByte mem (sb + i)) [
          0
          1
          2
        ])
        (length strings.__data.strings)
      ]
    )
    [
      209
      false
      [
        104
        105
        0
      ]
      3
    ]
  )
  (t "cc link 9: duplicate definitions, definitions the host has, duplicate units"
    (
      map throws [
        (lk [
          (u "a" "int g;")
          (u "b" "int g = 1;")
        ])
        (lk [
          (u "a" "int f(void) { return 1; }")
          (u "b" "int f(void) { return 2; }")
        ])
        (lk [
          (u "a" "int f;")
          (u "b" "int f(void) { return 0; }")
        ])
        (withHost [ (u "a" "int twice(int x) { return x; }") ])
        (withHost [ (u "a" "int hv;") ])
        (lk [
          (u "a" "int x;")
          (u "a" "int y;")
        ])
      ]
      ++ [
        (passes (lk [
          (u "a" "static int g; static int f(void) { return 1; }")
          (u "b" "int g; int f(void) { return 2; }")
        ]))
      ]
    )
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
  (t "cc link 10: undefined references; unused externs and prototypes and sizeof are no use"
    [
      (throws (lk [ (u "a" "extern int x; int f(void) { return x; }") ]))
      (throws (lk [ (u "a" "int h(void); int f(void) { return h(); }") ]))
      (throws (lk [ (u "a" "int f(void) { extern int y; return y; }") ]))
      (ret (lk [ (u "a" "extern int x; int h(void); int f(void) { extern int y; return 1; }") ]) "f" [ ])
      (ret (lk [ (u "a" "extern int z; int f(void) { return sizeof z; }") ]) "f" [ ])
    ]
    [
      true
      true
      true
      1
      4
    ]
  )
  (t "cc link 11: conflicting types between units; an anonymous struct of a shared header"
    [
      (throws (lk [
        (u "a" "extern int g; int f(void) { return g; }")
        (u "b" "char g;")
      ]))
      (throws (lk [
        (u "a" "extern int a[]; int f(void) { return a[0]; }")
        (u "b" "char a[4];")
      ]))
      (throws (lk [
        (u "a" "int h(int); int f(void) { return h(1); }")
        (u "b" "int h(int a, int b) { return a; }")
      ]))
      (throws (lk [
        (u "a" "int h(int); int f(void) { return h(1); }")
        (u "b" "int h(char a) { return a; }")
      ]))
      (throws (lk [
        (u "a" "int h(int); int f(void) { return h(1); }")
        (u "b" "unsigned h(int a) { return a; }")
      ]))
      (throws (withHost [ (u "a" "int vh(int); int f(void) { return vh(1); }") ]))
      (ret (lk [
        (u "a" "int h(int); int f(void) { return h(1); }")
        (u "b" "int h(int a) { return a + 1; }")
      ]) "f" [ ])
      (ret (linkBox [
        "a.c"
        "b.c"
      ]) "getv" [ ])
      (ret (linkBox [
        "c.c"
        "b.c"
      ]) "getv" [ ])
    ]
    [
      true
      true
      true
      true
      true
      true
      2
      7
      7
    ]
  )
  (t "cc link 11: struct, union and enum types agree by contents between units"
    [
      (ret (lk [
        (u "a" "struct node { int v; struct node *next; }; extern struct node *head; int sum(void) { int s = 0; for (struct node *p = head; p; p = p->next) s += p->v; return s; }")
        (u "b" "struct node { int v; struct node *next; }; struct node n2 = { 2, 0 }; struct node n1 = { 1, &n2 }; struct node *head = &n1;")
      ]) "sum" [ ])
      (ret (lk [
        (u "a" "struct b; struct a { struct b *pb; int w; }; struct b { struct a *pa; int v; }; extern struct a x; int f(void) { return x.pb->v + x.pb->pa->w; }")
        (u "b" "struct a; struct b { struct a *pa; int v; }; struct a { struct b *pb; int w; }; extern struct b y; struct a x = { &y, 30 }; struct b y = { &x, 4 };")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "struct s; extern struct s *p; int f(void) { return p != 0; }")
        (u "b" "struct s { int a; } v; struct s *p = &v;")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "int f(void) { struct s { int a; }; extern struct s v; return v.a; }")
        (u "b" "struct s { int a; } v = { 9 };")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "int f(void) { struct { int a; } *g(void); return g()->a; }")
        (u "b" "typedef struct { int a; } T; T v = { 6 }; T *g(void) { return &v; }")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "enum c { R, G = 5 }; extern enum c col; int f(void) { return col; }")
        (u "b" "enum c { G = 5, R = 0 }; enum c col = G;")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "extern unsigned col; int f(void) { return col; }")
        (u "b" "enum c { R, G } col = G;")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "union u { int a; char b; }; extern union u w; int f(void) { return w.a; }")
        (u "b" "union u { char b; int a; } w = { 7 };")
      ]) "f" [ ])
    ]
    [
      3
      34
      1
      9
      6
      5
      1
      7
    ]
  )
  (t "cc link 11: struct, union and enum types of other contents conflict between units" (map throws [
    (lk [
      (u "a" "struct s { int a; }; extern struct s v; int f(void) { return v.a; }")
      (u "b" "struct s { char a; } v;")
    ])
    (lk [
      (u "a" "struct s { int a; }; extern struct s v; int f(void) { return v.a; }")
      (u "b" "struct t { int a; } v;")
    ])
    (lk [
      (u "a" "struct s { int a; }; extern struct s v; int f(void) { return v.a; }")
      (u "b" "struct s { int b; } v;")
    ])
    (lk [
      (u "a" "struct s { int a; int b; }; extern struct s v; int f(void) { return v.a; }")
      (u "b" "struct s { int b; int a; } v;")
    ])
    (lk [
      (u "a" "struct s { unsigned a : 8; unsigned b : 8; unsigned c : 16; }; extern struct s v; int f(void) { return v.a; }")
      (u "b" "struct s { unsigned a : 16; unsigned b : 8; unsigned c : 8; } v;")
    ])
    (lk [
      (u "a" "struct s { int a; } __attribute__((packed)); extern struct s v; int f(void) { return v.a; }")
      (u "b" "struct s { int a; } v;")
    ])
    (lk [
      (u "a" "struct node { int v; struct node *next; }; extern struct node *head; int f(void) { return head->v; }")
      (u "b" "struct node { int v; struct node2 *next; }; struct node *head;")
    ])
    (lk [
      (u "a" "enum c { R, G }; extern enum c col; int f(void) { return col; }")
      (u "b" "enum c { R, G = 2 } col;")
    ])
    (lk [
      (u "a" "enum c { R, G }; extern enum c col; int f(void) { return col; }")
      (u "b" "enum c { R, B } col;")
    ])
    (lk [
      (u "a" "enum c { R, G }; extern enum c col; int f(void) { return col; }")
      (u "b" "enum d { R, G } col;")
    ])
    (lk [
      (u "a" "int f(void) { struct s { int a; }; extern struct s v; return v.a; }")
      (u "b" "struct s { char a; } v;")
    ])
    (linkPair)
  ]) (genList (_: true) 12))
  (t "cc link 11: tags agree when both types have none or both the same, never one alone"
    [
      (ret (lk [
        (u "a" "typedef struct { int a; } T; extern T v; int f(void) { return v.a; }")
        (u "b" "typedef struct { int a; } T; T v = { 5 };")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "typedef enum { R, G } E; extern E col; int f(void) { return col; }")
        (u "b" "typedef enum { R, G } E; E col = G;")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "int f(void) { struct s { int a; }; extern struct s v; return v.a; }")
        (u "b" "struct s { int a; } v = { 7 };")
      ]) "f" [ ])
      (throws (lk [
        (u "a" "typedef struct { int a; } T; extern T v; int f(void) { return v.a; }")
        (u "b" "struct s { int a; } v;")
      ]))
      (throws (lk [
        (u "a" "struct s { int a; }; extern struct s v; int f(void) { return v.a; }")
        (u "b" "typedef struct { int a; } T; T v;")
      ]))
      (throws (lk [
        (u "a" "typedef enum { R, G } E; extern E col; int f(void) { return col; }")
        (u "b" "enum c { R, G } col;")
      ]))
      (throws (lk [
        (u "a" "struct s { int a; }; struct s *g(void); int f(void) { return g()->a; }")
        (u "b" "typedef struct { int a; } T; T v; T *g(void) { return &v; }")
      ]))
    ]
    [
      5
      1
      7
      true
      true
      true
      true
    ]
  )
  (t "cc link 11: an array without a length agrees with any length inside other types"
    [
      (ret (lk [
        (u "a" "typedef int A[]; struct s { A *p; }; extern struct s v; int f(void) { return v.p != 0; }")
        (u "b" "typedef int A[4]; struct s { A *p; }; struct s v;")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "typedef int A[]; struct s { A *p; }; extern struct s v; int f(void) { return v.p != 0; }")
        (u "b" "typedef int A[4]; struct s { A *p; }; A arr; struct s v = { &arr };")
      ]) "f" [ ])
      (ret (lk [
        (u "a" "typedef int A[]; extern A *q; int f(void) { return q != 0; }")
        (u "b" "typedef int A[2]; A *q;")
      ]) "f" [ ])
      (throws (lk [
        (u "a" "typedef int A[3]; struct s { A *p; }; extern struct s v; int f(void) { return v.p != 0; }")
        (u "b" "typedef int A[4]; struct s { A *p; }; struct s v;")
      ]))
      (throws (lk [
        (u "a" "typedef int A[3]; extern A *q; int f(void) { return q != 0; }")
        (u "b" "typedef int A[2]; A *q;")
      ]))
    ]
    [
      0
      1
      0
      true
      true
    ]
  )
  (t "cc link 12: linkage within a file (static first is internal, static later throws)"
    [
      (runCalls
        (lk [
          (u "a" "static int f(void); int f(void) { return 1; } int fa(void) { return f(); }")
          (u "b" "int f(void) { return 2; } int fb(void) { return f(); }")
        ])
        [
          [ "fa" ]
          [ "fb" ]
          [ "f" ]
        ]
      )
      (runCalls
        (lk [
          (u "a" "static int v = 1; extern int v; int va(void) { return v; }")
          (u "b" "int v = 2; int vb(void) { return v; }")
        ])
        [
          [ "va" ]
          [ "vb" ]
        ]
      )
      (throws (lk [ (u "a" "int f(void); static int f(void) { return 1; }") ]))
      (throws (lk [ (u "a" "int v; static int v;") ]))
      (throws (lk [
        (u "a" "int g(void) { int f(void); return f(); } static int f(void) { return 1; }")
        (u "b" "int f(void) { return 2; }")
      ]))
      (throws (lk [
        (u "a" "int f(void) { extern int v; return v; } static int v = 3;")
        (u "b" "int v = 4;")
      ]))
    ]
    [
      [
        1
        2
        2
      ]
      [
        1
        2
      ]
      true
      true
      true
      true
    ]
  )
  (t "cc link 13: linkFiles with a shared header (struct typedef and extern declarations)"
    [
      (ret pts "useB" [ ])
      (attrNames pts.__units)
    ]
    [
      5
      [
        "a.c"
        "b.c"
      ]
    ]
  )
  (t "cc link 14: unit order changes no result; a unit after an odd size starts at 8k"
    [
      (orderRets forward)
      (orderRets backward)
      [
        (forward.__data.units.b.base - base)
        (forward.__data.units.c.base - base)
        (forward.__data.symbols.gb - base)
      ]
      [
        (backward.__data.units.b.base - base)
        (backward.__data.units.a.base - base)
      ]
    ]
    [
      [
        21
        20
        3
      ]
      [
        21
        20
        3
      ]
      [
        8
        16
        8
      ]
      [
        8
        16
      ]
    ]
  )
  (t "cc link 15: 4 units of 1,000 variables each"
    [
      (ret scale "probe" [ ])
      scale.__data.size
      (scale.__data.symbols.u3_g0 - base)
    ]
    [
      1499
      16000
      12000
    ]
  )
  (t "cc link 16: allowUndefined places undefined variables; undefined functions throw when called"
    [
      (attrNames undefined.__data.undefined)
      [
        (undefined.__data.undefined.buf - base)
        (undefined.__data.undefined.u - base)
        undefined.__data.size
      ]
      (runCalls undefined [
        [
          "setu"
          5
        ]
        [ "getu" ]
        [ "one" ]
      ])
      (ret undefined "pbuf" [ ] == undefined.__data.undefined.buf)
      (tryEval (ret undefined "callh" [ ])).success
      undefinedArrays.__data.size
    ]
    [
      [
        "buf"
        "u"
      ]
      [
        1
        4
        8
      ]
      [
        null
        5
        1
      ]
      true
      false
      16
    ]
  )
  (t "cc link 17: the shape of __data"
    [
      (attrNames shape.__data)
      (attrNames shape.__data.symbols)
      (attrNames shape.__data.units)
      (length (attrNames shape.__data.units.a.symbols))
      (hasAttr "s" shape.__data.units.a.symbols)
      (shape.__data.units.b.base - base)
      shape.__data.undefined
    ]
    [
      [
        "base"
        "init"
        "size"
        "strings"
        "symbols"
        "undefined"
        "units"
      ]
      [
        "e"
        "e2"
      ]
      [
        "a"
        "b"
      ]
      3
      true
      16
      { }
    ]
  )
  (t "cc link 23: a host given by the caller: values, state across units, data, variadic"
    [
      (runCalls hosted [
        [ "ta" ]
        [ "ba" ]
        [ "bb" ]
        [ "ba" ]
        [ "m1" ]
        [ "um" ]
        [
          "pk"
          42
        ]
        [ "rdhv" ]
        [ "wh" ]
      ])
      (hosted.__data.symbols.hv - base)
      (hasAttr "unused" hosted.__data.symbols)
      (
        let
          wrapped =
            Lk.wrapHost
              {
                nargs = 1;
                variadic = true;
                call = w: args: va: {
                  world = w // {
                    seen = va;
                  };
                  ret = head args + length va;
                };
              }
              {
                ret = {
                  tag = "int";
                };
              };
          r = wrapped (M.empty // { host = { }; }) (-5) [
            1
            (-2)
          ];
        in
        [
          r.ret
          r.mem.host.seen
        ]
      )
    ]
    [
      [
        (-6)
        10
        11
        12
        (-1)
        4294967295
        null
        42
        (base + 12)
      ]
      8
      false
      [
        (-3)
        [
          1
          (-2)
        ]
      ]
    ]
  )
  (t "cc link 23: a host function gets its fixed arguments as unsigned 32-bit values"
    (
      let
        l = withHost [ (u "a" "unsigned echo(int); unsigned f(void) { return echo(-1); }") ];
        r = l.f (l.__init M.empty);
      in
      [
        r.ret
        r.mem.host.last
      ]
    )
    [
      4294967295
      4294967295
    ]
  )
  (t "cc link 23: a host function's result is converted to a narrower return type like a cast"
    [
      (echoAs "char" "511")
      (echoAs "signed char" "511")
      (echoAs "unsigned char" "-1")
      (echoAs "short" "98304")
      (echoAs "unsigned short" "-1")
      (echoAs "int" "-1")
    ]
    [
      255
      (-1)
      255
      (-32768)
      65535
      (-1)
    ]
  )
  (t "cc link 11: host data and host functions declared against the host's table"
    [
      (throws (withHost [ (u "a" "extern int hv[]; int f(void) { return hv[0]; }") ]))
      (throws (withHost [ (u "a" "extern char hv; int f(void) { return hv; }") ]))
      (throws (withHost [ (u "a" "int twice(int, int); int f(void) { return twice(1, 2); }") ]))
      (throws (withHost [ (u "a" "int twice(void); int f(void) { return twice(); }") ]))
      (ret (withHost [ (u "a" "extern int hv[1]; int f(void) { return hv[0] + 1; }") ]) "f" [ ])
    ]
    [
      true
      true
      true
      true
      1
    ]
  )
  (t "cc link 33: a name that nothing defines, imported as a variable and as a function"
    (
      let
        lkU = lkWith { allowUndefined = true; };
        asVar = u "a" "extern int x; int fa(void) { return x; }";
        asFunc = u "b" "int x(void); int fb(void) { return x(); }";
      in
      [
        (throws (lkU [
          asVar
          asFunc
        ]))
        (throws (lkU [
          asFunc
          asVar
        ]))
        (passes (lkU [
          asVar
          (u "b" "extern int x; int fb(void) { return x; }")
        ]))
      ]
    )
    [
      true
      true
      true
    ]
  )
  (t "cc link 18: libc functions of the default host"
    [
      (runCalls libcUse [
        [ "t_strlen" ]
        [ "t_strcmp" ]
        [ "t_abs" ]
        [ "t_toupper" ]
        [ "t_memcpy" ]
        [ "t_memset" ]
        [ "nofile" ]
      ])
      (
        let
          r = runCalls libcUse [
            [ "m1" ]
            [ "m2" ]
            [ "m1" ]
          ];
          a = elemAt r 0;
          b = elemAt r 1;
          c = elemAt r 2;
        in
        [
          (a >= libcUse.__data.base + libcUse.__data.size)
          (b > a)
          (c > b)
        ]
      )
      (outOf libcUse [
        [ "say" ]
        [ "say" ]
      ])
    ]
    [
      [
        5
        (-1)
        5
        81
        121
        511
        12
      ]
      [
        true
        true
        true
      ]
      "hi\n!hi\n!"
    ]
  )
  (t "cc link 19: the platform layer: the clock and DG_DrawFrame over DG_ScreenBuffer and colors"
    [
      (ret platform "ticks" [ ])
      drawn.frameCount
      (map (elemAt (head drawn.frames).screen) [
        0
        1
        63999
      ])
      (elemAt (head drawn.frames).palette 7)
      (length (head drawn.frames).screen)
      (throws
        (afterCalls (lk [
          (u "a" "void DG_DrawFrame(void); void draw(void) { DG_DrawFrame(); }")
        ]) [ [ "draw" ] ]).mem
      )
      (passes (lk [ (u "a" "void DG_DrawFrame(void); void draw(void) { DG_DrawFrame(); }") ]).__data)
    ]
    [
      42
      1
      [
        7
        0
        9
      ]
      {
        r = 17;
        g = 34;
        b = 51;
      }
      64000
      true
      true
    ]
  )
  (t "cc link 20: the host state stays across bulk writes (storeRun and storeStride)"
    [
      (contains "M.storeRun" bulk.__units.a.nix)
      (contains "M.storeStride" bulk.__units.a.nix)
      bulkRun.mem.host.out
      (elemAt bulkRun.rets 5 - head bulkRun.rets)
      (M.loadByte bulkRun.mem (bulk.__data.symbols.small + 63))
      (M.loadByte bulkRun.mem (bulk.__data.symbols.big + 11 * 320))
    ]
    [
      true
      true
      "ab"
      16
      63
      1
    ]
  )
  (t "cc link 21: errno is placed when a unit uses it"
    [
      (hasAttr "errno" libcUse.__data.symbols)
      ((libcUse.__init M.empty).host.errnoAddr == libcUse.__data.symbols.errno)
      (hasAttr "errno" bulk.__data.symbols)
      (bulk.__init M.empty).host.errnoAddr
    ]
    [
      true
      true
      false
      0
    ]
  )
  (t "cc link 22: exit throws where it is reached and nowhere else"
    [
      (ret exiting "f" [ 0 ])
      (passes (exiting.f (exiting.__init M.empty) 0))
      (throws (exiting.f (exiting.__init M.empty) 1))
    ]
    [
      2
      true
      true
    ]
  )
  (t "cc link 23: C calls a variadic function of a host given by the caller"
    (
      let
        l = withHost [
          (u "a" ''
            int vh(int, ...);
            int none(void) { return vh(10); }
            int some(void) { char c = 3; return vh(10, 1, -2, c); }
          '')
        ];
        r = l.some (l.__init M.empty);
      in
      [
        (ret l "none" [ ])
        r.ret
        r.mem.host.seen
      ]
    )
    [
      10
      13
      [
        1
        (-2)
        3
      ]
    ]
  )
  (t "cc link 24: printf conversions of the variable arguments" formats (
    concatStringsSep "\n" [
      "plain"
      "5 -5 123456789 7000000000 ffffffffffffffff"
      "-1 4294967295 ffffffff"
      "3000000000 -1294967296"
      "200 -3 -300 65535"
      "0x1234 lit|abc Z%"
      "[   42][7   ][-0042][005][ ab][xy]"
      ""
    ]
  ))
  (t "cc link 25: the arguments are evaluated left to right with their side effects" order
    "1 20\n5 6 7\n9\n"
  )
  (t "cc link 26: snprintf, fprintf to stderr and stdout, sscanf into globals"
    [
      (
        let
          st = afterCalls strio [ [ "sn" ] ];
        in
        [
          (head st.rets)
          (map (i: M.loadByte st.mem (strio.__data.symbols.b + i)) [
            0
            1
            2
            3
          ])
        ]
      )
      (outOf strio [ [ "err" ] ])
      (runCalls strio [
        [ "sc" ]
        [ "ra" ]
        [ "rx" ]
      ])
    ]
    [
      [
        5
        [
          49
          50
          51
          0
        ]
      ]
      "e1;o2;"
      [
        2
        17
        171
      ]
    ]
  )
  (t "cc link 27: variadic calls in a loop and right of &&"
    [
      (outOf loops [ [ "run" ] ])
      (runCalls loops [
        [
          "ok"
          0
        ]
        [
          "ok"
          1
        ]
      ])
      (outOf loops [
        [
          "ok"
          0
        ]
        [
          "ok"
          1
        ]
      ])
    ]
    [
      "0,1,2,"
      [
        0
        1
      ]
      "y"
    ]
  )
  (t "cc link 28: a format that needs more arguments than given throws"
    [
      (throws (printed (printfSrc ''void run(void) { printf("%d %d", 1); }'')))
      (throws (
        outOf (withStd {
          "a.c" = ''
            #include <stdio.h>
            int a;
            void run(void) { sscanf("1 2", "%d %d", &a); }
          '';
        }) [ [ "run" ] ]
      ))
      (printed (printfSrc ''void run(void) { printf("%d", 1, 2); }''))
    ]
    [
      true
      true
      "1"
    ]
  )
  (t "cc link 29: variadic calls that stop: too few fixed arguments, floating-point, va_list" (
    map (s: throws (withStdWith { allowUndefined = true; } { "a.c" = printfSrc s; })) [
      "void run(void) { printf(); }"
      "int sn(char *b) { return snprintf(b, 4); }"
      "extern double d; void run(void) { printf(\"%f\", d); }"
      "struct s { int a; } g; void run(void) { printf(\"%d\", g); }"
      "void run(void) { vprintf(\"x\", (va_list)0); }"
      "void run(va_list ap) { vprintf(\"x\", ap); }"
      "int mine(int a, ...) { return a; }"
    ]
    ++ [
      (compileThrows ''int printf(const char *, ...); int f(void) { return printf("x"); }'')
      (passes (
        withStdWith { allowUndefined = true; } {
          "a.c" = printfSrc "extern int d; void run(void) { printf(\"%d\", d); }";
        }
      ))
    ]
  ) (genList (_: true) 9))
  (t "cc link 34: a host function declared with an 8-byte result or parameter"
    [
      (throws (lk [
        (u "a" "long long strlen(const char *); long long f(void) { return strlen(\"a\"); }")
      ]))
      (throws (lk [ (u "a" "int abs(long long); int f(void) { return abs(1); }") ]))
      (ret (lk [
        (u "a" "unsigned strlen(const char *); int f(void) { return strlen(\"ab\"); }")
      ]) "f" [ ])
    ]
    [
      true
      true
      2
    ]
  )
  (t "cc link 31: the layout of a unit reads no address of the variables it imports"
    [
      (passes layoutCheck.layout)
      (map (v: v.name) layoutCheck.layout.imports.vars)
      (map (v: v.size) layoutCheck.layout.imports.vars)
      (map (f: f.name) layoutCheck.layout.imports.funcs)
      (map (v: v.name) layoutCheck.layout.exports.vars)
      (map (f: f.name) layoutCheck.layout.exports.funcs)
      (throws layoutCheck.checked)
    ]
    [
      true
      [
        "arr"
        "c"
        "x"
      ]
      [
        0
        4
        4
      ]
      [
        "h"
        "k"
      ]
      [
        "p"
        "v"
      ]
      [
        "f"
        "g"
      ]
      true
    ]
  )
  (t "cc link 32: a call to an undefined internal function stops even if another unit has it"
    [
      (throws (lk [
        (u "a" "static int f(void); int g(void) { return f(); }")
        (u "b" "int f(void) { return 1; }")
      ]))
      (ret (lk [
        (u "a" "int f(void); int g(void) { return f(); }")
        (u "b" "int f(void) { return 1; }")
      ]) "g" [ ])
    ]
    [
      true
      1
    ]
  )
  (t "cc link 33: disagreeing declarations of an undefined name in a unit and between units"
    (
      let
        lkU = lkWith { allowUndefined = true; };
      in
      [
        (throws (lkU [
          (u "a" "int fa(void) { extern int x; return x; } int fb(void) { extern char x; return x; }")
        ]))
        (throws (lkU [ (u "a" "void fa(void) { extern int x; } void fb(void) { extern char x; }") ]))
        (throws (lkU [
          (u "a" "int fa(void) { int h(int); return h(1); } int fb(void) { int h(char); return h(1); }")
        ]))
        (passes (lkU [
          (u "a" "int fa(void) { extern int x; return x; } int fb(void) { extern int x; return x; }")
        ]))
        (lkU [ (u "a" "extern int x[]; int fa(void) { extern int x[3]; return x[0]; }") ]).__data.size
        (throws (lkU [
          (u "a" "extern int x; int fa(void) { return x; }")
          (u "b" "extern char x; int fb(void) { return x; }")
        ]))
        (throws (withHost [
          (u "a" "int twice(int); int fa(void) { return twice(1); }")
          (u "b" "int twice(char); int fb(void) { return twice(1); }")
        ]))
        (ret (withHost [
          (u "a" "int twice(int); int fa(void) { return twice(1); }")
          (u "b" "int twice(int); int fb(void) { return twice(2); }")
        ]) "fb" [ ])
      ]
    )
    [
      true
      true
      true
      true
      12
      true
      true
      4
    ]
  )
  (t "cc link 35: the nodes of a unit carry its name; tags and static locals keep their names"
    (
      let
        src = "struct { int v; } s; extern int x; int f(void) { static int n; return n + s.v + x; }";
        named = P.parseNamed "a" src;
        plain = P.parse src;
        checked = Ch.checkWith {
          dataBase = base;
          link.externAddr = _: 0;
        } named;
      in
      [
        (map (i: i.file or null) named.items)
        ((elemAt named.items 1).type.name == (elemAt plain.items 1).type.name)
        (elemAt named.items 1).type.name
        (attrNames (lkWith { allowUndefined = true; } [ (u "a" src) ]).__data.units.a.symbols)
        (attrNames (Cc.load "${src} int x;").__data.symbols)
        (map (v: v.file or null) checked.layout.imports.vars)
        (head checked.checked.funcs).file
      ]
    )
    [
      [
        "a"
        "a"
        "a"
        "a"
      ]
      true
      "(anonymous at 1:1)"
      [
        "f'n'1'61"
        "s"
      ]
      [
        "f'n'1'61"
        "s"
        "x"
      ]
      [ "a" ]
      "a"
    ]
  )
  (t "cc link 35: the tokens of a unit carry its name, which the errors of the lexer show"
    (
      let
        src = "int f(void)\n{\n  return \"a\" \"b\"[0]; /* x\n */ }\n";
      in
      [
        (Lx.lexNamed "a" src == map (k: k // { file = "a"; }) (Lx.lex src))
        (throws (Lx.lexNamed "a" "int f(void) { return 1.5; }"))
        (throws (lk [ (u "a" "int f(void) { return 1.5; }") ]))
      ]
    )
    [
      true
      true
      true
    ]
  )
  (t "cc link 31: switch conditions and sizeof operands that fold an imported address"
    [
      (runCalls folded [
        [ "s1" ]
        [ "s2" ]
        [ "s3" ]
      ])
      (passes foldedCheck.layout)
      foldedCheck.layout.size
      (map (v: v.name) foldedCheck.layout.imports.vars)
    ]
    [
      [
        2
        3
        8
      ]
      true
      8
      [ "x" ]
    ]
  )
  (t "cc link 31: in sizeof, an imported address folded to 0 is a null pointer constant"
    [
      (ret (lk [
        (u "a" nullFoldSrc)
        (u "b" "int x;")
      ]) "f" [ ])
      (passes nullFoldCheck.layout)
      nullFoldCheck.layout.size
    ]
    [
      8
      true
      8
    ]
  )
  (t "cc link: a declaration without a prototype agrees with a non-variadic definition"
    [
      (ret (lk [
        (u "a" "int h(); extern int (*hp)(); int (*hv)() = h; int get(void) { return hp == 0; }")
        (u "b" "int h(int a, int b) { return a + b; } int (*hp)(int, int);")
      ]) "get" [ ])
      (ret
        (lk [
          (u "a" "int h(); extern int (*hp)(); int (*hv)() = h; int get(void) { return hp == 0; }")
          (u "b" "int h(int a, int b) { return a + b; } int (*hp)(int, int);")
        ])
        "h"
        [
          2
          3
        ]
      )
      (ret (lk [
        (u "a" "void tick(); int ticks(void) { extern int n; tick(); tick(); return n; }")
        (u "b" "int n; void tick() { n = n + 1; }")
      ]) "ticks" [ ])
      (passes (lk [ (u "a" "void DG_Init(); void start(void) { DG_Init(); }") ]))
      (throws (lk [
        (u "a" "int tick(); int f(void) { return tick(); }")
        (u "b" "void tick() { }")
      ]))
      (throws (lk [
        (u "a" "extern int (*hp)(); int f(void) { return hp == 0; }")
        (u "b" "int (*hp)(int, ...);")
      ]))
      (throws (lk [
        (u "a" "extern int (*hp)(); int f(void) { return hp == 0; }")
        (u "b" "void (*hp)(int);")
      ]))
      (throws (lk [ (u "a" "void g(); int f(void) { g(1); return 0; } void g(int x) { }") ]))
    ]
    [
      1
      5
      2
      true
      true
      true
      true
      true
    ]
  )

  # Function pointers
  (t "cc link: a function declared without a prototype in one unit is called through its value"
    [
      (ret (lk [
        (u "a" "void h(); void (*hv)() = h; int box; int run(void) { hv(&box); return box; }")
        (u "b" "void h(int *p) { *p = 7; }")
      ]) "run" [ ])
      (contains "  vu = [\n    (throw \"cc: call through a null function pointer\")\n    f1\n  ];"
        (lk [
          (u "a" "void h(); void (*hv)() = h; int box; int run(void) { hv(&box); return box; }")
          (u "b" "void h(int *p) { *p = 7; }")
        ]).__tables.nix
      )
    ]
    [
      7
      true
    ]
  )
  (t "cc link: values of one external function are equal across units, of two static ones not"
    (
      let
        l = lk [
          (u "a" "int ext(void); static int st(void) { return 1; } int (*ea)(void) = ext; int (*sa)(void) = st;")
          (u "b" ''
            int ext(void) { return 5; }
            static int st(void) { return 2; }
            int (*eb)(void) = ext;
            int (*sb)(void) = st;
            extern int (*ea)(void);
            extern int (*sa)(void);
            int cmp(void) { return (ea == eb) * 10 + (sa == sb); }
            int calls(void) { return ea() * 100 + sa() * 10 + sb(); }
          '')
        ];
        m = l.__init M.empty;
        word = n: M.loadWord m l.__data.symbols.${n};
      in
      [
        (runCalls l [
          [ "cmp" ]
          [ "calls" ]
        ])
        (map word [
          "ea"
          "sa"
          "eb"
          "sb"
        ])
      ]
    )
    [
      [
        10
        512
      ]
      [
        1
        2
        1
        3
      ]
    ]
  )
  (t "cc link: the tables hold the functions of the shape and adapters for the others"
    (
      let
        l = lk [
          (u "a" ''
            int k(int a, int b);
            static int s1(int x) { return x * 3; }
            int (*p1)(int) = s1;
            int run(void) { int (*q)(int) = (int (*)(int))k; return p1(5) * 100 + q(7); }
          '')
          (u "b" "int k(int a, int b) { return a + b; }")
        ];
      in
      [
        (ret l "run" [ ])
        l.__tables.nix
      ]
    )
    [
      1507
      ''
        { X, U, B, R }:
        let
          inherit (builtins) bitAnd elemAt seq;
          f1 = (elemAt U 0).__static.s1;
          f2 = X.k;
        in
        {
          ss = [
            (throw "cc: call through a null function pointer")
            f1
            (mem: a0: f2 mem a0 0)
          ];
        }
      ''
    ]
  )
  (t "cc link: a function of the host or a variadic function used as a value throws"
    [
      (throws (lk [ (u "a" "int puts(const char *s); int (*p)(const char *) = puts;") ]))
      (passes (lk [ (u "a" "int puts(const char *s); int f(void) { return puts(\"x\"); }") ]))
      (throws (
        lkWith { allowUndefined = true; } [ (u "a" "int v(int a, ...); int (*p)(int, ...) = v;") ]
      ))
      (passes (
        lkWith { allowUndefined = true; } [ (u "a" "int v(int a, ...); int (*p)(int, ...) = 0;") ]
      ))
    ]
    [ true true true true ]
  )
  (t
    "cc link: a direct call through a declaration without a prototype needs the parameters of the definition"
    [
      (throws (lk [
        (u "a" "int tick(); int f(void) { return tick(); }")
        (u "b" "int tick(int a) { return a; }")
      ]))
      (ret (lk [
        (u "a" "int tick(); int f(void) { return tick(); }")
        (u "b" "int tick(void) { return 4; }")
      ]) "f" [ ])
      (passes (lk [
        (u "a" "int tick(); int (*t)() = tick;")
        (u "b" "int tick(int a) { return a; }")
      ]))
    ]
    [
      true
      4
      true
    ]
  )
  (t "cc link: a function used as a value that nothing defines"
    [
      (throws (lk [ (u "a" "void gone(void); void (*p)(void) = gone;") ]))
      (throws (lk [ (u "a" "static void gone(void); void (*p)(void) = gone; void f(void) { }") ]))
      (passes (
        lkWith { allowUndefined = true; } [
          (u "a" "void gone(void); void (*p)(void) = gone; int f(void) { return p != 0; }")
        ]
      ))
      (ret (lkWith { allowUndefined = true; } [
        (u "a" "void gone(void); void (*p)(void) = gone; int f(void) { return p != 0; }")
      ]) "f" [ ])
      (throws (
        afterCalls (lkWith { allowUndefined = true; } [
          (u "a" "void gone(void); void (*p)(void) = gone; int f(void) { p(); return 0; }")
        ]) [ [ "f" ] ]
      ))
    ]
    [ true true true 1 true ]
  )
  (t "cc link: a single file numbers and calls like a link of it alone"
    (
      let
        src = ''
          int add1(int x) { return x + 1; }
          static int dbl(int x) { return x * 2; }
          char buf[sizeof(&add1)];
          int (*ops[3])(int) = { dbl, 0, add1 };
          int pick(int i, int x) { if (ops[i] == 0) return -1; return ops[i](x) + sizeof buf; }
          int num(int i) { return (int)ops[i]; }
        '';
        calls = [
          [
            "pick"
            0
            5
          ]
          [
            "pick"
            1
            5
          ]
          [
            "pick"
            2
            5
          ]
          [
            "num"
            0
          ]
          [
            "num"
            2
          ]
        ];
        single =
          let
            f = Cc.load src;
          in
          map (c: (foldl' (g: a: g a) (f.${head c} (f.__data.init M.empty)) (tail c)).ret) calls;
      in
      [
        single
        (runCalls (lk [ (u "a" src) ]) calls)
      ]
    )
    [
      [
        14
        (-1)
        10
        1
        2
      ]
      [
        14
        (-1)
        10
        1
        2
      ]
    ]
  )
  (t "cc link: a local buffer of snprintf and & of locals for sscanf"
    (
      let
        st = afterCalls frameIo [
          [
            "sn"
            65536
          ]
          [ "sc" ]
        ];
      in
      [
        st.rets
        (genList (i: M.loadByte st.mem (65536 + i)) 8)
      ]
    )
    [
      [
        7
        17171
      ]
      [
        60
        52
        50
        58
        111
        107
        62
        0
      ]
    ]
  )
  (t "cc link: frames are placed as in a single file"
    [
      (frameUnit.__data.units.a.symbols == (Cc.load frameUnitSrc).__data.symbols)
      (length (attrNames frameUnit.__data.units.a.symbols))
      (runCalls frameUnit [
        [
          "f"
          5
        ]
        [ "g" ]
      ])
    ]
    [
      true
      4
      [
        5
        7
      ]
    ]
  )
  (t "cc link: initialized locals as the format, arguments and buffer of snprintf"
    (
      let
        st = afterCalls frameInitIo [
          [
            "fm"
            65536
            42
          ]
        ];
      in
      [
        st.rets
        (genList (i: M.loadByte st.mem (65536 + i)) 12)
        (length frameInitIo.__data.strings)
      ]
    )
    [
      [ 8 ]
      [
        60
        52
        50
        124
        121
        101
        115
        62
        0
        0
        0
        0
      ]
      2
    ]
  )
]
