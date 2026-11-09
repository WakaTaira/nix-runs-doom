# nix-doom-tui

An experiment: write an RV32IM emulator in pure Nix (`nix eval` only, no derivations) and eventually run Doom on it in a terminal.

## Goals

- **100% Nix evaluation.** The emulator and everything it needs at runtime is plain Nix expressions evaluated by `nix eval`. No derivations, no IFD, no external processes.
- **Runs in a TTY.** The output is a string printed to a terminal; no GUI, no framebuffer device.
- **ASCII rendering.** Frames are rendered as ASCII text.
- **Color (nice to have).** ANSI escape sequences for color are desirable but optional.

## Language

- All code comments, documentation, and commit messages are written in **English**.
- The only exception is `CLAUDE.local.md` (the git-ignored local handoff note), which may be written in any language.

## What "100% Nix" means here

Not just the emulator: the guest programs are Nix too.

- **Emulator** — pure Nix, evaluated by `nix eval`.
- **Our guest code** (examples, tests, and later the Doom platform glue) — written in the Nix eDSL (`lib/dsl.nix`) as Nix values, assembled into RV32I machine code by Nix. No C, no assembler strings.
- **Doom itself** — the upstream C source is an external input (like a ROM for nixboy). The long-term plan is to compile it with a C compiler written in Nix. Rewriting Doom by hand in Nix is out of scope.
- **No scripts.** Steps that need something outside an evaluation (setting `NIX_SHOW_STATS`, providing a WAD) are documented one-line commands, in the style of [nixboy](https://github.com/psyclyx/nixboy).

Transitional exception: `examples/fizzbuzz-c` embeds C in a Nix string and builds it with clang via `toolchain/guest.nix`. It exists only to compare against the eDSL version and will be removed.

## Commands

| Purpose | Command |
|---|---|
| Unit tests (evaluation fails on any failure) | `nix eval --raw -f . tests.check` |
| Test details (got/expected for failures) | `nix eval --json -f . tests.summary` |
| FizzBuzz (eDSL guest) stdout | `nix eval --raw -f . fizzbuzz.stdout` |
| FizzBuzz run stats | `nix eval --json -f . fizzbuzz.stats` |
| Transitional C FizzBuzz | `nix eval --raw -f . fizzbuzzC.stdout` |
| Format | `nix fmt` |

All of these also work as `.#<attr>` through the flake (flakes only see git-tracked files, so `git add -N` new files first).

Performance budget (two evaluations; the first lets Nix record its own CPU time):

```sh
export NIX_SHOW_STATS_PATH=/tmp/nix-doom-bench.json
NIX_SHOW_STATS=1 nix eval -f . bench.run
nix eval --raw -f . bench.report
```

Regenerate the transitional C fixture: `nix build .#fizzbuzz-c && cp result/fizzbuzz.hex examples/fizzbuzz-c/`.

## Layout

- `lib/bits.nix` — 32-bit arithmetic. Values are always unsigned (0..2^32-1). Shifts use a power-of-two table with multiply/divide.
- `lib/mem.nix` — persistent 64-ary trie over word addresses (5 levels x 6 bits). Sparse; unwritten words read as 0. An update copies the 5 nodes on the path.
- `lib/cpu.nix` — RV32IM. `step` (one instruction) and `run` (loop that runs `foldl'` in chunks). ECALL supports only a7=64 write and a7=93 exit.
- `lib/dsl.nix` — the guest eDSL: instructions, pseudo-instructions (`li`, `la`, `call`, ...), labels, data (`string`, `space`, `align`), and structured control flow (`when`, `ifElse`, `while`). Two-pass assembler `assemble` and loader `toMemory`.
- `lib/asm.nix` — raw instruction encoders used by the eDSL (encodings verified against llvm-mc).
- `lib/ascii.nix` — chr/ord tables.
- `lib/elf.nix` — parses a hex-encoded ELF32 and places its PT_LOAD segments (for external guests such as Doom).
- `tests/unit.nix`, `tests/mext.nix`, `tests/dsl.nix` — RV32I, M-extension and eDSL tests.
- `examples/fizzbuzz/` — FizzBuzz in the eDSL.
- `examples/fizzbuzz-c/`, `toolchain/guest.nix` — transitional clang-built C version and its hex fixture.
- `bench/` — `workload.nix`, `report.nix` (Doom performance budget), `default.nix` (`bench.run` / `bench.report`).

## Performance budget

`bench.report` is the source of truth for "how fast must the emulator be for Doom to feel comfortable". It reports the measured cost per instruction and, for each target frame rate (comfortable 35 fps = Doom's tic rate, playable 10 fps, slideshow 1 fps), the required us/instr and the speedup still needed. Doom's instructions per frame are not measured yet; once they are, pass the value as `doomInstrPerFrame` in `bench/report.nix`.

## Constraints and design decisions

- The emulator never triggers a build (no IFD). External binaries (ELF, later the WAD) are read as committed or user-provided hex text.
- `builtins.readFile` cannot read binaries containing NUL; binaries are converted with `od -An -v -tx1 | tr -d ' \n'` (or `xxd -p`) and parsed in Nix.
- Output to a TTY: `builtins.trace` streams during evaluation and keeps ANSI color when stderr is a real terminal (it strips escapes when piped). `nix eval --raw` always keeps them. nixboy streams frames with `trace`.
- A clock is not observable inside an evaluation; benchmarks read `cpuTime` from `NIX_SHOW_STATS_PATH`.
- State updates are forced with `seq` (`commit`, `storeWordAt`). Left lazy, thunks chain and memory blows up.
- `tail` and list updates copy in O(n), so the hot path never updates lists. Registers and memory are updated with attribute-set `//`.
- Nix `div` truncates toward zero; arithmetic right shift corrects this to floor.

## References and acknowledgements

Prior art studied for this project. Ideas only; no code is copied (nixcc and nix-riscv have no license, so their code may not be reused). The eventual README must credit each of them in an Acknowledgements section.

- [psyclyx/nixboy](https://github.com/psyclyx/nixboy) — Game Boy emulator in Nix: `builtins.trace` frame streaming, input timelines, JSON checkpoints, hex ROM loading.
- [eisbaw/nixcc](https://github.com/eisbaw/nixcc) — C compiler in Nix targeting RV32I (a port of lcc): lcc-style AST → DAG → rule-table instruction selection suits a language without mutation.
- [eisbaw/nix-riscv](https://github.com/eisbaw/nix-riscv) — RV32I emulator in Nix.
