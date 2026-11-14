# Design

This project compiles C directly to Nix functions and runs them with `nix eval` alone. The
C compiler in `cc/` is itself written in Nix: it turns each C function into a Nix function
that takes the memory (a persistent trie, `lib/mem.nix`) and its arguments and returns the
new memory, or the memory and a result. The generated source is imported during the same
evaluation; nothing is built and no external process runs.

## Deliberate deviations from C for speed

Compiled code follows C except in the points below. The compiler is built to run Doom,
not general C: these points break the C semantics on purpose to make the compiled code
faster, on the ground that Doom's sources do not rely on the behaviour they break. A
general C program that does rely on it may misbehave. Most of them leave out a check or a
representation that every call or operation would pay for. A few are not about speed but
follow from the same design; they say so. Each item names the files that define the
behaviour.

### `exit` is a `throw`

- **What.** The host function `exit` (`cc/host.nix`, body in `lib/libc.nix`) throws
  `"libc: exit: <status>"`. The throw happens when the memory returned by the call is
  evaluated (`cc/link.nix`, `wrapHost` forces the new host state there), not at the point
  where C reaches the call.
- **Why.** Generated functions return the memory, or `{ mem; ret; }`. Signalling the end
  through that result would need a test after every call in every function; a `throw`
  costs nothing until `exit` is called.
- **Observable differences.**
  - A `throw` carries no state out of the evaluation, so the message itself carries the
    output still held in the memory (`mem.host.out`, see below): the status, then a line
    break and that output when there is any (`exitText` in `cc/host.nix`). The driver
    `doom/run.nix` empties `out` after each call, so what is appended is the output not yet
    shown, including the text of `I_Error`.
  - A caller that reads only the result of a function and drops the memory never sees the
    `exit`.
  - An error of a pure computation that C would run after the `exit`, but whose value is
    needed before the memory, is raised instead. For example, in
    `if (d == 0) die(); return 100 / d;` a caller that evaluates the result before the
    memory gets Nix's `division by zero`. Such errors stop the whole evaluation and cannot
    be caught with `builtins.tryEval`, while the `exit` throw can.

### Pure computations run when their value is needed

- **What.** The generated code is ordinary lazy Nix (`cc/emit.nix`): side effects (stores,
  calls, assignments) are bound in C order, but a pure value is computed only if and when
  something needs it.
- **Why.** Forcing every intermediate value would cost time on every operation.
- **Observable differences.** The failures below (division by zero, an out-of-range
  shift, a `long long` overflow) are raised only if their value is used: in
  `int x = a / b; return 1;` a `b` of 0 raises nothing, and a failure whose value is
  needed late is raised late.
- **Forced order.** A generated function forces the memory it receives on entry, and
  `R.loop` and `R.loopDo` force the memory after every iteration (`cc/emit.nix`,
  `cc/runtime.nix`). Without this, the chain of lazy bindings grew with the total number of
  statements executed, and the start of Doom hit `max-call-depth`. The limit that remains:
  about 1,000 statements in one function with no call and no loop between them still hit
  `max-call-depth` (500 pass). Doom has no such function.

### Signed 32-bit arithmetic wraps

- **What.** `+`, `-`, `*`, unary `-` and `<<` on `int` and `long`, and signed `/` and `%`
  unless the divisor is a constant other than -1, wrap to [-2^31, 2^31) (`cc/emit.nix`,
  `wrapInt` in `cc/runtime.nix`; constant folding in `cc/check.nix` folds the same way).
  In C, signed overflow is undefined.
- **Why.** Not for speed: the values match what clang's RISC-V code computes on the
  scaffold, so the two can be compared. Wrapping costs time, which `cc/emit.nix` reduces
  by leaving out the wraps that a bound on the intermediate values shows to be unneeded.
- **Observable differences.** `INT_MAX + 1` is `INT_MIN`; `INT_MIN / -1` is `INT_MIN` and
  `INT_MIN % -1` is 0.

