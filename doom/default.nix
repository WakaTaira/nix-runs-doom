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
#          doom/render.nix fit picks for COLUMNS and LINES
# report   every frame drawn from doomgeneric_Create (tick 0) on as [ { tick; hash; } ]:
#          hash is the sha256 of the screen bytes followed by the palette (r, g, b per
#          entry), each byte as two hex digits, as in scaffold.boot.report
# play     streams, at each tick, the guest output added in it (if any) and the last
#          frame drawn in it (if any) with builtins.trace, the frame under a status
#          line (the tick and the key events sent at it, + a press, - a release);
#          the value is
#          "ticks: <n>, frames: <m>\n"
#
# Environment (read with builtins.getEnv):
#   DOOM_SRC      absolute path of the doomgeneric sources (Makefile and *.c); required
#   DOOM_WAD_HEX  path of the hex text of doom1.wad (as for scaffold/); required
#   DOOM_ARGS     more arguments after `doom -iwad doom1.wad`, separated by white space
#   DOOM_TICKS    calls of doomgeneric_Tick; 2 for title and report, 1000000 for play
#   DOOM_KEYS     path of the key file, read again before every tick at which no key
#                 event is pending (doom/run.nix, doom/keys.nix poll); no input
#                 without it
#   COLUMNS, LINES  the terminal size; 160 and 52 without them
let
  R = import ./render.nix;
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

  size = R.fit {
    columns = numberOr "COLUMNS" 160;
    lines = numberOr "LINES" 52;
  };

  ticksOr = numberOr "DOOM_TICKS";

  run =
    ticks: onTick: init:
    import ./run.nix {
      inherit
        linked
        args
        ticks
        readKeys
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

  image =
    f:
    R.render {
      inherit (f) screen palette;
      inherit (size) cols rows;
    };

  # The image without its last line break (trace adds one).
  traced =
    f:
    let
      s = image f;
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
  };

  # The name of a doomkeys.h number: a word for the special keys, else the character.
  keyName = k: keyNames.${toString k} or ((import ../lib/ascii.nix).chr k);

  eventName = e: (if e.pressed == 1 then "+" else "-") + keyName e.key;

  # The status line of a tick: its number and the key events sent at it.
  status = tick: events: concatStringsSep " " ([ "tick ${toString tick}" ] ++ map eventName events);

  # Traces the output, then the last frame under its status line, of one call.
  stream =
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
          trace (status tick events + "\n" + traced (elemAt frames (builtins.length frames - 1))) acc;
    in
    if out == "" then withFrame else trace out withFrame;

  titleRun = run (ticksOr 2) (_: acc: acc) null;
  playTicks = ticksOr 1000000;
  playRun = run playTicks stream null;
in
{
  title = if titleRun.last == null then throw "doom: no frame was drawn" else image titleRun.last;

  report = (run (ticksOr 2) hashEntries [ ]).acc;

  play = builtins.seq playRun.acc "ticks: ${toString playTicks}, frames: ${toString playRun.frameCount}\n";
}
