# The launcher behind `nix run .#play`: the one place where a shell script stands between
# the user and the evaluation. An evaluation cannot read the terminal, so something outside
# it has to switch the terminal to unbuffered input and copy the keys to a file; the
# launcher does that and nothing else of substance. Doom itself (compiling the C sources,
# running them, drawing the frames) is `nix eval -f <repository> doom.play`, exactly as
# when it is started by hand (see doom/default.nix).
#
#   nix run .#play -- /path/to/doom1.wad [doom arguments ...]
#
# The WAD may also be given as DOOM_WAD, or as hex text (a name ending in .hex, or
# DOOM_WAD_HEX). A binary WAD is converted to hex text once, into the cache directory
# ($XDG_CACHE_HOME or ~/.cache, under nix-doom). DOOM_TICS and DOOM_TICKS are passed on;
# GC_INITIAL_HEAP_SIZE is 4g unless set. Ctrl-C ends the key reader, then the launcher
# stops the evaluation and restores the terminal.
{
  pkgs,
  doomgeneric,
  self,
}:
pkgs.writeShellApplication {
  name = "nix-doom-play";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    wad=''${1:-''${DOOM_WAD:-}}
    if [ "$#" -gt 0 ]; then shift; fi
    hex=''${DOOM_WAD_HEX:-}

    if [ -z "$wad" ] && [ -z "$hex" ]; then
      echo "usage: nix run .#play -- /path/to/doom1.wad [doom arguments ...]" >&2
      exit 2
    fi

    # Hex text of the WAD: given as such, or converted once into the cache.
    if [ -z "$hex" ]; then
      case "$wad" in
        *.hex) hex=$wad ;;
        *)
          cache=''${XDG_CACHE_HOME:-$HOME/.cache}/nix-doom
          mkdir -p "$cache"
          hex=$cache/$(basename "$wad").hex
          if [ ! -s "$hex" ] || [ "$wad" -nt "$hex" ]; then
            echo "converting $wad to hex text ..." >&2
            od -An -v -tx1 "$wad" | tr -d ' \n' > "$hex.tmp"
            mv "$hex.tmp" "$hex"
          fi
          ;;
      esac
    fi
    if [ ! -r "$hex" ]; then
      echo "nix-doom-play: cannot read $hex" >&2
      exit 1
    fi

    keys=$(mktemp "''${TMPDIR:-/tmp}/nix-doom-keys.XXXXXX")
    saved=$(stty -g)
    size=$(stty size)

    DOOM_SRC=${doomgeneric}/doomgeneric \
    DOOM_WAD_HEX=$hex \
    DOOM_KEYS=$keys \
    DOOM_ARGS="''${DOOM_ARGS:-} $*" \
    LINES=''${size% *} \
    COLUMNS=''${size#* } \
    GC_INITIAL_HEAP_SIZE=''${GC_INITIAL_HEAP_SIZE:-4g} \
      nix --extra-experimental-features nix-command eval --raw -f ${self} doom.play < /dev/null &
    eval_pid=$!

    finish() {
      kill "$eval_pid" 2>/dev/null || true
      stty "$saved"
      rm -f "$keys" "$keys.pid"
    }
    trap finish EXIT
    trap : INT

    # When the evaluation ends by itself (Doom quit, or an error), stop the key reader too.
    (
      while kill -0 "$eval_pid" 2>/dev/null; do sleep 1; done
      kill "$(cat "$keys.pid")" 2>/dev/null || true
    ) &

    # The keys typed here go to the key file until Ctrl-C; the evaluation draws meanwhile.
    stty -icanon -echo min 1
    sh -c 'echo $$ > "$1.pid"; exec cat > "$1"' sh "$keys" || true
  '';
}