### Division by zero is not checked

- **What.** Integer `/` and `%` become Nix `div` with no test of the divisor
  (`cc/emit.nix`). Constant folding leaves a division by zero to run time
  (`cc/check.nix`).
- **Why.** A test would be paid by every division.
- **Observable differences.** When its value is needed, a division by zero stops the
  evaluation with Nix's `division by zero`, which `builtins.tryEval` cannot catch. (C
  leaves it undefined; RISC-V hardware returns a value and goes on.)

### Shifts by a variable amount are not reduced

- **What.** A shift by a variable amount multiplies or divides by a power of two from a
  table of the powers 2^0 to 2^62 (`B.pow2` in `lib/bits.nix`), and the amount is not
  reduced: `B.shl`, `B.srl` and `B.sra` in `lib/bits.nix` and `R.shlInt` and `R.sraInt`
  in `cc/runtime.nix` for 32-bit values, `R.shlLL` and `R.sraLL` in `cc/runtime.nix` for
  `long long`. A constant amount outside the range of the type is rejected at compile
  time (`unsupported: shift of a 32-bit value by ...`, `... of a 64-bit value by ...` and
  `left shift of a 64-bit value by 63`, `cc/check.nix`).
- **Why.** Masking the amount would be paid by every variable shift.
- **Observable differences.**
  - 32-bit values (`int`, `long`, their unsigned types, and narrower types after
    promotion): an amount of 32 to 62 gives 0 (or -1 for `>>` of a negative value),
    unless the product of `<<` passes 2^63, which stops the evaluation with
    `integer overflow`; a negative amount or one of 63 or more stops it with an index
    error of `builtins.elemAt`. (C leaves these undefined; RISC-V uses the low 5 bits of
    the amount.)
  - `long long`: an amount of 0 to 63 for `>>` gives the value C defines: 0 to 62 divide
    exactly, with the floor (`R.sraLL 1099511627776 32` is 256), and 63 gives the sign,
    0 or -1. `<<` by 0 to 62 is exact, and a result that passes the range stops the
    evaluation with `integer overflow` (see below). `<<` by 63, even of 0 (which C
    defines as 0), `>>` by 64 or more and a negative amount stop it with an index error
    of `builtins.elemAt`.

### `long long` does not wrap

- **What.** `long long` values are plain Nix integers (`cc/emit.nix`, `cc/runtime.nix`);
  arithmetic on them is not wrapped to 64 bits.
- **Why.** Nix integers are 64-bit already; wrapping would add operations to each one.
- **Observable differences.** An overflow, undefined in C, stops the evaluation with Nix's
  `integer overflow`. (`unsigned long long` and 8-byte objects in memory are outside the
  supported subset and stop compilation with `unsupported: ...`.)

### Variable arguments are a Nix list

- **What.** A call to a variadic function (when linking) passes the variable arguments,
  after the default argument promotions, as one Nix list after the fixed arguments:
  `<f>_fn mem <fixed>... [ <variable>... ]` (`cc/check.nix`, `cc/emit.nix`). The host's
  `printf` family reads that list as its `va_list` (`nextArg` in `lib/libc.nix`). A
  variadic function defined in C takes the list as a hidden last parameter. A `va_list`
  variable is a Nix binding: `va_start` assigns the list to it (any number of times),
  `va_arg` takes the head and leaves the tail, and `va_copy` is an assignment (`cc/check.nix`,
  `cc/emit.nix`).
