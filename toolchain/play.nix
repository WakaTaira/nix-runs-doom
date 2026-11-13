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
# ($XDG_CACHE_HOME or ~/.cache, under nix-doom). DOOM_TICS, DOOM_TICKS, DOOM_VIEW and
# DOOM_ARGS are passed on; GC_INITIAL_HEAP_SIZE is 4g unless set.
#
# Keys: the launcher asks the terminal whether it speaks the kitty keyboard protocol
# (CSI ? u, then the primary device attributes CSI c, whose reply ends the wait; 2 s at
# most). If it replies with its flags, the launcher pushes the flags 11 (CSI > 11 u: every
# press, repeat and release of every key, modifier keys alone included, as an escape
# sequence), asks again, and keeps the protocol only when the terminal now reports 11;
# the evaluation then decodes the key file with DOOM_KEYS_PROTO=kitty. Otherwise, or with
# DOOM_KEYS_PROTO=legacy, the terminal stays in its usual mode and the evaluation makes up
# the releases (DOOM_KEYS_PROTO=legacy). In the kitty protocol Ctrl-C is a key sequence
# and no longer an interrupt, so the launcher watches the key file for a press or a
# repeat of c with the ctrl bit in its modifiers; this is the only thing it reads from
# the keys, which it otherwise never decodes. Ctrl-C ends the key reader, and so does the
# end of the evaluation (Doom quit, or an error); then the launcher stops the evaluation,
# in the kitty protocol pops the flags (CSI < u) and drops what the terminal still sends
# within 0.3 s (the releases of the last keys), and restores the terminal.
{
  pkgs,
  doomgeneric,
  self,
}:
pkgs.writeShellApplication {
  name = "nix-doom-play";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
  ];
  text = ''
    wad=''${1:-''${DOOM_WAD:-}}
    if [ "$#" -gt 0 ]; then shift; fi
    hex=''${DOOM_WAD_HEX:-}
    proto=''${DOOM_KEYS_PROTO:-}

    if [ -z "$wad" ] && [ -z "$hex" ]; then
      echo "usage: nix run .#play -- /path/to/doom1.wad [doom arguments ...]" >&2
      exit 2
    fi
    case "$proto" in
      "" | kitty | legacy) ;;
      *)
        echo "nix-doom-play: DOOM_KEYS_PROTO is neither kitty nor legacy: $proto" >&2
        exit 2
        ;;
    esac

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
    esc=$'\e'
    pushed=""
    eval_pid=""
    watch_pid=""

    # The kitty flags in the reply of the terminal to CSI ? u followed by CSI c, read up to
    # the c that ends the reply to CSI c (2 s at most); nothing when there are none.
    kitty_flags() {
      local reply="" pattern="''${esc}\[\?([0-9]+)u"
      printf '%s[?u%s[c' "$esc" "$esc" > /dev/tty
      IFS= read -r -s -d c -t 2 reply || true
      if [[ $reply =~ $pattern ]]; then echo "''${BASH_REMATCH[1]}"; fi
    }

    # Whether the key file $1 holds a press or a repeat of c (code 99) with the ctrl bit
    # (4) in its modifiers, whatever the other bits (shift, caps lock, num lock, ...).
    ctrl_c() {
      local matches match mods
      matches=$(grep -aoE "''${esc}\[99(:[0-9]*)*;[0-9]+(:[12])?(;[0-9:]*)?u" "$1" || true)
      for match in $matches; do
        mods=''${match#*;}
        mods=''${mods%%[!0-9]*}
        if (((mods - 1) & 4)); then return 0; fi
      done
      return 1
    }

    # Waits until the evaluation ends or, in the kitty protocol, Ctrl-C is in the key
    # file, then ends the key reader.
    watch_keys() {
      while kill -0 "$eval_pid" 2>/dev/null; do
        if [ "$proto" = kitty ] && ctrl_c "$keys"; then break; fi
        sleep 0.2
      done
      while [ ! -s "$keys.pid" ]; do sleep 0.1; done
      kill "$(cat "$keys.pid")" 2>/dev/null || true
    }

    finish() {
      if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null || true; fi
      if [ -n "$eval_pid" ]; then kill "$eval_pid" 2>/dev/null || true; fi
      if [ -n "$pushed" ]; then
        printf '%s[<u' "$esc" > /dev/tty || true
        IFS= read -r -s -d "" -t 0.3 _ || true
      fi
      stty "$saved"
      rm -f "$keys" "$keys.pid"
    }
    trap finish EXIT
    trap : INT

    # The terminal sends the keys unbuffered and without echo from here on.
    stty -icanon -echo min 1

    if [ "$proto" != legacy ]; then
      proto=legacy
      if [ -n "$(kitty_flags)" ]; then
        printf '%s[>11u' "$esc" > /dev/tty
        pushed=1
        if [ "$(kitty_flags)" = 11 ]; then
          proto=kitty
        else
          printf '%s[<u' "$esc" > /dev/tty
          pushed=""
        fi
      fi
    fi
    echo "nix-doom-play: keys: $proto" >&2

    DOOM_SRC=${doomgeneric}/doomgeneric \
    DOOM_WAD_HEX=$hex \
    DOOM_KEYS=$keys \
    DOOM_KEYS_PROTO=$proto \
    DOOM_ARGS="''${DOOM_ARGS:-} $*" \
    LINES=''${size% *} \
    COLUMNS=''${size#* } \
    GC_INITIAL_HEAP_SIZE=''${GC_INITIAL_HEAP_SIZE:-4g} \
      nix --extra-experimental-features nix-command eval --raw -f ${self} doom.play < /dev/null &
    eval_pid=$!

    watch_keys &
    watch_pid=$!

    # The keys typed here go to the key file until the key reader ends; the evaluation
    # draws meanwhile.
    sh -c 'echo $$ > "$1.pid"; exec cat > "$1"' sh "$keys" || true
  '';
}
