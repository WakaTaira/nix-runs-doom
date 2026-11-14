# The text that doom.play (doom/default.nix) traces for a frame: a status line over the
# picture of the frame, in one of the two forms of DOOM_STREAM.
#
#   status : tick -> events -> string
#   frame  : mode -> line -> picture -> string
#
# status is the status line of a tick: "tick <n>", then the key events sent at it, each a
# + for a press or a - for a release followed by the name of the key (a word for the
# special keys of doomkeys.h, else the character), separated by spaces.
#
# picture is a picture of doom/picture.nix (lines that each end with ESC[0m and a line
# break). frame puts the status line line over it, as mode says:
#   scroll  line, a line break and the picture without its last line break (trace adds
#           one), so that every frame is printed under the one before it;
#   home    ESC[?2026h (begin a synchronized update), ESC[H (the cursor to the top left
#           corner), then every line (the status line, then the lines of the picture)
#           as ESC[K (erase the line), the line and a line break, then ESC[J (erase the
#           rest of the screen, which holds what is left of a taller frame before it)
#           and ESC[?2026l (end the synchronized update), so that every frame is drawn
#           over the one before it. The erasing comes at the start of a line and not at
#           its end, because after a line as wide as the terminal the cursor waits on
#           the last column, where ESC[K would erase the last cell on some terminals.
#           The frame takes one line more than it shows (the line of ESC[J), which the
#           two lines that doom/render.nix fit leaves free allow. It is meant for
#           a reader of the log in internal-json form (toolchain/play.nix), which copies it
#           as it is.
# Any other mode is a throw.
let
  inherit (builtins)
    concatStringsSep
    fromJSON
    replaceStrings
    stringLength
    substring
    ;

  esc = fromJSON ''"\u001b"'';

  keyNames = {
    "173" = "Up";
    "175" = "Down";
    "174" = "Right";
    "172" = "Left";
    "27" = "Esc";
    "13" = "Enter";
    "127" = "Backspace";
    "9" = "Tab";
    "162" = "Use";
    "163" = "Fire";
    "182" = "Shift";
    "184" = "Alt";
  };

  # The name of a doomkeys.h number: a word for the special keys, else the character.
  keyName = k: keyNames.${toString k} or ((import ../lib/ascii.nix).chr k);

  eventName = e: (if e.pressed == 1 then "+" else "-") + keyName e.key;

  status = tick: events: concatStringsSep " " ([ "tick ${toString tick}" ] ++ map eventName events);

  # The string s without its last character (the line break that ends a picture).
  dropLast = s: substring 0 (stringLength s - 1) s;

  scroll = line: picture: line + "\n" + dropLast picture;

  # The picture with ESC[K at the start of every line, without its last line break.
  erasedLines = picture: "${esc}[K" + replaceStrings [ "\n" ] [ "\n${esc}[K" ] (dropLast picture);

  home =
    line: picture:
    "${esc}[?2026h${esc}[H${esc}[K" + line + "\n" + erasedLines picture + "\n${esc}[J${esc}[?2026l";

  frame =
    mode:
    if mode == "scroll" then
      scroll
    else if mode == "home" then
      home
    else
      throw "doom: stream: unknown mode '${mode}'";
in
{
  inherit status frame;
}
