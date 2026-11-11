# Tests for the linker of the Nix C compiler (cc/link.nix, cc.linkSources, cc.linkFiles)
# and the link mode of the checker (cc/check.nix). Units are small C sources; expected
# values follow C and the placement rules of cc/link.nix, worked out by hand. Errors are
# checked to be thrown (tryEval does not show the message); each sits next to a valid
# variant of the same input. The number in a test name is the one of the work order.
let
  Cc = import ../cc;
  Ch = import ../cc/check.nix;
  Lk = import ../cc/link.nix;
  P = import ../cc/parse.nix;
  M = import ../lib/mem.nix;
  B = import ../lib/bits.nix;
  inherit (builtins)
    attrNames
    concatStringsSep
    deepSeq
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
  contains = needle: s: builtins.replaceStrings [ needle ] [ "" ] s != s;

  # The return values of the calls ([ fn arg ... ]) of the linked program l, made in order
  # on one memory, starting from __init; null for a void function.
  runCalls =
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
    (foldl' step {
      mem = l.__init M.empty;
      rets = [ ];
    } calls).rets;
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
        vh = {
          nargs = 1;
          variadic = true;
          call = w: args: va: {
            world = w;
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
      (throws (linkBox [
        "c.c"
        "b.c"
      ]))
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
]
