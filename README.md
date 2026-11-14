# nix-runs-doom

[Japanese version](README.ja.md)

Doom, run by `nix eval` and nothing else. Inside one Nix evaluation, a C compiler written in Nix compiles the 80 C files of [doomgeneric](https://github.com/ozkl/doomgeneric) into Nix functions, a libc and a platform layer written in Nix support them, and a driver steps the game frame by frame and draws each frame in the terminal with 24-bit colour half-block characters (`▀`). No derivation is built, no IFD, no external process computes anything.

## Quick start

You need Nix with flakes and a Doom WAD. The shareware `doom1.wad` is freely distributed; the sources of Doom and the WAD are not part of this repository.

```sh
nix run github:WakaTaira/nix-runs-doom#play -- /path/to/doom1.wad
```

Inside a clone, `nix run .#play -- /path/to/doom1.wad` does the same. The WAD is converted to hex text once and cached in `~/.cache/nix-runs-doom`. The first frame appears after about 45 seconds on the author's machine, because all 80 files are compiled at every start.

The launcher (`toolchain/play.nix`) is a short shell script and does no Doom computation. An evaluation cannot read a terminal, so the launcher puts the terminal in raw mode, writes the keys to a file, starts `nix eval -f . doom.play`, and copies the frames from the log of the evaluation to the screen.

| Key | Action |
|---|---|
| Arrow keys | Move, turn |
| Ctrl or `x` | Fire |
| Space | Use |
| Shift | Run |
| Alt | Strafe |
| Esc | Menu |
| Enter | Confirm |
| Ctrl-C | Quit |

Holding several keys at once, and Ctrl, Shift and Alt alone, need a terminal that reports key releases: one that speaks the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), or Windows Terminal through its win32-input-mode. The launcher asks the terminal and picks what it supports. In other terminals a key counts as pressed for one frame after you press it, and `x` is the way to fire. Inside a terminal multiplexer, release events may get lost.

Without the launcher (the environment variables are described in `CLAUDE.md` and `doom/default.nix`):

```sh
export DOOM_SRC=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.doomgeneric.outPath')/doomgeneric
export DOOM_WAD_HEX=~/doom1.wad.hex   # od -An -v -tx1 doom1.wad | tr -d ' \n' > ~/doom1.wad.hex
GC_INITIAL_HEAP_SIZE=4g nix eval --raw -f . doom.play < /dev/null
```

## How it works

```
Doom C sources (80 files)
        |
        v
[ C compiler in Nix: cc/ ]   preprocess, lex, parse, type-check, emit, link
        |
        v
Nix functions   (memory in, memory out)
        |
        v
[ driver: doom/ ]   keys in, virtual clock, one frame per step
        |
        v
frames  ->  terminal
```

- **Compiler (`cc/`).** It turns C source into Nix source: each C function becomes a Nix function that takes the memory and the arguments and returns the new memory and a result. The generated source is imported in the same evaluation. It accepts the C that Doom uses, not all of C, and it deliberately differs from C in places where Doom does not care and speed gains (`docs/design.md`).
- **Host (`lib/libc.nix`, `scaffold/platform.nix`, `cc/host.nix`).** The libc functions and doomgeneric's `DG_*` platform calls are Nix functions over the same memory.
- **Driver (`doom/`).** It calls `doomgeneric_Create`, then `doomgeneric_Tick` once per frame, reads the keys, advances the clock, turns the screen buffer into coloured text fitted to the terminal size, and emits it.

Some limits of an evaluation, and how the project works around them:

- **Input.** A pure evaluation cannot wait for a key, and `builtins.readFile` of a FIFO does not work. A regular file, however, is read again at every `readFile`. The launcher appends the keys to a file and the driver reads it before every frame.
- **Time.** An evaluation cannot observe a clock. Doom's clock is virtual: the driver moves it, so each frame runs a fixed number of game tics (`DOOM_TICS`, 5 by default).
- **Output.** `builtins.trace` is the only way to print during an evaluation, and the usual log format drops cursor movements. The launcher runs Nix with `--log-format internal-json`, which keeps a trace whole, and draws each frame over the previous one.
- **Keys held down.** Terminals do not report key releases, except with the kitty keyboard protocol or the win32-input-mode of Windows Terminal. The launcher asks for one of them when the terminal supports it. Otherwise the driver makes up the releases.
- **Memory.** The guest memory is a persistent 4-level trie (`lib/mem.nix`), so a store copies four small nodes and the old memory stays valid.

