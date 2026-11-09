# Tests for the host-call libc (lib/libc.nix), called directly as pure functions on a
# `world` without the CPU, and for the register ABI of the host-call dispatch
# (lib/hostcall.nix) on both execution paths of lib/cpu.nix.
let
  A = import ../lib/ascii.nix;
  B = import ../lib/bits.nix;
  C = import ../lib/cpu.nix;
  D = import ../lib/dsl.nix;
  H = import ../lib/hostcall.nix;
  L = import ../lib/libc.nix;
  M = import ../lib/mem.nix;
  inherit (builtins)
    bitAnd
    concatStringsSep
    elemAt
    filter
    foldl'
    genList
    hasAttr
    length
    map
    match
    ;

  # Store a NUL-terminated string at address a.
  putStr =
    mem: a: s:
    let
      bs = A.bytesOf s ++ [ 0 ];
    in
    foldl' (m: i: M.storeByte m (a + i) (elemAt bs i)) mem (genList (i: i) (length bs));

  putStrs = mem: strs: foldl' (m: e: putStr m e.addr e.str) mem strs;

  putWords =
    mem: a: ws:
    foldl' (m: i: M.storeWord m (a + 4 * i) (elemAt ws i)) mem (genList (i: i) (length ws));

  getStr =
    mem: a:
    concatStringsSep "" (genList (i: A.chr (M.loadByte mem (a + i))) (L.strlen (world mem) [ a ]).ret);

  getBytes =
    mem: a: n:
    genList (i: M.loadByte mem (a + i)) n;

  world =
    mem:
    L.mkWorld {
      inherit mem;
      heapBase = 65536;
    };

  # Call a libc function and keep its return value.
  ret =
    mem: name: args:
    (L.${name} (world mem) args).ret;

  sign =
    x:
    if x == 0 then
      0
    else if B.toSigned x < 0 then
      -1
    else
      1;

  # A signed 64-bit integer as { lo; hi; } (two's complement words).
  s64 =
    x:
    let
      lo = B.u32 x;
    in
    {
      inherit lo;
      hi = B.u32 ((x - lo) / B.two32);
    };
  toS64 = v: (if v.hi >= B.sign32 then v.hi - B.two32 else v.hi) * B.two32 + v.lo;

  # --- memcpy / memset ---

  memStrs = putStrs M.empty [
    {
      addr = 4096;
      str = "abcdefghijklmnopqrstuvwxyz";
    }
  ];
  # Unaligned source and destination, crossing several words.
  copied =
    (L.memcpy (world memStrs) [
      8195
      4097
      13
    ]).world.mem;
  # Overlapping move to a higher address.
  moved =
    (L.memmove (world memStrs) [
      4099
      4096
      10
    ]).world.mem;
  set =
    (L.memset (world memStrs) [
      4097
      (B.u32 (-1))
      21
    ]).world.mem;

  # --- strings ---

  strMem = putStrs M.empty [
    {
      addr = 256;
      str = "hello";
    }
    {
      addr = 512;
      str = "help";
    }
    {
      addr = 768;
      str = "HeLLo";
    }
    {
      addr = 1025;
      str = "";
    }
  ];

  # --- vsnprintf ---

  fmtMem =
    let
      m = putStrs M.empty [
        {
          addr = 1024;
          str = "%d|%5d|%-5s|%08x|%c|%%|%lld";
        }
        {
          addr = 2048;
          str = "ab";
        }
      ];
      ll = s64 (-1234567890123);
    in
    # The long long is aligned to 8 bytes: 0x3014 is skipped.
    putWords m 12288 [
      (B.u32 (-42))
      42
      2048
      48879
      90
      0
      ll.lo
      ll.hi
    ];
  fmtExpected = "-42|   42|ab   |0000beef|Z|%|-1234567890123";
  snprintfTo =
    n:
    let
      r = L.vsnprintf (world fmtMem) [
        16384
        n
        1024
        12288
      ];
    in
    {
      ret = r.ret;
      text = getStr r.world.mem 16384;
    };

  # --- malloc / realloc ---

  heap =
    let
      w0 = world M.empty;
      r1 = L.malloc w0 [ 10 ];
      r2 = L.malloc r1.world [ 3 ];
      r3 = L.malloc r2.world [ 100 ];
    in
    [
      r1.ret
      r2.ret
      r3.ret
    ];

  realloced =
    let
      r1 = L.malloc (world M.empty) [ 5 ];
      w1 = r1.world // {
        mem = putStr r1.world.mem r1.ret "hey!";
      };
      r2 = L.realloc w1 [
        r1.ret
        64
      ];
    in
    {
      moved = r2.ret != r1.ret;
      text = getStr r2.world.mem r2.ret;
      size = M.loadWord r2.world.mem (r2.ret - 4);
    };

  # --- 64-bit division ---

  divCase =
    a: b:
    let
      args = [
        (s64 a)
        (s64 b)
      ];
    in
    [
      (toS64 (L.__divdi3 (world M.empty) args).ret)
      (toS64 (L.__moddi3 (world M.empty) args).ret)
    ];

  # --- fopen / fread on a hand-made WAD ---

  # "IWAD", 1 lump, directory at 16.
  wadHex = "4957414401000000" + "10000000" + "deadbeef";
  wadWorld = L.mkWorld {
    mem = putStrs M.empty [
      {
        addr = 256;
        str = "/data/doom1.wad";
      }
      {
        addr = 512;
        str = "rb";
      }
      {
        addr = 768;
        str = "default.cfg";
      }
    ];
    heapBase = 65536;
    errnoAddr = 4096;
    wad = {
      hex = wadHex;
      size = 16;
    };
  };
  wadOpen = L.fopen wadWorld [
    256
    512
  ];
  # Read to an unaligned buffer, then the next 8 bytes after a seek.
  wadRead = L.fread wadOpen.world [
    8193
    1
    4
    wadOpen.ret
  ];
  wadSeek = L.fseek wadRead.world [
    wadOpen.ret
    8
    0
  ];
  wadRead2 = L.fread wadSeek.world [
    12288
    4
    3
    wadOpen.ret
  ];
  cfgOpen = L.fopen wadWorld [
    768
    512
  ];

  # Every table entry other than DG_* needs a body.
  missing = filter (n: match "DG_.*" n == null && !(hasAttr n L)) (map (e: e.name) H.table);

  # --- Host-call ABI through the CPU ---

  # Run an eDSL program (EBREAK appended) with the libc host calls, without and with
  # a code region covering the image, as tests/paths.nix does (its runner has no way
  # to pass a host). The result is the code-region run, or a mismatch marker when the
  # two paths disagree on the observed fields.
  runHost =
    program:
    let
      prog = D.assemble { } [
        program
        D.ebreak
      ];
      host = {
        call = H.dispatch L;
        world = removeAttrs (world M.empty) [
          "mem"
          "out"
        ];
      };
      runWith =
        code:
        C.run { maxSteps = 1000; } (
          C.mkState {
            mem = D.toMemory M.empty prog;
            pc = prog.entry;
            inherit code host;
          }
        );
      observe = s: {
        inherit (s)
          pc
          regs
          out
          halted
          exitCode
          count
          ;
      };
      slow = runWith null;
      fast = runWith { inherit (prog) base size; };
    in
    if observe slow == observe fast then
      fast
    else
      { regs = "the paths with and without a code region disagree"; };

  hostStrlen =
    with D;
    runHost [
      (la a0 "msg")
      (li a7 H.byName.strlen.num)
      ecall
      ebreak
      (label "msg")
      (string "hello, host")
      (bytes [ 0 ])
    ];

  # An i64 argument takes two registers and an i64 result returns in a0 / a1.
  hostUdiv =
    let
      n = s64 10000000007;
    in
    with D;
    runHost [
      (li a0 n.lo)
      (li a1 n.hi)
      (li a2 3)
      (li a3 0)
      (li a7 H.byName.__udivdi3.num)
      ecall
    ];
