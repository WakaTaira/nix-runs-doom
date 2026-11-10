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
# one `//` per leaf instead of one path copy per byte; storeStride does the same
# with one `//` per 16 KiB node for a stride of 256 or more, is storeRun for a
# stride of 1, and folds storeByte for a stride of 2 to 255. readPages hands out the
# leaves over a byte range as lazy lists of bytes, for code that reads a table many
# times without walking the trie for each byte.
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

  # Install a leaf (256 B) or a level-2 node (16 KiB) at the address a, forcing
  # the path like the other stores do.
  putLeaf =
    m: a: leaf:
    let
      a0 = rootKey a;
      a1 = midKey a;
      n0 = m.${a0} or { };
      n1 = n0.${a1} or { };
      n1' = n1 // {
        ${elemAt keyList (bitAnd (div a 256) 63)} = leaf;
      };
      n0' = n0 // {
        ${a1} = n1';
      };
    in
    seq leaf (seq n1' (seq n0' (m // { ${a0} = n0'; })));

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

  # nw whole words starting at the word-aligned byte address wa; the word k comes
  # from vals[i0 + 4k .. i0 + 4k + 3]. One `//` per leaf; the leaves are folded with
  # foldl', so the evaluation depth does not grow with nw.
  storeWords =
    m: wa: nw: vals: i0:
    let
      byteAt = i: bitAnd (elemAt vals i) 255;
      first =
        let
          w0 = bitAnd (div wa 4) 63;
        in
        if nw < 64 - w0 then nw else 64 - w0;
      # Leaf c holds the words from offset `startOf c` on: the first one up to the end
      # of its leaf, every other one a whole leaf or the rest.
      leaves = if nw <= 0 then 0 else 1 + div (nw - first + 63) 64;
      startOf = c: if c == 0 then 0 else first + 64 * (c - 1);
      leaf =
        m0: c:
        let
          k0 = startOf c;
          cnt =
            if c == 0 then
              first
            else if nw - k0 < 64 then
              nw - k0
            else
              64;
          la = wa + 4 * k0;
          w0 = bitAnd (div la 4) 63;
          part = listToAttrs (
            genList (j: {
              name = elemAt keyList (w0 + j);
              value =
                let
                  i = i0 + 4 * (k0 + j);
                in
                byteAt i + 256 * byteAt (i + 1) + 65536 * byteAt (i + 2) + 16777216 * byteAt (i + 3);
            }) cnt
          );
        in
        seq (forceAll part) (putLeaf m0 la (leafAt m0 la // part));
    in
    foldl' leaf m (genList (c: c) leaves);

  # The low 8 bits of vals[i] are written to address a + i for i = 0 .. n-1.
  # The caller guarantees n >= 0 and, for n >= 1, 0 <= a and a + n <= 2^32. Only
  # the first n elements of vals are forced.
  storeRun =
    m: a: n: vals:
    let
      h0 = bitAnd (4 - bitAnd a 3) 3;
      head = if h0 > n then n else h0;
      nw = div (n - head) 4;
      tailStart = head + 4 * nw;
      bytes =
        m0: from: to:
        foldl' (mm: i: storeByte mm (a + i) (elemAt vals i)) m0 (genList (i: from + i) (to - from));
    in
    bytes (storeWords (bytes m 0 head) (a + head) nw vals head) tailStart n;

  # The low 8 bits of vals[i] are written to address a + i * stride for
  # i = 0 .. n-1. The caller guarantees n >= 0, stride >= 1 and, for n >= 1,
  # 0 <= a and a + (n-1) * stride < 2^32. Only the first n elements of vals are forced.
  # stride 1 is storeRun, and stride 2 .. 255 folds storeByte. For stride >= 256 every
  # byte lies in its own leaf, so one `//` per touched leaf and one per 16 KiB node
  # suffice; the nodes are folded with foldl' (their first indices found by
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
          part = listToAttrs (
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
            ) (countAt i)
          );
        in
        seq (forceAll part) (putNode m0 ai (old // part));
    in
    if stride == 1 then
      storeRun m a n vals
    else if stride < 256 then
      foldl' (mm: i: storeByte mm (a + i * stride) (elemAt vals i)) m (genList (i: i) n)
    else if n <= 0 then
      m
    else
      foldl' node m starts;
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
    ;
}
