# Linker of the Nix C compiler: C translation units (syntax trees of cc/parse.nix) and a
# host (cc/host.nix) -> one set of loaded functions. cc/default.nix linkSources and
# linkFiles call it.
#
#   link { units = [ { name; unit; } ]; dataBase; host; allowUndefined; }
#     -> { <function> = ...; __data; __units; __init; }
#
# Each unit is checked and compiled on its own (cc/check.nix checkWith in link mode,
# cc/emit.nix), with the data of the units placed in the given order: the first from
# dataBase, each next one from the end of the one before rounded up to a multiple of 8.
# String literals are shared within a unit only. After the units come the host data
# (host.data) that some unit uses, in the order of host.data, each aligned as given, and
# then, with allowUndefined, the variables that units use and nothing defines, by name,
# each with the size and alignment of the largest of their declarations (an array
# without a length has size 0). Every unit gets the addresses of the variables it uses
# from the global symbol table, which is built lazily from the layouts of all units
# (which read no address), so the units are tied together without a second pass.
#
# The result holds the functions with external linkage of the units, by name, and
#   __data = { base; size; symbols; units; strings; undefined; init; }
#     symbols    the addresses of the variables with external linkage and of the placed
#                host data, by name
#     units      units.<unit> = { base; size; symbols; }, symbols as in the __data of a
#                single file (internal linkage and static locals included)
#     strings    the string literals of all units ([ { addr; size; } ], in unit order)
#     undefined  the addresses of the variables placed by allowUndefined ({ } otherwise)
#     init       mem: the memory with the initial values of every unit written
#   __units.<unit> = { nix; }   the generated Nix source of the unit
#   __init = mem: the memory after __data.init, with the initial host state
#            (host.init) under the key `host`
# The functions of the units, those of the host and, with allowUndefined, the functions
# that units call and nothing defines (which throw when called) are joined into one set X
# that every unit reads its imported functions from (see cc/emit.nix).
#
# A host function f = { nargs; variadic ? false; call; } is called by the generated code
# as `f_fn mem a1 ... aN` (and a list of the variable arguments when variadic): see
# wrapHost. Its result follows the declaration in the units: the memory for void,
# otherwise { mem; ret; } with ret converted to the declared return type as a cast to it
# converts an unsigned 32-bit value (so a narrower type keeps the low bytes).
#
# Errors are thrown as "cc: link: <message>", with positions "<unit>:<line>:<col>" (the
# file of the node instead of the unit for a preprocessed unit) at the first use of the
# name in a unit (the position of its import), in this order:
#   duplicate unit '<name>'
#   duplicate definition of '<name>' in '<unit>' and '<unit>'
#     (a variable or function with external linkage defined by two units)
#   '<name>' in '<unit>' is also defined by the host
#   <position>: undefined reference to '<name>'   (a used variable or a called function)
#     at the import of the first unit, in unit order, that imports the name
#   <position>: conflicting types for '<name>'
#     at the first import, in unit order, that disagrees with the definition, or, without
#     one, with the first import of the name (see below)
#   <position>: unsupported: host function '<name>' with a 64-bit, floating-point or
#     struct parameter or return value
# Types of variables agree when they are compatible, or arrays of compatible element
# types of which one has no length; functions when the return types, the parameter types
# and variadic are. Types are compared by structure (C99 6.2.7, see sameType): two
# structs, or two unions, are compatible when their tags are equal if both have one and,
# when both are complete, they have the same size and alignment and the same members (in
# order for a struct) with the same names, offsets, bit-field widths and compatible types;
# two enums when their tags are and their enumerators have the same names and values, and
# an enum and its compatible integer type. A type being compared is taken to agree with
# itself on the way, so types that refer to themselves compare. The anonymous or
# block-scope struct of one unit can thus agree with that of another. Qualifiers are not
# compared (cc/parse.nix drops them). Each import is compared with the definition, or,
# without one (host, undefined), with the first import of the name; a host function also
# needs nargs parameters and the same variadic, and a host variable the size and
# alignment of host.data. A name that nothing defines and that units import both as a
# variable and as a function conflicts at the first import of the kind the first import
# does not have.
# Of the errors of the units themselves (cc/check.nix), only those that their layouts
# raise come first; the others (those of their expressions, for one) are raised when the
# units are generated, after the link errors.
let
  Ch = import ./check.nix;
  E = import ./emit.nix;
  T = Ch.types;
  M = import ../lib/mem.nix;
  B = import ../lib/bits.nix;
  R = import ./runtime.nix;
  inherit (builtins)
    any
    attrNames
    concatLists
    concatMap
    div
    elem
    elemAt
    filter
    foldl'
    genList
    groupBy
    hasAttr
    head
    length
    listToAttrs
    map
    match
    removeAttrs
    seq
    tail
    ;

  alignUp = n: a: div (n + a - 1) a * a;
  linkError = msg: throw "cc: link: ${msg}";

  # The position of x (an import, with the name of its unit in `unit`).
  posText = x: "${x.file or x.unit}:${toString x.line}:${toString x.col}";

  # ---- Types ----

  # Types are compared as cc/check.nix linkType gives them (ltype and lsig of the imports
  # and exports), each with the definitions of its unit (defs = { structs; enums; }, see
  # cc/check.nix scopeDefs), structurally (C99 6.2.7). A comparison threads the set of the
  # pairs of struct and union types under comparison, which are taken to agree, so a type
  # that refers to itself ends and every pair is visited once; it gives that set, or null
  # when the types disagree.

  # The C tag of the internal name of a struct, union or enum: null for an anonymous one,
  # without the `@<id>` of a block-scope one (see cc/check.nix localTagName).
  tagOf =
    name: if match "\\(anonymous at .*" name != null then null else head (match "([^@]*).*" name);

  # The tags of a and b agree: equal when both have one.
  tagsAgree =
    a: b:
    let
      x = tagOf a.name;
      y = tagOf b.name;
    in
    x == null || y == null || x == y;

  # The type a (with the definitions da) and the type b (with db), given the pairs seen.
  sameType =
    da: db: seen: a: b:
    if a.tag == "enum" || b.tag == "enum" then
      (if sameEnum da db a b then seen else null)
    else if a.tag != b.tag then
      null
    else if a.tag == "ptr" then
      sameType da db seen a.to b.to
    else if a.tag == "array" then
      (if a.len == b.len then sameType da db seen a.of b.of else null)
    else if a.tag == "fn" then
      sameSig da db seen a b
    else if a.tag == "struct" || a.tag == "union" then
      sameRecord da db seen a b
    else if a == b then
      seen
    else
      null;

  # The type lists as and bs, pairwise.
  sameTypes =
    da: db: seen: as: bs:
    if length as != length bs then
      null
    else
      foldl' (s: i: if s == null then null else sameType da db s (elemAt as i) (elemAt bs i)) seen (
        genList (i: i) (length as)
      );

  # The signatures (or function types) a and b: { ret; params; variadic; }.
  sameSig =
    da: db: seen: a: b:
    let
      s = sameType da db seen a.ret b.ret;
    in
    if a.variadic != b.variadic || s == null then null else sameTypes da db s a.params b.params;

  # Two enums agree when their tags do and their enumerators have the same names and
  # values; an enum and an integer type when that is the compatible integer type of the
  # enum (C99 6.7.2.2).
  sameEnum =
    da: db: a: b:
    if a.tag == "enum" && b.tag == "enum" then
      tagsAgree a b && da.enums.${a.name}.consts == db.enums.${b.name}.consts
    else if a.tag == "enum" then
      da.enums.${a.name}.type == b
    else
      db.enums.${b.name}.type == a;

  # Two structs or two unions agree when their tags do and, if both are complete, they have
  # the same size and alignment and their members agree: in order for a struct, by name
  # for a union. An incomplete one agrees with any.
  sameRecord =
    da: db: seen: a: b:
    let
      key = "${a.name}\n${b.name}";
      la = da.structs.${a.name} or null;
      lb = db.structs.${b.name} or null;
      pairs =
        if a.tag == "union" then
          map (f: {
            inherit f;
            g = lb.byName.${f.name} or null;
          }) la.fields
        else
          genList (i: {
            f = elemAt la.fields i;
            g = elemAt lb.fields i;
          }) (length la.fields);
    in
    if !tagsAgree a b then
      null
    else if hasAttr key seen || la == null || lb == null then
      seen
    else if la.size != lb.size || la.align != lb.align || length la.fields != length lb.fields then
      null
    else
      foldl' (s: p: if s == null || p.g == null then null else sameMember da db s p.f p.g) (
        seen // { ${key} = true; }
      ) pairs;

  # Two members agree in name, offset, bit-field width and declared type.
  sameMember =
    da: db: seen: f: g:
    if f.name != g.name || f.offset != g.offset || (f.width or null) != (g.width or null) then
      null
    else
      sameType da db seen f.ltype g.ltype;

  # The variables (imports or exports) a and b agree: the same type, or arrays of the same
  # element type of which one has no length.
  varTypesMatch =
    a: b:
    let
      x = a.ltype;
      y = b.ltype;
    in
    (
      if x.tag == "array" && y.tag == "array" && (x.len == null || y.len == null) then
        sameType a.defs b.defs { } x.of y.of
      else
        sameType a.defs b.defs { } x y
    ) != null;

  # The functions (imports or exports) a and b agree.
  sigsMatch = a: b: sameSig a.defs b.defs { } a.lsig b.lsig != null;

  # A type that a host function cannot take or return (see wrapHost).
  isWide =
    t:
    elem t.tag [
      "llong"
      "float"
      "double"
      "struct"
      "union"
    ];

  # ---- Placement ----

  # The units checked in order, each from the end of the one before rounded up to a
  # multiple of 8. The next base is forced at every step, so the bases build no chain of
  # thunks. -> { units = [ { name; base; c; } ]; end; } with c the result of checkWith
  # and end the end of the data of the last unit.
  placeUnits =
    dataBase: externAddr: units:
    foldl'
      (
        acc: u:
        let
          c = Ch.checkWith {
            dataBase = acc.next;
            link = { inherit externAddr; };
          } u.unit;
          end = acc.next + c.layout.size;
          next = alignUp end 8;
        in
        seq next {
          inherit next end;
          units = acc.units ++ [
            {
              inherit (u) name;
              base = acc.next;
              inherit c;
            }
          ];
        }
      )
      {
        next = dataBase;
        end = dataBase;
        units = [ ];
      }
      units;

  # The items [ { name; size; align; } ] placed in order from start, each aligned.
  # -> { end; symbols = [ { name; value; } ]; }
  placeItems =
    start: items:
    foldl'
      (
        st: d:
        let
          addr = alignUp st.end d.align;
        in
        seq addr {
          end = addr + d.size;
          symbols = st.symbols ++ [
            {
              inherit (d) name;
              value = addr;
            }
          ];
        }
      )
      {
        end = start;
        symbols = [ ];
      }
      items;

  # ---- Host functions ----

  # The host function h in the convention of the generated code, for its declaration decl
  # (an import): `mem: a1: ... aN:` (and `va:` when h is variadic), returning the memory,
  # or { mem; ret; } unless decl returns void. The fixed arguments go to h.call as u32, va
  # as it is; the world is mem.host with mem, and the new world goes back into the memory
  # under `host`. Every field of the new host state is forced, and the small libc fields
  # completely, so no thunk keeps old states alive (as lib/hostcall.nix dispatch does).
  wrapHost =
    h: decl:
    let
      variadic = h.variadic or false;
      result =
        r:
        let
          state = removeAttrs r.world [ "mem" ];
          mem = r.world.mem // {
            host = state;
          };
        in
        seq (forceState state) (
          if T.isVoid decl.ret then
            mem
          else
            {
              inherit mem;
              ret = T.wrapTo decl.ret r.ret;
            }
        );
      run =
        mem: args:
        let
          world = mem.host // {
            inherit mem;
          };
          fixed = map B.u32 args;
        in
        if variadic then va: result (h.call world fixed va) else result (h.call world fixed);
    in
    mem: gather h.nargs (run mem) [ ];

  # A function of n more arguments that passes the arguments so far (acc) and them to k.
  gather =
    n: k: acc:
    if n == 0 then k acc else a: gather (n - 1) k (acc ++ [ a ]);

  forceState =
    state:
    seq (foldl' (acc: k: seq state.${k} acc) true (attrNames state)) (
      builtins.deepSeq [
        (state.brk or null)
        (state.files or null)
        (state.errnoAddr or null)
      ] true
    );

  # A function that nothing defines (allowUndefined): it throws when called.
  undefinedFunc = name: _: linkError "call to undefined function '${name}'";

  # ---- Diagnostics ----

  # The names that occur more than once in names (sorted).
  duplicates =
    names:
    let
      groups = groupBy (x: x) names;
    in
    filter (n: length groups.${n} > 1) (attrNames groups);

  # The conflicting types for the imports is (in unit order) of the name n, whose
  # definition is target: { kind = "unit"; def; }, { kind = "hostData"; data; },
  # { kind = "hostFunc"; func; } or { kind = "none"; }. -> the first import that
  # disagrees, or null.
  conflictOf =
    isFunc: target: is:
    let
      matches = a: b: if isFunc then sigsMatch a b else varTypesMatch a b;
      first = head is;
      bad =
        if target.kind == "unit" then
          (if (target.def ? ret) == isFunc then filter (i: !matches i target.def) is else is)
        else if target.kind == "hostData" then
          (
            if isFunc then
              is
            else
              filter (i: i.size != target.data.size || i.align != target.data.align || !matches i first) is
          )
        else if target.kind == "hostFunc" then
          (
            if !isFunc then
              is
            else
              filter (
                i:
                length i.params != target.func.nargs
                || i.variadic != (target.func.variadic or false)
                || !matches i first
              ) is
          )
        else
          filter (i: !matches i first) (tail is);
    in
    if bad == [ ] then null else head bad;

  # ---- The link ----

  # The units placed and their names resolved: the definitions, imports and addresses of
  # the link, everything that reads no generated code.
  resolve =
    {
      units,
      dataBase,
      host,
      allowUndefined,
    }:
    let
      placed = placeUnits dataBase externAddr units;
      layouts = map (u: u.c.layout // { unit = u.name; }) placed.units;
      unitIndex = listToAttrs (
        genList (i: {
          inherit (elemAt placed.units i) name;
          value = i;
        }) (length placed.units)
      );
      tagged = f: concatMap (l: map (x: x // { inherit (l) unit; }) (f l)) layouts;

      defs = tagged (l: l.exports.vars ++ l.exports.funcs);
      defsByName = groupBy (d: d.name) defs;
      defOf = n: if hasAttr n defsByName then head defsByName.${n} else null;
      varImports = groupBy (i: i.name) (tagged (l: l.imports.vars));
      funcImports = groupBy (i: i.name) (tagged (l: l.imports.funcs));

      hostFuncs = host.funcs { inherit symbols dataEnd; };
      hostData = listToAttrs (
        map (d: {
          inherit (d) name;
          value = d;
        }) host.data
      );
      # What the name n refers to (see conflictOf).
      targetOf =
        n:
        if defOf n != null then
          {
            kind = "unit";
            def = defOf n;
          }
        else if hasAttr n hostData then
          {
            kind = "hostData";
            data = hostData.${n};
          }
        else if hasAttr n hostFuncs then
          {
            kind = "hostFunc";
            func = hostFuncs.${n};
          }
        else
          { kind = "none"; };

      hostPlaced = placeItems placed.end (filter (d: hasAttr d.name varImports) host.data);
      undefinedVars = filter (n: (targetOf n).kind == "none") (attrNames varImports);
      undefinedFuncs = filter (n: (targetOf n).kind == "none") (attrNames funcImports);
      largest = is: foldl' (a: b: if b.size > a.size then b else a) (head is) is;
      undefinedPlaced = placeItems hostPlaced.end (
        if allowUndefined then map (n: largest varImports.${n}) undefinedVars else [ ]
      );
      dataEnd = undefinedPlaced.end;

      symbols =
        listToAttrs (
          map (v: {
            inherit (v) name;
            value = v.addr;
          }) (filter (d: !(d ? ret)) defs)
        )
        // listToAttrs hostPlaced.symbols;
      undefinedSymbols = listToAttrs undefinedPlaced.symbols;
      externAddr =
        n: symbols.${n} or undefinedSymbols.${n} or (linkError "undefined reference to '${n}'");
    in
    {
      inherit
        dataBase
        host
        allowUndefined
        placed
        layouts
        defs
        defsByName
        varImports
        funcImports
        hostFuncs
        hostData
        targetOf
        undefinedVars
        undefinedFuncs
        dataEnd
        symbols
        undefinedSymbols
        unitIndex
        ;
    };

  # The link errors of the resolved link r, in the order of the header.
  linkErrors =
    r:
    let
      conflicts =
        isFunc: imports:
        concatMap (
          n:
          let
            i = conflictOf isFunc (r.targetOf n) imports.${n};
          in
          if i == null then [ ] else [ "${posText i}: conflicting types for '${n}'" ]
        ) (attrNames imports);
      undefinedRefs =
        imports: names:
        map (n: "${posText (head imports.${n})}: undefined reference to '${n}'") (
          if r.allowUndefined then [ ] else names
        );
      # The names that nothing defines and that are imported both as a variable and as a
      # function: the first import of the kind that the first import does not have.
      kindConflicts = map (
        n:
        let
          v = head r.varImports.${n};
          f = head r.funcImports.${n};
        in
        if r.unitIndex.${v.unit} <= r.unitIndex.${f.unit} then f else v
      ) (filter (n: hasAttr n r.funcImports && (r.targetOf n).kind == "none") (attrNames r.varImports));
      wideHostImports = filter (
        i: (r.targetOf i.name).kind == "hostFunc" && (isWide i.ret || any isWide i.params)
      ) (concatMap (n: r.funcImports.${n}) (attrNames r.funcImports));
    in
    concatLists [
      (map (
        n:
        let
          ds = r.defsByName.${n};
        in
        "duplicate definition of '${n}' in '${(head ds).unit}' and '${(head (tail ds)).unit}'"
      ) (filter (n: length r.defsByName.${n} > 1) (attrNames r.defsByName)))
      (map (d: "'${d.name}' in '${d.unit}' is also defined by the host") (
        filter (d: hasAttr d.name r.hostFuncs || hasAttr d.name r.hostData) r.defs
      ))
      (undefinedRefs r.varImports r.undefinedVars)
      (undefinedRefs r.funcImports r.undefinedFuncs)
      (conflicts false r.varImports)
      (conflicts true r.funcImports)
      (map (i: "${posText i}: conflicting types for '${i.name}'") kindConflicts)
      (map (
        i:
        "${posText i}: unsupported: host function '${i.name}' with a 64-bit, floating-point or struct parameter or return value"
      ) wideHostImports)
    ];

  # The functions that the units of the resolved link r import from the host, wrapped,
  # and, with allowUndefined, those that nothing defines.
  importedFunctions =
    r:
    listToAttrs (
      concatMap (
        n:
        if (r.targetOf n).kind == "hostFunc" then
          [
            {
              name = n;
              value = wrapHost r.hostFuncs.${n} (head r.funcImports.${n});
            }
          ]
        else
          [ ]
      ) (attrNames r.funcImports)
      ++ map (n: {
        name = n;
        value = undefinedFunc n;
      }) (if r.allowUndefined then r.undefinedFuncs else [ ])
    );

  # The __data of the resolved link r with the loaded units mods (see the header).
  dataOf = r: mods: {
    base = r.dataBase;
    size = r.dataEnd - r.dataBase;
    inherit (r) symbols;
    units = listToAttrs (
      map (u: {
        inherit (u) name;
        value = {
          inherit (u) base;
          inherit (u.c.layout) size;
          symbols = listToAttrs (
            map (s: {
              inherit (s) name;
              value = s.addr;
            }) u.c.layout.symbols
          );
        };
      }) r.placed.units
    );
    strings = concatMap (m: m.__data.strings) mods;
    undefined = r.undefinedSymbols;
    init = mem: foldl' (m: mod: mod.__data.init m) mem mods;
  };

  link =
    args:
    let
      r = resolve args;
      errors = linkErrors r;
      # The errors of the units that their layouts raise (cc/check.nix linkUnit) first.
      verdict = seq (foldl' (acc: l: seq l.imports acc) true r.layouts) (
        if errors == [ ] then true else linkError (head errors)
      );
      compiled = map (u: u // { code = E.emit u.c.checked; }) r.placed.units;
      mods = map (
        u:
        import (builtins.toFile "cc-unit.nix" u.code) {
          inherit
            M
            B
            R
            X
            ;
        }
      ) compiled;
      unitFuncs = foldl' (acc: m: acc // removeAttrs m [ "__data" ]) { } mods;
      X = importedFunctions r // unitFuncs;
      data = dataOf r mods;
      duplicateUnits = duplicates (map (u: u.name) args.units);
    in
    if duplicateUnits != [ ] then
      linkError "duplicate unit '${head duplicateUnits}'"
    else
      seq verdict (
        unitFuncs
        // {
          __data = data;
          __units = listToAttrs (
            map (u: {
              inherit (u) name;
              value.nix = u.code;
            }) compiled
          );
          __init =
            mem:
            data.init mem
            // {
              host = args.host.init { inherit (r) symbols dataEnd; };
            };
        }
      );
in
{
  inherit link wrapHost;
}