in
[
  {
    name = "hostcall: strlen through ecall returns in a0 (both paths)";
    got = C.getReg hostStrlen 10;
    expected = 11;
  }
  {
    name = "hostcall: i64 arguments and result in register pairs (both paths)";
    got = [
      (C.getReg hostUdiv 10)
      (C.getReg hostUdiv 11)
    ];
    expected = [
      3333333335
      0
    ];
  }
  {
    name = "libc: every table entry has a body";
    got = missing;
    expected = [ ];
  }
  {
    name = "libc: memcpy unaligned";
    got = getStr copied 8195;
    expected = "bcdefghijklmn";
  }
  {
    name = "libc: memmove overlapping";
    got = getStr moved 4096;
    expected = "abcabcdefghijnopqrstuvwxyz";
  }
  {
    name = "libc: memset";
    got = [
      (M.loadByte set 4096)
      (M.loadByte set 4097)
      (M.loadByte set 4117)
      (M.loadByte set 4118)
    ];
    expected = [
      97
      255
      255
      119
    ];
  }
  {
    name = "libc: strlen";
    got = [
      (ret strMem "strlen" [ 256 ])
      (ret strMem "strlen" [ 512 ])
      (ret strMem "strlen" [ 1025 ])
    ];
    expected = [
      5
      4
      0
    ];
  }
  {
    name = "libc: strcmp";
    got = [
      (sign (
        ret strMem "strcmp" [
          256
          256
        ]
      ))
      (sign (
        ret strMem "strcmp" [
          256
          512
        ]
      ))
      (sign (
        ret strMem "strcmp" [
          512
          256
        ]
      ))
      (sign (
        ret strMem "strcmp" [
          256
          1025
        ]
      ))
    ];
    expected = [
      0
      (-1)
      1
      1
    ];
  }
  {
    name = "libc: strcasecmp";
    got = [
      (sign (
        ret strMem "strcasecmp" [
          256
          768
        ]
      ))
      (sign (
        ret strMem "strcmp" [
          256
          768
        ]
      ))
      (sign (
        ret strMem "strcasecmp" [
          768
          512
        ]
      ))
    ];
    expected = [
      0
      1
      (-1)
    ];
  }
  {
    name = "libc: vsnprintf formats";
    got = snprintfTo 100;
    expected = {
      ret = 43;
      text = fmtExpected;
    };
  }
  {
    name = "libc: vsnprintf truncates";
    got = snprintfTo 5;
    expected = {
      ret = 43;
      text = "-42|";
    };
  }
  {
    name = "libc: malloc aligns to 16 and grows";
    got = {
      aligned = map (p: bitAnd p 15) heap;
      ascending = elemAt heap 0 + 10 <= elemAt heap 1 && elemAt heap 1 + 3 <= elemAt heap 2;
      aboveBase = elemAt heap 0 >= 65536;
    };
    expected = {
      aligned = [
        0
        0
        0
      ];
      ascending = true;
      aboveBase = true;
    };
  }
  {
    name = "libc: realloc keeps the contents";
    got = realloced;
    expected = {
      moved = true;
      text = "hey!";
      size = 64;
    };
  }
  {
    name = "libc: __divdi3 / __moddi3 signs";
    got = [
      (divCase 10000000007 3)
      (divCase (-10000000007) 3)
      (divCase 10000000007 (-3))
      (divCase (-10000000007) (-3))
    ];
    expected = [
      [
        3333333335
        2
      ]
      [
        (-3333333335)
        (-2)
      ]
      [
        (-3333333335)
        2
      ]
      [
        3333333335
        (-2)
      ]
    ];
  }
  {
    name = "libc: fopen and fread the WAD";
    got = {
      handle = wadOpen.ret;
      read = wadRead.ret;
      magic = getStr wadRead.world.mem 8193;
      seek = wadSeek.ret;
      # 3 items of 4 bytes requested, 8 bytes left: 2 whole items.
      read2 = wadRead2.ret;
      bytes = getBytes wadRead2.world.mem 12288 8;
      tell = (L.ftell wadRead2.world [ wadOpen.ret ]).ret;
    };
    expected = {
      handle = 16;
      read = 4;
      magic = "IWAD";
      seek = 0;
      read2 = 2;
      bytes = [
        16
        0
        0
        0
        222
        173
        190
        239
      ];
      tell = 16;
    };
  }
  {
    name = "libc: fopen of another file fails with ENOENT";
    got = {
      handle = cfgOpen.ret;
      errno = M.loadWord cfgOpen.world.mem 4096;
    };
    expected = {
      handle = 0;
      errno = 2;
    };
  }
]
