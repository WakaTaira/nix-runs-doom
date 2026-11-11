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
  - The output still held in the memory (`mem.host.out`, see below) is lost: a `throw`
    carries no state out of the evaluation.
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
  `printf` family reads that list as its `va_list` (`nextArg` in `lib/libc.nix`).
- **Why.** No argument save area has to be written to memory for each call.
- **Observable differences.** A `va_list` is a Nix list, not 32-bit data: it cannot be
  stored in memory or in a struct, have its address taken or be cast. Values of type
  `va_list` and the definition of variadic functions are not supported yet
  (`unsupported: 'va_list'`, `unsupported: definition of a variadic function`). A format
  that needs more arguments than given throws `"libc: too few variadic arguments"`.

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
  order; it is not printed while the evaluation runs, and each write copies the string, so
  a large amount of output costs quadratic time.
- `DG_GetKey` always returns 0: there is no key input yet.
- `DG_DrawFrame` records `instrs = 0` in its frame records: compiled code counts no
  instructions (`count` of the host state stays 0).

### Implementation-defined choices

These are not deviations from C, but a program can observe them: types follow clang's
ilp32 RISC-V ABI (the scaffold's), so plain `char` is unsigned (but a type of its own),
`int`, `long` and pointers have 4 bytes, and an enum has the type `unsigned int` unless
one of its constants is negative, then `int` (`cc/check.nix`).
