# The C compiler written in Nix: C source -> Nix source (lexer cc/lex.nix, parser
# cc/parse.nix, type checker cc/check.nix, code generator cc/emit.nix).
#   compile : string -> string    the Nix source of `{ M, B, R }: { <function> = ...; }`
#   load    : string -> attrs     the compiled functions, ready to call
# A compiled function takes the memory trie (lib/mem.nix) and its arguments, and returns
# the new memory, or { mem; ret; } when it returns a value.
let
  P = import ./parse.nix;
  Ch = import ./check.nix;
  E = import ./emit.nix;

  compile = src: E.emit (Ch.check (P.parse src));

  # builtins.toFile writes the source to the store during evaluation (no build).
  load =
    src:
    import (builtins.toFile "cc-out.nix" (compile src)) {
      M = import ../lib/mem.nix;
      B = import ../lib/bits.nix;
      R = import ./runtime.nix;
    };

  spikeSrc = import ./examples/spike.nix;
in
{
  inherit compile load;

  examples.spike = {
    src = spikeSrc;
    nix = compile spikeSrc;
  };
}