- **Why.** No argument save area has to be written to memory for each call.
- **Observable differences.**
  - A `va_list` is a Nix list, not 32-bit data: `=` on a `va_list`, storing it in memory or
    in a struct, taking its address, a cast, `sizeof` and a function pointer to a variadic
    function stop compilation with `unsupported: ...`.
  - The callee's `va_arg` does not advance the caller's list (it is passed by value; in C
    the caller's `va_list` is indeterminate after that).
  - A `va_arg` with no argument left, and a format that needs more arguments than given
    (`"libc: too few variadic arguments"`), stop the evaluation with an error that
    `builtins.tryEval` cannot catch.

### Floating point

- **What.** `float`, `double` and `long double` values are Nix floats (`cc/emit.nix`,
  `cc/runtime.nix`, `cc/check.nix`). A `float` is rounded to single precision at every
  operation, conversion, assignment, argument, return and store to memory (`R.toF32`), so
  results equal those of C. Only `atof` and `fabs` are host calls (`ccFloatTypes` and
  `floatCalls` in `lib/hostcall.nix`), and the host's `%f` prints a double.
- **Why.** Nix has floats; computing in them needs no emulation.
- **Observable differences.**
  - A division by zero is a Nix evaluation error that `builtins.tryEval` cannot catch (C
    gives inf or NaN).
  - A `double` overflow stays inf and flows on; a conversion to single precision of a value
    out of range throws; reading an inf or a NaN from memory throws; `-0.0` is stored as
    +0; a float to integer conversion out of range throws.
  - `long double` is `double`.
  - Hexadecimal floating constants and literals of 1e308 or more are `unsupported`.
  - An `f` suffix goes through a `double` first, so a literal very close to the midpoint of
    two singles can differ by 1 ulp from clang.
  - The host's `%f` supports a precision of 6 or less with no width and no flags, and
    `%.Nf` of a value with |x| >= 2^63 throws.
  - Doom computes floats only in the constants of `am_map` (folded at compile time),
    `mouse_acceleration`, the `%f` of the quit-from-menu and timedemo-end messages, and the
    path of `testcontrols`.

### `goto` is rewritten into flags and loops

- **What.** The parser rewrites `goto` and labels into a flag per label and `do ... while`
  loops on the syntax tree (`cc/parse.nix`); `cc/emit.nix` is unchanged and sees only
  structured code. Accepted: forward and backward jumps, jumps to a label inside nested
  `if`s, and jumps out of loops.
  `unsupported`: a label inside a loop or a `switch`, a `goto` from inside a `switch`, a
  forward `goto` from one branch of an `if` to a label in the other branch, and a `goto`
  that jumps over a declaration used outside the skipped range.
- **Why.** It needs no new construct in the generated code, and the cost is not on a hot
  path (`R_AddLine`, which has one, is 0.15% of the instructions).
- **Observable differences.** None known for the accepted forms; the rejected forms stop
  compilation.

### Function pointers are numbers

- **What.** A function pointer holds the number of a function, not its address: from 1
  in the order in which the functions are first used as values (unit by unit, then in
  the order of the uses), and 0 is NULL. A function with external linkage has one number
  in all units; a `static` function has its own (`cc/link.nix`, `cc/check.nix`). A call
  through a pointer is `(elemAt <table> <number>) mem <args>`: one lookup in a list that
  the linker generates for each shape, the representation classes of the return type and
  of the parameters (signed 32-bit, unsigned 32-bit or pointer, `long long`, and void for
  a return). A function whose signature has the shape of the call is the element itself;
  any other is wrapped by an adapter (`cc/link.nix`) that fills a missing argument with 0,
  drops an extra one and converts the arguments and the result like a cast. Element 0
  throws `cc: call through a null function pointer`.
- **Why.** Speed. A lookup by number costs 0.06 to 0.07 us more than a direct call
  (measured over a million calls); a general call with a check of the argument count in
  every call, or one through a list of arguments, costs several times that.
- **Observable differences.**
  - Converting a function pointer to an integer or to `void *` gives the number, and the
    number converts back; it is not an address and no arithmetic on it means anything.
  - A value that is no number of a function is not caught: calling `(actionf_v)(-1)`
    stops the evaluation with an index error of `builtins.elemAt`, which
    `builtins.tryEval` cannot catch (a range check would be paid by every call). Only
    NULL has its own message.
  - A parameter whose width differs from the one in the type of the pointer, in the same
    class (a pointer to `()` that calls a function with an `unsigned short` parameter),
    is not converted: the value goes through as it is. Parameters of another class are
    converted, and a missing argument is 0.
  - Doom's sources do not depend on these: function pointers are never used as
    addresses, and a value that is no function (`(actionf_v)(-1)`) only serves as a mark
    to compare with and is never called.

### Locals in memory live in a fixed frame

- **What.** Arrays, structs, unions, and variables and parameters whose address is taken
  (`&x`) live in memory, in a frame at a fixed address in the data area: one frame per
  function, not per call (`cc/check.nix`, "Locals in memory"). A parameter whose address
  is taken is written to its place at entry. The frame is not cleared at entry or at the
  declaration, so it keeps the values of the previous run (C leaves them indeterminate);
  an initializer is run each time the declaration is reached, writes the whole object,
  and the parts it does not mention become 0. An array of scalars that is only used
  through constant indices (`a[2]`) is not put in the frame but split into Nix bindings
  `<name>'<k>'`; an element without an initializer reads as 0 until it is assigned.
- **Why.** Speed. The frame costs nothing per call. A frame addressed from a stack
  pointer costs 0.5 to 0.7 us more in every call (measured over a million calls).
- **Observable differences.**
  - A function that is entered again while it runs (recursion, mutual recursion, or a
    call through a function pointer) overwrites the frame of the outer run with the
    inner one, and the outer run then reads the inner values. This is not diagnosed.
  - A local that is read before it is written holds the value of the last run instead of
    an unpredictable one; a split array holds 0.
  - Doom's sources do not depend on this: of the 64 functions with such locals (75
    objects, 2,900 bytes of frames) only `P_NewChaseDir` can be entered again, and its
    array is used through constant indices only, so it is split into bindings. (Its
    re-entry needs a lost soul, which the shareware WAD does not have; the demo of the
    scaffold never enters it twice at once.)

