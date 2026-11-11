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
# 32-bit value (ignored for a function declared void). world is the host state together
# with the memory: `<state> // { mem; }`, as in lib/libc.nix. The state lives in the
# memory trie under the key `host` (a key that is not an address), which init sets up.
# data are variables that the host provides: the linker places those that the units use
# after the units' data, each aligned as given.
#
# default is the empty host (no function, no data).
{
  default = {
    funcs = _: { };
    data = [ ];
    init = _: { };
  };
}
