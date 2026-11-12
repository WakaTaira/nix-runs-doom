# Host functions and data for the code linked by cc/link.nix: what a linked program uses
# without defining it in C (the libc, the platform layer). A host is
#   {
#     funcs = { symbols; dataEnd; }: { <name> = { nargs; variadic ? false; call; }; ... };
#     data = [ { name; size; align; } ... ];
#     init = { symbols; dataEnd; }: <state>;
#   }
# symbols are the addresses of the variables with external linkage and of the host data
# (`__data.symbols` of the link), and dataEnd is the end of the linked data; the linker
# passes them lazily, so the names in funcs must not depend on them. A function
# takes nargs fixed arguments: call is `world: args: { world; ret; }`, or
# `world: args: va: { world; ret; }` when it is variadic (va the list of the variable
# arguments), with args the fixed arguments as unsigned 32-bit values and ret an unsigned
# 32-bit value (ignored for a function declared void); an argument or result of a
# floating-point or va_list type is a Nix float or list (see cc/link.nix wrapHost). world
# is the host state together with the memory: `<state> // { mem; }`, as in lib/libc.nix.
# The state lives in the memory trie under the key `host` (a key that is not an address),
# which init sets up. data are variables that the host provides: the linker places those
# that the units use after the units' data, each aligned as given.
#
# mk { wad ? null; } is the host of the libc (lib/libc.nix) and the doomgeneric platform
# layer (scaffold/platform.nix), and default is mk { }. Its functions are the entries of
# lib/hostcall.nix whose arguments and result are int, ptr or void, and atof and fabs,
# which take and return doubles as Nix floats (ccFloatTypes of lib/hostcall.nix,
# lib/libc.nix floatCalls), but the compiler runtime (the names that start with `__`):
# printf, fprintf, snprintf and sscanf are variadic and run vprintf, vfprintf, vsnprintf
# and vsscanf with va as the va_list, which take the va_list as their last argument (a
# list; they can be called from C once va_list values are supported). exit throws
# "libc: exit: <status>", so the output not yet shown is lost. DG_DrawFrame records a
# frame from the variables DG_ScreenBuffer and colors in symbols, and throws when called
# in a link without them. Its data is hostData of lib/hostcall.nix (errno). The initial
# state is the world of lib/libc.nix mkWorld (the heap from dataEnd rounded up to a
# multiple of 4096, errno at symbols.errno or not written, and wad, { hex; size; } or
# null) with that of the platform layer and count = 0 (the instruction count that
# DG_DrawFrame records).
#
# empty is the host without functions or data.
let
  H = import ../lib/hostcall.nix;
  Libc = import ../lib/libc.nix;
  inherit (builtins)
    all
    div
    filter
    hasAttr
    length
    listToAttrs
    map
    removeAttrs
    substring
    ;

  empty = {
    funcs = _: { };
    data = [ ];
    init = _: { };
  };

  # The entries of the host-call table that compiled C can call, with the types of
  # ccFloatTypes (atof and fabs on Nix floats): no 64-bit argument or result ("i64"), and
  # no compiler runtime.
  entries = filter (e: all (t: t != "i64") (e.args ++ [ e.ret ]) && substring 0 2 e.name != "__") (
    map (e: e // H.ccFloatTypes.${e.name} or { }) H.table
  );

  # The platform layer over the addresses in symbols (read only when a frame is read).
  platformOf =
    symbols:
    import ../scaffold/platform.nix {
      screenBufferAddr = symbols.DG_ScreenBuffer;
      colorsAddr = symbols.colors;
    };

  # DG_DrawFrame of the platform layer p, which throws unless symbols has the variables
  # that it reads.
  drawFrame =
    symbols: p: world: args:
    if hasAttr "DG_ScreenBuffer" symbols && hasAttr "colors" symbols then
      p.impls.DG_DrawFrame world args
    else
      throw "cc: host: DG_DrawFrame needs the variables DG_ScreenBuffer and colors";

  # The call of the entry e (see the header).
  callOf =
    symbols: e:
    let
      p = platformOf symbols;
    in
    if e.variadic or false then
      world: args: va:
      Libc."v${e.name}" world (args ++ [ va ])
    else if e.name == "DG_DrawFrame" then
      drawFrame symbols p
    else if hasAttr e.name p.impls then
      p.impls.${e.name}
    else
      Libc.floatCalls.${e.name} or Libc.${e.name};

  mk =
    {
      wad ? null,
    }:
    {
      funcs =
        { symbols, dataEnd }:
        listToAttrs (
          map (e: {
            inherit (e) name;
            value = {
              nargs = length e.args;
              variadic = e.variadic or false;
              call = callOf symbols e;
            };
          }) entries
        );
      data = H.hostData;
      init =
        { symbols, dataEnd }:
        removeAttrs (Libc.mkWorld {
          mem = null;
          heapBase = div (dataEnd + 4095) 4096 * 4096;
          errnoAddr = symbols.errno or 0;
          inherit wad;
        }) [ "mem" ]
        // (platformOf { }).world
        // {
          count = 0;
        };
    };
in
{
  inherit empty mk;
  default = mk { };
}