### The host state lives in the memory

- **What.** The state of the host functions (the heap break, open files, output, clock,
  frame records) is kept in the memory trie under the key `host`, which is not an address
  (`cc/host.nix`; `cc/link.nix` passes it to the host functions and back).
- **Why.** Generated functions carry one value, the memory. Carrying a separate state
  next to it would add an attribute access and an update to every memory access.
- **Observable differences.** A program's host state goes with the memory value: a driver
  must apply `__init` first and pass the memory returned by one call to the next; an older
  memory holds the older state.

### Output, input and frames of the default host

These are limitations of the default host (`cc/host.nix` over `lib/libc.nix` and
`scaffold/platform.nix`), shared with the scaffold, rather than choices made for speed.

- Output to `stdout` and `stderr` is appended to one string, `mem.host.out`, in call
  order; the host itself does not print it (`doom.play` streams what each tick added with
  `builtins.trace`), and each write copies the string, so a large amount of output costs
  quadratic time.
- `DG_GetKey` takes the key events from the front of the queue `mem.host.keys`, which the
  driver fills (see below), and returns 0 when it is empty.
- `DG_DrawFrame` records `instrs = 0` in its frame records: compiled code counts no
  instructions (`count` of the host state stays 0).

### Input and clock

How a run reads keys and tells time, in `doom/` and `scaffold/platform.nix`.

- **Input is a regular file that is read again during the run.** Nix cannot wait for input: in
  the version used (2.34.9), `builtins.readFile` of a FIFO returns `""` the first time and
  never returns the second time, and a `/proc` file reads as `""`. A regular file, on the
  other hand, is read again at every `readFile`, even with the same path, so a program
  outside the evaluation appends to a file (for example `cat > /tmp/doom.keys` in a raw
  terminal) and the driver reads its whole text before a `doomgeneric_Tick`
  (`doom/run.nix`; see the next item for which ticks). `doom/keys.nix` `poll` keeps how much of the text it has consumed and
  decodes only the new part into the key numbers of `doomkeys.h`; the events go to the end
  of the queue `keys` of the host state, from which `DG_GetKey` takes them one by one.
