# Evaluation attributes for doomgeneric on the emulator (see scaffold/boot.nix).
#
#   od -An -v -tx1 /path/to/doom1.wad | tr -d ' \n' > ~/doom1.wad.hex
#   nix build .#doom-scaffold -o result-doom
#   DOOM_WAD_HEX=~/doom1.wad.hex nix eval --raw -f . scaffold.title
#   DOOM_WAD_HEX=~/doom1.wad.hex nix eval --json -f . scaffold.boot.report
#   DOOM_WAD_HEX=~/doom1.wad.hex nix eval --json -f . scaffold.demo.report
#
# boot.report   the first `bootFrames` frames from start-up as [ { hash; instrs; } ]:
#               hash is the sha256 of the screen bytes followed by the palette (r, g, b
#               per entry), each byte as two hex digits; instrs the instructions since
#               the previous frame (since start-up for the first).
# title         the last of those frames as an ANSI still image (scaffold/render.nix).
# demo.report   `-timedemo demo1`, measured over frames demoWindow.first ..
#               demoWindow.last: { instrPerFrame; profile; window; } with the
#               instructions per frame and the top 30 functions by pc samples
#               (scaffold/profile.nix).
let
  C = import ../lib/cpu.nix;
  E = import ../lib/elf.nix;
  inherit (builtins)
    concatStringsSep
    div
    elemAt
    genList
    getEnv
    map
    pathExists
    readFile
    ;

  wadPath = getEnv "DOOM_WAD_HEX";
  wadHex =
    if wadPath == "" then
      throw ''
        scaffold: DOOM_WAD_HEX is not set. Point it at the hex text of doom1.wad:
          od -An -v -tx1 /path/to/doom1.wad | tr -d ' \n' > ~/doom1.wad.hex
          DOOM_WAD_HEX=~/doom1.wad.hex nix eval ...''
    else
      readFile wadPath;

  doomHexPath = ../result-doom/doom.hex;
  doomHex =
    if pathExists doomHexPath then
      readFile doomHexPath
    else
      throw ''
        scaffold: ./result-doom/doom.hex is missing. Build doomgeneric first:
          nix build .#doom-scaffold -o result-doom'';

  argv = [
    "doom"
    "-iwad"
    "doom1.wad"
  ];

  boot =
    args:
    import ./boot.nix (
      {
        hex = doomHex;
        inherit wadHex;
      }
      // args
    );

  # The final state s, after checking that the run drew at least n frames.
  drewFrames =
    n: s:
    let
      drawn = s.host.world.frameCount;
    in
    if drawn >= n then
      s
    else
      throw "scaffold: the guest drew ${toString drawn} of ${toString n} frames (halted: ${
        if s.halted then "exit ${toString s.exitCode}" else "no"
      }); guest output:\n${s.out}";

  # Instructions of frames[i] counted from the previous record (0 before the first).
  instrsAt =
    frames: i: (elemAt frames i).instrs - (if i == 0 then 0 else (elemAt frames (i - 1)).instrs);

  hexDigit = i: builtins.substring i 1 "0123456789abcdef";
  hexTable = genList (n: hexDigit (div n 16) + hexDigit (builtins.bitAnd n 15)) 256;
  bytesHex = bs: concatStringsSep "" (map (elemAt hexTable) bs);

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

  # --- Start-up mode ---

  bootFrames = 60;
  bootRun =
    (drewFrames bootFrames (boot {
      inherit argv;
      maxFrames = bootFrames;
    })).host.world.frames;

  # --- Demo mode ---

  # W: the demo's last frame before the 3D renderer runs, measured (1-based frame
  # numbers). The level starts with the screen melt (wipe), one frame per step: frames
  # 2-41 take 8k-160k instructions each (frame 1 also counts start-up). The melt has
  # left the screen at frame 40 (identical to frame 42 pixel for pixel) and the wipe
  # loop draws its last frame at 41; from frame 42 every frame renders the 3D view
  # (about 1.2M instructions each). The window W+1 .. W+10 thus covers the first ten
  # rendered frames.
  demoFirst3D = 41;
  demoWindow = {
    first = demoFirst3D + 1;
    last = demoFirst3D + 10;
  };

  demoArgv = argv ++ [
    "-timedemo"
    "demo1"
  ];

  # Run without profiling up to frame W, then profile from a cleared counter until the
  # last frame of the window.
  demoRun =
    let
      atStart = drewFrames demoFirst3D (boot {
        argv = demoArgv;
        maxFrames = demoFirst3D;
      });
      s = C.runUntil {
        maxSteps = 1000000000000;
        profile = true;
        stop = s: s.host.world.frameCount >= demoWindow.last;
      } (atStart // { profile = { }; });
    in
    {
      inherit s;
      frames = (drewFrames demoWindow.last s).host.world.frames;
    };
in
{
  boot.report = genList (i: {
    hash = frameHash (elemAt bootRun i);
    instrs = instrsAt bootRun i;
  }) bootFrames;

  title = import ./render.nix { inherit (elemAt bootRun (bootFrames - 1)) screen palette; };

  demo.report = {
    instrPerFrame = genList (i: instrsAt demoRun.frames (demoFirst3D + i)) 10;
    profile = import ./profile.nix {
      syms = E.symbols doomHex;
      inherit (demoRun.s) profile;
    };
    window = demoWindow;
  };
}
