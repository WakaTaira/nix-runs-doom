# Shared memory image of the execution-strategy spike (M0). Every variant starts
# from `image { ... }` and is checked with `screenBytes` and `result`.
#
#   PARAMS 0x00100000  4 words  frames, columns, spans, muls
#   SCREEN 0x00110000  64000 B  zero
#   CMAP   0x00120000  256 B    cmap[i]   = (i*7 + 3) mod 256
#   COLSRC 0x00121000  128 B    colsrc[i] = (i*13) mod 256
#   FLAT   0x00122000  4096 B   flat[i]   = (i*31 + i/64) mod 256
#   RESULT 0x00123000  1 word   zero
#
# Zero regions are not written: unwritten memory reads as 0.
let
  M = import ../../lib/mem.nix;
  inherit (builtins) foldl' genList;

  PARAMS = 1048576;
  SCREEN = 1114112;
  CMAP = 1179648;
  COLSRC = 1183744;
  FLAT = 1187840;
  RESULT = 1191936;

  screenSize = 64000;

  # Store `count` bytes produced by `byteAt` from `base` (word-aligned, count a
  # multiple of 4), one little-endian word at a time.
  storeBytes =
    mem: base: count: byteAt:
    foldl' (
      m: k:
      let
        i = 4 * k;
      in
      M.storeWord m (base + i) (
        byteAt i + 256 * byteAt (i + 1) + 65536 * byteAt (i + 2) + 16777216 * byteAt (i + 3)
      )
    ) mem (genList (k: k) (count / 4));

  mod256 = x: x - x / 256 * 256;

  cmapByte = i: mod256 (i * 7 + 3);
  colsrcByte = i: mod256 (i * 13);
  flatByte = i: mod256 (i * 31 + i / 64);

  image =
    {
      frames,
      columns,
      spans,
      muls,
    }:
    let
      withParams = foldl' (m: p: M.storeWord m (PARAMS + 4 * p.i) p.v) M.empty [
        {
          i = 0;
          v = frames;
        }
        {
          i = 1;
          v = columns;
        }
        {
          i = 2;
          v = spans;
        }
        {
          i = 3;
          v = muls;
        }
      ];
      withCmap = storeBytes withParams CMAP 256 cmapByte;
      withColsrc = storeBytes withCmap COLSRC 128 colsrcByte;
    in
    storeBytes withColsrc FLAT 4096 flatByte;

  screenBytes = mem: genList (i: M.loadByte mem (SCREEN + i)) screenSize;

  result = mem: M.loadWord mem RESULT;
in
{
  inherit
    PARAMS
    SCREEN
    CMAP
    COLSRC
    FLAT
    RESULT
    screenSize
    image
    screenBytes
    result
    ;
}