- **The file is read only at a tick with no pending key event.** When the driver leaves
  the clock to Doom (`tics = 0`, see the last item), doomgeneric takes key events only at
  every other tick: at one call `TryRunTics` in
  `d_loop.c` sleeps until a tic has passed, builds the new tic (taking the events) and
  returns, and at the next, with the clock not advanced, it runs that tic without taking
  events. If the file were polled at every tick, the release of a single press would be
  queued behind the press before Doom took either, the two would be taken together and
  cancel out, and a key changed at every tick would make the queue grow without end. So
  while the queue is not empty the driver does not read the file and keeps the key
  state; the bytes that arrive meanwhile are decoded together at the next read. With
  `tics >= 1` Doom takes events at each of the tics of a tick, so the queue is empty
  after a tick unless more releases were queued than tics, and the file is read before
  nearly every tick.
- **Releases are made up.** A terminal in its usual mode never reports that a key was
  released (see the kitty keyboard protocol and the win32-input-mode below for modes
  that do), and holding
  a key repeats its bytes. A key is therefore pressed from the read that
  finds its bytes until the next read. `poll` gives the presses of the keys decoded now, then
  a release for each key that was pressed at the previous read and is not decoded now.
  A key that stays down gets a new press at every read and no release. Presses come before
  releases because `I_GetEvent` in `i_input.c` stops at the first key release it hands
  over: a release placed first would be taken together with the press of a key that is
  held, in one call, and cancel it, and movement would not work. Repeating a press only
  keeps `gamekeydown` true, and in the menus it acts as auto-repeat.
- **A lone ESC is confirmed one tick late.** `ESC` is also the start of the arrow
  sequences (`ESC [ A`, `ESC O A`), so an `ESC` at the end of the text, or any cut-off
  sequence, is not decoded at once. If nothing more has arrived at the next read, it is
  read as complete (`ESC` is `KEY_ESCAPE`); otherwise it is decoded with the new bytes.
- **With the kitty keyboard protocol, releases are real.** Made-up releases fail in two
  ways a player meets at once: a terminal auto-repeats only the key pressed last, so
  holding up and then pressing right stops the bytes of up and the driver releases it
  (two keys cannot be held at once), and a modifier key alone sends nothing, so Doom's
  Ctrl (fire), Shift (run) and Alt (strafe) cannot be used. A terminal that implements
  the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
  reports, with the progressive enhancement flags 11 (disambiguate, report event types,
  report all keys as escape codes), every press, repeat and release of every key as an
  escape sequence, modifier keys alone included. `nix run .#play` asks the terminal for
  the protocol, switches it to these flags when it can, and runs `doom.play` with
  `DOOM_KEYS_PROTO=kitty`; `pollKitty` of `doom/keys.nix` then passes on the presses and
  releases as reported, drops the repeats of a key already down, and maps left or right
  Ctrl to fire, Shift to `KEY_RSHIFT` (run) and Alt to `KEY_RALT` (strafe); a character
  typed with a modifier is the character. Once the terminal has reported a release, nothing
  is made up, so a held key stays down with no more bytes while others are pressed and
  released.
- **Releases are made up until the terminal reports one.** Some terminals accept the
  flags and answer the query with them, yet send presses only (measured: a terminal behind
  a pane of a terminal multiplexer sent just `ESC [ 13 u` and `ESC [ 27 u` for Enter and Esc pressed and
  released). Trusting such a terminal leaves the key down for ever, and its next press is
  ignored. `pollKitty` therefore makes up the releases as `poll` does (a key is pressed
  again at every read that finds it and released at the first read that does not) until
  it sees a release event that the terminal wrote with its event type (`:3`); that read
  and all later ones use the events as reported. The release of the Enter that started
  the program normally arrives first. The state of `pollKitty` carries the switch as
  `trusted`.
