# Tests for the ELF loader's symbol table, executable segments and pc lookup.
# Uses the committed examples/fizzbuzz-c/fizzbuzz.hex fixture.
let
  E = import ../lib/elf.nix;
  hex = builtins.replaceStrings [ "\n" ] [ "" ] (
    builtins.readFile ../examples/fizzbuzz-c/fizzbuzz.hex
  );

  syms = E.symbols hex;
  segs = E.execSegments hex;
  loaded = E.load hex;

  names = map (s: s.name) syms;
  sorted = builtins.genList (i: i) (builtins.length syms - 1);
  isAscending = builtins.all (
    i: (builtins.elemAt syms i).addr <= (builtins.elemAt syms (i + 1)).addr
  ) sorted;

  # Hand-made table: [0x100, 0x110) a, [0x110, 0x118) b, gap, [0x200, 0x204) c.
  table = [
    {
      name = "a";
      addr = 256;
      size = 16;
    }
    {
      name = "b";
      addr = 272;
      size = 8;
    }
    {
      name = "c";
      addr = 512;
      size = 4;
    }
  ];
  t = name: got: expected: {
    inherit name got expected;
  };
in
[
  (t "elf: symbols include main" (builtins.elem "main" names) true)
  (t "elf: symbols ascending" isAscending true)
  (t "elf: main spans its symbol range" (E.lookup syms 65556) "main")
  (t "elf: main last byte" (E.lookup syms (65556 + 411)) "main")
  (t "elf: just past main" (E.lookup syms (65556 + 412)) null)
  (t "elf: before main (_start is NOTYPE)" (E.lookup syms loaded.entry) null)
  (t "elf: execSegments nonempty" (segs != [ ]) true)
  (t "elf: execSegments bases are PT_LOAD vaddrs" (builtins.all (
    s: builtins.any (l: l.vaddr == s.base) loaded.segments
  ) segs) true)
  (t "elf: lookup first byte" (E.lookup table 256) "a")
  (t "elf: lookup last byte" (E.lookup table 271) "a")
  (t "elf: lookup next function start" (E.lookup table 272) "b")
  (t "elf: lookup end of last in table" (E.lookup table 515) "c")
  (t "elf: lookup in gap" (E.lookup table 300) null)
  (t "elf: lookup below range" (E.lookup table 0) null)
  (t "elf: lookup past end" (E.lookup table 516) null)
  (t "elf: lookup in empty table" (E.lookup [ ] 5) null)
]
