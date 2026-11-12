# Variable-size ANSI still image of a frame record of scaffold/platform.nix.
#
#   fit    : { columns; lines; } -> { cols; rows; }
#   render : { screen; palette; cols; rows; } -> string
#
# fit picks the largest picture that keeps the 16:5 proportions of a 320x200 screen drawn
# with cells twice as tall as wide and leaves two lines free for the prompt:
# cols = min columns (div ((lines - 2) * 16) 5), rows = div (cols * 5) 16, each at least 1.
#
# render draws cols x rows cells of the upper half block U+2580 from the 320x200 palette
# indices in screen (row-major) and the 256-entry palette of { r; g; b; }. For cell (c, r)
# the upper half is the box of pixels x0 <= x < x1, y0 <= y < ym and the lower half the
# box x0 <= x < x1, ym <= y < y1, with
#   x0 = div (c * 320) cols, x1 = max (x0 + 1) (div ((c + 1) * 320) cols),
#   ya = div (r * 200) rows, y1 = min 200 (max (ya + 2) (div ((r + 1) * 200) rows)),
#   y0 = min ya (y1 - 2), ym = div (y0 + y1) 2.
# The foreground is the average color of the upper box and the background that of the
# lower one (each component: sum divided by the pixel count, rounded down), in 24-bit
# color (ESC[38;2;r;g;bm / ESC[48;2;r;g;bm). Every row ends with ESC[0m and a newline.
# At 160 x 50 the output is byte for byte that of scaffold/render.nix.
let
  inherit (builtins)
    concatStringsSep
    div
    elemAt
    foldl'
    genList
    ;

  width = 320;
  height = 200;

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

  # Average color "r;g;b" of the box x0 <= x < x1, y0 <= y < y1.
  average =
    screen: palette: x0: x1: y0: y1:
    let
      xs = genList (i: x0 + i) (x1 - x0);
      ys = genList (i: y0 + i) (y1 - y0);
      sum =
        c:
        foldl' (
          acc: y: foldl' (a: x: a + (elemAt palette (elemAt screen (y * width + x))).${c}) acc xs
        ) 0 ys;
      avg = c: toString (div (sum c) ((x1 - x0) * (y1 - y0)));
    in
    "${avg "r"};${avg "g"};${avg "b"}";

  cell =
    screen: palette: cols: rows: c: r:
    let
      x0 = div (c * width) cols;
      x1 = max (x0 + 1) (div ((c + 1) * width) cols);
      ya = div (r * height) rows;
      y1 = min height (max (ya + 2) (div ((r + 1) * height) rows));
      y0 = min ya (y1 - 2);
      ym = div (y0 + y1) 2;
      box = average screen palette x0 x1;
    in
    "${esc}[38;2;${box y0 ym}m${esc}[48;2;${box ym y1}m▀";

  render =
    {
      screen,
      palette,
      cols,
      rows,
    }:
    let
      line = r: concatStringsSep "" (genList (c: cell screen palette cols rows c r) cols) + reset + "\n";
    in
    concatStringsSep "" (genList line rows);
in
{
  inherit fit render;
}