- **A tap is held for one read.** When a key is pressed and released between two reads,
  both events would reach Doom in the same tic: `I_GetEvent` takes events up to and
  including the first release, and the press and the release would cancel out in
  `gamekeydown` (a tap of Ctrl would not fire). The release of such a key is therefore
  put off to the next read, so that the key is down for at least one tick (the
  `DOOM_TICS` tics of it).
- **Windows Terminal's win32-input-mode is the second choice.** Windows Terminal, often
  the terminal of WSL, does not answer the kitty query, but it has a mode of its own, set
  with `CSI ? 9001 h` (microsoft/terminal, `doc/specs/#4999 - Improved keyboard handling
  in Conpty.md`), in which every key event of Windows, modifier keys alone included,
  comes as `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _` (virtual-key code, scan code, character,
  key down 1 for a press or a repeat and 0 for a release, control key state, repeat
  count; an omitted field is 0, the repeat count 1). When the kitty query fails, the
  launcher asks with DECRQM (`CSI ? 9001 $ p`, then the device attributes) and sets the
  mode when the reply `CSI ? 9001 ; Ps $ y` has `Ps` 1 or 2 (set or reset), or, with no
  such reply, when `WT_SESSION` is set; it then runs `doom.play` with
  `DOOM_KEYS_PROTO=win32` (also given by hand, it sets the mode without asking), and
  resets the mode with `CSI ? 9001 l` on exit. `pollWin32` of `doom/keys.nix` takes the
  key from the virtual-key code (arrows, Enter, Esc, Tab, Backspace, space, Shift as run,
  Ctrl as fire, Alt as strafe, letters in lower case with `x` as fire, digits) and
  otherwise from a printable ASCII character (so `-` and `=` work on any layout); a
  letter typed with Ctrl carries a control character, so the virtual-key code comes
  first. Events with no virtual-key code (pasted text) are dropped. Windows reports every
  release, so `pollWin32` trusts the terminal from the first read: it passes on the
  presses and releases as `pollKitty` does once trusted (repeats of a key down dropped, a
  release of a key not down dropped, a tap held for one read), and the release of the
  Enter that started the program, usually the first event, is dropped.
- **In the kitty protocol and the win32-input-mode, Ctrl-C belongs to the launcher.**
  Ctrl-C is then a key sequence and no longer an interrupt. The launcher watches the key
  file for a press of c with the ctrl bit in its modifiers (whatever caps lock or num lock
  add) or, in the win32-input-mode, a press of the virtual key 67 (C) with the character
  3 or a control bit (left or right) in its control key state, then stops the
  evaluation, pops the flags or resets the mode and restores the terminal; this also
  works while the evaluation is still starting and reads no keys. It is the only look the
  launcher takes into the keys, which it otherwise never decodes.
- **The usual mode is the fallback.** The terminal stays in its usual mode, and
  `doom.play` makes up releases as described above (`DOOM_KEYS_PROTO=legacy`, the
  default), when the terminal takes neither the kitty protocol (it does not answer the
  query, replying only to the device attributes asked for after it or not at all within
  2 s, or it does not report the flags 11 after they are pushed) nor the
  win32-input-mode (see above), or when the launcher is given `DOOM_KEYS_PROTO=legacy`
  (with `DOOM_KEYS_PROTO=kitty` it does not ask for the win32-input-mode). The commands
  typed by hand use the usual mode.
- **Limits of the file.** A NUL byte (Ctrl-Space) in the key file makes `readFile` abort
  the whole evaluation, because a Nix string cannot hold NUL; it cannot be prevented. If
  the file becomes shorter than what was consumed, `poll` starts again from the front, so
  the file can be emptied and written anew; but if it is emptied and then written past
  its former length before the next read, the shortening goes unnoticed and the beginning
  is skipped.
