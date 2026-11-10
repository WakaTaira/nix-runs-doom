# Memory: persistent trie over 4-byte words, 4 levels of 12 + 6 + 6 + 6 bits
# over the 30-bit word address.
#   level 0: sparse 4096-ary root, bits 18..29 of w (one entry per touched 1 MiB)
#   level 1: 64-ary, bits 12..17 (16 KiB regions)
#   level 2: 64-ary, bits 6..11 (256 B regions)
#   level 3: 64-ary leaf, bits 0..5
# Unwritten regions are represented by missing children and read as 0 (sparse).
# An update copies only the 4 nodes on the path. The root grows only with the
# number of touched MiB, so it stays small for working sets of a few MiB.
# See bench/memlayout.nix for the comparison against other layouts.
# Byte-granular accessors resolve the two lower keys, the byte divisor and the
# keep mask with one lookup in a 16384-entry table indexed by the low 14 bits of
# the byte address; storeByte walks the path once. storeRun writes many bytes with
# one `//` per leaf instead of one path copy per byte, merging the words at both ends
# with their old bytes; storeStride does the same with one `//` per 16 KiB node for a
# stride of 256 or more (directly when the bytes lie in one node), is storeRun for a
# stride of 1, and folds storeByte for a stride of 2 to 255. readPages hands out the
# leaves over a byte range as lazy lists of bytes, for code that reads a table many
# times without walking the trie for each byte; readLeaves hands out the leaf sets
# themselves, read byte by byte with leafByte, for code that reads a table a few times.
let
  inherit (builtins)
    bitAnd
    div
    seq
    genList
    elemAt
    toString
    bitOr
    foldl'
    listToAttrs
    attrValues
    genericClosure
    ;

  rootKeys = genList toString 4096;
  keyList = genList toString 64;

  pairList = genList (i: {
    hi = elemAt keyList (div i 64);
    lo = elemAt keyList (bitAnd i 63);
  }) 4096;

  empty = { };

  # w < 2^30, so w / 2^18 < 4096 needs no mask.
  loadWordAt =
    m: w:
    let
      p = elemAt pairList (bitAnd w 4095);
    in
    (((m.${elemAt rootKeys (div w 262144)} or { }).${elemAt keyList (bitAnd (div w 4096) 63)} or { })
      .${p.hi} or { }
    ).${p.lo} or 0;

  storeWordAt =
    m: w: v:
    let
      p = elemAt pairList (bitAnd w 4095);
      a0 = elemAt rootKeys (div w 262144);
      a1 = elemAt keyList (bitAnd (div w 4096) 63);
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      n2 = n1.${p.hi} or { };
      n2' = n2 // {
        ${p.lo} = v;
      };
      n1' = n1 // {
        ${p.hi} = n2';
      };
      n0' = n0 // {
        ${a1} = n1';
      };
    in
    seq v (seq n2' (seq n1' (seq n0' (m // { ${a0} = n0'; }))));
  B = import ./bits.nix;

  # Indexed by the low 14 bits of a byte address: the keys of the level-2 node and
  # of the leaf word, the divisor of the byte inside the word, and the mask that
  # keeps the other three bytes of the word.
  byteDivisors = [
    1
    256
    65536
    16777216
  ];
  byteTable = genList (
    i:
    let
      w = div i 4;
      d = elemAt byteDivisors (bitAnd i 3);
    in
    {
      hi = elemAt keyList (div w 64);
      lo = elemAt keyList (bitAnd w 63);
      inherit d;
      keep = B.mask32 - 255 * d;
    }
  ) 16384;

  # Keys of the root and of the level-1 node for a byte address (< 2^32).
  rootKey = a: elemAt rootKeys (div a 1048576);
  midKey = a: elemAt keyList (bitAnd (div a 16384) 63);

  # The word holding byte address a (a is not necessarily a multiple of 4).
  wordOf =
    m: a: p:
    (((m.${rootKey a} or { }).${midKey a} or { }).${p.hi} or { }).${p.lo} or 0;

  # Byte-addressed accessors (little-endian).
  loadByte =
    m: a:
    let
      p = elemAt byteTable (bitAnd a 16383);
    in
    bitAnd (div (wordOf m a p) p.d) 255;

  loadHalf =
    m: a:
    if bitAnd a 3 != 3 then
      bitAnd (div (loadWordAt m (div a 4)) (B.pow2 (8 * bitAnd a 3))) 65535
    else
      loadByte m a + 256 * loadByte m (B.add a 1);

  loadWord =
    m: a:
    if bitAnd a 3 == 0 then
      wordOf m a (elemAt byteTable (bitAnd a 16383))
    else
      loadHalf m a + 65536 * loadHalf m (B.add a 2);

  # Replace the field of width widthMask starting at bit `shift` with v.
  replaceField =
    old: shift: widthMask: v:
    bitOr (bitAnd old (B.mask32 - widthMask * B.pow2 shift)) (bitAnd v widthMask * B.pow2 shift);

  # Store the word nv(old word) at the byte address a, forcing the path.
  storeWordWith =
    m: a: nv:
    let
      p = elemAt byteTable (bitAnd a 16383);
      a0 = rootKey a;
      a1 = midKey a;
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      n2 = n1.${p.hi} or { };
      v = nv p (n2.${p.lo} or 0);
      n2' = n2 // {
        ${p.lo} = v;
      };
      n1' = n1 // {
        ${p.hi} = n2';
      };
      n0' = n0 // {
        ${a1} = n1';
      };
    in
    seq v (seq n2' (seq n1' (seq n0' (m // { ${a0} = n0'; }))));

  # Store the aligned word v at the byte address a.
  storeAligned =
    m: a: v:
    let
      p = elemAt byteTable (bitAnd a 16383);
      a0 = rootKey a;
      a1 = midKey a;
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      n2' = (n1.${p.hi} or { }) // {
        ${p.lo} = v;
      };
      n1' = n1 // {
        ${p.hi} = n2';
      };
      n0' = n0 // {
        ${a1} = n1';
      };
    in
    seq v (seq n2' (seq n1' (seq n0' (m // { ${a0} = n0'; }))));

  storeByte =
    m: a: v:
    storeWordWith m a (p: old: bitOr (bitAnd old p.keep) (bitAnd v 255 * p.d));

  storeHalf =
    m: a: v:
    if bitAnd a 3 != 3 then
      let
        w = div a 4;
      in
      storeWordAt m w (replaceField (loadWordAt m w) (8 * bitAnd a 3) 65535 v)
    else
      storeByte (storeByte m a v) (B.add a 1) (div v 256);

  storeWord =
    m: a: v:
    if bitAnd a 3 == 0 then
      storeAligned m a v
    else
      storeHalf (storeHalf m a v) (B.add a 2) (div v 65536);

  leafAt =
    m: a: ((m.${rootKey a} or { }).${midKey a} or { }).${elemAt keyList (bitAnd (div a 256) 63)} or { };

  nodeAt = m: a: (m.${rootKey a} or { }).${midKey a} or { };

  # Install a level-2 node (16 KiB) at the address a, forcing the path like the other
  # stores do.
  putNode =
    m: a: node:
    let
      a0 = rootKey a;
      n0 = m.${a0} or { };
      n0' = n0 // {
        ${midKey a} = node;
      };
    in
    seq node (seq n0' (m // { ${a0} = n0'; }));

  # The 256 bytes of a leaf in address order, as a lazy list. The first 256 entries of
  # byteTable give the word key and the divisor of a byte offset inside a leaf.
  leafBytes =
    leaf:
    genList (
      i:
      let
        p = elemAt byteTable i;
      in
      bitAnd (div (leaf.${p.lo} or 0) p.d) 255
    ) 256;

  # The leaves (256 B) that the bytes [base, base + len) touch, from the first one on,
  # each as the list of its 256 bytes. Byte base + o is element bitAnd q 255 of leaf
  # div q 256, with q = bitAnd base 255 + o. The caller guarantees len >= 1, 0 <= base
  # and base + len - 1 < 2^32. Both lists are lazy: a leaf or a byte is read when used.
  readPages =
    m: base: len:
    let
      first = div base 256;
    in
    genList (j: leafBytes (leafAt m ((first + j) * 256))) (div (base + len - 1) 256 - first + 1);

  forceAll = s: foldl' (acc: x: seq x acc) 0 (attrValues s);

  # Replace the leaf (256 B) at the byte address a with f applied to it (a missing leaf
  # is { }), walking the path once and forcing it like the other stores do.
  modifyLeaf =
    m: a: f:
    let
      a0 = rootKey a;
      a1 = midKey a;
      k2 = elemAt keyList (bitAnd (div a 256) 63);
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      leaf = f (n1.${k2} or { });
      n1' = n1 // {
        ${k2} = leaf;
      };
      n0' = n0 // {
        ${a1} = n1';
      };
    in
    seq leaf (seq n1' (seq n0' (m // { ${a0} = n0'; })));

  # The same for the level-2 node (16 KiB) at the byte address a.
  modifyNode =
    m: a: f:
    let
      a0 = rootKey a;
      a1 = midKey a;
      n0 = m.${a0} or { };
      node = f (n0.${a1} or { });
      n0' = n0 // {
        ${a1} = node;
      };
    in
    seq node (seq n0' (m // { ${a0} = n0'; }));

  # The word at the word address w after writing the low 8 bits of vals[i] to the byte
  # address a + i for i = 0 .. n-1: a word inside the run is built from vals alone, a
  # word at an end of the run keeps the bytes of old outside it.
  runWord =
    a: n: vals: old: w:
    let
      i = 4 * w - a;
      byte = j: bitAnd (elemAt vals (i + j)) 255;
      part = j: d: if i + j >= 0 && i + j < n then byte j * d else bitAnd old (255 * d);
    in
    if i >= 0 && i + 4 <= n then
      byte 0 + 256 * byte 1 + 65536 * byte 2 + 16777216 * byte 3
    else
      part 0 1 + part 1 256 + part 2 65536 + part 3 16777216;

  # The leaf old with its words ws .. we (word addresses inside it) replaced by those of
  # the run (see runWord), the new words forced.
  runLeaf =
    a: n: vals: ws: we: old:
    let
      part = listToAttrs (
        genList (
          j:
          let
            key = elemAt keyList (bitAnd (ws + j) 63);
          in
          {
            name = key;
            value = runWord a n vals (old.${key} or 0) (ws + j);
          }
        ) (we - ws + 1)
      );
    in
    seq (forceAll part) (old // part);

  # The low 8 bits of vals[i] are written to address a + i for i = 0 .. n-1.
  # The caller guarantees n >= 0 and, for n >= 1, 0 <= a and a + n <= 2^32. Only
  # the first n elements of vals are forced. Each touched leaf is updated with one `//`
  # (the words at both ends merged with their old bytes); the leaves are folded with
  # foldl', so the evaluation depth does not grow with n.
  storeRun =
    m: a: n: vals:
    if n <= 0 then
      m
    else
      let
        wFirst = div a 4;
        wLast = div (a + n - 1) 4;
        lFirst = div wFirst 64;
        lLast = div wLast 64;
        leaf =
          m0: l:
          modifyLeaf m0 (l * 256) (
            runLeaf a n vals (if l == lFirst then wFirst else l * 64) (
              if l == lLast then wLast else l * 64 + 63
            )
          );
      in
      if lFirst == lLast then
        leaf m lFirst
      else
        foldl' leaf m (genList (j: lFirst + j) (lLast - lFirst + 1));

  # The leaves of the node old that the bytes vals[i .. i + cnt - 1] go to, at the
  # addresses ai + j * stride (j < cnt) inside the node, with stride >= 256: one leaf
  # each, as a set from the leaf keys to the new leaves.
  strideLeaves =
    old: ai: stride: vals: i: cnt:
    listToAttrs (
      genList (
        j:
        let
          p = elemAt byteTable (bitAnd (ai + j * stride) 16383);
          leaf = old.${p.hi} or { };
          nv = bitOr (bitAnd (leaf.${p.lo} or 0) p.keep) (bitAnd (elemAt vals (i + j)) 255 * p.d);
        in
        {
          name = p.hi;
          value = seq nv (leaf // { ${p.lo} = nv; });
        }
      ) cnt
    );

  # The low 8 bits of vals[i] are written to address a + i * stride for
  # i = 0 .. n-1. The caller guarantees n >= 0, stride >= 1 and, for n >= 1,
  # 0 <= a and a + (n-1) * stride < 2^32. Only the first n elements of vals are forced.
  # stride 1 is storeRun, and stride 2 .. 255 folds storeByte. For stride >= 256 every
  # byte lies in its own leaf, so one `//` per touched leaf and one per 16 KiB node
  # suffice. When all the addresses lie in one node, that node is updated directly;
  # otherwise the nodes are folded with foldl' (their first indices found by
  # genericClosure), so the evaluation depth does not grow with n.
  storeStride =
    m: a: stride: n: vals:
    let
      # The number of bytes from index i on that lie in the 16 KiB node of byte i.
      countAt =
        i:
        let
          ai = a + i * stride;
          inNode = div ((div ai 16384 + 1) * 16384 - ai + stride - 1) stride;
        in
        if inNode < n - i then inNode else n - i;
      starts = map (x: x.key) (genericClosure {
        startSet = [ { key = 0; } ];
        operator =
          x:
          let
            next = x.key + countAt x.key;
          in
          if next < n then [ { key = next; } ] else [ ];
      });
      node =
        m0: i:
        let
          ai = a + i * stride;
          old = nodeAt m0 ai;
          part = strideLeaves old ai stride vals i (countAt i);
        in
        seq (forceAll part) (putNode m0 ai (old // part));
      # All n addresses lie in the node of a.
      inOneNode =
        old:
        let
          part = strideLeaves old a stride vals 0 n;
        in
        seq (forceAll part) (old // part);
    in
    if stride == 1 then
      storeRun m a n vals
    else if stride < 256 then
      foldl' (mm: i: storeByte mm (a + i * stride) (elemAt vals i)) m (genList (i: i) n)
    else if n <= 0 then
      m
    else if div a 16384 == div (a + (n - 1) * stride) 16384 then
      modifyNode m a inOneNode
    else
      foldl' node m starts;

  # The leaves (256 B) that the bytes [base, base + len) touch, from the first one on, as
  # a lazy list of the leaf sets themselves: a leaf is taken from the trie when used.
  # The caller guarantees len >= 1, 0 <= base and base + len - 1 < 2^32.
  readLeaves =
    m: base: len:
    let
      first = div base 256;
    in
    genList (j: leafAt m ((first + j) * 256)) (div (base + len - 1) 256 - first + 1);

  # Byte base + o (0 <= o < len) of the leaves = readLeaves m base len, with
  # q = bitAnd base 255 + o: byte bitAnd q 255 of leaf div q 256 (0 when unwritten).
  leafByte =
    leaves: q:
    let
      p = elemAt byteTable (bitAnd q 255);
    in
    bitAnd (div ((elemAt leaves (div q 256)).${p.lo} or 0) p.d) 255;
in
{
  inherit
    empty
    loadWordAt
    storeWordAt
    loadByte
    loadHalf
    loadWord
    storeByte
    storeHalf
    storeWord
    storeRun
    storeStride
    readPages
    readLeaves
    leafByte
    ;
}
