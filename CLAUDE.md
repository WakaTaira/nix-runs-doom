# nix-doom-tui

An experiment: write an RV32IM emulator in pure Nix (`nix eval` only, no derivations) and eventually run Doom on it in a terminal.

## Goals

- **100% Nix evaluation.** The emulator and everything it needs at runtime is plain Nix expressions evaluated by `nix eval`. No derivations, no IFD, no external processes.
- **Runs in a TTY.** The output is a string printed to a terminal; no GUI, no framebuffer device.
- **ANSI color rendering.** Frames are drawn as colored characters: the upper half block `▀` with 24-bit color escape sequences (foreground = upper half, background = lower half of the cell).

## Language

- All code comments, documentation, and commit messages are written in **English**.
- The only exceptions are git-ignored private files: `CLAUDE.local.md` (the local handoff note) and `docs/private/` (detailed working documents), which may be written in any language.

## What "100% Nix" means here

Not just the emulator: the guest programs are Nix too.

- **Emulator** — pure Nix, evaluated by `nix eval`.
- **Our guest code** (examples, tests, and later the Doom platform glue) — written in the Nix eDSL (`lib/dsl.nix`) as Nix values, assembled into RV32I machine code by Nix. No C, no assembler strings.
- **Doom itself** — the upstream C source is an external input (like a ROM for nixboy). The long-term plan is to compile it with a C compiler written in Nix. Rewriting Doom by hand in Nix is out of scope.
- **No scripts.** Steps that need something outside an evaluation (setting `NIX_SHOW_STATS`, providing a WAD) are documented one-line commands, in the style of [nixboy](https://github.com/psyclyx/nixboy).
- **One launcher.** The exception to the rule above is `nix run .#play` (`toolchain/play.nix`): an evaluation cannot read the terminal, so a short shell script switches the terminal to unbuffered input (and to the kitty keyboard protocol when the terminal supports it), copies the keys to a file, converts a binary WAD to hex text and starts `nix eval -f . doom.play`. It computes nothing of Doom and decodes no keys (except that it looks for Ctrl-C in the key file in the kitty protocol, where Ctrl-C is no longer an interrupt); everything it does can be typed by hand (see Commands; the hand-typed lines use the terminal's usual mode).

Transitional exception: `examples/fizzbuzz-c` embeds C in a Nix string and builds it with clang via `toolchain/guest.nix`. It exists only to compare against the eDSL version and will be removed.

Transitional exception: `toolchain/doom.nix` embeds a small C string (`mainC`: call `doomgeneric_Create`, then call `doomgeneric_Tick` forever) in place of doomgeneric's platform `main`. The Doom scaffold (`scaffold/`, `toolchain/doom.nix`) is a temporary mirror for cross-checking a future C compiler written in Nix, and is removed once that compiler can run Doom.

The Nix C compiler keeps its C inputs and test cases as Nix strings (`cc/examples/`, `tests/cc.nix`). They are input data for the compiler, not guest code written in C, so they are not an exception to the rule above.

## Commands

| Purpose | Command |
|---|---|
| Unit tests (evaluation fails on any failure) | `nix eval --raw -f . tests.check` |
| Test details (got/expected for failures) | `nix eval --json -f . tests.summary` |
| FizzBuzz (eDSL guest) stdout | `nix eval --raw -f . fizzbuzz.stdout` |
| FizzBuzz run stats | `nix eval --json -f . fizzbuzz.stats` |
| Transitional C FizzBuzz | `nix eval --raw -f . fizzbuzzC.stdout` |
| Spike report (needs measured stats, see below) | `SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.report` |
| cc gate report (needs measured stats of `nix` and `cc`, see below) | `SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.ccReport` |
| draw gate report (needs measured stats of `nix` and `draw`, see below) | `SPIKE_STATS_DIR=/tmp/spike nice -n 19 taskset -c 0-15 nix eval --raw -f . bench.spike.drawReport` |
| Screen hashes after one full frame (`nix`, `cc`, `draw`; must be equal) | `nice -n 19 taskset -c 0-15 nix eval --json -f . bench.spike.screens` |
| Play Doom (launcher; needs only the WAD) | `nix run .#play -- /path/to/doom1.wad` |
| Format | `nix fmt` |

The flake exposes only `lib`, `tests`, `fizzbuzz` and `fizzbuzzC`, so the commands on those also work as `.#<attr>` (flakes only see git-tracked files, so `git add -N` new files first). `bench.*`, `scaffold.*`, `cc.*` and `doom.*` are used with `-f .` only. The flake also has the app `play` (the default app) and the packages `play`, `doom-scaffold` and `fizzbuzz-c`.

Performance budget (two evaluations; the first lets Nix record its own CPU time):

```sh
export NIX_SHOW_STATS_PATH=/tmp/nix-doom-bench.json
NIX_SHOW_STATS=1 nix eval -f . bench.run
nix eval --raw -f . bench.report
```

Execution-strategy spike (M0; compares clang-compiled RV32IM, the same with the `fixmul` instruction, and C translated to Nix; each variant runs 1 and 2 frames three times, and the cost of a frame is the difference of the minimum CPU times):

```sh
mkdir -p /tmp/spike && for r in 1 2 3; do for v in rv rvx nix; do for k in 1 2; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.report
```

Gate of the Nix C compiler (`cc/`; compares the compiled C with the hand-written Nix variant and prints `CC GATE: pass` when cc/nix <= 1.25). The gates take the cost of a frame as (minimum CPU time of 5 frames - minimum of 1 frame) / 4, and the rounds are the outer loop so that the variants alternate:

```sh
mkdir -p /tmp/spike && for r in 1 2 3; do for v in nix cc; do for k in 1 5; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
SPIKE_STATS_DIR=/tmp/spike nix eval --raw -f . bench.spike.ccReport
```

Gate of the draw input (`cc/examples/draw.nix`: file-scope variables, argument-less draw functions, early return, wrapped signed arithmetic; prints `DRAW GATE: pass` when draw/nix <= 0.65):

```sh
mkdir -p /tmp/spike && for r in 1 2 3; do for v in nix draw; do for k in 1 5; do NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/spike/$v-n$k-$r.json nice -n 19 taskset -c 0-15 nix eval -f . bench.spike.$v.n$k >/dev/null; done; done; done
SPIKE_STATS_DIR=/tmp/spike nice -n 19 taskset -c 0-15 nix eval --raw -f . bench.spike.drawReport
```

Doom scaffold (clang-built doomgeneric on the emulator through host calls; the WAD is passed as hex text, the ELF is built once into `./result-doom`; run with `-f .`, because a flake evaluation sees neither):

```sh
od -An -v -tx1 /path/to/doom1.wad | tr -d ' \n' > ~/doom1.wad.hex
nix build .#doom-scaffold -o result-doom
DOOM_WAD_HEX=~/doom1.wad.hex nix eval --raw -f . scaffold.title
DOOM_WAD_HEX=~/doom1.wad.hex nix eval --json -f . scaffold.boot.report
DOOM_WAD_HEX=~/doom1.wad.hex nix eval --json -f . scaffold.demo.report
```

Doom compiled by the Nix C compiler (`doom/`; the sources of doomgeneric come from the flake input, the WAD as hex text). Every run links all 80 units again, which takes about 70 s of CPU time and 18 GB of allocation, so use `nice -n 19 taskset -c 0-15` for the evaluations. `doom.report` prints the hash of every frame from tick 0 on (the first three equal the scaffold's `fd744291…2045`), `doom.title` prints the last frame after `DOOM_TICKS` ticks as an image fitted to the terminal, and `doom.play` streams the frames with `builtins.trace` while it evaluates. `GC_INITIAL_HEAP_SIZE=4g` on the `doom.play` line makes the garbage collector run less often, which makes a frame 8–12% faster (measured); the heap then takes about 4 GB. To play, empty the key file (it must exist, because reading a missing file stops the evaluation), start `doom.play` in the background and read the keys in the foreground of the same terminal; the `sh -c` with `trap : INT` makes Ctrl-C end the key reader normally, so that the shell goes on to stop `doom.play` (zsh drops the rest of a line whose command was interrupted), and inside `sh` `cat` is the plain binary even where the shell aliases it:

```sh
export DOOM_SRC=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.doomgeneric.outPath')/doomgeneric
export DOOM_WAD_HEX=~/doom1.wad.hex
nice -n 19 taskset -c 0-15 nix eval --json -f . doom.report
COLUMNS=$COLUMNS LINES=$LINES nice -n 19 taskset -c 0-15 nix eval --raw -f . doom.title
# play in one terminal: Doom draws from the background, the keys typed here go to the key file; Ctrl-C ends both
: > /tmp/doom.keys
GC_INITIAL_HEAP_SIZE=4g DOOM_KEYS=/tmp/doom.keys COLUMNS=$COLUMNS LINES=$LINES nice -n 19 taskset -c 0-15 nix eval --raw -f . doom.play < /dev/null &
sh -c 'trap : INT; stty -icanon -echo min 1; cat > /tmp/doom.keys; stty sane'; kill $!
```

Environment variables of `doom.*` (all read with `builtins.getEnv`): `DOOM_SRC` (doomgeneric sources, required), `DOOM_WAD_HEX` (hex text of the WAD, required), `DOOM_ARGS` (more arguments after `doom -iwad doom1.wad`, separated by white space, e.g. `-timedemo demo1`), `DOOM_TICKS` (calls of `doomgeneric_Tick`; 2 for `title` and `report`, 1000000 for `play`), `DOOM_TICS` (tics of the game per tick, run by moving the virtual clock, then one frame drawn; 0 for `title` and `report`, where the driver leaves the clock to Doom as the scaffold does and a tic runs at every other tick, 5 for `play`; `-timedemo` runs one tic per call of `TryRunTics` whatever the clock), `DOOM_VIEW` (the view window: `auto`, the default for `play`, sets Doom's screen size to the least one whose window is at least as wide as the picture (3 to 10, 5 at 160 columns) and, while the 3D view is on, draws the window and the status bar alone, so that Doom draws only as many columns as the terminal shows; a number from 3 to 10 does the same with that screen size; `full`, the default for `title` and `report`, leaves the window alone and always draws the whole screen, as before; menus, the automap, intermissions and the title are drawn on the whole screen in every mode), `DOOM_KEYS` (path of the key file, read again before every tick at which no key event is pending; no input without it), `DOOM_KEYS_PROTO` (how the key file is decoded: `legacy`, the default, for a terminal in its usual mode, where releases are made up; `kitty` for a terminal in the kitty keyboard protocol with the flags 11, which reports every press, repeat and release, modifier keys alone included; the launcher sets it) and `COLUMNS`/`LINES` (terminal size, 160 and 52 without them; the picture is at most `LINES - 2` lines high, keeping the 16:5 proportions). Keys: arrows move, space is use, `x` is fire, Enter, Esc, Tab and Backspace are themselves, and the other printable characters are passed as they are (letters in lower case); in the kitty protocol also Ctrl (left or right) is fire, Shift is run and Alt is strafe, and several keys can be held at once; there is no mouse.

Regenerate the transitional C fixture: `nix build .#fizzbuzz-c && cp result/fizzbuzz.hex examples/fizzbuzz-c/`.

## Layout

- `lib/bits.nix` — 32-bit arithmetic. Values are always unsigned (0..2^32-1). Shifts use a power-of-two table with multiply/divide.
- `lib/mem.nix` — persistent trie over word addresses, 4 levels of 12+6+6+6 bits (sparse 1 MiB-granular root, then 64-ary nodes). Sparse; unwritten words read as 0. An update copies the 4 nodes on the path. Chosen over the previous 5x6-bit layout with `bench/memlayout.nix`: 12-18% faster at the memory interface (4 KB and 6 MiB workloads); the whole-emulator benchmark, which stores once per 8 instructions, shows no difference beyond noise. Byte accessors use a 16384-entry table indexed by the low 14 bits of the address (one lookup for the lower keys, byte divisor and keep mask; `storeByte` walks the path once), `storeRun` writes many bytes with one `//` per leaf (the partial words at both ends merged with their old bytes), and `storeStride` with one `//` per 16 KiB node for a stride of 256 or more, updating the node directly when all bytes lie in one (a stride of 1 is `storeRun`, 2 to 255 fold `storeByte`). `readPages` returns the 256-byte leaves over a byte range as lazy lists of bytes; `readLeaves` returns the same leaves as a lazy list of leaf sets, read byte by byte with `leafByte`.
- `lib/cpu.nix` — RV32IM. The words of the decode-cache region (`mkState { code = { base; size; }; }`; `runProgram` declares the whole image, code and data) are decoded once into a lazy list of threaded ops (`state -> state`). Inside the region, straight-line code and direct branches/jumps go to the linked successor op without a fetch; once a store touches the region, fetch goes through the checked path, which re-reads memory and re-decodes changed words. Outside the region every instruction is decoded from the memory trie. `run` folds in chunks and forces state every 64 steps. ECALL supports a7=64 write and a7=93 exit; a7 >= 1000 is a host call, delegated to `state.host.call` (`mkState { host = { call; ... }; }`, see `lib/hostcall.nix`).
- `lib/dsl.nix` — the guest eDSL: instructions, pseudo-instructions (`li`, `la`, `call`, ...), labels, data (`string`, `space`, `align`), and structured control flow (`when`, `ifElse`, `while`). Two-pass assembler `assemble` and loader `toMemory`.
- `lib/asm.nix` — raw instruction encoders used by the eDSL (encodings verified against llvm-mc).
- `lib/ascii.nix` — chr/ord tables.
- `lib/elf.nix` — parses a hex-encoded ELF32 and places its PT_LOAD segments (for external guests such as Doom).
- `lib/hostcall.nix` — the host-call table (libc, compiler runtime and doomgeneric's `DG_*`; the single source of truth for the generated guest headers and ecall stubs) and the emulator-side `dispatch`. For the Nix C compiler it also holds `stdHeaderFiles` (`limits.h`, `stdarg.h`, `stdbool.h`, `stddef.h`, `stdint.h`, which the toolchain takes from clang), `ccHeaderFiles` (those with the generated headers) and `hostData` (`errno`). `ccFloatTypes` and `floatCalls` give the float types of the host entries for `cc/` (`atof`, `fabs`).
- `lib/libc.nix` — the host-call libc in Nix: pure functions over a libc world (`{ mem; brk; files; out; ... }`), independent of CPU state; WAD reads decode only the requested range of the hex text. The `va_list` of the formatted output and input is the address of the ilp32 save area (clang-built guests) or the list of the variable arguments (code compiled by `cc/`). `%f` prints a double (`atof` and `fabs` are the only float host calls).
- `toolchain/play.nix` — the launcher behind `nix run .#play -- <wad> [doom arguments]`: converts a binary WAD to hex text once (into `~/.cache/nix-doom`), takes the terminal size from `stty size`, asks the terminal for the kitty keyboard protocol (`CSI ? u` and `CSI c`) and, when it answers and then takes the flags 11 (`CSI > 11 u`, checked by asking again), uses it with `DOOM_KEYS_PROTO=kitty` (`legacy` otherwise, or when `DOOM_KEYS_PROTO=legacy` is given), starts `nix eval -f <the flake source> doom.play` in the background with `DOOM_SRC` from the flake input, and copies the keys typed to a temporary key file until Ctrl-C (in the kitty protocol a background loop finds the Ctrl-C sequence in the key file); it stops the evaluation, pops the flags (`CSI < u`), drops the input still arriving and restores the terminal on exit. `DOOM_TICS`, `DOOM_TICKS`, `DOOM_VIEW` and `DOOM_ARGS` are passed on.
- `toolchain/doom.nix` — build-only derivation behind `nix build .#doom-scaffold`: cross-compiles unpatched doomgeneric for RV32IM with clang + lld against headers and stubs generated from `lib/hostcall.nix`; outputs `doom.elf`, `doom.hex` and `doom.dis`.
- `scaffold/` — doomgeneric on the emulator: `boot.nix` (loads the ELF, builds argv on the stack, runs with `runUntil` of `lib/cpu.nix` until a frame count), `platform.nix` (the `DG_*` host calls: frame records, which also hold the memory at the frame and the screen address, a virtual clock, and the queue of key events `keys` that `DG_GetKey` takes from the front), `render.nix` (ANSI still image), `profile.nix` (pc samples summed by function), `default.nix` (`scaffold.boot.report`, `scaffold.title`, `scaffold.demo.report`).
- `doom/` — Doom compiled by the Nix C compiler and run by `nix eval`: `default.nix` (the entries `doom.title`, `doom.report` and `doom.play`, and the environment variables), `link.nix` (the one-shot `cc.linkFiles` of the units of `SRC_DOOM` in the Makefile of the doomgeneric sources, without the platform files; the sources are never copied into the repository), `run.nix` (the driver: places argv, calls `doomgeneric_Create`, points `DG_ScreenBuffer` at `I_VideoBuffer` (when `fb_scaling` is 1) and, with `view`, sets Doom's screen size as the menu does, and then calls `doomgeneric_Tick` per tick; with `tics = N >= 1` it moves the virtual clock `mem.host.ms` to the boundary N tics ahead before each tick, through calls of `TryRunTics` of at most 5 tics each and then `doomgeneric_Tick`, so that a tick runs N tics and draws once, and with `tics = 0` it leaves the clock to Doom; it reads the key file (decoded as `keyProto` says, legacy or kitty) before each tick at which no key event is pending, because with `tics = 0` Doom takes events only at every other tick, and after each tick hands the frame records and guest output to `onTick` and empties them), `keys.nix` (pure decoding of terminal input into doomkeys numbers, and `poll`, which turns the growing key file into press and release events with made-up releases; `decodeKitty` and `pollKitty` do the same for the kitty keyboard protocol, passing on the reported presses and releases and putting off to the next poll the release of a key pressed and released between two polls), `render.nix` (`fit`, `render` and `renderMem`: the variable-size `▀` image of the whole screen, byte for byte that of `scaffold/render.nix` at 160 x 50, or of any rectangle of it read from the memory of a frame record, with a fast path when a half cell is one pixel), `picture.nix` (`blocksFor`, the screen size for a width, and `picture`: the whole screen, or, while the 3D view is on, the view window with the status bar under it).
- `tests/unit.nix`, `tests/mext.nix`, `tests/dsl.nix` — RV32I, M-extension and eDSL tests; every CPU test runs both with and without a code region and the two must agree (`tests/paths.nix`). `tests/mem.nix` checks `lib/mem.nix` against a naive reference built from `loadWordAt` / `storeWordAt`, `storeRun` / `storeStride` against a `storeByte` fold, and `readPages` and `readLeaves` / `leafByte` against `loadByte`.
- `cc/` — the C compiler written in Nix (C source -> Nix source): `pp.nix` (preprocessor: C99 6.10 without variadic macros, `#pragma` and `#line`), `lex.nix` (lexer, also of preprocessing tokens), `parse.nix` (parser), `check.nix` (type checker), `emit.nix` (Nix code generator), `runtime.nix` (runtime helpers used by the generated code), `link.nix` (linker: checks and compiles each translation unit on its own, places the data of the units one after another, each from a multiple of 8, then the host data they use, and ties them together through a lazily built symbol table; link errors are `cc: link: ...`), `host.nix` (the shape of a host, the functions and variables a linked program uses without defining them in C, with their state in the memory under `host`; `mk { wad ? null; }` and `default` are the libc of `lib/libc.nix` and the platform layer of `scaffold/platform.nix` over the int/ptr/void entries of `lib/hostcall.nix`, with `errno` as host data, and `empty` has nothing; `exit` throws `exitText`: the status followed by the output not yet shown), `default.nix` (`compile` / `load` of preprocessed C; `preprocess`, and `compileFile` / `loadFile`, which preprocess the files given by a `read` function (`readFrom` reads them from directories) and report errors as `<file>:<line>:<col>`; `linkSources` (units `[ { name; src; } ]`) and `linkFiles` (files preprocessed like `compileFile`), which link several units with a `host` (`cc.host.default` unless given) and optionally `allowUndefined`, and return the external functions with `__data` (`symbols`, `units.<unit>`, `undefined`, ...), `__units.<unit>.nix` and `__init` (apply it to the memory first)), `examples/spike.nix` (the M0 reference C as a string), `examples/draw.nix` (the same workload in Doom's shape: file-scope variables, argument-less draw functions, early return). The input of `compile` is preprocessed C; the accepted subset (declarations including function pointers, unions, bit-fields and attributes, the comma operator, `static` locals, side effects right of `&&`/`||`, string literals, `goto` and labels (rewritten into flags and loops by the parser), `float`/`double` values, `va_list` variables (`va_start`, `va_arg`, `va_copy`), definitions of variadic functions, `__builtin_va_list` in typedefs and in the parameters of function declarations, and, when linking, calls to variadic functions, which pass the promoted variable arguments as one Nix list after the fixed ones) and its exact rules are described at the top of each file, and anything outside it stops with `unsupported: ...`. File-scope variables live at fixed addresses in a data area (`__data` of the compiled output holds `base`, `size`, `symbols`, `strings` and `init`; `compileWith` / `loadWith` take `dataBase`); `static` locals follow them in source order, with symbols `<function>'<name>'<line>'<col>` (`<function>'<name>'<seq>` for preprocessed input, where tokens of one macro expansion share a position and `seq`, the index of the token in the translation unit, identifies nodes instead), and then one array per distinct string literal contents (listed in `__data.strings`). A word load or store at a constant address that is a multiple of 4 goes to the memory trie by literal keys, a load as `mem."k0"."k1"."k2"."k3" or 0` and a store through `sw-<address>`, a function of the unit that copies the path as `M.storeWord` does, instead of through `M.loadWord` / `M.storeWord`. `emit.nix` drives a loop with no condition to test with `R.loopDo`, and an innermost loop without calls caches its reads at constant addresses in loop variables, read again after any store that may overlap them. An innermost loop without calls that has a countable trip count (`n--`, `--n`, or a unit-step comparison), induction or temporary variables only, exactly one 1-byte store at an address `a0 + k * d` and loads of known extent runs in bulk: after an entry test (counts, address ranges below 2^32 and no overlap between the store range and the load ranges) it computes the stored values with `genList` and writes them with `M.storeRun` / `M.storeStride`, and when the test is false it runs the ordinary loop. In the bulk form, 1-byte reads of a table (an invariant `char` pointer plus an index of known range, at most 16384 bytes) read the table's leaves once on entry with `M.readPages` when the count reaches a threshold (32, or 8 per leaf the table may touch if that is more), and below it take the leaf sets once with `M.readLeaves` and read each byte with `M.leafByte`. The function given to `genList` keeps only the bindings its value uses. The exact rules are at the top of `cc/emit.nix`. A generated function forces the memory it receives on entry, and `R.loop` / `R.loopDo` force it after every iteration, so that the chain of lazy bindings stays short. `float` and `double` are Nix floats, a `float` rounded to single precision at every operation (`R.toF32`); a `va_list` is a Nix binding of the list of variable arguments. A function pointer is the number of a function (from 1, 0 is null; numbers go to the functions used as values, in unit order), and any expression of function pointer type can be called: the call is `(elemAt <table> <pointer>) mem <args>` over one list per shape (the representation classes of the return and parameter types), which the linker generates, with a fitting function as the element itself and any other wrapped by an adapter that pads missing arguments with 0 and drops extra ones. Arrays, structs, unions and address-taken variables and parameters of a function live in a fixed frame in the data area, one per function and not per call, so a re-entered function overwrites its own frame; an array used only through constant indices is split into Nix bindings instead (`<name>'<k>'`), and a struct or union assignment reads all its words first and then writes them.
- `tests/doom.nix` — tests of `doom/` that need neither the WAD nor the Doom sources: key decoding and `poll`, the kitty decoding and `pollKitty`, `fit`, `render` (against `scaffold/render.nix`) and `renderMem`, `picture` and `blocksFor` over an artificial memory, `DG_GetKey`, the driver on small linked C programs (including the view window, `fb_scaling` and `keyProto = "kitty"`), and `exitText`.
- `tests/cc.nix`, `tests/pp.nix`, `tests/link.nix` — tests of the Nix C compiler, of its preprocessor and of its linker (with the default host: libc, platform layer and variadic calls).
- `tests/fastpath.nix` — regression and self-modifying-code tests for the code-region path.
- `tests/xdoom.nix` — both-path tests for the `fixmul` (custom-0) instruction, the equivalence tests of the five spike variants (`rv`, `rvx`, `nix`, `cc`, `draw`), the packed-position rows of `R_DrawSpan` of `draw`, and the boundary tests of the frame-cost calculation, the spike verdict, the cc gate (1.25) and the draw gate (0.65).
- `examples/fizzbuzz/` — FizzBuzz in the eDSL.
- `examples/fizzbuzz-c/`, `toolchain/guest.nix` — transitional clang-built C version and its hex fixture.
- `bench/spike/` — the M0 execution-strategy spike: `data.nix` (shared memory image and checks), `rv.nix` / `rvx.nix` (clang output transcribed to the eDSL, without / with `fixmul`), `nix.nix` (the C translated to Nix), `default.nix` (`bench.spike.*` workloads and the report with its verdict). Variant `cc` is the same C compiled by `cc/`; `bench.spike.ccReport` compares it with `nix` and prints the `CC GATE:` line (the cost of a frame is measured with 5 frames against 1). Variant `draw` is `cc/examples/draw.nix` compiled by `cc/` (the memory is initialized with `__data.init` first); `bench.spike.drawReport` compares it with `nix` and prints the `DRAW GATE:` line (bound 0.65). `bench.spike.screens` holds the sha256 of the screen after one full frame of `nix`, `cc` and `draw`.
- `fixmul` (`lib/cpu.nix`, encoder in `lib/asm.nix`) — custom-0 instruction for Doom's fixed-point multiply: `(a * b) >> 16` on signed 32-bit operands via a 64-bit product.
- `bench/` — `workload.nix`, `report.nix` (Doom performance budget), `format.nix` (shared number/string formatting), `default.nix` (`bench.run` / `bench.report`).
- `docs/design.md` — the approach in brief (C compiled to Nix functions, run by `nix eval` alone) and the deliberate deviations of compiled code from C (`exit` as `throw`, lazy pure computations, wrapping, unchecked division and shifts, variadic arguments as a Nix list, the host state in the memory), each with its reason and observable difference.

## Performance budget

`bench.report` is the source of truth for "how fast must the emulator be for Doom to feel comfortable". It reports the measured cost per instruction and, for each target frame rate (comfortable 35 fps = Doom's tic rate, playable 10 fps, slideshow 1 fps), the required us/instr and the speedup still needed. Doom's instructions per frame are not measured yet; once they are, pass the value as `doomInstrPerFrame` in `bench/report.nix`.

## Constraints and design decisions

- The emulator never triggers a build (no IFD). External binaries (ELF, later the WAD) are read as committed or user-provided hex text.
- `builtins.readFile` cannot read binaries containing NUL; binaries are converted with `od -An -v -tx1 | tr -d ' \n'` (or `xxd -p`) and parsed in Nix.
- Output to a TTY: `builtins.trace` streams during evaluation. On a terminal (measured on a pseudo-terminal) it keeps SGR sequences (`ESC[…m`, colors) and drops the other escapes (clear screen, cursor movement), so `doom.play` streams each frame as a block of lines scrolling vertically. `nix eval --raw` keeps all escapes. nixboy streams frames with `trace`.
- Input during an evaluation (Nix 2.34.9, measured): `builtins.readFile` cannot read a FIFO (the first read gives `""`, the second never returns) and a `/proc` file reads as `""`. A regular file is read again at every `readFile`, even with the same path, so input is a regular file that something outside appends to, read before every tick at which no key event is pending. A NUL byte in the key file (Ctrl-Space) makes `readFile` abort the whole evaluation; it cannot be prevented.
- A clock is not observable inside an evaluation; benchmarks read `cpuTime` from `NIX_SHOW_STATS_PATH`.
- State is forced every 64 steps (`strict` in `lib/cpu.nix`), and memory-trie paths on every store (`storeWordAt`). Fully lazy state builds thunk chains that blow up memory; forcing every step costs about 2.4x in speed.
- `tail` and list updates copy in O(n), so the hot path never updates lists. Registers and memory are updated with attribute-set `//`.
- Nix `div` truncates toward zero; arithmetic right shift corrects this to floor.

## References and acknowledgements

Prior art studied for this project. Ideas only; no code is copied (nixcc and nix-riscv have no license, so their code may not be reused). The eventual README must credit each of them in an Acknowledgements section.

- [psyclyx/nixboy](https://github.com/psyclyx/nixboy) — Game Boy emulator in Nix: `builtins.trace` frame streaming, input timelines, JSON checkpoints, hex ROM loading.
- [eisbaw/nixcc](https://github.com/eisbaw/nixcc) — C compiler in Nix targeting RV32I (a port of lcc): lcc-style AST → DAG → rule-table instruction selection suits a language without mutation.
- [eisbaw/nix-riscv](https://github.com/eisbaw/nix-riscv) — RV32I emulator in Nix.