- **The clock is virtual, and the driver sets the pace.** The clock `ms` of the host
  state never follows real time, so Doom never waits for a tic to pass, and keys arrive
  per tick of evaluation, not per tic of time. With `tics = 0` (`doom.report` and
  `doom.title` by default) the driver does not touch it and only `DG_SleepMs` advances
  it: as described above, `TryRunTics` then sleeps through one tick and runs one tic at
  the next, and since both ticks draw a frame (`D_Display`), which costs far more than a
  tic in 3D, the game runs at a small fraction of its speed (about 1/55). This mode stays
  as the mirror of the scaffold, whose frame hashes it matches. With `tics = N >= 1`
  (`DOOM_TICS`, 5 for `doom.play`) the driver moves the clock at each tick, after the
  key events are queued, to the boundary N tics past the tic count of the current clock
  (the least `ms` at which `(ms - basetime) * 35 / 1000`, the formula of `I_GetTime`, reaches it;
  `basetime` is the first nonzero clock value Doom reads, 1 here because the clock starts at 0
  and Doom reads it first right after a sleep of 1 ms in startup), so
  that Doom runs N tics and then draws once. One call runs at most 5 tics, because
  `BuildNewTic` refuses to build more than 5 tics ahead of the game; a larger N is split
  into calls of `TryRunTics` followed by one `doomgeneric_Tick`. The clock is read back
  rather than counted by the driver because Doom also sleeps (the screen wipe sleeps
  until each tic), and those tics are run at the next tick as well, up to 5 in its first
  call. A key read before a tick stays pressed for its N tics, and its release, made up
  by the next read, comes at the first tic of the next tick. `-timedemo` (`singletics`)
  ignores the clock and runs one tic per call of `TryRunTics`, so `tics` affects it only
  above 5 (one tic per call, `ceil(N / 5)` per tick). `GetAdjustedTime` of `d_loop.c`
  multiplies the `int` `time_ms` by 35, so once the virtual clock passes 61,356,676 ms it
  overflows and no more tics are made (an upstream limit; with `DOOM_TICS=5` that is about
  430,000 ticks, about 20 hours of real time at 6 ticks a second).

### The view window fits the terminal

How `doom.play` draws a frame (`doom/picture.nix`, `doom/run.nix` `view`, `DOOM_VIEW`).

- **Why it is faster.** A full-screen picture of 160 columns averages the 320 columns of
  Doom's screen two by two, so half of what Doom draws in 3D is thrown away. Doom draws
  walls, floors and sprites column by column, and its cost in 3D grows with the number
  of columns of the view window, not with the number of pixels (measured on E1M1: about
  0.9 ms per column). So `doom.play` sets Doom's screen size (`screenblocks`) to the
  least one whose window, `32 * blocks` pixels wide, is at least as wide as the picture
  (5, a 160x80 window, at 160 columns), and draws that window 1:1, one pixel per half
  cell, with the status bar under it, averaged as before. Measured on E1M1 at 160
  columns with 5 tics per tick, a tick takes about 0.17 s instead of 0.34 s.
