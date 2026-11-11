# nix-doom-tui

An experiment: write an RV32IM emulator in pure Nix (`nix eval` only, no derivations) and eventually run Doom on it in a terminal.

## Goals

- **100% Nix evaluation.** The emulator and everything it needs at runtime is plain Nix expressions evaluated by `nix eval`. No derivations, no IFD, no external processes.
- **Runs in a TTY.** The output is a string printed to a terminal; no GUI, no framebuffer device.
- **ASCII rendering.** Frames are rendered as ASCII text.
- **Color (nice to have).** ANSI escape sequences for color are desirable but optional.

## Language

- All code comments, documentation, and commit messages are written in **English**.
- The only exceptions are git-ignored private files: `CLAUDE.local.md` (the local handoff note) and `docs/private/` (detailed working documents), which may be written in any language.

## What "100% Nix" means here

Not just the emulator: the guest programs are Nix too.

- **Emulator** — pure Nix, evaluated by `nix eval`.
- **Our guest code** (examples, tests, and later the Doom platform glue) — written in the Nix eDSL (`lib/dsl.nix`) as Nix values, assembled into RV32I machine code by Nix. No C, no assembler strings.
- **Doom itself** — the upstream C source is an external input (like a ROM for nixboy). The long-term plan is to compile it with a C compiler written in Nix. Rewriting Doom by hand in Nix is out of scope.
- **No scripts.** Steps that need something outside an evaluation (setting `NIX_SHOW_STATS`, providing a WAD) are documented one-line commands, in the style of [nixboy](https://github.com/psyclyx/nixboy).

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
| Format | `nix fmt` |

The flake exposes only `lib`, `tests`, `fizzbuzz` and `fizzbuzzC`, so the commands on those also work as `.#<attr>` (flakes only see git-tracked files, so `git add -N` new files first). `bench.*`, `scaffold.*` and `cc.*` are used with `-f .` only.

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

Regenerate the transitional C fixture: `nix build .#fizzbuzz-c && cp result/fizzbuzz.hex examples/fizzbuzz-c/`.

## Layout

- `lib/bits.nix` — 32-bit arithmetic. Values are always unsigned (0..2^32-1). Shifts use a power-of-two table with multiply/divide.
- `lib/mem.nix` — persistent trie over word addresses, 4 levels of 12+6+6+6 bits (sparse 1 MiB-granular root, then 64-ary nodes). Sparse; unwritten words read as 0. An update copies the 4 nodes on the path. Chosen over the previous 5x6-bit layout with `bench/memlayout.nix`: 12-18% faster at the memory interface (4 KB and 6 MiB workloads); the whole-emulator benchmark, which stores once per 8 instructions, shows no difference beyond noise. Byte accessors use a 16384-entry table indexed by the low 14 bits of the address (one lookup for the lower keys, byte divisor and keep mask; `storeByte` walks the path once), `storeRun` writes many bytes with one `//` per leaf (the partial words at both ends merged with their old bytes), and `storeStride` with one `//` per 16 KiB node for a stride of 256 or more, updating the node directly when all bytes lie in one (a stride of 1 is `storeRun`, 2 to 255 fold `storeByte`). `readPages` returns the 256-byte leaves over a byte range as lazy lists of bytes; `readLeaves` returns the same leaves as a lazy list of leaf sets, read byte by byte with `leafByte`.
- `lib/cpu.nix` — RV32IM. The words of the decode-cache region (`mkState { code = { base; size; }; }`; `runProgram` declares the whole image, code and data) are decoded once into a lazy list of threaded ops (`state -> state`). Inside the region, straight-line code and direct branches/jumps go to the linked successor op without a fetch; once a store touches the region, fetch goes through the checked path, which re-reads memory and re-decodes changed words. Outside the region every instruction is decoded from the memory trie. `run` folds in chunks and forces state every 64 steps. ECALL supports a7=64 write and a7=93 exit; a7 >= 1000 is a host call, delegated to `state.host.call` (`mkState { host = { call; ... }; }`, see `lib/hostcall.nix`).
- `lib/dsl.nix` — the guest eDSL: instructions, pseudo-instructions (`li`, `la`, `call`, ...), labels, data (`string`, `space`, `align`), and structured control flow (`when`, `ifElse`, `while`). Two-pass assembler `assemble` and loader `toMemory`.
- `lib/asm.nix` — raw instruction encoders used by the eDSL (encodings verified against llvm-mc).
- `lib/ascii.nix` — chr/ord tables.
- `lib/elf.nix` — parses a hex-encoded ELF32 and places its PT_LOAD segments (for external guests such as Doom).
- `lib/hostcall.nix` — the host-call table (libc, compiler runtime and doomgeneric's `DG_*`; the single source of truth for the generated guest headers and ecall stubs) and the emulator-side `dispatch`.
- `lib/libc.nix` — the host-call libc in Nix: pure functions over a libc world (`{ mem; brk; files; out; ... }`), independent of CPU state; WAD reads decode only the requested range of the hex text.
- `toolchain/doom.nix` — build-only derivation behind `nix build .#doom-scaffold`: cross-compiles unpatched doomgeneric for RV32IM with clang + lld against headers and stubs generated from `lib/hostcall.nix`; outputs `doom.elf`, `doom.hex` and `doom.dis`.
- `scaffold/` — doomgeneric on the emulator: `boot.nix` (loads the ELF, builds argv on the stack, runs with `runUntil` of `lib/cpu.nix` until a frame count), `platform.nix` (the `DG_*` host calls: frame records and a virtual clock), `render.nix` (ANSI still image), `profile.nix` (pc samples summed by function), `default.nix` (`scaffold.boot.report`, `scaffold.title`, `scaffold.demo.report`).
- `tests/unit.nix`, `tests/mext.nix`, `tests/dsl.nix` — RV32I, M-extension and eDSL tests; every CPU test runs both with and without a code region and the two must agree (`tests/paths.nix`). `tests/mem.nix` checks `lib/mem.nix` against a naive reference built from `loadWordAt` / `storeWordAt`, `storeRun` / `storeStride` against a `storeByte` fold, and `readPages` and `readLeaves` / `leafByte` against `loadByte`.
- `cc/` — the C compiler written in Nix (C source -> Nix source): `pp.nix` (preprocessor: C99 6.10 without variadic macros, `#pragma` and `#line`), `lex.nix` (lexer, also of preprocessing tokens), `parse.nix` (parser), `check.nix` (type checker), `emit.nix` (Nix code generator), `runtime.nix` (runtime helpers used by the generated code), `link.nix` (linker: checks and compiles each translation unit on its own, places the data of the units one after another, each from a multiple of 8, then the host data they use, and ties them together through a lazily built symbol table; link errors are `cc: link: ...`), `host.nix` (the shape of a host, the functions and variables a linked program uses without defining them in C, with their state in the memory under `host`; the default host is empty), `default.nix` (`compile` / `load` of preprocessed C; `preprocess`, and `compileFile` / `loadFile`, which preprocess the files given by a `read` function (`readFrom` reads them from directories) and report errors as `<file>:<line>:<col>`; `linkSources` (units `[ { name; src; } ]`) and `linkFiles` (files preprocessed like `compileFile`), which link several units with a `host` and optionally `allowUndefined`, and return the external functions with `__data` (`symbols`, `units.<unit>`, `undefined`, ...), `__units.<unit>.nix` and `__init` (apply it to the memory first)), `examples/spike.nix` (the M0 reference C as a string), `examples/draw.nix` (the same workload in Doom's shape: file-scope variables, argument-less draw functions, early return). The input of `compile` is preprocessed C; the accepted subset (declarations including function pointers, unions, bit-fields and attributes, the comma operator, `static` locals, side effects right of `&&`/`||`, string literals) and its exact rules are described at the top of each file, and anything outside it stops with `unsupported: ...`. File-scope variables live at fixed addresses in a data area (`__data` of the compiled output holds `base`, `size`, `symbols`, `strings` and `init`; `compileWith` / `loadWith` take `dataBase`); `static` locals follow them in source order, with symbols `<function>'<name>'<line>'<col>` (`<function>'<name>'<seq>` for preprocessed input, where tokens of one macro expansion share a position and `seq`, the index of the token in the translation unit, identifies nodes instead), and then one array per distinct string literal contents (listed in `__data.strings`). `emit.nix` drives a loop with no condition to test with `R.loopDo`, and an innermost loop without calls caches its reads at constant addresses in loop variables, read again after any store that may overlap them. An innermost loop without calls that has a countable trip count (`n--`, `--n`, or a unit-step comparison), induction or temporary variables only, exactly one 1-byte store at an address `a0 + k * d` and loads of known extent runs in bulk: after an entry test (counts, address ranges below 2^32 and no overlap between the store range and the load ranges) it computes the stored values with `genList` and writes them with `M.storeRun` / `M.storeStride`, and when the test is false it runs the ordinary loop. In the bulk form, 1-byte reads of a table (an invariant `char` pointer plus an index of known range, at most 16384 bytes) read the table's leaves once on entry with `M.readPages` when the count reaches a threshold (32, or 8 per leaf the table may touch if that is more), and below it take the leaf sets once with `M.readLeaves` and read each byte with `M.leafByte`. The function given to `genList` keeps only the bindings its value uses. The exact rules are at the top of `cc/emit.nix`.
- `tests/cc.nix`, `tests/pp.nix`, `tests/link.nix` — tests of the Nix C compiler, of its preprocessor and of its linker.
- `tests/fastpath.nix` — regression and self-modifying-code tests for the code-region path.
- `tests/xdoom.nix` — both-path tests for the `fixmul` (custom-0) instruction, the equivalence tests of the five spike variants (`rv`, `rvx`, `nix`, `cc`, `draw`), the packed-position rows of `R_DrawSpan` of `draw`, and the boundary tests of the frame-cost calculation, the spike verdict, the cc gate (1.25) and the draw gate (0.65).
- `examples/fizzbuzz/` — FizzBuzz in the eDSL.
- `examples/fizzbuzz-c/`, `toolchain/guest.nix` — transitional clang-built C version and its hex fixture.
- `bench/spike/` — the M0 execution-strategy spike: `data.nix` (shared memory image and checks), `rv.nix` / `rvx.nix` (clang output transcribed to the eDSL, without / with `fixmul`), `nix.nix` (the C translated to Nix), `default.nix` (`bench.spike.*` workloads and the report with its verdict). Variant `cc` is the same C compiled by `cc/`; `bench.spike.ccReport` compares it with `nix` and prints the `CC GATE:` line (the cost of a frame is measured with 5 frames against 1). Variant `draw` is `cc/examples/draw.nix` compiled by `cc/` (the memory is initialized with `__data.init` first); `bench.spike.drawReport` compares it with `nix` and prints the `DRAW GATE:` line (bound 0.65). `bench.spike.screens` holds the sha256 of the screen after one full frame of `nix`, `cc` and `draw`.
- `fixmul` (`lib/cpu.nix`, encoder in `lib/asm.nix`) — custom-0 instruction for Doom's fixed-point multiply: `(a * b) >> 16` on signed 32-bit operands via a 64-bit product.
- `bench/` — `workload.nix`, `report.nix` (Doom performance budget), `format.nix` (shared number/string formatting), `default.nix` (`bench.run` / `bench.report`).

## Performance budget

`bench.report` is the source of truth for "how fast must the emulator be for Doom to feel comfortable". It reports the measured cost per instruction and, for each target frame rate (comfortable 35 fps = Doom's tic rate, playable 10 fps, slideshow 1 fps), the required us/instr and the speedup still needed. Doom's instructions per frame are not measured yet; once they are, pass the value as `doomInstrPerFrame` in `bench/report.nix`.

## Constraints and design decisions

- The emulator never triggers a build (no IFD). External binaries (ELF, later the WAD) are read as committed or user-provided hex text.
- `builtins.readFile` cannot read binaries containing NUL; binaries are converted with `od -An -v -tx1 | tr -d ' \n'` (or `xxd -p`) and parsed in Nix.
- Output to a TTY: `builtins.trace` streams during evaluation and keeps ANSI color when stderr is a real terminal (it strips escapes when piped). `nix eval --raw` always keeps them. nixboy streams frames with `trace`.
- A clock is not observable inside an evaluation; benchmarks read `cpuTime` from `NIX_SHOW_STATS_PATH`.
- State is forced every 64 steps (`strict` in `lib/cpu.nix`), and memory-trie paths on every store (`storeWordAt`). Fully lazy state builds thunk chains that blow up memory; forcing every step costs about 2.4x in speed.
- `tail` and list updates copy in O(n), so the hot path never updates lists. Registers and memory are updated with attribute-set `//`.
- Nix `div` truncates toward zero; arithmetic right shift corrects this to floor.

## References and acknowledgements

Prior art studied for this project. Ideas only; no code is copied (nixcc and nix-riscv have no license, so their code may not be reused). The eventual README must credit each of them in an Acknowledgements section.

- [psyclyx/nixboy](https://github.com/psyclyx/nixboy) — Game Boy emulator in Nix: `builtins.trace` frame streaming, input timelines, JSON checkpoints, hex ROM loading.
- [eisbaw/nixcc](https://github.com/eisbaw/nixcc) — C compiler in Nix targeting RV32I (a port of lcc): lcc-style AST → DAG → rule-table instruction selection suits a language without mutation.
- [eisbaw/nix-riscv](https://github.com/eisbaw/nix-riscv) — RV32I emulator in Nix.
