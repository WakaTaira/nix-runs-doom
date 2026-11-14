# The launcher behind `nix run .#play`: the one place where a shell script stands between
# the user and the evaluation. An evaluation can neither read the terminal nor write to it
# freely, so something outside it has to connect the two: switch the terminal to
# unbuffered input and copy the keys to a file, and copy the frames from the log of the
# evaluation to the screen. The launcher does that and nothing else of substance. Doom
# itself (compiling the C sources, running them, drawing the frames) is
# `nix eval -f <repository> doom.play`, exactly as when it is started by hand (see
# doom/default.nix).
#
#   nix run .#play -- /path/to/doom1.wad [doom arguments ...]
#
# The WAD may also be given as DOOM_WAD, or as hex text (a name ending in .hex, or
# DOOM_WAD_HEX). A binary WAD is converted to hex text once, into the cache directory
# ($XDG_CACHE_HOME or ~/.cache, under nix-doom). DOOM_TICS, DOOM_TICKS, DOOM_VIEW and
# DOOM_ARGS are passed on; GC_INITIAL_HEAP_SIZE is 4g unless set.
#
# Screen: when standard error is a terminal (and unless DOOM_STREAM=scroll), every frame
# is drawn over the one before it. The usual log format of Nix drops the cursor movements
# of a trace, so the launcher runs the evaluation with DOOM_STREAM=home and
# --log-format internal-json, which keeps a trace whole as the msg of one JSON line, and
# lets jq read those lines from a FIFO: a message that starts with "trace: " and
# ESC[?2026h is a frame (doom/stream.nix home), written without the "trace: " to the
# screen; any other message (the output of Doom, warnings, errors) goes to a log file. The
# launcher switches to the alternate screen and hides the cursor at the start and shows
# the cursor and leaves the alternate screen at the end. Then it prints the log when the
# evaluation failed (Doom quit, or an error) and was not stopped by Ctrl-C, and what the
# evaluation printed on its standard output (the "ticks: ..." line of a run that ended by
# itself). The launcher decodes only the envelope of the log; the frames are copied as
# they are. With DOOM_STREAM=scroll
# (or when standard error is not a terminal) the evaluation logs as usual and every frame
# is printed under the one before it.
#
# Keys: the launcher asks the terminal whether it speaks the kitty keyboard protocol
# (CSI ? u, then the primary device attributes CSI c, whose reply ends the wait; 2 s at
# most). If it replies with its flags, the launcher pushes the flags 11 (CSI > 11 u: every
# press, repeat and release of every key, modifier keys alone included, as an escape
# sequence), asks again, and keeps the protocol only when the terminal now reports 11;
# the evaluation then decodes the key file with DOOM_KEYS_PROTO=kitty. Otherwise, or with
# DOOM_KEYS_PROTO=legacy, the terminal stays in its usual mode and the evaluation makes up
# the releases (DOOM_KEYS_PROTO=legacy). The flags are pushed after the switch to the
# alternate screen and popped before leaving it (the two screens keep separate stacks of
# flags). In the kitty protocol Ctrl-C is a key sequence and no longer an interrupt, so
# the launcher watches the key file for a press or a repeat of c with the ctrl bit in its
# modifiers; this is the only thing it reads from the keys, which it otherwise never
# decodes. Ctrl-C ends the key reader, and so does the
# end of the evaluation (Doom quit, or an error); then the launcher stops the evaluation
# (and waits up to 5 s for it and jq to end, then kills them), in the kitty protocol pops
# the flags (CSI < u) and drops what the terminal still sends within 0.3 s (the releases
# of the last keys), and restores the terminal.
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
    pkgs.jq
  ];
  text = ''
    wad=''${1:-''${DOOM_WAD:-}}
    if [ "$#" -gt 0 ]; then shift; fi
    hex=''${DOOM_WAD_HEX:-}
    proto=''${DOOM_KEYS_PROTO:-}
    stream=''${DOOM_STREAM:-}

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
    case "$stream" in
      "" | home | scroll) ;;
      *)
        echo "nix-doom-play: DOOM_STREAM is neither home nor scroll: $stream" >&2
        exit 2
        ;;
    esac
    if [ -z "$stream" ]; then
      if [ -t 2 ]; then stream=home; else stream=scroll; fi
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
    fifo=$keys.fifo
    log=$keys.log
    out=$keys.out
    saved=$(stty -g)
    size=$(stty size)
    esc=$'\e'
    pushed=""
    alternate=""
    eval_pid=""
    filter_pid=""
    watch_pid=""
    reader_status=0
    eval_status=0

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

    # The frames in the log of the evaluation, read from the FIFO: the msg of every message
    # of the internal-json log format (a line "@nix {...}"), without its "trace: ", on
    # standard output when it is a frame (it starts with ESC[?2026h), and with a line break
    # on standard error otherwise, as any line that is not such a message.
    filter_log() {
      jq --unbuffered -Rj '
        . as $line
        | (if startswith("@nix ") then (.[5:] | try fromjson catch null) else null end) as $m
        | if ($m | type) != "object" then $line + "\n" | stderr | empty
          elif $m.action != "msg" then empty
          elif ($m.msg | startswith("trace: \u001b[?2026h")) then $m.msg[7:]
          else $m.msg + "\n" | stderr | empty
          end'
    }

    # Runs doom.play with the nix options "$@", in place of the calling (background) shell.
    run_eval() {
      exec env \
        DOOM_SRC=${doomgeneric}/doomgeneric \
        DOOM_WAD_HEX="$hex" \
        DOOM_KEYS="$keys" \
        DOOM_KEYS_PROTO="$proto" \
        DOOM_STREAM="$stream" \
        DOOM_ARGS="$args" \
        LINES="''${size% *}" \
        COLUMNS="''${size#* }" \
        GC_INITIAL_HEAP_SIZE="''${GC_INITIAL_HEAP_SIZE:-4g}" \
        nix --extra-experimental-features nix-command "$@" eval --raw -f ${self} doom.play < /dev/null
    }

    # Whether the user ended the game: Ctrl-C ended the key reader (status 130) or, in the
    # kitty protocol, is in the key file.
    stopped_by_user() {
      [ "$reader_status" = 130 ] || { [ "$proto" = kitty ] && ctrl_c "$keys"; }
    }

    # Stops the evaluation and waits up to 5 s for it and the filter to end, then kills
    # them; sets eval_status.
    stop_eval() {
      local _
      kill "$eval_pid" 2>/dev/null || true
      for _ in $(seq 50); do
        if ! kill -0 "$eval_pid" 2>/dev/null && { [ -z "$filter_pid" ] || ! kill -0 "$filter_pid" 2>/dev/null; }; then
          break
        fi
        sleep 0.1
      done
      kill -9 "$eval_pid" 2>/dev/null || true
      wait "$eval_pid" 2>/dev/null || eval_status=$?
      if [ -n "$filter_pid" ]; then
        kill -9 "$filter_pid" 2>/dev/null || true
        wait "$filter_pid" 2>/dev/null || true
      fi
    }

    finish() {
      if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null || true; fi
      if [ -n "$eval_pid" ]; then stop_eval; fi
      if [ -n "$pushed" ]; then
        printf '%s[<u' "$esc" > /dev/tty || true
        IFS= read -r -s -d "" -t 0.3 _ || true
      fi
      if [ -n "$alternate" ]; then
        printf '%s[?2026l%s[?25h%s[?1049l' "$esc" "$esc" "$esc" >&2 || true
      fi
      stty "$saved"
      if [ -n "$alternate" ]; then
        if [ "$eval_status" != 0 ] && ! stopped_by_user; then cat "$log" >&2 || true; fi
        cat "$out" 2>/dev/null || true
      fi
      rm -f "$keys" "$keys.pid" "$fifo" "$log" "$out"
    }
    trap finish EXIT
    trap : INT

    # The terminal sends the keys unbuffered and without echo from here on.
    stty -icanon -echo min 1

    # The alternate screen, cleared and without a cursor, before the flags are pushed.
    if [ "$stream" = home ]; then
      printf '%s[?1049h%s[?25l%s[H%s[2J' "$esc" "$esc" "$esc" "$esc" >&2
      alternate=1
    fi

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

    args="''${DOOM_ARGS:-} $*"
    if [ "$stream" = home ]; then
      echo "nix-doom-play: the first frame takes about a minute" >&2
      mkfifo "$fifo"
      filter_log < "$fifo" >&2 2> "$log" &
      filter_pid=$!
      run_eval --log-format internal-json 2> "$fifo" > "$out" &
    else
      run_eval &
    fi
    eval_pid=$!

    watch_keys &
    watch_pid=$!

    # The keys typed here go to the key file until the key reader ends; the evaluation
    # draws meanwhile.
    sh -c 'echo $$ > "$1.pid"; exec cat > "$1"' sh "$keys" || reader_status=$?
  '';
}