- **How it is set.** After `doomgeneric_Create` the driver writes `screenblocks` (and the
  menu's `screenSize`) and calls `R_SetViewSize`, as the `-` and `=` keys do; the next
  `D_Display` resizes the window. Nothing in Doom sets it again afterwards, and the
  player can still change it with `-` and `=`: the picture reads the window's position
  and size from Doom's variables at every frame.
- **When the whole screen comes back.** The window alone is drawn only while the 3D view
  is on: a level is running (`gamestate` is `GS_LEVEL` and `gametic` is not 0), the
  automap is off (`automapactive`) and no menu is open (`menuactive`, which also covers
  the help screens and the questions of the menus). The title, the demos' pages, the
  intermissions, the finale, the automap and the menus are drawn on the whole screen, as
  is everything with `DOOM_VIEW=full` (the default of `doom.title` and `doom.report`,
  which stay the mirror of the scaffold). The pause picture lies inside the window.
- **The messages of the heads-up display are not shown** with a window smaller than
  screen size 10: Doom draws them at the top left of the screen, outside the window, and
  whether one is up is `message_on`, a `static` variable of `hu_stuff.c`, which is not
  among the variables with external linkage (`__data.symbols`) that the picture reads.
- **The screen is not copied.** `I_FinishUpdate` of doomgeneric copies the screen Doom
  draws on, `I_VideoBuffer`, to `DG_ScreenBuffer` row by row. The driver sets the pointer
  `DG_ScreenBuffer` to `I_VideoBuffer` after `doomgeneric_Create` (only when `fb_scaling`
  is 1, the case of a 1:1 copy), so every copy has the same source and destination and
  returns at once (`copyMem` of `lib/libc.nix`), and the picture reads the pixels
  straight from the memory of the frame, only the rows and columns it shows.

### Frames are drawn in place

How the frames of `doom.play` reach the screen (`doom/stream.nix`, `DOOM_STREAM`,
`toolchain/play.nix`).

- **The usual log drops cursor movements.** An evaluation can show something while it
  runs only through `builtins.trace`, whose message Nix writes to standard error. In the
  usual log format (measured with Nix 2.34.9) Nix keeps the colors of a message on a
  terminal and drops every other escape sequence (clear screen, cursor movement), and
  through a pipe it drops the colors too; `FORCE_COLOR` and `CLICOLOR_FORCE` change
  nothing. So the hand-typed `doom.play` (`DOOM_STREAM=scroll`, the default) prints each
  frame as a block of lines under the one before it, and the terminal scrolls the whole
  picture up at every frame, which flickers badly.
- **The JSON log keeps them.** With `--log-format internal-json` Nix writes every message
  as one line `@nix {"action":"msg","level":0,"msg":"trace: …"}` on standard error, and
  the message is the string as traced, escape sequences and line breaks included.
  `nix run .#play` runs the evaluation this way with `DOOM_STREAM=home`, under which a
  frame moves the cursor to the top left corner (`ESC[H`), draws the status line and the
  picture with every line erased at its start (`ESC[K` before the line, not after it: after a line as wide as the terminal the cursor waits on the last column, where `ESC[K` would erase the last cell on some terminals) and erases the rest of the screen
  (`ESC[J`), which holds what is left of a taller frame before it (the whole screen is 50
  lines at 160 columns, the 3D view 48). The frame is wrapped in a synchronized update
  (`ESC[?2026h` … `ESC[?2026l`), so a terminal that supports it shows each frame whole.
  The launcher reads the log with `jq` and writes the message of a frame, without its
  `trace: `, to the screen as it is, on the alternate screen and with the cursor hidden;
  the other messages (Doom's output, warnings, errors) go to a file that it prints after
  restoring the screen when the evaluation failed. Copying the frames out of the log is
  part of connecting the terminal, like copying the keys in: the frames are computed by
  the evaluation alone, and `jq` only takes them out of their JSON envelope. Measured on
  E1M1 (`-warp 1 1`, 160x52, 5 tics per tick, the 3D view), a tick takes about 0.17 s in
  either form, so the extra step costs nothing visible.
- **Observable differences.** In the home form the frames, Doom's startup messages and
  the final `ticks: …` line are not mixed on the screen: the messages appear only after
  the game ends, and only when the evaluation failed. A terminal without synchronized
  updates ignores the two sequences and draws each frame over the previous one line by
  line.

### Implementation-defined choices

These are not deviations from C, but a program can observe them: types follow clang's
ilp32 RISC-V ABI (the scaffold's), so plain `char` is unsigned (but a type of its own),
`int`, `long` and pointers have 4 bytes, and an enum has the type `unsigned int` unless
one of its constants is negative, then `int` (`cc/check.nix`).