More detail is in `docs/design.md`.

## Performance

Measured on the author's machine.

| Item | Value |
|---|---|
| Start to first frame | about 45 s (compiling 80 files) |
| 3D scene, 160-column terminal | about 6 fps (about 0.17 s per frame) |
| Peak memory | about 4.6 GB (with `GC_INITIAL_HEAP_SIZE=4g`) |

This is slow. A frame is slower than the 35 tics per second Doom is built for, which is why each frame runs several tics. Where the time went:

- Inner loops of the drawing code (`R_DrawColumn`, `R_DrawSpan`) are recognised and computed in bulk with `genList` and bulk memory writes, instead of byte by byte.
- Reads and writes at constant addresses use literal trie keys.
- Loops are folded in growing chunks so that short loops stop early.
- The driver draws only the 3D window and status bar, sized to the terminal, and sums packed colours per character cell.
- A larger initial heap (`GC_INITIAL_HEAP_SIZE=4g`) makes the garbage collector run less often, which made a frame 8 to 12 percent faster.

## Limitations

- No sound: `nix eval` has no way to play it.
- No mouse.
- Low frame rate (see above). Maps with many monsters are slower.
- The clock is virtual. Time passes in fixed steps per frame, not with the wall clock.
- Quitting Doom ends the evaluation with an error, because `exit` is a `throw`. The launcher reads the status from it and treats exit 0 as a normal end.
- The compiler is for running Doom. It is not a general C compiler (see "Deliberate deviations from C" in `docs/design.md`).

## Tested on

| Environment | Terminal | Result |
|---|---|---|
| NixOS-WSL (WSL2), Nix 2.34.9 | A Windows fork of Ghostty (kitty keyboard protocol) | Playable, held keys and Ctrl work |
| NixOS-WSL (WSL2), Nix 2.34.9 | Windows Terminal | Playable; held keys and Ctrl alone do not work |

## Repository layout

- `cc/` — the C compiler in Nix (preprocessor, lexer, parser, type checker, code generator, linker, host interface).
- `doom/` — the driver: linking doomgeneric, keys, clock, rendering, frame streaming.
- `lib/` — 32-bit arithmetic, the memory trie, the libc, and the RV32IM emulator with its assembler eDSL.
- `scaffold/`, `toolchain/doom.nix` — the reference run of clang-built Doom on the emulator, used to cross-check the compiled one.
- `toolchain/play.nix` — the launcher behind `nix run .#play`.
- `tests/` — 1649 tests, run with `nix eval --raw -f . tests.check`.
- `bench/`, `examples/` — benchmarks and small guest programs.
- `docs/design.md` — the design and the deliberate deviations from C.

The Nix code is about 46,000 lines. `CLAUDE.md` is a development note that doubles as instructions for the AI assistant; it holds the full list of commands and files.

## License

GPL-2.0-or-later (`LICENSE`). The compiler examples, benchmarks and tests contain C and translations of Doom's drawing loops (`R_DrawColumn`, `R_DrawSpan`), which is why the whole repository is under the GPL. The C compiler in `cc/` (except `cc/examples/`) may also be used under the MIT license (`LICENSE-MIT`). The Doom sources and the WAD are not in this repository and keep their own licenses.

## Acknowledgements

These projects were studied for ideas. No code was copied.

- [psyclyx/nixboy](https://github.com/psyclyx/nixboy), a Game Boy emulator in Nix: streaming frames with `builtins.trace`, input timelines, hex ROM loading.
- [eisbaw/nixcc](https://github.com/eisbaw/nixcc), a C compiler in Nix: a compiler pipeline suits a language without mutation.
- [eisbaw/nix-riscv](https://github.com/eisbaw/nix-riscv), an RV32I emulator in Nix.

And thanks to the people whose work is the thing being run:

- id Software, for releasing the Doom source code.
- [Chocolate Doom](https://www.chocolate-doom.org/), the source port that doomgeneric builds on.
- [ozkl/doomgeneric](https://github.com/ozkl/doomgeneric), the port that needs only a few platform functions, which made this possible.

The direction of the project was set by a human (WakaTaira); most of the implementation was written by an AI (Claude Code), with the human reviewing and deciding.
