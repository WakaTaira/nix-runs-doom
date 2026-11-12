# Linker of the Nix C compiler: C translation units (syntax trees of cc/parse.nix) and a
# host (cc/host.nix) -> one set of loaded functions. cc/default.nix linkSources and
# linkFiles call it.
#
#   link { units = [ { name; unit; } ]; dataBase; host; allowUndefined; }
#     -> { <function> = ...; __data; __units; __tables; __init; }
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
#                single file (internal linkage, static locals and locals in memory
#                included)
#     strings    the string literals of all units ([ { addr; size; } ], in unit order)
#     undefined  the addresses of the variables placed by allowUndefined ({ } otherwise)
#     init       mem: the memory with the initial values of every unit written
#   __units.<unit> = { nix; }   the generated Nix source of the unit
#   __tables = { nix; }         the generated Nix source of the tables (see below)
#   __init = mem: the memory after __data.init, with the initial host state
#            (host.init) under the key `host`
# The functions of the units, those of the host and, with allowUndefined, the functions
# that units call or use as values and nothing defines (which throw when called) are
# joined into one set X that every unit reads its imported functions from (see
# cc/emit.nix), with the tables in X.__tables.
#
# Function pointers (cc/check.nix, "Function pointers"): the functions that units use as
# values are numbered from 1, in unit order and, within a unit, in the order of their
# first uses (layout.fnvals), each function once: one with external linkage has one
# number in all units, one with internal linkage one for its unit (numberFuncs). The
# number reaches the checker lazily through link.funcNum, and finding it reads no address.
# The tables are one Nix source (tablesSource), loaded like a unit, with one list for each
# shape of the calls through function pointers of all units (cc/emit.nix tableList): at
# index i the function numbered i, X.<name> for one with external linkage (typed by its
# definition in a unit, or taken as it is when nothing defines it) and the __static.<name>
# of its unit for one with internal linkage, or an adapter of it to the shape. The tables
# stay lazy and are not part of __data.
#
# A host function f = { nargs; variadic ? false; call; } is called by the generated code
# as `f_fn mem a1 ... aN` (and a list of the variable arguments when variadic): see
# wrapHost. Its result follows the declaration in the units: the memory for void,
# otherwise { mem; ret; } with ret converted to the declared return type as a cast to it
# converts an unsigned 32-bit value (so a narrower type keeps the low bytes), or, for a
# floating-point type, a Nix float.
#
# Errors are thrown as "cc: link: <message>", with positions "<unit>:<line>:<col>" (the
# file of the node instead of the unit for a preprocessed unit) at the first use of the
# name in a unit (the position of its import), in this order:
#   duplicate unit '<name>'
#   duplicate definition of '<name>' in '<unit>' and '<unit>'
#     (a variable or function with external linkage defined by two units)
#   '<name>' in '<unit>' is also defined by the host
#   <position>: unsupported: function '<name>' of the host used as a value
#     at the first use as a value (in number order)
#   <position>: undefined reference to '<name>'   (a used variable, or a function called
#     or used as a value)
#     at the import of the first unit, in unit order, that imports the name
#   <position>: conflicting types for '<name>'
#     at the first import, in unit order, that disagrees with the definition, or, without
#     one, with the first import of the name (see below)
#   <position>: unsupported: host function '<name>' with a 64-bit, struct or union
#     parameter or return value
# Types of variables agree when they are compatible; functions when the return types, the
# parameter types and variadic are, or when the return types are and one of the two is
# declared without a prototype (`()`, see cc/parse.nix) and the other is not variadic,
# also for the function types inside other types. Types are compared by structure (C99
# 6.2.7, see sameType): two arrays are compatible when their element types are and, if
# both have a length, the lengths are equal (also inside pointers, members and
# parameters); two structs, or two unions, are compatible when both have no tag or both
# have the same tag and, when both are complete, they have the same size and alignment and
# the same members (in order for a struct) with the same names, offsets, bit-field widths
# and compatible types; two enums when their tags agree the same way and their enumerators
# have the same names and values, and an enum and its compatible integer type. A type
# being compared is taken to agree with itself on the way, so types that refer to
# themselves compare. The anonymous struct of one unit can thus agree with an anonymous
# one of another, and a block-scope struct with one of the same tag, but a struct with a
# tag never agrees with one without (nor does an enum). Qualifiers are not compared
# (cc/parse.nix drops them).
# Each import is compared with the definition, or, without one (host, undefined), with
# the first import of the name; a host function also needs nargs parameters and the same
# variadic, and a host variable the size and alignment of host.data. The direct calls of
# an imported function (calls of the import) must give as many arguments as a definition
# that is not variadic has parameters, which matters for a declaration without a
# prototype; its uses as values take any definition whose type agrees. A name that nothing
# defines and that units import both as a variable and as a function conflicts at the
# first import of the kind the first import does not have.
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
    all
    any
    attrNames
    concatLists
    concatMap
    concatStringsSep
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
    replaceStrings
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

  # The tags of a and b agree: both have none, or both have the same one (C99 6.2.7p1).
  tagsAgree = a: b: tagOf a.name == tagOf b.name;

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
      # An array without a length is compatible with any length (C99 6.7.5.2p6).
      (if a.len == b.len || a.len == null || b.len == null then sameType da db seen a.of b.of else null)
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

  # The signatures (or function types) a and b: { ret; params; variadic; unspecified; }.
  # One without a prototype (unspecified) agrees with any that is not variadic.
  sameSig =
    da: db: seen: a: b:
    let
      s = sameType da db seen a.ret b.ret;
    in
    if s == null then
      null
    else if a.unspecified then
      (if b.variadic then null else s)
    else if b.unspecified then
      (if a.variadic then null else s)
    else if a.variadic != b.variadic then
      null
    else
      sameTypes da db s a.params b.params;

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

  # The variables (imports or exports) a and b agree: their types are compatible.
  varTypesMatch = a: b: sameType a.defs b.defs { } a.ltype b.ltype != null;

  # The functions (imports or exports) a and b agree.
  sigsMatch = a: b: sameSig a.defs b.defs { } a.lsig b.lsig != null;

  # A type that a host function cannot take or return (see wrapHost).
  isWide =
    t:
    elem t.tag [
      "llong"
      "struct"
      "union"
    ];

  # ---- Placement ----

  # The units checked in order, each from the end of the one before rounded up to a
  # multiple of 8, with funcNumOf <unit> the numbers of the functions that the unit uses as
  # values. The next base is forced at every step, so the bases build no chain of
  # thunks. -> { units = [ { name; base; c; } ]; end; } with c the result of checkWith
  # and end the end of the data of the last unit.
  placeUnits =
    dataBase: externAddr: funcNumOf: units:
    foldl'
      (
        acc: u:
        let
          c = Ch.checkWith {
            dataBase = acc.next;
            link = {
              inherit externAddr;
              funcNum = funcNumOf u.name;
            };
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
  # (an import, or at least { ret; }): `mem: a1: ... aN:` (and `va:` when h is variadic),
  # returning the memory,
  # or { mem; ret; } unless decl returns void. The fixed arguments go to h.call as u32,
  # but those that decl declares with a floating-point or va_list type, which go as they
  # are (Nix floats and lists), and so does va. The result is converted to the declared
  # return type: as a cast converts an unsigned 32-bit value, or to a Nix float (rounded to
  # single precision for float). Which arguments pass as they are is decided once, from
  # the types of decl, not at each call. The world is mem.host with mem, and the new world
  # goes back into the memory under `host`. Every field of the new host state is forced,
  # and the small libc fields completely, so no thunk keeps old states alive (as
  # lib/hostcall.nix dispatch does).
  wrapHost =
    h: decl:
    let
      variadic = h.variadic or false;
      params = decl.params or [ ];
      np = length params;
      # Whether the fixed argument i passes as it is.
      asIs = genList (
        i:
        i < np
        && (
          let
            p = elemAt params i;
          in
          T.isFloat p || p.tag == "valist"
        )
      ) h.nargs;
      convArgs =
        if any (x: x) asIs then
          args: genList (i: if elemAt asIs i then elemAt args i else B.u32 (elemAt args i)) (length args)
        else
          map B.u32;
      retOf = T.numberTo R.toF32 decl.ret;
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
              ret = retOf r.ret;
            }
        );
      run =
        mem: args:
        let
          world = mem.host // {
            inherit mem;
          };
          fixed = convArgs args;
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
          (
            if (target.def ? ret) == isFunc then
              filter (i: !matches i target.def || isFunc && !callsFit i target.def) is
            else
              is
          )
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

  # ---- Function pointers ----

  # The key of the function fv (an entry of the fnvals of the layout of unit, see
  # cc/check.nix checkWith) in the numbering: its name, or the unit and its name for one
  # with internal linkage.
  funcKey = unit: fv: if fv.internal then "${unit}\n${fv.name}" else fv.name;

  # The functions that the units use as values, numbered from 1 in unit order and, in a
  # unit, in the order of their first uses (the fnvals of each layout), each key once.
  # -> { nums = { <key> = <number>; }; list = [ fv // { unit; } ] } with list in number
  # order. The next number is forced at every step.
  numberFuncs =
    layouts:
    foldl'
      (
        acc: l:
        foldl' (
          acc: fv:
          let
            key = funcKey l.unit fv;
            n = length acc.list + 1;
          in
          if hasAttr key acc.nums then
            acc
          else
            seq n {
              nums = acc.nums // {
                ${key} = n;
              };
              list = acc.list ++ [ (fv // { inherit (l) unit; }) ];
            }
        ) acc l.fnvals
      )
      {
        nums = { };
        list = [ ];
      }
      layouts;

  # The Nix source of the tables of the shapes (see cc/emit.nix tableList) for the
  # numbered functions of the resolved link r: `{ X, U, B, R }: { <shape> = [ ... ]; }`,
  # with U the loaded units in order. A function with external linkage is X.<name>
  # (typed by its definition in a unit; one that nothing defines, with allowUndefined, is
  # taken as it is), one with internal linkage the __static.<name> of its unit.
  tablesSource =
    r: shapes:
    let
      fs = r.numbered.list;
      ref = i: "f${toString (i + 1)}";
      func =
        i:
        let
          fv = elemAt fs i;
          target = r.targetOf fv.name;
        in
        if fv.internal then
          {
            ref = ref i;
            inherit (fv) ret params;
          }
        else if target.kind == "unit" then
          {
            ref = ref i;
            inherit (target.def) ret params;
          }
        else
          { ref = ref i; };
      source =
        i:
        let
          fv = elemAt fs i;
        in
        if fv.internal then
          "(elemAt U ${toString r.unitIndex.${fv.unit}}).__static.${E.quoteAttr fv.name}"
        else
          "X.${E.quoteAttr fv.name}";
      funcs = genList func (length fs);
    in
    "{ X, U, B, R }:\nlet\n  inherit (builtins) bitAnd elemAt seq;\n"
    + concatStringsSep "" (genList (i: "  ${ref i} = ${source i};\n") (length fs))
    + "in\n{\n"
    + concatStringsSep "" (
      map (sh: "  ${sh} = ${replaceStrings [ "\n" ] [ "\n  " ] (E.tableList sh funcs)};\n") shapes
    )
    + "}\n";

  # The direct calls of the function import i give as many arguments as the definition def
  # has parameters (a declaration without a prototype says nothing about them).
  callsFit = i: def: def.variadic || all (n: n == length def.params) i.calls;

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
      placed = placeUnits dataBase externAddr funcNumOf units;
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

      numbered = numberFuncs layouts;
      # The functions that each unit uses as values, by name.
      unitFnvals = listToAttrs (
        map (l: {
          name = l.unit;
          value = listToAttrs (
            map (fv: {
              inherit (fv) name;
              value = fv;
            }) l.fnvals
          );
        }) layouts
      );
      funcNumOf =
        unit: n:
        numbered.nums.${funcKey unit unitFnvals.${unit}.${n}}
          or (throw "cc: internal error: no number for '${n}' in '${unit}'");
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
        numbered
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
      # The functions of the host that units use as values.
      hostValues = filter (fv: !fv.internal && (r.targetOf fv.name).kind == "hostFunc") r.numbered.list;
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
      (map (
        fv: "${posText fv}: unsupported: function '${fv.name}' of the host used as a value"
      ) hostValues)
      (undefinedRefs r.varImports r.undefinedVars)
      (undefinedRefs r.funcImports r.undefinedFuncs)
      (conflicts false r.varImports)
      (conflicts true r.funcImports)
      (map (i: "${posText i}: conflicting types for '${i.name}'") kindConflicts)
      (map (
        i:
        "${posText i}: unsupported: host function '${i.name}' with a 64-bit, struct or union parameter or return value"
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
      unitFuncs = foldl' (
        acc: m:
        acc
        // removeAttrs m [
          "__data"
          "__static"
        ]
      ) { } mods;
      # The shapes of the calls through function pointers in all units.
      shapes = attrNames (
        listToAttrs (
          map (sh: {
            name = sh;
            value = null;
          }) (concatMap (u: u.c.checked.tables) r.placed.units)
        )
      );
      tablesCode = tablesSource r shapes;
      tables = import (builtins.toFile "cc-tables.nix" tablesCode) {
        inherit X B R;
        U = mods;
      };
      X =
        importedFunctions r
        // unitFuncs
        // {
          __tables = tables;
        };
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
          __tables.nix = tablesCode;
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
