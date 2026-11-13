# The picture of a frame record of scaffold/platform.nix for a terminal: the whole screen,
# or, while the 3D view is on, Doom's view window with the status bar under it.
#
#   blocksFor : cols -> blocks
#   picture   : { symbols; windowed; cols; rows; } -> frame -> string
#
# blocksFor is the least screen size (Doom's screenblocks) whose view window, 32 * blocks
# pixels wide, has at least cols columns, kept within 3 .. 10: the window is then drawn
# with one column of pixels or more per cell and no wider than needed. The cost of Doom's
# 3D drawing grows with the width of the window (one column of wall, floor and sprite
# drawing per pixel column), so a window as wide as the terminal saves the work of the
# columns that a full-screen picture would average away.
#
# picture draws the frame cols x rows cells large (doom/render.nix fit) from frame.mem,
# frame.screenAddr and frame.palette, with the addresses of Doom's variables in symbols
# (__data.symbols of the link). Without windowed, or when the 3D view is not on (see
# viewOn), it is the whole 320x200 screen (doom/render.nix renderMem), the same picture
# as render of the screen bytes. Otherwise it is, from the top:
#   - the view window, scaledviewwidth x viewheight pixels at (viewwindowx, viewwindowy),
#     as c columns x max 1 (div (viewheight * c) (2 * scaledviewwidth)) rows;
#   - unless viewheight is 200 (screen size 11, where ST_Drawer draws no bar), the status
#     bar, the rows 168 .. 199 of the screen, as c columns x max 1 (div (32 * c) 640)
#     rows.
# c is cols when the two fit in rows lines; else it is the largest width that keeps the
# proportions of both and fits them in rows lines, so both shrink by the same ratio.
#
# Messages of the heads-up display (the line at the top left, y 0 .. 7, which lies
# outside a window smaller than screen size 10) are not drawn: whether one is shown is
# message_on of hu_stuff.c, which is static and so not in __data.symbols.
let
  R = import ./render.nix;
  M = import ../lib/mem.nix;
  inherit (builtins) div;

  min = a: b: if a < b then a else b;
  max = a: b: if a > b then a else b;

  screenWidth = 320;
  screenHeight = 200;
  # ST_Y and ST_HEIGHT of st_stuff.h.
  barY = 168;
  barHeight = 32;

  blocksFor = cols: max 3 (min 10 (div (cols + 31) 32));

  # The value of the word variable name of Doom in mem, or a throw when the link lacks it.
  wordOf =
    symbols: mem: name:
    M.loadWord mem (
      symbols.${name} or (throw "doom: picture: the view window needs the variable ${name} in the link")
    );

  # Whether the frame shows the 3D view, as D_Display of d_main.c decides it: the level is
  # on (gamestate is GS_LEVEL, 0 in doomdef.h) and has run a tic (gametic is not 0, else
  # D_Display draws nothing of it), the automap is off (automapactive, else AM_Drawer draws
  # over the whole screen above the bar and R_RenderPlayerView is skipped) and no menu is
  # open (menuactive, also set for the help screens and the messages of M_StartMessage,
  # which M_Drawer draws over the whole screen). The pause picture needs no full screen:
  # D_Display draws it at viewwindowy + 4, centered in the window, when the automap is off.
  viewOn =
    word:
    word "gamestate" == 0 && word "gametic" != 0 && word "automapactive" == 0 && word "menuactive" == 0;

  # The view window of the frame, as R_ExecuteSetViewSize and R_InitBuffer of r_main.c and
  # r_draw.c leave it, or null when it does not lie on the screen.
  windowOf =
    word:
    let
      x = word "viewwindowx";
      y = word "viewwindowy";
      width = word "scaledviewwidth";
      height = word "viewheight";
    in
    if width >= 1 && height >= 2 && x + width <= screenWidth && y + height <= screenHeight then
      {
        inherit
          x
          y
          width
          height
          ;
      }
    else
      null;

  # The rows of the window and of the bar at c columns.
  windowRows = window: c: max 1 (div (window.height * c) (2 * window.width));
  barRows = window: c: if window.height == screenHeight then 0 else max 1 (div (barHeight * c) 640);

  # The columns of the picture: cols, or the largest width at which the window and the bar,
  # c * height / (2 * width) and c * 32 / 640 rows before rounding down, fit in rows lines.
  columnsOf =
    window: cols: rows:
    if windowRows window cols + barRows window cols <= rows then
      cols
    else if window.height == screenHeight then
      max 1 (min cols (div (rows * 2 * window.width) window.height))
    else
      max 1 (min cols (div (rows * 20 * window.width) (10 * window.height + window.width)));

  # The rectangle rect of the frame as cols x rows cells.
  rectangle =
    frame: rect: cols: rows:
    R.renderMem (
      {
        inherit (frame) mem screenAddr palette;
        inherit cols rows;
      }
      // rect
    );

  fullScreen = {
    x = 0;
    y = 0;
    width = screenWidth;
    height = screenHeight;
  };

  statusBar = {
    x = 0;
    y = barY;
    width = screenWidth;
    height = barHeight;
  };

  # The window and, under it, the bar, c columns wide.
  windowPicture =
    frame: window: cols: rows:
    let
      c = columnsOf window cols rows;
      bar = barRows window c;
    in
    rectangle frame window c (windowRows window c)
    + (if bar == 0 then "" else rectangle frame statusBar c bar);

  picture =
    {
      symbols,
      windowed,
      cols,
      rows,
    }:
    frame:
    let
      word = wordOf symbols frame.mem;
      window = windowOf word;
    in
    if windowed && viewOn word && window != null then
      windowPicture frame window cols rows
    else
      rectangle frame fullScreen cols rows;
in
{
  inherit blocksFor picture;
}
