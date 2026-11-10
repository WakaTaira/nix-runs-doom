# The C compiler written in Nix: C source -> Nix source (lexer cc/lex.nix, parser
# cc/parse.nix, type checker cc/check.nix, code generator cc/emit.nix).
#   compileWith { dataBase } : string -> string    the Nix source of
#                                                  `{ M, B, R }: { <function> = ...; __data = ...; }`
#   loadWith { dataBase }    : string -> attrs     the compiled functions, ready to call
#   compile, load                                  the same with the default dataBase
# dataBase (default 0x00400000) is the address of the first file-scope variable. A
# compiled function takes the memory trie (lib/mem.nix) and its arguments, and returns the
# new memory, or { mem; ret; } when it returns a value. `__data.init` (see cc/emit.nix)
# writes the initial values of the file-scope variables and static locals and the contents
# of the string literals (placed after them, listed in `__data.strings`); apply it to the
# memory first.
let
  P = import ./parse.nix;
  Ch = import ./check.nix;
  E = import ./emit.nix;

  compileWith =
    {
      dataBase ? Ch.defaultDataBase,
    }:
    src: E.emit (Ch.checkWith { inherit dataBase; } (P.parse src));

  # builtins.toFile writes the source to the store during evaluation (no build).
  loadWith =
    opts: src:
    import (builtins.toFile "cc-out.nix" (compileWith opts src)) {
      M = import ../lib/mem.nix;
      B = import ../lib/bits.nix;
      R = import ./runtime.nix;
    };

  compile = compileWith { };
  load = loadWith { };

  spikeSrc = import ./examples/spike.nix;
  drawSrc = import ./examples/draw.nix;
in
{
  inherit
    compile
    compileWith
    load
    loadWith
    ;

  examples.spike = {
    src = spikeSrc;
    nix = compile spikeSrc;
  };

  examples.draw = {
    src = drawSrc;
    nix = compile drawSrc;
  };
}
