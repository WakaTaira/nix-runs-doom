# ANSI still image of a frame record of scaffold/platform.nix.
#
#   import ./render.nix { screen; palette; } -> string
#
# screen is the 320x200 palette indices (list of 64000 bytes, row-major) and palette
# 256 { r; g; b; }. The image is 160 columns x 50 rows of the upper half block U+2580:
# the character at (col, row) covers pixels x = 2col .. 2col+1, y = 4row .. 4row+3; its
# foreground is the average RGB of the upper 2x2 pixels (y = 4row, 4row+1) and its
# background that of the lower 2x2 pixels (y = 4row+2, 4row+3), in 24-bit color
# (ESC[38;2;r;g;bm / ESC[48;2;r;g;bm). A terminal cell is about twice as tall as wide,
# so each half is a square 2x2 block and the picture keeps the screen's proportions.
# Every row ends with ESC[0m and a newline.
{ screen, palette }:
let
  inherit (builtins)
    concatStringsSep
    div
    elemAt
    genList
    ;

  width = 320;
  cols = 160;
  rows = 50;

  esc = builtins.fromJSON ''"\u001b"'';
  reset = "${esc}[0m";

  rgbAt = x: y: elemAt palette (elemAt screen (y * width + x));

  # Average color of the 2x2 pixels whose top-left corner is (x, y), as "r;g;b".
  block =
    x: y:
    let
      ps = [
        (rgbAt x y)
        (rgbAt (x + 1) y)
        (rgbAt x (y + 1))
        (rgbAt (x + 1) (y + 1))
      ];
      avg = c: toString (div (builtins.foldl' (acc: p: acc + p.${c}) 0 ps) 4);
    in
    "${avg "r"};${avg "g"};${avg "b"}";

  cell =
    col: row:
    let
      x = 2 * col;
      y = 4 * row;
    in
    "${esc}[38;2;${block x y}m${esc}[48;2;${block x (y + 2)}m▀";

  line = row: concatStringsSep "" (genList (col: cell col row) cols) + reset + "\n";
in
concatStringsSep "" (genList line rows)
