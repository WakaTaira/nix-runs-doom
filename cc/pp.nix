# C preprocessor (C99 6.10): files -> preprocessing tokens of one translation unit.
#
#   preprocess { main; read; includePaths ? [ ]; defines ? { }; }
#     -> { toks; end; }
#
# toks are the preprocessing tokens after directives and macro expansion, before adjacent
# string literals are joined; each is { kind; text; file; line; col; ws; } (kind as in
# cc/lex.nix ppKind; ws tells that whitespace precedes it). end is the position after the
# last character of main. Numbers and literals are not checked here (cc/lex.nix fromPp
# does that afterwards).
#
# read : name -> contents (string) or null when there is no such file. Names are relative
# names separated by `/`; `#include "x"` looks in the directory of the including file,
# then in includePaths, and `#include <x>` in includePaths only, each directory d giving
# the name "d/x" ("x" when d is ""). `..` and absolute names are passed as they are.
# defines are object-like macros defined first (name -> replacement text of one line,
# like -D); their tokens are at "<command line>". `__STDC__` is 1 and `__STDC_VERSION__`
# 199901L; `__FILE__` is the name given to read and `__LINE__` the line of the token
# (see below).
#
# Lines are spliced and comments removed in the whole file first (cc/lex.nix ppLex), so
# a skipped group follows the same lines, comments and quotes as an active one; there,
# only the conditional directives are looked at. A file is cut into units: one
# directive line, or a run of text lines between directives. A text unit is macro-
# expanded as a whole with the macros of that point, so a macro call may span its lines
# but not a directive (unsupported).
#
# Macro expansion follows C99 6.10.3 with hide sets: every token carries the set `hs` of
# the macro names it must not expand. The tokens of an object-like macro's replacement
# get hs(name) + {name}; those of a function-like macro's (hs(name) * hs(`)`)) + {name};
# an argument substituted into a replacement keeps its own set and gets the same names
# added. Arguments are fully expanded before substitution unless they are an operand of
# `#` or `##`. A token produced by an expansion is at the position of the name of the
# outermost macro call. `__LINE__` is the line of its token: in the replacement of a call
# that spans lines, the line of the name; written in an argument, its own line (arguments
# are expanded before they are substituted).
#
# Unsupported (a diagnostic "unsupported: ..."): variadic macros, `#include` with a macro,
# `#pragma`, `#line` and other directives outside the list below, digraphs, an unsigned
# literal or a value of 2^63 or more in `#if`, `defined` produced by macro expansion in
# `#if`, a directive inside the arguments of a macro call, and a function-like macro name
# at the end of a text unit followed by `(` after a directive. Directives: `#include`,
# `#define`, `#undef`, `#if`, `#ifdef`, `#ifndef`, `#elif`, `#else`, `#endif`, `#error`
# and the null directive. Errors are thrown as "cc: <file>:<line>:<col>: <message>".
#
# Loops run with genericClosure (iterate), list builtins and foldl', so the evaluation
# depth grows with the nesting of includes, macro calls and expressions only.
let
  L = import ./lex.nix;
  inherit (builtins)
    attrNames
    concatLists
    concatStringsSep
    elemAt
    filter
    foldl'
    genList
    genericClosure
    hasAttr
    head
    intersectAttrs
    length
    listToAttrs
    map
    match
    removeAttrs
    replaceStrings
    stringLength
    substring
    ;

  posText = t: "${t.file}:${toString t.line}:${toString t.col}";
  fail = t: msg: throw "cc: ${posText t}: ${msg}";
  unsupported = t: what: fail t "unsupported: ${what}";

  maxDepth = 200;
  maxInt = 9223372036854775807;
  minInt = -9223372036854775807 - 1;

  # Run `step` from state s0 iteratively (genericClosure), so long sequences do not nest
  # Nix calls. `step s` is null at the end, or { node; s; }. -> { nodes; s; }.
  iterate =
    step: s0:
    let
      items = genericClosure {
        startSet = [
          {
            key = 0;
            s = s0;
            r = step s0;
          }
        ];
        operator =
          it:
          if it.r == null then
            [ ]
          else
            [
              {
                key = it.key + 1;
                inherit (it.r) s;
                r = step it.r.s;
              }
            ];
      };
      n = length items;
    in
    {
      nodes = genList (k: (elemAt items k).r.node) (n - 1);
      s = (elemAt items (n - 1)).s;
    };

  range = n: genList (k: k) n;
  slice =
    xs: a: b:
    genList (k: elemAt xs (a + k)) (b - a);
  drop = k: xs: slice xs k (length xs);
  isPunct = t: s: t.kind == "punct" && t.text == s;
  isIdent = t: s: t.kind == "ident" && t.text == s;
  setOf =
    xs:
    listToAttrs (
      map (x: {
        name = x;
        value = true;
      }) xs
    );

  # The spelling of the tokens toks, with one space where whitespace preceded a token
  # (not before the first).
  spell =
    esc: toks:
    concatStringsSep "" (
      genList (
        k:
        let
          t = elemAt toks k;
        in
        (if k > 0 && t.ws then " " else "") + esc t
      ) (length toks)
    );

  # ---- Files ----

  # The directory part of a name ("" when it has no `/`).
  dirOf =
    name:
    let
      m = match "(.*)/[^/]*" name;
    in
    if m == null then "" else head m;
  joinName = dir: x: if dir == "" then x else "${dir}/${x}";

  # The units of a file (see the header): { dir; toks; } with dir true for a directive
  # line (its first token is `#`) and digraph true for a line that starts with `%:`.
  unitsOf =
    lexed:
    let
      toks = lexed.toks;
      n = length toks;
      lineStarts = filter (i: (elemAt toks i).bol) (range n);
      nl = length lineStarts;
      lineAt = k: elemAt lineStarts k;
      startsDir =
        k:
        let
          t = elemAt toks (lineAt k);
        in
        isPunct t "#" || isPunct t "%:";
      unitStarts = filter (k: k == 0 || startsDir k || startsDir (k - 1)) (range nl);
      nu = length unitStarts;
    in
    genList (
      j:
      let
        k = elemAt unitStarts j;
        a = lineAt k;
        b = if j + 1 < nu then lineAt (elemAt unitStarts (j + 1)) else n;
        first = elemAt toks a;
      in
      {
        dir = startsDir k;
        digraph = isPunct first "%:";
        toks = slice toks a b;
      }
    ) nu;

  # ---- Macro definitions ----

  # A macro: { kind = "obj" | "fn"; nparams; items; paste; sig; } where items is the
  # replacement as { lit = <token>; } | { param = k; raw; ws; } (raw: an operand of `##`)
  # | { str = k; ws; } (`#` with its operand) | { paste = true; } (the `##` operator), and
  # sig what two definitions must share to be the same. `__FILE__` and `__LINE__` are
  # { kind = "file"; } and { kind = "line"; }.
  reserved = setOf [
    "defined"
    "__FILE__"
    "__LINE__"
  ];

  # The macro of the replacement tokens body (positions dropped) with the parameters
  # params (null for an object-like macro); errors are reported at the token at.
  mkMacro =
    at: params: body:
    let
      isFn = params != null;
      ps = if isFn then params else [ ];
      index = listToAttrs (
        genList (k: {
          name = elemAt ps k;
          value = k;
        }) (length ps)
      );
      nb = length body;
      tok = k: elemAt body k;
      isParam = t: t.kind == "ident" && hasAttr t.text index;
      isHash = k: isFn && isPunct (tok k) "#";
      isPaste = k: k >= 0 && k < nb && isPunct (tok k) "##";
      item =
        k:
        let
          t = tok k;
        in
        if isIdent t "__VA_ARGS__" then
          unsupported t "variadic macro"
        else if t.kind == "other" && match "['\"].*" t.text != null then
          fail t "missing terminating ${substring 0 1 t.text} character"
        else if isHash k then
          if k + 1 < nb && isParam (tok (k + 1)) then
            [
              {
                str = index.${(tok (k + 1)).text};
                inherit (t) ws;
              }
            ]
          else
            fail t "'#' is not followed by a macro parameter"
        else if k > 0 && isHash (k - 1) then
          [ ]
        else if isPaste k then
          (if isPaste (k + 1) then fail t "'##' cannot be an operand of '##'" else [ { paste = true; } ])
        else if isParam t then
          [
            {
              param = index.${t.text};
              raw = isPaste (k - 1) || isPaste (k + 1);
              inherit (t) ws;
            }
          ]
        else
          [
            {
              lit = {
                inherit (t) kind text ws;
              };
            }
          ];
      items = concatLists (genList item nb);
      forced = foldl' (acc: x: builtins.seq x acc) null items;
    in
    if nb > 0 && (isPaste 0 || isPaste (nb - 1)) then
      fail at "'##' cannot appear at either end of a macro expansion"
    else
      builtins.seq forced {
        kind = if isFn then "fn" else "obj";
        nparams = length ps;
        inherit items;
        paste = nb > 0 && builtins.any (x: x ? paste) items;
        sig = {
          inherit params;
          body = genList (k: [
            (tok k).text
            (k > 0 && (tok k).ws)
          ]) nb;
        };
      };

  # The parameter names of a function-like macro from the tokens toks after its `(`.
  # -> { params; rest; } with rest the tokens after the `)`.
  macroParams =
    at: toks:
    let
      n = length toks;
      closes = filter (k: isPunct (elemAt toks k) ")") (range n);
      j = head closes;
      inside = slice toks 0 j;
      ni = length inside;
      check =
        k:
        let
          t = elemAt inside k;
        in
        if isPunct t "..." then
          unsupported t "variadic macro"
        else if k / 2 * 2 == k then
          (if t.kind != "ident" then fail t "expected a parameter name" else t.text)
        else if !isPunct t "," then
          fail t "expected ',' or ')' in the macro parameter list"
        else
          null;
      checked = genList check ni;
      params = filter (x: x != null) checked;
      forced = foldl' (acc: x: builtins.seq x acc) null checked;
    in
    if closes == [ ] then
      fail at "missing ')' in the macro parameter list"
    else if ni > 0 && ni / 2 * 2 == ni then
      builtins.seq forced (fail (elemAt inside (ni - 1)) "expected a parameter name")
    else
      builtins.seq forced (
        if length (attrNames (setOf params)) != length params then
          fail at "duplicate macro parameter name"
        else if builtins.elem "__VA_ARGS__" params then
          unsupported at "variadic macro"
        else
          {
            inherit params;
            rest = drop (j + 1) toks;
          }
      );

  # The macro name token of a `#define`, `#undef`, `#ifdef` or `#ifndef` with the tokens
  # toks after the directive name; hash is the `#` token.
  macroName =
    what: hash: toks:
    if toks == [ ] then
      fail hash "macro name missing"
    else if (head toks).kind != "ident" then
      fail (head toks) "macro names must be identifiers"
    else if what != "test" && hasAttr (head toks).text reserved then
      fail (head toks) "'${(head toks).text}' cannot be ${
        if what == "define" then "defined" else "undefined"
      } as a macro"
    else
      head toks;

  # macros with the macro m named by nameTok; a different definition of the same name is
  # an error.
  addMacro =
    macros: nameTok: m:
    let
      name = nameTok.text;
    in
    if hasAttr name macros && (macros.${name}.sig or null) != m.sig then
      fail nameTok "'${name}' macro redefined"
    else
      builtins.seq m (macros // { ${name} = m; });

  # macros with the `#define` of the tokens toks (after `define`).
  define =
    macros: hash: toks:
    let
      nameTok = macroName "define" hash toks;
      isFn = length toks > 1 && isPunct (elemAt toks 1) "(" && !(elemAt toks 1).ws;
      ps = macroParams (elemAt toks 1) (drop 2 toks);
    in
    addMacro macros nameTok (
      if isFn then mkMacro nameTok ps.params ps.rest else mkMacro nameTok null (drop 1 toks)
    );

  # The macros defined before the first file: __STDC__, __STDC_VERSION__ and defines.
  initialMacros =
    defines:
    let
      at = {
        file = "<command line>";
        line = 1;
        col = 1;
      };
      one =
        macros: name: value:
        let
          lexed = (L.ppLex "<command line>" value).toks;
        in
        if replaceStrings [ "\n" ] [ "" ] value != value then
          fail at "the value of the macro '${name}' contains a newline"
        else if match "[A-Za-z_][A-Za-z0-9_]*" name == null then
          fail at "macro names must be identifiers ('${name}')"
        else if hasAttr name reserved then
          fail at "'${name}' cannot be defined as a macro"
        else
          addMacro macros (at // { text = name; }) (mkMacro at null lexed);
      base = {
        __FILE__ = {
          kind = "file";
        };
        __LINE__ = {
          kind = "line";
        };
      };
      std = foldl' (acc: x: one acc x.name x.value) base [
        {
          name = "__STDC__";
          value = "1";
        }
        {
          name = "__STDC_VERSION__";
          value = "199901L";
        }
      ];
    in
    foldl' (acc: name: one acc name defines.${name}) std (attrNames defines);

  # ---- Macro expansion ----

  # A frame of the input stack: the tokens toks from index i, with cands the indices of
  # the tokens that name a macro and ci the first of them at or after i.
  mkFrame =
    macros: toks:
    let
      n = length toks;
      cands = filter (
        k:
        let
          t = elemAt toks k;
        in
        t.kind == "ident" && hasAttr t.text macros
      ) (range n);
    in
    {
      inherit toks n cands;
      nc = length cands;
      i = 0;
      ci = 0;
    };

  # The stack (a list of frames { f; next; }, null when empty) with toks in front.
  push =
    macros: stack: toks:
    if toks == [ ] then
      stack
    else
      {
        f = mkFrame macros toks;
        next = stack;
      };

  # The next token of a non-empty stack, and the stack after it (empty frames popped).
  peek = stack: elemAt stack.f.toks stack.f.i;
  pop1 =
    stack:
    let
      f = stack.f;
      i = f.i + 1;
    in
    if i >= f.n then
      stack.next
    else
      {
        f = f // {
          inherit i;
          ci = if f.ci < f.nc && elemAt f.cands f.ci == f.i then f.ci + 1 else f.ci;
        };
        inherit (stack) next;
      };

  # The arguments of a call of the macro named by nameTok, from the stack after its `(`.
  # -> { args; close; stack; } with close the `)` token. onOpen nameTok is the result when
  # the input ends first.
  collectArgs =
    onOpen: nameTok: stack0:
    let
      step =
        s:
        if s.done then
          null
        else if s.stack == null then
          onOpen nameTok
        else
          let
            t = peek s.stack;
            rest = pop1 s.stack;
            close = isPunct t ")" && s.depth == 0;
          in
          {
            node = {
              tok = t;
              sep = isPunct t "," && s.depth == 0;
            };
            s = {
              stack = rest;
              done = close;
              depth =
                if isPunct t "(" then
                  s.depth + 1
                else if isPunct t ")" then
                  s.depth - 1
                else
                  s.depth;
            };
          };
      r = iterate step {
        stack = stack0;
        depth = 0;
        done = false;
      };
      m = length r.nodes - 1;
      seps = filter (k: (elemAt r.nodes k).sep) (range m);
      bounds = [ (-1) ] ++ seps ++ [ m ];
      args = genList (j: map (x: x.tok) (slice r.nodes (elemAt bounds j + 1) (elemAt bounds (j + 1)))) (
        length bounds - 1
      );
    in
    {
      inherit args;
      close = (elemAt r.nodes m).tok;
      inherit (r.s) stack;
    };

  escapeLit = s: replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s;

  # The string literal of `#` applied to the argument toks.
  stringify = toks: ws: {
    kind = "string";
    text = "\"${
      spell (t: if t.kind == "string" || t.kind == "char" then escapeLit t.text else t.text) toks
    }\"";
    inherit ws;
  };

  placemarker = {
    kind = "placemarker";
    text = "";
  };

  # The token of `##` on a and b (either may be a placemarker); errors at the call at.
  pasteTwo =
    at: a: b:
    if a.kind == "placemarker" then
      b
    else if b.kind == "placemarker" then
      a
    else
      let
        text = a.text + b.text;
        kind = L.ppOne text;
      in
      if kind == null then
        fail at "pasting \"${a.text}\" and \"${b.text}\" does not give a valid preprocessing token"
      else
        {
          inherit kind text;
          ws = a.ws or false;
          hs = intersectAttrs (a.hs or { }) (b.hs or { });
        };

  # The tokens toks (with "paste" operators) after `##`: each run `x ## y ## z` becomes
  # one token, left to right; placemarkers are removed.
  pasteAll =
    at: toks:
    let
      n = length toks;
      isOp = k: (elemAt toks k).kind == "paste";
      starts = filter (k: !isOp k && (k == 0 || !isOp (k - 1))) (range n);
      ns = length starts;
      group =
        j:
        let
          s = elemAt starts j;
          e = if j + 1 < ns then elemAt starts (j + 1) else n;
        in
        foldl' (pasteTwo at) (elemAt toks s) (genList (k: elemAt toks (s + 2 * k + 2)) ((e - s - 1) / 2));
    in
    filter (t: t.kind != "placemarker") (genList group ns);

  # The replacement of macro m called by nameTok with the arguments args, the hide set hs
  # added to every token, every token at the position of nameTok.
  substitute =
    expandArg: m: nameTok: args: hs:
    let
      expanded = map expandArg args;
      withWs = ws: toks: if toks == [ ] then [ ] else [ (head toks // { inherit ws; }) ] ++ drop 1 toks;
      piece =
        x:
        if x ? lit then
          [ x.lit ]
        else if x ? str then
          [ (stringify (elemAt args x.str) x.ws) ]
        else if x ? paste then
          [ { kind = "paste"; } ]
        else if x.raw then
          let
            a = elemAt args x.param;
          in
          if a == [ ] then [ placemarker ] else withWs x.ws a
        else
          withWs x.ws (elemAt expanded x.param);
      flat = concatLists (map piece m.items);
      toks = if m.paste then pasteAll nameTok flat else flat;
      pos = {
        inherit (nameTok) file line col;
      };
    in
    genList (
      k:
      let
        t = elemAt toks k;
      in
      t
      // pos
      // {
        hs = (t.hs or { }) // hs;
      }
      // (if k == 0 then { ws = nameTok.ws or false; } else { })
    ) (length toks);

  # The macro expansion of the tokens toks. -> { toks; dangling; } where dangling is the
  # name of a function-like macro that ended the input (and so was not called), or null.
  # onOpen nameTok is the result when the input ends inside the arguments of a call.
  expandWith =
    macros: onOpen: toks0:
    let
      expandArg = a: (expandWith macros openArg a).toks;
      openArg = t: fail t "unterminated argument list invoking macro '${t.text}'";
      special =
        t: kind:
        {
          inherit (t) file line col;
          ws = t.ws or false;
        }
        // (
          if kind == "file" then
            {
              kind = "string";
              text = "\"${escapeLit t.file}\"";
            }
          else
            {
              kind = "number";
              text = toString t.line;
            }
        );
      emit = s: toks: dangling: {
        node = toks;
        s = s // {
          inherit dangling;
        };
      };
      # One macro name t at the top of the stack; rest is the stack after it.
      call =
        s: t: rest:
        let
          m = macros.${t.text};
          hs = t.hs or { };
        in
        if hasAttr t.text hs then
          emit (s // { stack = rest; }) [ t ] null
        else if m.kind == "file" || m.kind == "line" then
          emit (s // { stack = rest; }) [ (special t m.kind) ] null
        else if m.kind == "obj" then
          emit (
            s // { stack = push macros rest (substitute expandArg m t [ ] (hs // { ${t.text} = true; })); }
          ) [ ] null
        else if rest != null && isPunct (peek rest) "(" then
          let
            c = collectArgs onOpen t (pop1 rest);
            n = length c.args;
            given = if n == 1 && head c.args == [ ] && m.nparams == 0 then 0 else n;
            ok = given == m.nparams || (m.nparams == 1 && n == 1);
            chs = intersectAttrs hs (c.close.hs or { }) // {
              ${t.text} = true;
            };
          in
          if !ok then
            fail t "macro '${t.text}' takes ${toString m.nparams} argument(s) but ${toString given} were given"
          else
            emit (s // { stack = push macros c.stack (substitute expandArg m t c.args chs); }) [ ] null
        else
          emit (s // { stack = rest; }) [ t ] (if rest == null then t else null);
      step =
        s:
        if s.stack == null then
          null
        else
          let
            f = s.stack.f;
            c = if f.ci < f.nc then elemAt f.cands f.ci else f.n;
          in
          if c > f.i then
            emit (
              s
              // {
                stack =
                  if c >= f.n then
                    s.stack.next
                  else
                    {
                      f = f // {
                        i = c;
                      };
                      inherit (s.stack) next;
                    };
              }
            ) (slice f.toks f.i c) null
          else
            let
              # Evaluated here, so the stack does not become a chain of pop1 thunks.
              rest = pop1 s.stack;
            in
            builtins.seq rest (call s (elemAt f.toks f.i) rest);
      r = iterate step {
        stack = push macros null toks0;
        dangling = null;
      };
    in
    {
      toks = concatLists r.nodes;
      inherit (r.s) dangling;
    };

  # ---- #if expressions ----

  # The tokens toks with `defined X` and `defined ( X )` replaced by 1 or 0.
  replaceDefined =
    macros: hash: toks:
    let
      n = length toks;
      tk = k: if k < n then elemAt toks k else hash;
      num = t: v: {
        kind = "number";
        text = if v then "1" else "0";
        inherit (t)
          file
          line
          col
          ws
          ;
      };
      step =
        k:
        if k >= n then
          null
        else
          let
            t = elemAt toks k;
            a = tk (k + 1);
          in
          if !isIdent t "defined" then
            {
              node = [ t ];
              s = k + 1;
            }
          else if k + 1 < n && a.kind == "ident" then
            {
              node = [ (num t (hasAttr a.text macros)) ];
              s = k + 2;
            }
          else if k + 1 < n && isPunct a "(" && k + 2 < n && (tk (k + 2)).kind == "ident" then
            if k + 3 < n && isPunct (tk (k + 3)) ")" then
              {
                node = [ (num t (hasAttr (tk (k + 2)).text macros)) ];
                s = k + 4;
              }
            else
              fail t "missing ')' after 'defined'"
          else
            fail t "macro name missing after 'defined'";
    in
    concatLists (iterate step 0).nodes;

  binaryPrec = {
    "*" = 10;
    "/" = 10;
    "%" = 10;
    "+" = 9;
    "-" = 9;
    "<<" = 8;
    ">>" = 8;
    "<" = 7;
    ">" = 7;
    "<=" = 7;
    ">=" = 7;
    "==" = 6;
    "!=" = 6;
    "&" = 5;
    "^" = 4;
    "|" = 3;
    "&&" = 2;
    "||" = 1;
  };

  bool = b: if b then 1 else 0;
  pow2 = genList (k: foldl' (acc: _: acc * 2) 1 (range k)) 63;

  # The value of the binary operator op (token at) on a and b, signed 64-bit; overflow,
  # division by zero and shift counts outside 0..63 are errors.
  binaryValue =
    at: op: a: b:
    let
      overflow = fail at "integer overflow in preprocessor expression";
      mulOverflows =
        if a == 0 || b == 0 then
          false
        else if a > 0 then
          (if b > 0 then a > maxInt / b else b < minInt / a)
        else if b > 0 then
          a < minInt / b
        else
          b < maxInt / a;
      shiftCount =
        if b < 0 || b > 63 then fail at "shift count out of range in preprocessor expression" else b;
    in
    if op == "+" then
      (if (b > 0 && a > maxInt - b) || (b < 0 && a < minInt - b) then overflow else a + b)
    else if op == "-" then
      (if (b < 0 && a > maxInt + b) || (b > 0 && a < minInt + b) then overflow else a - b)
    else if op == "*" then
      (if mulOverflows then overflow else a * b)
    else if op == "/" || op == "%" then
      if b == 0 then
        fail at "division by zero in preprocessor expression"
      else if a == minInt && b == -1 then
        overflow
      else if op == "/" then
        builtins.div a b
      else
        a - b * builtins.div a b
    else if op == "<<" then
      if shiftCount == 63 then
        (if a == 0 then 0 else overflow)
      else
        binaryValue at "*" a (elemAt pow2 shiftCount)
    else if op == ">>" then
      if shiftCount == 63 then
        (if a < 0 then -1 else 0)
      else if a >= 0 then
        builtins.div a (elemAt pow2 shiftCount)
      else
        -1 - builtins.div (-1 - a) (elemAt pow2 shiftCount)
    else if op == "<" then
      bool (a < b)
    else if op == ">" then
      bool (a > b)
    else if op == "<=" then
      bool (a <= b)
    else if op == ">=" then
      bool (a >= b)
    else if op == "==" then
      bool (a == b)
    else if op == "!=" then
      bool (a != b)
    else if op == "&" then
      builtins.bitAnd a b
    else if op == "^" then
      builtins.bitXor a b
    else if op == "|" then
      builtins.bitOr a b
    else if op == "&&" then
      bool (a != 0 && b != 0)
    else
      bool (a != 0 || b != 0);

  # The value of an integer or character constant token t of an #if expression.
  literalValue =
    t:
    let
      c = L.fromPpToken t;
    in
    if t.kind == "number" && c.unsigned then
      unsupported t "unsigned integer in a preprocessor expression"
    else
      c.value;

  # The value of the #if expression toks (after replaceDefined and expansion); hash is
  # the `#` token. Values of subexpressions that are not evaluated (the right of `&&` when
  # the left is 0, and the like) are not computed (live = false), so they raise no errors
  # of division, but their syntax is checked.
  evalExpr =
    hash: toks:
    let
      n = length toks;
      tk = k: if k < n then elemAt toks k else null;
      describe = t: if t == null then "end of the expression" else "'${t.text}'";
      expect =
        k: s:
        if tk k != null && isPunct (tk k) s then
          k + 1
        else
          fail (
            if tk k == null then hash else tk k
          ) "expected '${s}' in preprocessor expression but found ${describe (tk k)}";
      primary =
        k: live:
        let
          t = tk k;
          unary =
            f:
            let
              x = primary (k + 1) live;
            in
            {
              value = if live then f x.value else 0;
              inherit (x) i;
            };
        in
        if t == null then
          fail hash "expected a value in preprocessor expression"
        else if t.kind == "number" || t.kind == "char" then
          let
            v = literalValue t;
          in
          builtins.seq v {
            value = v;
            i = k + 1;
          }
        else if t.kind == "ident" then
          {
            value = 0;
            i = k + 1;
          }
        else if isPunct t "(" then
          let
            e = conditional (k + 1) live;
          in
          {
            inherit (e) value;
            i = expect e.i ")";
          }
        else if isPunct t "!" then
          unary (v: bool (v == 0))
        else if isPunct t "~" then
          unary (v: -v - 1)
        else if isPunct t "+" then
          unary (v: v)
        else if isPunct t "-" then
          unary (v: if v == minInt then fail t "integer overflow in preprocessor expression" else -v)
        else
          fail t "token '${t.text}' is not valid in preprocessor expressions";
      opOf =
        k:
        let
          t = tk k;
        in
        if t != null && t.kind == "punct" && hasAttr t.text binaryPrec then t else null;
      # Binary operators of precedence minPrec and above, left to right.
      binary =
        k: minPrec: live:
        let
          lhs = primary k live;
          step =
            s:
            let
              op = opOf s.i;
              prec = binaryPrec.${op.text};
              rhsLive =
                if op.text == "&&" then
                  live && s.value != 0
                else if op.text == "||" then
                  live && s.value == 0
                else
                  live;
              rhs = binary (s.i + 1) (prec + 1) rhsLive;
              value =
                if !live then
                  0
                else if op.text == "&&" then
                  bool (s.value != 0 && rhs.value != 0)
                else if op.text == "||" then
                  bool (s.value != 0 || rhs.value != 0)
                else
                  binaryValue op op.text s.value rhs.value;
            in
            if op == null || prec < minPrec then
              null
            else
              {
                node = null;
                s = builtins.seq value {
                  inherit value;
                  inherit (rhs) i;
                };
              };
        in
        (iterate step lhs).s;
      conditional =
        k: live:
        let
          c = binary k 1 live;
          x = conditional (c.i + 1) (live && c.value != 0);
          y = conditional (expect x.i ":") (live && c.value == 0);
        in
        if tk c.i != null && isPunct (tk c.i) "?" then
          {
            value = if c.value != 0 then x.value else y.value;
            inherit (y) i;
          }
        else
          c;
      r = conditional 0 true;
    in
    if toks == [ ] then
      fail hash "#if with no expression"
    else if r.i < n then
      fail (tk r.i) "missing binary operator before token '${(tk r.i).text}'"
    else
      r.value;

  # Whether the #if or #elif expression toks (after the directive name) is true.
  condition =
    macros: hash: toks:
    let
      expanded =
        (expandWith macros (t: fail t "unterminated argument list invoking macro '${t.text}'") (
          replaceDefined macros hash toks
        )).toks;
      generated = filter (t: isIdent t "defined") expanded;
    in
    if generated != [ ] then
      unsupported (head generated) "'defined' produced by macro expansion in #if"
    else
      evalExpr hash expanded != 0;

  # ---- Directives and the file loop ----

  # The state of the loop: { stack; macros; cache; dangling; } with stack a list of file
  # frames { f; next; } (null when done). A file frame is { name; dir; units; n; u; conds;
  # depth; } with u the index of its next unit and conds the open conditionals (a list
  # { c; next; } of { active; taken; live; sawElse; at; }: live tells that the enclosing
  # group is active, taken that a group of the conditional was chosen).

  conditionals = setOf [
    "if"
    "ifdef"
    "ifndef"
    "elif"
    "else"
    "endif"
  ];

  # A conditional directive name (token nameTok) with the tokens args after it.
  conditional =
    s: fr: hash: nameTok: args: active:
    let
      name = nameTok.text;
      top = fr.conds.c;
      withConds =
        conds:
        s
        // {
          stack = s.stack // {
            f = s.stack.f // {
              inherit conds;
            };
          };
        };
      open =
        v:
        withConds {
          c = {
            active = v;
            taken = v || !active;
            live = active;
            sawElse = false;
            at = hash;
          };
          next = fr.conds;
        };
      testName =
        let
          t = macroName "test" hash args;
        in
        if length args > 1 then fail (elemAt args 1) "extra tokens at end of #${name} directive" else t;
      noExtra =
        if args != [ ] then fail (head args) "extra tokens at end of #${name} directive" else true;
      replaceTop = c: withConds (fr.conds // { inherit c; });
    in
    if name == "if" then
      open (active && condition s.macros hash args)
    else if name == "ifdef" then
      open (active && hasAttr testName.text s.macros)
    else if name == "ifndef" then
      open (active && !hasAttr testName.text s.macros)
    else if fr.conds == null then
      fail hash "#${name} without #if"
    else if name == "endif" then
      builtins.seq (!top.live || noExtra) (withConds fr.conds.next)
    else if top.sawElse then
      fail hash "#${name} after #else"
    else if name == "else" then
      builtins.seq (!top.live || noExtra) (
        replaceTop (
          top
          // {
            active = top.live && !top.taken;
            taken = true;
            sawElse = true;
          }
        )
      )
    else
      let
        v = top.live && !top.taken && condition s.macros hash args;
      in
      replaceTop (
        top
        // {
          active = v;
          taken = top.taken || v;
        }
      );

  # The header name of an #include with the tokens args after `include`. -> { name; quoted; }
  includeName =
    hash: args:
    let
      first = head args;
      n = length args;
      closes = filter (k: isPunct (elemAt args k) ">") (range n);
      j = head closes;
      extraAt =
        k: if k < n then fail (elemAt args k) "extra tokens at end of #include directive" else null;
    in
    if args == [ ] then
      fail hash "#include expects \"FILENAME\" or <FILENAME>"
    else if first.kind == "string" && substring 0 1 first.text == "\"" then
      builtins.seq (extraAt 1) {
        name = substring 1 (stringLength first.text - 2) first.text;
        quoted = true;
      }
    else if isPunct first "<" then
      if closes == [ ] then
        fail first "missing terminating '>' character"
      else
        builtins.seq (extraAt (j + 1)) {
          name = spell (t: t.text) (slice args 1 j);
          quoted = false;
        }
    else if first.kind == "ident" then
      unsupported first "#include with a macro"
    else
      fail first "#include expects \"FILENAME\" or <FILENAME>";

  # The state after an #include.
  include =
    env: s: fr: hash: args:
    let
      h = includeName hash args;
      dirs = (if h.quoted then [ fr.dir ] else [ ]) ++ env.includePaths;
      found = foldl' (
        acc: d:
        if acc != null then
          acc
        else
          let
            name = joinName d h.name;
          in
          if hasAttr name s.cache then
            { inherit name; }
          else
            let
              src = env.read name;
            in
            if src == null then null else { inherit name src; }
      ) null dirs;
      cached = hasAttr found.name s.cache;
      units = if cached then s.cache.${found.name} else unitsOf (L.ppLex found.name found.src);
    in
    if h.name == "" then
      fail hash "empty filename in #include"
    else if fr.depth >= maxDepth then
      fail hash "#include nested too deeply"
    else if found == null then
      fail hash "'${h.name}' file not found"
    else
      s
      // {
        stack = {
          f = fileFrame found.name units (fr.depth + 1);
          next = s.stack;
        };
        cache = if cached then s.cache else s.cache // { ${found.name} = units; };
      };

  fileFrame = name: units: depth: {
    inherit name units depth;
    dir = dirOf name;
    n = length units;
    u = 0;
    conds = null;
  };

  # The state after the directive line toks (s with the unit consumed).
  directive =
    env: s: fr: toks: active:
    let
      hash = head toks;
      nameTok = elemAt toks 1;
      name = nameTok.text;
      args = drop 2 toks;
    in
    if length toks == 1 then
      s
    else if nameTok.kind == "ident" && hasAttr name conditionals then
      conditional s fr hash nameTok args active
    else if !active then
      s
    else if nameTok.kind != "ident" then
      unsupported nameTok "preprocessing directive '#${nameTok.text}'"
    else if name == "define" then
      s // { macros = define s.macros hash args; }
    else if name == "undef" then
      let
        t = macroName "undef" hash args;
      in
      if length args > 1 then
        fail (elemAt args 1) "extra tokens at end of #undef directive"
      else
        s // { macros = removeAttrs s.macros [ t.text ]; }
    else if name == "include" then
      include env s fr hash args
    else if name == "error" then
      fail hash "#error ${spell (t: t.text) args}"
    else
      unsupported nameTok "preprocessing directive '#${name}'";

  # The state s with its macros and the state of its innermost conditional evaluated, so
  # that the errors of a directive are raised at the directive and no chain of thunks
  # grows with the number of directives.
  strict =
    s:
    builtins.seq s.macros (
      if s.stack == null || s.stack.f.conds == null then s else builtins.seq s.stack.f.conds.c.active s
    );

  # One step of the file loop.
  step =
    env: s:
    if s.stack == null then
      null
    else
      let
        fr = s.stack.f;
        unit = elemAt fr.units fr.u;
        s' = s // {
          stack = s.stack // {
            f = fr // {
              u = fr.u + 1;
            };
          };
        };
        active = fr.conds == null || fr.conds.c.active;
        isLast = fr.u + 1 >= fr.n;
        first = head unit.toks;
        digraphs = filter (t: t.kind == "punct" && hasAttr t.text L.digraphs) unit.toks;
        onOpen =
          t:
          if isLast then
            fail t "unterminated argument list invoking macro '${t.text}'"
          else
            unsupported t "preprocessing directive inside the arguments of macro '${t.text}'";
        text =
          let
            r = expandWith s.macros onOpen unit.toks;
          in
          if s.dangling != null && isPunct first "(" then
            unsupported first "call of the macro '${s.dangling.text}' across a preprocessing directive"
          else if digraphs != [ ] then
            unsupported (head digraphs) "digraph '${(head digraphs).text}'"
          else
            # The expansion is run here, so its errors come in the order of the source.
            builtins.seq (length r.toks) {
              node = r.toks;
              s = s' // {
                inherit (r) dangling;
              };
            };
      in
      if fr.u >= fr.n then
        if fr.conds != null then
          fail fr.conds.c.at "unterminated conditional directive"
        else
          {
            node = [ ];
            s = s // {
              stack = s.stack.next;
            };
          }
      else if unit.digraph then
        unsupported first "digraph '%:'"
      else if unit.dir then
        if active && digraphs != [ ] then
          unsupported (head digraphs) "digraph '${(head digraphs).text}'"
        else
          {
            node = [ ];
            s = strict (directive env s' fr unit.toks active);
          }
      else if active then
        text
      else
        {
          node = [ ];
          s = s';
        };

  preprocess =
    {
      main,
      read,
      includePaths ? [ ],
      defines ? { },
    }:
    let
      src = read main;
      lexed = L.ppLex main src;
      units = unitsOf lexed;
      env = { inherit read includePaths; };
      r = iterate (step env) (strict {
        stack = {
          f = fileFrame main units 0;
          next = null;
        };
        macros = initialMacros defines;
        cache = { };
        dangling = null;
      });
      toks = map (t: {
        inherit (t)
          kind
          text
          file
          line
          col
          ;
        ws = t.ws or false;
      }) (concatLists r.nodes);
    in
    if src == null then
      throw "cc: ${main}: file not found"
    else
      {
        inherit toks;
        inherit (lexed) end;
      };
in
{
  inherit preprocess;
}
