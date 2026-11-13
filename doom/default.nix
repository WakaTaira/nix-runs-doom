# Evaluation attributes for doomgeneric compiled by the Nix C compiler (doom/link.nix)
# and run by doom/run.nix, with nothing but `nix eval -f .`.
#
#   export DOOM_SRC=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.doomgeneric.outPath')/doomgeneric
#   export DOOM_WAD_HEX=~/doom1.wad.hex
#   nix eval --json -f . doom.report
#   COLUMNS=$COLUMNS LINES=$LINES nix eval --raw -f . doom.title
#   DOOM_KEYS=/tmp/doom.keys COLUMNS=$COLUMNS LINES=$LINES nix eval --raw -f . doom.play
#
# title    the last frame after DOOM_TICKS ticks as an ANSI still image of the size that
#          doom/render.nix fit picks for COLUMNS and LINES (doom/picture.nix)
# report   every frame drawn from doomgeneric_Create (tick 0) on as [ { tick; hash; } ]:
#          hash is the sha256 of the screen bytes followed by the palette (r, g, b per
#          entry), each byte as two hex digits, as in scaffold.boot.report
# play     streams, at each tick, the guest output added in it (if any) and the last
#          frame drawn in it (if any) with builtins.trace, the frame under a status
#          line (the tick and the key events sent at it, + a press, - a release); each
#          tick runs DOOM_TICS tics of the game and draws once (doom/run.nix tics); the
#          frames are pictures of doom/picture.nix of the size of title; the value is
#          "ticks: <n>, frames: <m>\n"
#
# Environment (read with builtins.getEnv):
#   DOOM_SRC      absolute path of the doomgeneric sources (Makefile and *.c); required
#   DOOM_WAD_HEX  path of the hex text of doom1.wad (as for scaffold/); required
#   DOOM_ARGS     more arguments after `doom -iwad doom1.wad`, separated by white space
#   DOOM_TICKS    calls of doomgeneric_Tick; 2 for title and report, 1000000 for play
#   DOOM_TICS     tics of the game per tick, run by moving the virtual clock (doom/run.nix
#                 tics); 0 for title and report (the clock is left to Doom, as in the
#                 scaffold), 5 for play
#   DOOM_VIEW     the view window: auto (the default for play) sets Doom's screen size to
#                 the least one at least as wide as the picture (doom/picture.nix
#                 blocksFor) and draws the window and the status bar alone while the 3D
#                 view is on; a number from 3 to 10 does the same with that screen size;
#                 full (the default for title and report) leaves Doom's view window alone
#                 and always draws the whole screen
#   DOOM_KEYS     path of the key file, read again before every tick at which no key
#                 event is pending (doom/run.nix, doom/keys.nix poll); no input
#                 without it
#   DOOM_KEYS_PROTO  how the key file is decoded (doom/run.nix keyProto): legacy (the
#                 default) for the bytes of a terminal in its usual mode, kitty for those
#                 of a terminal in the kitty keyboard protocol (doom/keys.nix pollKitty)
#   COLUMNS, LINES  the terminal size; 160 and 52 without them
let
  R = import ./render.nix;
  P = import ./picture.nix;
  inherit (builtins)
    concatStringsSep
    div
    elemAt
    filter
    fromJSON
    genList
    getEnv
    isString
    match
    readFile
    split
    stringLength
    substring
    trace
    ;

  # The value of the environment variable name, or a throw with help when it is unset.
  required =
    name: help:
    let
      v = getEnv name;
    in
    if v == "" then throw "doom: ${name} is not set. ${help}" else v;

  # The non-negative integer in the environment variable name, or default when it is unset.
  numberOr =
    name: default:
    let
      v = getEnv name;
    in
    if v == "" then
      default
    else if match "[0-9]+" v != null then
      fromJSON v
    else
      throw "doom: ${name} is not a non-negative integer: '${v}'";

  src = required "DOOM_SRC" ''
    Point it at the doomgeneric sources:
      export DOOM_SRC=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.doomgeneric.outPath')/doomgeneric'';

  wadHex = readFile (
    required "DOOM_WAD_HEX" ''
      Point it at the hex text of doom1.wad:
        od -An -v -tx1 /path/to/doom1.wad | tr -d ' \n' > ~/doom1.wad.hex
        export DOOM_WAD_HEX=~/doom1.wad.hex''
  );

  linked = import ./link.nix {
    inherit src;
    wad = {
      hex = wadHex;
      size = div (stringLength wadHex) 2;
    };
  };

  words = s: filter (w: isString w && w != "") (split "[[:space:]]+" s);

  args = [
    "doom"
    "-iwad"
    "doom1.wad"
  ]
  ++ words (getEnv "DOOM_ARGS");

  keysPath = getEnv "DOOM_KEYS";

  # The text of the key file, read again at each call.
  readKeys = if keysPath == "" then _: null else _: readFile keysPath;

  # The key protocol of the key file (doom/run.nix keyProto).
  keyProto =
    let
      v = getEnv "DOOM_KEYS_PROTO";
    in
    if v == "" then
      "legacy"
    else if v == "legacy" || v == "kitty" then
      v
    else
      throw "doom: DOOM_KEYS_PROTO is neither legacy nor kitty: '${v}'";

  size = R.fit {
    columns = numberOr "COLUMNS" 160;
    lines = numberOr "LINES" 52;
  };

  ticksOr = numberOr "DOOM_TICKS";

  ticsOr = numberOr "DOOM_TICS";

  # The screen size of the view window (doom/run.nix view) that DOOM_VIEW asks for, with
  # default ("auto" or "full") when it is unset: null for full.
  viewOr =
    default:
    let
      v = getEnv "DOOM_VIEW";
      setting = if v == "" then default else v;
    in
    if setting == "full" then
      null
    else if setting == "auto" then
      P.blocksFor size.cols
    else if match "([3-9]|10)" setting != null then
      fromJSON setting
    else
      throw "doom: DOOM_VIEW is not auto, full or a number from 3 to 10: '${v}'";

  run =
    ticks: tics: view: onTick: init:
    import ./run.nix {
      inherit
        linked
        args
        ticks
        tics
        view
        readKeys
        keyProto
        onTick
        init
        ;
    };

  hexDigit = i: substring i 1 "0123456789abcdef";
  hexTable = genList (n: hexDigit (div n 16) + hexDigit (builtins.bitAnd n 15)) 256;
  bytesHex = bs: concatStringsSep "" (map (elemAt hexTable) bs);

  # The hash of a frame record, as frameHash of scaffold/default.nix.
  frameHash =
    f:
    builtins.hashString "sha256" (
      bytesHex f.screen
      + concatStringsSep "" (
        map (
          p:
          bytesHex [
            p.r
            p.g
            p.b
          ]
        ) f.palette
      )
    );

  # The picture of a frame record, the view window alone when view is not null.
  image =
    view:
    P.picture {
      inherit (linked.__data) symbols;
      windowed = view != null;
      inherit (size) cols rows;
    };

  # The picture without its last line break (trace adds one).
  traced =
    view: f:
    let
      s = image view f;
    in
    substring 0 (stringLength s - 1) s;

  # The hashes of the frames of one call, forced so that no frame record is kept.
  hashEntries =
    { tick, frames, ... }:
    acc:
    let
      new = map (f: {
        inherit tick;
        hash = frameHash f;
      }) frames;
    in
    builtins.deepSeq new (acc ++ new);

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

  # The status line of a tick: its number and the key events sent at it.
  status = tick: events: concatStringsSep " " ([ "tick ${toString tick}" ] ++ map eventName events);

  # Traces the output, then the last frame under its status line, of one call.
  stream =
    view:
    {
      tick,
      frames,
      out,
      events,
    }:
    acc:
    let
      withFrame =
        if frames == [ ] then
          acc
        else
          trace (status tick events + "\n" + traced view (elemAt frames (builtins.length frames - 1))) acc;
    in
    if out == "" then withFrame else trace out withFrame;

  titleView = viewOr "full";
  titleRun = run (ticksOr 2) (ticsOr 0) titleView (_: acc: acc) null;
  playTicks = ticksOr 1000000;
  playView = viewOr "auto";
  playRun = run playTicks (ticsOr 5) playView (stream playView) null;
in
{
  title =
    if titleRun.last == null then throw "doom: no frame was drawn" else image titleView titleRun.last;

  report = (run (ticksOr 2) (ticsOr 0) (viewOr "full") hashEntries [ ]).acc;

  play = builtins.seq playRun.acc "ticks: ${toString playTicks}, frames: ${toString playRun.frameCount}\n";
}
