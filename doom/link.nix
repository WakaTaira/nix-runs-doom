# The one-shot link of doomgeneric's units by the Nix C compiler (cc/); doom/run.nix calls
# the resulting Nix functions directly, without the RV32IM emulator.
#
#   import ./link.nix { src; wad; }  -> the result of cc.linkFiles
#
# src is the directory of the doomgeneric sources (a path with Makefile and *.c) and wad
# is { hex; size; } as for cc.host.mk. The files are the objects of SRC_DOOM in the
# Makefile (as .c), without the platform files doomgeneric_<platform>.c, whose DG_* come
# from the host (cc/host.nix). The result has doomgeneric_Create, doomgeneric_Tick,
# __init and __data; applying __init to the memory is the first step of a run. No symbol
# may stay undefined. Linking all units takes about a minute of CPU time and 15 GB.
let
  Cc = import ../cc;
  H = import ../lib/hostcall.nix;
  inherit (builtins)
    filter
    head
    isString
    match
    readFile
    split
    stringLength
    substring
    ;

  prefix = "SRC_DOOM = ";

  hasPrefix = p: s: substring 0 (stringLength p) s == p;

  words = s: filter (w: isString w && w != "") (split " " s);

  objectToSource = o: substring 0 (stringLength o - 2) o + ".c";

  # The file names listed on the SRC_DOOM line of the Makefile, platform files excluded.
  sourceFiles =
    src:
    let
      lines = filter (l: isString l && hasPrefix prefix l) (split "\n" (readFile (src + "/Makefile")));
      line = if lines == [ ] then throw "doom: SRC_DOOM not found in Makefile" else head lines;
      objects = words (substring (stringLength prefix) (stringLength line) line);
    in
    map objectToSource (filter (o: match "doomgeneric_.*" o == null) objects);

  link =
    { src, wad }:
    let
      dg = Cc.readFrom [ src ];
    in
    Cc.linkFiles {
      files = sourceFiles src;
      allowUndefined = false;
      host = Cc.host.mk { inherit wad; };
      read = n: H.ccHeaderFiles.${n} or (dg n);
      includePaths = [ "" ];
      defines = {
        CMAP256 = "1";
        DOOMGENERIC_RESX = "320";
        DOOMGENERIC_RESY = "200";
        __BYTE_ORDER__ = "__ORDER_LITTLE_ENDIAN__";
        __ORDER_LITTLE_ENDIAN__ = "1234";
        __ORDER_BIG_ENDIAN__ = "4321";
      };
    };
in
link
