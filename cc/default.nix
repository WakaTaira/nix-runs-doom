# The C compiler written in Nix: C source -> Nix source (preprocessor cc/pp.nix, lexer
# cc/lex.nix, parser cc/parse.nix, type checker cc/check.nix, code generator cc/emit.nix).
#   compileWith { dataBase } : string -> string    the Nix source of
#                                                  `{ M, B, R }: { <function> = ...; __data = ...; }`
#                                                  for preprocessed C (no directives)
#   loadWith { dataBase }    : string -> attrs     the compiled functions, ready to call
#   compile, load                                  the same with the default dataBase
#   preprocess { main; read; includePaths ? [ ]; defines ? { }; }
#                            -> [ token ]          the preprocessing tokens of the
#                                                  translation unit (see cc/pp.nix)
#   compileFile, loadFile    { main; read; includePaths ? [ ]; defines ? { }; dataBase ? <default>; }
#                                                  preprocess, then compileWith / loadWith
#   readFrom [ <path> ]      : name -> string or null
#                                                  a `read` over directories (see below)
# dataBase (default 0x00400000) is the address of the first file-scope variable. A
# compiled function takes the memory trie (lib/mem.nix) and its arguments, and returns the
# new memory, or { mem; ret; } when it returns a value. `__data.init` (see cc/emit.nix)
# writes the initial values of the file-scope variables and static locals and the contents
# of the string literals (placed after them, listed in `__data.strings`); apply it to the
# memory first.
let
  Pp = import ./pp.nix;
  L = import ./lex.nix;
  P = import ./parse.nix;
  Ch = import ./check.nix;
  E = import ./emit.nix;

  emitUnit = dataBase: unit: E.emit (Ch.checkWith { inherit dataBase; } unit);

  compileWith =
    {
      dataBase ? Ch.defaultDataBase,
    }:
    src: emitUnit dataBase (P.parse src);

  # builtins.toFile writes the source to the store during evaluation (no build).
  importCompiled =
    code:
    import (builtins.toFile "cc-out.nix" code) {
      M = import ../lib/mem.nix;
      B = import ../lib/bits.nix;
      R = import ./runtime.nix;
    };
  loadWith = opts: src: importCompiled (compileWith opts src);

  compile = compileWith { };
  load = loadWith { };

  preprocess = args: (Pp.preprocess args).toks;

  compileFile =
    {
      dataBase ? Ch.defaultDataBase,
      ...
    }@args:
    let
      r = Pp.preprocess (removeAttrs args [ "dataBase" ]);
    in
    emitUnit dataBase (P.parseTokenList (L.fromPp r.toks r.end));
  loadFile = args: importCompiled (compileFile args);

  # A `read` for preprocess: the name is looked up in the directories dirs (Nix paths) as
  # one namespace, the first directory that has it winning. For external inputs such as
  # the Doom sources.
  readFrom =
    dirs: name:
    let
      hits = builtins.filter (
        d: builtins.pathExists (d + "/${name}") && builtins.readFileType (d + "/${name}") != "directory"
      ) dirs;
    in
    if hits == [ ] then null else builtins.readFile (builtins.head hits + "/${name}");

  spikeSrc = import ./examples/spike.nix;
  drawSrc = import ./examples/draw.nix;
in
{
  inherit
    compile
    compileWith
    load
    loadWith
    preprocess
    compileFile
    loadFile
    readFrom
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
