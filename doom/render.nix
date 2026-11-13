# Variable-size ANSI still images of a frame record of scaffold/platform.nix.
#
#   fit       : { columns; lines; } -> { cols; rows; }
#   render    : { screen; palette; cols; rows; } -> string
#   renderMem : { mem; screenAddr; palette; x; y; width; height; cols; rows; } -> string
#
# fit picks the largest picture that keeps the 16:5 proportions of a 320x200 screen drawn
# with cells twice as tall as wide and leaves two lines free for the prompt:
# cols = min columns (div ((lines - 2) * 16) 5), rows = div (cols * 5) 16, each at least 1.
#
# renderMem draws the rectangle of the screen with its top left pixel at (x, y), width
# pixels wide and height pixels high (height >= 2, the rectangle inside the 320x200
# screen), as cols x rows cells of the upper half block U+2580. The screen is the 320x200
# palette indices (row-major) at the address screenAddr of the memory mem, and palette is
# 256 { r; g; b; }. Only the rows and columns of the rectangle are read, each pixel row
# through the leaves of the memory trie that it touches (lib/mem.nix readLeaves). For
# cell (c, r) the upper half is the box of pixels x0 <= px < x1, y + y0 <= py < y + ym and
# the lower half the box x0 <= px < x1, y + ym <= py < y + y1, with
#   x0 = x + div (c * width) cols, x1 = max (x0 + 1) (x + div ((c + 1) * width) cols),
#   ya = div (r * height) rows, y1 = min height (max (ya + 2) (div ((r + 1) * height) rows)),
#   y0 = min ya (y1 - 2), ym = div (y0 + y1) 2.
# The foreground is the average color of the upper box and the background that of the
# lower one (each component: sum divided by the pixel count, rounded down), in 24-bit
# color (ESC[38;2;r;g;bm / ESC[48;2;r;g;bm). Every row ends with ESC[0m and a newline.
# When cols = width and 2 * rows = height every half is one pixel, and the cells are
# looked up from strings made once per palette entry, with the same output.
#
# render is renderMem over the whole screen (x = 0, y = 0, width = 320, height = 200)
# with the palette indices given as the list screen (64000 bytes) instead of the memory.
# At 160 x 50 the output is byte for byte that of scaffold/render.nix.
#
# A box sum is taken over palette colors packed into one integer with 20 bits per component,
# which adds the three components in one pass; this is exact up to 4096 pixels per box
# (255 * 4096 < 2^20), and larger boxes are summed component by component.
let
  M = import ../lib/mem.nix;
  inherit (builtins)
    bitAnd
    concatStringsSep
    div
    elemAt
    foldl'
    genList
    ;

  screenWidth = 320;
  screenHeight = 200;

  esc = builtins.fromJSON ''"\u001b"'';
  reset = "${esc}[0m";

  min = a: b: if a < b then a else b;
  max = a: b: if a > b then a else b;

  fit =
    { columns, lines }:
    let
      cols = max 1 (min columns (div ((lines - 2) * 16) 5));
    in
    {
      inherit cols;
      rows = max 1 (div (cols * 5) 16);
    };

  # Palette colors packed into one integer, r + g * 2^20 + b * 2^40. Summing packed colors
  # adds the three components at once as long as no component sum reaches 2^20.
  shift = 1048576;
  packLimit = 4096;
  pack = color: color.r + color.g * shift + color.b * shift * shift;

  rgb = color: "${toString color.r};${toString color.g};${toString color.b}";

  # What a picture needs from the palette, computed once per picture: the packed colors and
  # the two halves of a one-pixel cell per entry.
  paintOf = palette: {
    inherit palette;
    packed = map pack palette;
    upper = map (color: "${esc}[38;2;${rgb color}m") palette;
    lower = map (color: "${esc}[48;2;${rgb color}m▀") palette;
  };

  # A pixel row is a function from the screen x to the palette index of the pixel.

  # Average color "r;g;b" of the box x0 <= x < x1 over the pixel rows rows (functions of
  # x) from the packed colors; the box has at most packLimit pixels (255 * 4096 < 2^20).
  packedAverage =
    packed: rows: x0: x1:
    let
      xs = genList (i: x0 + i) (x1 - x0);
      sum = foldl' (acc: row: foldl' (a: x: a + elemAt packed (row x)) acc xs) 0 rows;
      n = (x1 - x0) * builtins.length rows;
      b = div sum (shift * shift);
      g = div (sum - b * shift * shift) shift;
      r = sum - b * shift * shift - g * shift;
    in
    "${toString (div r n)};${toString (div g n)};${toString (div b n)}";

  # The same average for any box size, component by component from the palette itself.
  plainAverage =
    palette: rows: x0: x1:
    let
      xs = genList (i: x0 + i) (x1 - x0);
      sum = c: foldl' (acc: row: foldl' (a: x: a + (elemAt palette (row x)).${c}) acc xs) 0 rows;
      avg = c: toString (div (sum c) ((x1 - x0) * builtins.length rows));
    in
    "${avg "r"};${avg "g"};${avg "b"}";

  # Average color of a box: packed sums when the box is small enough, plain sums otherwise.
  average =
    paint: rows: x0: x1:
    if (x1 - x0) * builtins.length rows <= packLimit then
      packedAverage paint.packed rows x0 x1
    else
      plainAverage paint.palette rows x0 x1;

  # The pixel rows y0 <= y < y1 of a picture.
  rowsBetween =
    rowOf: y0: y1:
    genList (i: rowOf (y0 + i)) (y1 - y0);

  # Line r of a picture with boxes of any size (see the header); the pixel rows of the
  # line are made once and shared by its cells.
  averagedLine =
    paint: rowOf: rect: cols: rows: r:
    let
      ya = div (r * rect.height) rows;
      y1 = min rect.height (max (ya + 2) (div ((r + 1) * rect.height) rows));
      y0 = min ya (y1 - 2);
      ym = div (y0 + y1) 2;
      upperRows = rowsBetween rowOf (rect.y + y0) (rect.y + ym);
      lowerRows = rowsBetween rowOf (rect.y + ym) (rect.y + y1);
      cell =
        c:
        let
          x0 = rect.x + div (c * rect.width) cols;
          x1 = max (x0 + 1) (rect.x + div ((c + 1) * rect.width) cols);
        in
        "${esc}[38;2;${average paint upperRows x0 x1}m${esc}[48;2;${average paint lowerRows x0 x1}m▀";
    in
    concatStringsSep "" (genList cell cols) + reset + "\n";

  # Line r of a picture whose halves are single pixels: rows 2r and 2r + 1 of the rectangle.
  pixelLine =
    paint: rowOf: rect: r:
    let
      top = rowOf (rect.y + 2 * r);
      bottom = rowOf (rect.y + 2 * r + 1);
      cell = c: elemAt paint.upper (top (rect.x + c)) + elemAt paint.lower (bottom (rect.x + c));
    in
    concatStringsSep "" (genList cell rect.width) + reset + "\n";

  # The picture of the rectangle rect = { x; y; width; height; } as cols x rows cells.
  draw =
    paint: rowOf: rect: cols: rows:
    let
      line =
        if cols == rect.width && 2 * rows == rect.height then
          pixelLine paint rowOf rect
        else
          averagedLine paint rowOf rect cols rows;
    in
    concatStringsSep "" (genList line rows);

  # Pixel row y of the list screen.
  listRow =
    screen: y:
    let
      base = y * screenWidth;
    in
    x: elemAt screen (base + x);

  # Pixel row y of the screen at screenAddr in mem, read only over x0 <= x < x0 + width
  # through the leaves that those bytes touch.
  memRow =
    mem: screenAddr: x0: width: y:
    let
      start = screenAddr + y * screenWidth + x0;
      leaves = M.readLeaves mem start width;
      offset = bitAnd start 255 - x0;
    in
    x: M.leafByte leaves (offset + x);

  render =
    {
      screen,
      palette,
      cols,
      rows,
    }:
    draw (paintOf palette) (listRow screen) {
      x = 0;
      y = 0;
      width = screenWidth;
      height = screenHeight;
    } cols rows;

  renderMem =
    {
      mem,
      screenAddr,
      palette,
      x,
      y,
      width,
      height,
      cols,
      rows,
    }:
    draw (paintOf palette) (memRow mem screenAddr x width) {
      inherit
        x
        y
        width
        height
        ;
    } cols rows;
in
{
  inherit fit render renderMem;
}
