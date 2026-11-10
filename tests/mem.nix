# Tests for lib/mem.nix. The byte, half and word accessors are compared with a naive
# reference written with loadWordAt / storeWordAt only (the definitions that
# lib/mem.nix had before its table-driven rewrite). storeRun and storeStride are
# compared with a fold of storeByte, and readPages and readLeaves with loadByte.
let
  M = import ../lib/mem.nix;
  B = import ../lib/bits.nix;
  inherit (builtins)
    bitAnd
    bitOr
    concatMap
    div
    elemAt
    foldl'
    genList
    length
    ;

  # --- Reference implementation (word accessors only) ---
  R = rec {
    loadByte = m: a: bitAnd (div (M.loadWordAt m (div a 4)) (B.pow2 (8 * bitAnd a 3))) 255;
    loadHalf =
      m: a:
      if bitAnd a 3 != 3 then
        bitAnd (div (M.loadWordAt m (div a 4)) (B.pow2 (8 * bitAnd a 3))) 65535
      else
        loadByte m a + 256 * loadByte m (B.add a 1);
    loadWord =
      m: a:
      if bitAnd a 3 == 0 then M.loadWordAt m (div a 4) else loadHalf m a + 65536 * loadHalf m (B.add a 2);
    replaceField =
      old: shift: widthMask: v:
      bitOr (bitAnd old (B.mask32 - widthMask * B.pow2 shift)) (bitAnd v widthMask * B.pow2 shift);
    storeByte =
      m: a: v:
      M.storeWordAt m (div a 4) (replaceField (M.loadWordAt m (div a 4)) (8 * bitAnd a 3) 255 v);
    storeHalf =
      m: a: v:
      if bitAnd a 3 != 3 then
        M.storeWordAt m (div a 4) (replaceField (M.loadWordAt m (div a 4)) (8 * bitAnd a 3) 65535 v)
      else
        storeByte (storeByte m a v) (B.add a 1) (div v 256);
    storeWord =
      m: a: v:
      if bitAnd a 3 == 0 then
        M.storeWordAt m (div a 4) v
      else
        storeHalf (storeHalf m a v) (B.add a 2) (div v 65536);
  };

  # Deterministic 32-bit pattern for a word index.
  pattern = w: bitAnd (w * 2654435761 + 12345) B.mask32;

  # Memory with a patterned word at every word covering [a - 8, a + 8] for each a.
  filled =
    addrs:
    foldl' (
      m: a:
      foldl' (
        mm: k:
        let
          w = div (B.add a (k * 4)) 4;
        in
        M.storeWordAt mm w (pattern w)
      ) m (genList (k: k - 2) 5)
    ) M.empty addrs;

  # Addresses around the boundaries of leaves (256 B), level-2 nodes (16 KiB),
  # 1 MiB root entries and the end of the 32-bit space, where the last leaf, node and
  # root entry start at 2^32 - 256, 2^32 - 16384 and 2^32 - 2^20. The end itself needs
  # no entry: B.add wraps, so the addresses around 0 include 2^32 - 5 .. 2^32 - 1 (an
  # entry 2^32 would repeat those of 0).
  boundaries =
    concatMap
      (
        b:
        map (d: B.add b d) [
          (-5)
          (-4)
          (-3)
          (-2)
          (-1)
          0
          1
          2
          3
          4
          5
        ]
      )
      [
        0
        256
        16384
        1048576
        5242880
        2147483648
        4293918720
        4294950912
        4294967040
      ];
  accessAddrs = boundaries ++ [
    4660
    4661
    4662
    4663
  ];

  base = filled accessAddrs;
  values = [
    0
    1
    255
    256
    65535
    65536
    2864434397
    4294967295
  ];

  probes = a: genList (k: B.add a (k - 8)) 17;
  view = m: a: map (R.loadByte m) (probes a);

  loadCase = a: {
    name = "mem: loads at ${toString a} match the reference";
    got = [
      (M.loadByte base a)
      (M.loadHalf base a)
      (M.loadWord base a)
    ];
    expected = [
      (R.loadByte base a)
      (R.loadHalf base a)
      (R.loadWord base a)
    ];
  };

  storeCase = a: {
    name = "mem: stores at ${toString a} match the reference";
    got = map (
      v:
      map (f: view (f base a v) a) [
        M.storeByte
        M.storeHalf
        M.storeWord
      ]
    ) values;
    expected = map (
      v:
      map (f: view (f base a v) a) [
        R.storeByte
        R.storeHalf
        R.storeWord
      ]
    ) values;
  };

  # --- storeRun / storeStride ---
  # Value i: sometimes above 255 so that only the low 8 bits may be written.
  valueAt = i: (i + 1) * 65793 + 7 * i * i;
  valsFor = n: genList valueAt n;
  # The values valAt i for i < n, followed by an element that must never be evaluated.
  longValsWith =
    valAt: n: genList valAt n ++ [ (throw "storeRun/storeStride forced an element beyond n") ];

  targets =
    a: stride: n:
    genList (i: a + i * stride) n;
  prefilled =
    a: stride: n:
    filled (targets a stride n);
  viewAll =
    m: a: stride: n:
    concatMap (t: view m t) (targets a stride n ++ [ a ]);
  foldStoreWith =
    valAt: m: a: stride: n:
    foldl' (mm: i: R.storeByte mm (a + i * stride) (valAt i)) m (genList (i: i) n);

  # storeRun (kind "run") or storeStride of the values valAt i, on memory prefilled
  # around every target, compared with the fold of the reference storeByte: the bytes
  # around the targets and the whole tree.
  bulkCaseWith =
    label: valAt: kind: a: stride: n:
    let
      m = prefilled a stride n;
      vals = longValsWith valAt n;
      got = if kind == "run" then M.storeRun m a n vals else M.storeStride m a stride n vals;
      want = foldStoreWith valAt m a stride n;
    in
    {
      name = "mem: ${kind}${label} a=${toString a} stride=${toString stride} n=${toString n} matches storeByte fold";
      got = [
        (viewAll got a stride n)
        (got == want)
      ];
      expected = [
        (viewAll want a stride n)
        true
      ];
    };

  bulkCase = bulkCaseWith "" valueAt;

  runStarts = [
    4096
    4097
    4098
    4099
    250
    251
    252
    253
    16378
    16379
    16380
    16381
    1048570
    1048571
    1048572
    1048573
  ];
  runCounts = [
    0
    1
    3
    4
    5
    300
  ];
  strides = [
    1
    2
    255
    256
    320
    16384
    70000
  ];
  strideCounts = [
    0
    1
    3
    5
    300
  ];
  strideStarts = [
    4096
    4099
    16380
    1048570
  ];

  runCases = concatMap (a: map (bulkCase "run" a 1) runCounts) runStarts;
  strideCases = concatMap (
    s: concatMap (a: map (bulkCase "stride" a s) strideCounts) strideStarts
  ) strides;

  # The last byte is at 2^32 - 1.
  topCases =
    map (n: bulkCase "run" (4294967296 - n) 1 n) [
      1
      3
      4
      5
      300
    ]
    ++ map (s: bulkCase "stride" (4294967295 - 4 * s) s 5) [
      2
      255
      256
      70000
    ];

  # Values that are negative or above 255, of which only the low 8 bits are written.
  oddValues = [
    (-1)
    (-256)
    (-257)
    256
    511
    (-2)
    1000
  ];
  oddAt = i: elemAt oddValues (i - 7 * div i 7);
  # Words at an end of the run only (inside one word), whole words only, both, and
  # the direct path of storeStride (one 16 KiB node).
  oddCases = [
    (bulkCaseWith " (odd values)" oddAt "run" 4097 1 3)
    (bulkCaseWith " (odd values)" oddAt "run" 4096 1 8)
    (bulkCaseWith " (odd values)" oddAt "run" 4097 1 13)
    (bulkCaseWith " (odd values)" oddAt "stride" 4101 320 20)
  ];

  # storeRun over memory filled around every target (so every word that the run
  # touches holds a pattern): starts with the low 2 bits 0 to 3, counts that end inside
  # one word or in each position of a word, runs across a leaf, a 16 KiB node and a
  # 1 MiB root entry, and runs whose last byte is 2^32 - 1. Counts that runCases already
  # tests at the same starts are left out.
  denseCounts = builtins.filter (n: !builtins.elem n runCounts) (
    genList (i: i + 1) 9
    ++ [
      13
      255
      256
      257
      600
    ]
  );
  denseRunCases =
    concatMap (a: map (bulkCaseWith " (dense)" valueAt "run" a 1) denseCounts) [
      4096
      4097
      4098
      4099
    ]
    ++
      concatMap
        (
          a:
          map (bulkCaseWith " (dense)" valueAt "run" a 1) [
            9
            600
          ]
        )
        [
          4093
          16381
          1048573
        ]
    ++ map (n: bulkCaseWith " (dense)" valueAt "run" (4294967296 - n) 1 n) [
      2
      9
      13
      257
    ];

  # storeStride with stride >= 256: all bytes in one 16 KiB node, the last byte alone
  # at the start of the next node, and the first byte alone at the end of the previous
  # node (when the others fit in one node), over prefilled memory.
  nodeStrides = [
    256
    320
    4096
  ];
  nodeCounts = [
    1
    2
    51
    52
  ];
  nodeAt0 = 2097152;
  nodeCases = concatMap (
    s:
    concatMap (n: [
      (bulkCaseWith " (node)" valueAt "stride" (nodeAt0 + 7) s n)
      (bulkCaseWith " (node)" valueAt "stride" (nodeAt0 + 16384 - (n - 1) * s) s n)
      (bulkCaseWith " (node)" valueAt "stride" (nodeAt0 + 3 * 16384 - 1) s n)
    ]) nodeCounts
  ) nodeStrides;

  # With n = 0 the address and the stride are not used and no element is forced.
  emptyCases = [
    {
      name = "mem: storeRun with n = 0 returns the memory unchanged for any address";
      got = M.storeRun base (-12345) 0 [ (throw "forced") ] == base;
      expected = true;
    }
    {
      name = "mem: storeStride with n = 0 returns the memory unchanged for any address and stride";
      got = M.storeStride base 99999999999 0 0 [ (throw "forced") ] == base;
      expected = true;
    }
  ];

  # Writing 5 bytes over existing content keeps the bytes that are not written.
  keepCase = {
    name = "mem: storeRun keeps the bytes around the written range";
    got =
      let
        m = M.storeRun base 4661 5 (valsFor 5);
      in
      map (a: M.loadByte m a) [
        4659
        4660
        4661
        4662
        4663
        4664
        4665
        4666
      ];
    expected =
      map (a: R.loadByte base a) [
        4659
        4660
      ]
      ++ map (i: bitAnd (valueAt i) 255) [
        0
        1
        2
        3
        4
      ]
      ++ [ (R.loadByte base 4666) ];
  };

  # Long runs evaluate without a recursion as deep as n (recursive versions overflowed
  # the stack from about n = 860000 for storeRun and n = 3400 for storeStride with
  # stride 16384). The bytes at both ends, in the middle and just past the last one.
  deepCase =
    kind: a: stride: n:
    let
      m =
        if kind == "run" then
          M.storeRun M.empty a n (valsFor n)
        else
          M.storeStride M.empty a stride n (valsFor n);
      at = [
        0
        1
        (div n 2)
        (n - 2)
        (n - 1)
      ];
    in
    {
      name = "mem: ${kind} stride=${toString stride} n=${toString n} evaluates without deep recursion";
      got = map (i: M.loadByte m (a + i * stride)) at ++ [ (M.loadByte m (a + n * stride)) ];
      expected = map (i: bitAnd (valueAt i) 255) at ++ [ 0 ];
    };
  deepCases = [
    (deepCase "run" 1048577 1 1000000)
    (deepCase "stride" 1048577 16384 5000)
  ];

  # --- readPages ---
  # Patterned words over three windows: around the leaf at 0x1000 and the 16 KiB node at
  # 0x4000, around 1 MiB, and below 2^32. Every eighth leaf stays unwritten.
  pageWindows = [
    {
      lo = 3840;
      hi = 21248;
    }
    {
      lo = 1040384;
      hi = 1057024;
    }
    {
      lo = 4294950656;
      hi = 4294967296;
    }
  ];
  pageMem = foldl' (
    m: win:
    foldl' (
      mm: k:
      let
        a = win.lo + 4 * k;
        w = div a 4;
      in
      if bitAnd (div a 256) 7 == 3 then mm else M.storeWordAt mm w (pattern w)
    ) m (genList (k: k) (div (win.hi - win.lo) 4))
  ) M.empty pageWindows;

  # Byte base + o read from the pages, as readPages lays them out.
  pageByte =
    pages: base: o:
    let
      q = bitAnd base 255 + o;
    in
    elemAt (elemAt pages (div q 256)) (bitAnd q 255);
  # The number of leaves that [base, base + len) touches: the first one and every one that
  # starts inside the range.
  leavesOf =
    base: len: length (builtins.filter (o: o == 0 || bitAnd (base + o) 255 == 0) (genList (o: o) len));

  pageCase =
    m: base: len:
    let
      pages = M.readPages m base len;
    in
    {
      name = "mem: readPages base=${toString base} len=${toString len} matches loadByte";
      got = [
        (length pages)
        (map length pages)
        (genList (pageByte pages base) len)
      ];
      expected = [
        (leavesOf base len)
        (map (_: 256) pages)
        (genList (o: M.loadByte m (base + o)) len)
      ];
    };
  # The pairs [ base len ] of the readPages and readLeaves tests.
  pageRanges = [
    # low 8 bits 0, 1 and 255; lengths 1, 128, 256, 257, 4096 and 16384
    [
      4096
      1
    ]
    [
      4097
      128
    ]
    [
      4351
      128
    ]
    [
      4096
      256
    ]
    [
      4097
      256
    ]
    [
      4351
      257
    ]
    [
      4096
      4096
    ]
    [
      4351
      4096
    ]
    [
      4097
      16384
    ]
    # across the 16 KiB node at 0x4000 and the root entry at 1 MiB
    [
      16284
      257
    ]
    [
      16383
      4096
    ]
    [
      1048575
      128
    ]
    [
      1040385
      16384
    ]
    # unwritten: a whole region, and a range from an unwritten leaf into a written one
    [
      3145729
      300
    ]
    [
      4865
      300
    ]
    # the last byte at 2^32 - 1
    [
      4294967295
      1
    ]
    [
      4294967040
      256
    ]
    [
      4294967039
      257
    ]
    [
      4294950912
      16384
    ]
  ];

  pageCases = map (x: pageCase pageMem (builtins.head x) (elemAt x 1)) pageRanges;

  # readLeaves gives the same leaves as readPages, as leaf sets read with leafByte.
  leafCase =
    m: base: len:
    let
      leaves = M.readLeaves m base len;
    in
    {
      name = "mem: readLeaves base=${toString base} len=${toString len} with leafByte matches loadByte";
      got = [
        (length leaves)
        (genList (o: M.leafByte leaves (bitAnd base 255 + o)) len)
      ];
      expected = [
        (leavesOf base len)
        (genList (o: M.loadByte m (base + o)) len)
      ];
    };
  leafCases = map (x: leafCase pageMem (builtins.head x) (elemAt x 1)) pageRanges;

  # A memory built directly, whose word 2 of the leaf at 0x1000 and word 0 of the leaf at
  # 0x1100 fail when read: readPages reads neither for the lengths and for byte 0x1001.
  lazyMem = {
    "0" = {
      "0" = {
        "16" = {
          "0" = 43776;
          "2" = throw "readPages read word 2 of the leaf at 0x1000";
        };
        "17" = {
          "0" = throw "readPages read word 0 of the leaf at 0x1100";
        };
      };
    };
  };
  lazyCase =
    let
      pages = M.readPages lazyMem 4096 512;
    in
    {
      name = "mem: readPages reads only the bytes that are used";
      got = [
        (length pages)
        (length (elemAt pages 0))
        (length (elemAt pages 1))
        (elemAt (elemAt pages 0) 1)
      ];
      expected = [
        2
        256
        256
        171
      ];
    };

  # A memory built directly, whose leaf at 0x1100 and word 2 of the leaf at 0x1000 fail
  # when taken: readLeaves takes neither for the length and for byte 0x1001.
  lazyLeafMem = {
    "0" = {
      "0" = {
        "16" = {
          "0" = 43776;
          "2" = throw "readLeaves read word 2 of the leaf at 0x1000";
        };
        "17" = throw "readLeaves took the leaf at 0x1100";
      };
    };
  };
  lazyLeafCase =
    let
      leaves = M.readLeaves lazyLeafMem 4096 512;
    in
    {
      name = "mem: readLeaves takes only the leaves that are used";
      got = [
        (length leaves)
        (M.leafByte leaves 1)
      ];
      expected = [
        2
        171
      ];
    };
in
map loadCase accessAddrs
++ map storeCase accessAddrs
++ runCases
++ strideCases
++ topCases
++ emptyCases
++ [ keepCase ]
++ deepCases
++ pageCases
++ [ lazyCase ]
++ oddCases
++ denseRunCases
++ nodeCases
++ leafCases
++ [ lazyLeafCase ]
