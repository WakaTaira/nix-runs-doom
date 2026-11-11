# C lexer: source string -> list of tokens.
#
# A token is { kind; text; line; col; } with 1-based line and column (columns count
# bytes; a tab is one column). kind is one of:
#   "ident"    identifier (text is the name)
#   "keyword"  C keyword (text is the keyword)
#   "int"      integer literal; also has value (a non-negative Nix integer),
#              unsigned (bool, a u/U suffix) and long (0, 1 or 2: none, l/L, ll/LL)
#   "char"     character literal; also has value (the byte value 0..255 of its one
#              character: plain char is unsigned, so '\377' is 255)
#   "string"   string literal; also has bytes (the byte values 0..255 of its contents,
#              without the terminating 0). Adjacent string literals (with only
#              whitespace and comments between them) are joined into one token, which
#              has the position and text of the first
#   "punct"    operator or punctuator (text is the operator, e.g. ">>=")
#   "eof"      end of input (always the last token, text is "")
# Comments (/* */ and //) and whitespace are dropped.
#
# The whole source is cut by one builtins.split with a POSIX regex (leftmost-longest,
# so the order of the alternatives does not matter). A catch-all single-character
# alternative makes every non-whitespace character part of some match, so the text
# between matches is whitespace only. Positions are computed by a list whose element i
# refers to element i - 1; the list is forced in order by foldl', so the recursion stays
# shallow.
#
# An integer literal is decimal, hexadecimal (0x) or octal (a leading 0; `08` and `09` are
# errors).
#
# Character and string literals hold ASCII characters (0x01..0x7F; a raw byte from 0x80
# up is unsupported) and the escapes \n \t \r \b \a \f \v \\ \' \" \?, octal escapes of
# 1 to 3 digits and hex escapes \x of 1 or more digits (each the longest run of digits;
# a value above 255 is an error). Escapes are decoded before adjacent string literals
# are joined. A string literal ends on its line; Nix strings cannot hold the byte 0,
# hence the list of byte values.
#
# Rejected here: preprocessor directives, multi-character character literals, character
# and string literals with a prefix (L, u, U, and u8 for strings, which are recognized
# with the literal), floating-point literals, and characters that start no C token.
# Errors are thrown as "cc: <line>:<col>: <message>" ("unsupported: ..." for valid C
# outside the subset). lexNamed name src is lex for the source of a unit named name (of
# a link, see cc/parse.nix parseNamed): its tokens also have file = name, and its errors
# are at "<name>:<line>:<col>".
#
# For the preprocessor (cc/pp.nix): ppLex cuts a file into preprocessing tokens (lines
# spliced, comments removed, nothing checked), ppOne tells whether a text is one such
# token (for `##`), and fromPp turns the preprocessed tokens into the tokens above (the
# same checks and messages, at "<file>:<line>:<col>"; digraphs are unsupported), joining
# adjacent string literals after expansion. Those tokens also have `file`, and `seq`, their
# index in the translation unit, which identifies them (see fromPp).
let
  A = import ../lib/ascii.nix;
  inherit (builtins)
    concatLists
    elemAt
    filter
    foldl'
    fromJSON
    genList
    hasAttr
    head
    isList
    length
    listToAttrs
    map
    match
    split
    stringLength
    substring
    ;

  # pos is { line; col; } or, for a token of the preprocessor, { file; line; col; }.
  posText =
    pos: "${if pos ? file then "${pos.file}:" else ""}${toString pos.line}:${toString pos.col}";
  fail = pos: msg: throw "cc: ${posText pos}: ${msg}";
  unsupported = pos: what: fail pos "unsupported: ${what}";

  # Space, tab, newline, carriage return, form feed and vertical tab.
  ws = " \t\n\r" + fromJSON ''"\f\u000b"'';

  stringBody = "[^\"\\\n]*(\\\\[^\n][^\"\\\n]*)*";

  tokenRe =
    "("
    + "/\\*([^*]|\\*+[^*/])*\\*+/" # block comment
    + "|//[^\n]*" # line comment
    + "|/\\*" # unterminated block comment
    + "|'([^'\\\n]|\\\\[^\n])*'" # character literal
    + "|[LuU]'([^'\\\n]|\\\\[^\n])*'" # prefixed character literal
    # String literal, plain and prefixed. Runs of plain characters are matched as one
    # repetition, which keeps the regex engine's recursion shallow on long literals.
    + "|\"${stringBody}\""
    + "|(u8|[LuU])\"${stringBody}\""
    + "|[0-9][0-9A-Za-z_.]*" # preprocessing number
    + "|[.][0-9][0-9A-Za-z_.]*" # preprocessing number starting with a dot
    + "|[A-Za-z_][0-9A-Za-z_]*" # identifier or keyword
    + "|>>=|<<=|\\.\\.\\.|->|\\+\\+|--|<<|>>|&&|\\|\\||[-*/%+&^|<>=!]="
    + "|[^${ws}]" # any other single character
    + ")";

  chars = s: genList (i: substring i 1 s) (stringLength s);
  setOf =
    xs:
    listToAttrs (
      map (x: {
        name = x;
        value = true;
      }) xs
    );

  digits = setOf (chars "0123456789");
  identStart = setOf (chars "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_");

  keywords = setOf [
    "auto"
    "break"
    "case"
    "char"
    "const"
    "continue"
    "default"
    "do"
    "double"
    "else"
    "enum"
    "extern"
    "float"
    "for"
    "goto"
    "if"
    "inline"
    "int"
    "long"
    "register"
    "restrict"
    "return"
    "short"
    "signed"
    "sizeof"
    "static"
    "struct"
    "switch"
    "typedef"
    "union"
    "unsigned"
    "void"
    "volatile"
    "while"
    "_Bool"
    "_Complex"
  ];

  puncts = setOf (
    chars "[](){}.&*+-~!/%<>^|?:;=,"
    ++ [
      "->"
      "++"
      "--"
      "<<"
      ">>"
      "<="
      ">="
      "=="
      "!="
      "&&"
      "||"
      "*="
      "/="
      "%="
      "+="
      "-="
      "&="
      "^="
      "|="
      "<<="
      ">>="
      "..."
    ]
  );

  hexValues = listToAttrs (
    genList (i: {
      name = substring i 1 "0123456789abcdef";
      value = i;
    }) 16
    ++ genList (i: {
      name = substring i 1 "ABCDEF";
      value = 10 + i;
    }) 6
  );

  # Value of a string of hex digits (at most 16, the first below 8 if 16).
  hexValue = s: foldl' (acc: c: acc * 16 + hexValues.${c}) 0 (chars s);
  # Value of a string of octal digits (at most 21, so below 2^63).
  octValue = s: foldl' (acc: c: acc * 8 + hexValues.${c}) 0 (chars s);

  stripZeros =
    s:
    let
      m = match "0*([0-9A-Fa-f]+)" s;
    in
    if m == null then s else head m;

  # Suffix -> { unsigned; long; }, or null if it is not a valid integer suffix.
  parseSuffix =
    s:
    let
      ul = match "([uU]?)(ll|LL|l|L)?" s;
      lu = match "(ll|LL|l|L)[uU]" s;
      longOf = l: if l == null then 0 else stringLength l;
    in
    if ul != null then
      {
        unsigned = elemAt ul 0 != "";
        long = longOf (elemAt ul 1);
      }
    else if lu != null then
      {
        unsigned = true;
        long = longOf (head lu);
      }
    else
      null;

  maxInt64 = "9223372036854775807";

  # A preprocessing number as an integer-literal token.
  intToken =
    pos: text:
    let
      hex = match "0[xX]([0-9A-Fa-f]+)([0-9A-Za-z_]*)" text;
      oct = match "0([0-7]+)([0-9A-Za-z_]*)" text;
      dec = match "(0|[1-9][0-9]*)([0-9A-Za-z_]*)" text;
      parts =
        if hex != null then
          hex
        else if oct != null then
          oct
        else
          dec;
      body = if parts == null then "" else elemAt parts 0;
      suffix = if parts == null then null else parseSuffix (elemAt parts 1);
      sig = stripZeros body;
      tooLarge =
        if hex != null then
          stringLength sig > 16 || (stringLength sig == 16 && hexValues.${substring 0 1 sig} >= 8)
        else if oct != null then
          stringLength sig > 21
        else
          stringLength body > 19 || (stringLength body == 19 && body > maxInt64);
      value =
        if hex != null then
          hexValue body
        else if oct != null then
          octValue sig
        else
          fromJSON body;
      isFloat =
        match ".*[.].*" text != null
        || (hex == null && match "[0-9]+[eE].*" text != null)
        || (hex != null && match "0[xX][0-9A-Fa-f]*[pP].*" text != null);
    in
    if isFloat then
      unsupported pos "floating-point literal '${text}'"
    else if hex == null && match "0[0-7]*[89].*" text != null then
      fail pos "invalid digit in octal literal '${text}'"
    else if parts == null || suffix == null then
      fail pos "invalid integer literal '${text}'"
    else if tooLarge then
      unsupported pos "integer literal too large '${text}'"
    else
      pos
      // {
        kind = "int";
        inherit text value;
        inherit (suffix) unsigned long;
      };

  # Simple escape sequences: the character after the backslash -> character code.
  escapes = {
    n = 10;
    t = 9;
    r = 13;
    a = 7;
    b = 8;
    f = 12;
    v = 11;
    "\\" = 92;
    "'" = 39;
    "\"" = 34;
    "?" = 63;
  };
  octDigits = setOf (chars "01234567");

  # The codes of the ASCII characters 0x01..0x7F, by one-character string.
  asciiCodes = listToAttrs (
    genList (i: {
      name = A.chr (i + 1);
      value = i + 1;
    }) 127
  );

  # An escape sequence: the backslash and the longest run of octal or hex digits, or one
  # character. The capture groups give the escape and the text after the backslash.
  escapeRe = "(\\\\([0-7][0-7]?[0-7]?|x[0-9A-Fa-f]*|.))";

  # Byte value of the escape e (the text after the backslash) in a `what` at pos.
  escapeValue =
    pos: what: e:
    let
      c = substring 0 1 e;
      digits = substring 1 (stringLength e - 1) e;
      oct = octValue e;
    in
    if hasAttr c octDigits then
      (if oct > 255 then fail pos "octal escape sequence out of range" else oct)
    else if c == "x" then
      if digits == "" then
        fail pos "\\x used with no following hex digits"
      else if stringLength (stripZeros digits) > 2 then
        fail pos "hex escape sequence out of range"
      else
        hexValue digits
    else if hasAttr e escapes then
      escapes.${e}
    else if !hasAttr e asciiCodes then
      unsupported pos "non-ASCII byte in a ${what}"
    else
      fail pos "unknown escape sequence '\\${e}'";

  # Byte values of the text s without escapes, in a `what` at pos.
  plainBytes =
    pos: what: s:
    genList (i: asciiCodes.${substring i 1 s} or (unsupported pos "non-ASCII byte in a ${what}")) (
      stringLength s
    );

  # Byte values of the contents (between the quotes) of a `what` at pos, forced so that
  # its errors are raised with the token.
  decode =
    pos: what: body:
    let
      bytes = concatLists (
        map (p: if isList p then [ (escapeValue pos what (elemAt p 1)) ] else plainBytes pos what p) (
          split escapeRe body
        )
      );
    in
    builtins.deepSeq bytes bytes;

  # The text between the quotes of an unprefixed character or string literal.
  contents = text: substring 1 (stringLength text - 2) text;

  # A complete character literal ('...') as a token.
  charToken =
    pos: text:
    let
      body = contents text;
      bytes = decode pos "character literal" body;
    in
    if body == "" then
      fail pos "empty character literal"
    else if length bytes != 1 then
      unsupported pos "character literal ${text}"
    else
      pos
      // {
        kind = "char";
        inherit text;
        value = head bytes;
      };

  # A complete string literal ("...") as a token.
  stringToken =
    pos: text:
    let
      bytes = decode pos "string literal" (contents text);
    in
    builtins.seq bytes (
      pos
      // {
        kind = "string";
        inherit text bytes;
      }
    );

  # Classify the matched text at pos: a token, or null for a comment.
  classify =
    pos: text:
    let
      c = substring 0 1 text;
      c2 = substring 0 2 text;
    in
    if hasAttr c digits then
      intToken pos text
    else if match "[.][0-9].*" text != null then
      unsupported pos "floating-point literal '${text}'"
    else if match "[LuU]'.*" text != null then
      unsupported pos "prefixed character literal ${text}"
    else if match "(u8|[LuU])\".*" text != null then
      unsupported pos "prefixed string literal"
    else if hasAttr c identStart then
      pos
      // {
        kind = if hasAttr text keywords then "keyword" else "ident";
        inherit text;
      }
    else if text == "/*" then
      fail pos "unterminated comment"
    else if c2 == "/*" || c2 == "//" then
      null
    else if hasAttr text puncts then
      pos
      // {
        kind = "punct";
        inherit text;
      }
    else if c == "#" then
      unsupported pos "preprocessor directive"
    else if c == "\"" then
      if stringLength text > 1 then
        stringToken pos text
      else
        fail pos "missing terminating '\"' character"
    else if c == "'" then
      if stringLength text > 1 then charToken pos text else fail pos "unterminated character literal"
    else
      fail pos "unexpected character '${text}'";

  # Position after the text s, starting at pos.
  advance =
    pos: s:
    if s == "" then
      pos
    else if s == " " then
      pos // { col = pos.col + 1; }
    else
      let
        lines = split "\n" s;
        k = length lines;
      in
      if k == 1 then
        pos // { col = pos.col + stringLength s; }
      else
        pos
        // {
          line = pos.line + (k - 1) / 2;
          col = stringLength (elemAt lines (k - 1)) + 1;
        };

  lex = lexFrom {
    line = 1;
    col = 1;
  };

  # The tokens of the source of the unit named name: as lex, but every token, and the
  # position of every error, also has file = name.
  lexNamed =
    name:
    lexFrom {
      line = 1;
      col = 1;
      file = name;
    };

  # lex from the position origin ({ line; col; } and maybe file), whose other attributes
  # every position keeps.
  lexFrom =
    origin: src:
    let
      pieces = split tokenRe src;
      n = (length pieces - 1) / 2;
      # Element i: the i-th match, after the whitespace that precedes it.
      raw = genList (
        i:
        let
          before = if i == 0 then origin else (elemAt raw (i - 1)).end;
          start = advance before (elemAt pieces (2 * i));
          text = head (elemAt pieces (2 * i + 1));
        in
        {
          tok = classify start text;
          end = advance start text;
        }
      ) n;
      # Force positions and tokens in source order (first error wins, shallow recursion).
      forced = foldl' (acc: r: builtins.seq r.tok (builtins.seq r.end acc)) null raw;
      endPos = advance (if n == 0 then origin else (elemAt raw (n - 1)).end) (elemAt pieces (2 * n));
      eof = endPos // {
        kind = "eof";
        text = "";
      };
    in
    builtins.seq forced (joinStrings (map (r: r.tok) (filter (r: r.tok != null) raw)) ++ [ eof ]);

  # The tokens toks with each run of adjacent string literals joined into its first.
  # A run is cut at the tokens that start one (every token that is not a string literal
  # after a string literal), so each token is visited once and nothing recurses per token.
  joinStrings =
    toks:
    let
      n = length toks;
      isString = i: (elemAt toks i).kind == "string";
      starts = filter (i: !(i > 0 && isString i && isString (i - 1))) (genList (i: i) n);
      m = length starts;
      joined =
        j:
        let
          s = elemAt starts j;
          e = if j + 1 < m then elemAt starts (j + 1) else n;
          first = elemAt toks s;
        in
        if e - s == 1 then
          first
        else
          first // { bytes = concatLists (genList (k: (elemAt toks (s + k)).bytes) (e - s)); };
    in
    genList joined m;
  # ---- Preprocessing tokens (for cc/pp.nix) ----

  # The regex of tokenRe for preprocessing tokens: a preprocessing number may contain
  # `e+`, `e-`, `p+` and `p-`; `#`, `##` and the digraphs are one token each; a character
  # or string literal without its closing quote runs to the end of its line.
  ppRe =
    "("
    + "/\\*([^*]|\\*+[^*/])*\\*+/"
    + "|//[^\n]*"
    + "|/\\*"
    + "|'([^'\\\n]|\\\\[^\n])*'?"
    + "|[LuU]'([^'\\\n]|\\\\[^\n])*'"
    + "|\"${stringBody}\"?"
    + "|(u8|[LuU])\"${stringBody}\""
    + "|[.]?[0-9]([0-9A-Za-z_.]|[eEpP][-+])*"
    + "|[A-Za-z_][0-9A-Za-z_]*"
    + "|%:%:|##|<:|:>|<%|%>|%:"
    + "|>>=|<<=|\\.\\.\\.|->|\\+\\+|--|<<|>>|&&|\\|\\||[-*/%+&^|<>=!]="
    + "|[^${ws}]"
    + ")";

  digraphs = setOf [
    "<:"
    ":>"
    "<%"
    "%>"
    "%:"
    "%:%:"
  ];
  ppPuncts =
    puncts
    // digraphs
    // setOf [
      "#"
      "##"
    ];

  charRe = "[LuU]?'([^'\\\n]|\\\\[^\n])*'";
  stringRe = "(u8|[LuU])?\"${stringBody}\"";

  # The kind of the preprocessing token text (a match of ppRe): "number", "char",
  # "string", "ident", "punct" or "other" (any other character, and a character or string
  # literal without its closing quote); "comment" for a comment and "open" for the start
  # of a comment without its end.
  ppKind =
    text:
    let
      c = substring 0 1 text;
      c2 = substring 0 2 text;
    in
    if hasAttr c digits || match "[.][0-9].*" text != null then
      "number"
    else if match charRe text != null then
      "char"
    else if match stringRe text != null then
      "string"
    else if hasAttr c identStart then
      "ident"
    else if text == "/*" then
      "open"
    else if c2 == "/*" || c2 == "//" then
      "comment"
    else if hasAttr text ppPuncts then
      "punct"
    else
      "other";

  # Translation phase 2: each backslash-newline pair is removed, joining the lines.
  # -> { text; pos; } with pos mapping a position in text to the position in src.
  splice =
    src:
    let
      text = builtins.replaceStrings [ "\\\n" ] [ "" ] src;
      phys = filter builtins.isString (split "\n" src);
      np = length phys;
      segLen = p: stringLength (elemAt phys p) - 1;
      cont = p: p + 1 < np && segLen p >= 0 && substring (segLen p) 1 (elemAt phys p) == "\\";
      # The physical line (0-based) where each line of text starts.
      starts = filter (p: p == 0 || !cont (p - 1)) (genList (p: p) np);
      nl = length starts;
      pos =
        q:
        let
          p0 = elemAt starts (q.line - 1);
          segs = (if q.line < nl then elemAt starts q.line else np) - p0;
          r =
            foldl'
              (
                acc: _:
                if cont acc.p && acc.col > segLen acc.p then
                  {
                    p = acc.p + 1;
                    col = acc.col - segLen acc.p;
                  }
                else
                  acc
              )
              {
                p = p0;
                inherit (q) col;
              }
              (genList (k: k) segs);
        in
        {
          line = r.p + 1;
          inherit (r) col;
        };
    in
    if text == src then
      {
        inherit text;
        pos = q: q;
      }
    else
      { inherit text pos; };

  # The position (with file) of the first match of the regex re in text, or null.
  firstAt =
    file: re: text:
    let
      pieces = split re text;
    in
    if length pieces == 1 then
      null
    else
      advance {
        line = 1;
        col = 1;
      } (head pieces)
      // {
        inherit file;
      };

  # Translation phase 1 of the source src of the file named file: CR LF ends a line like
  # LF. A CR that is not followed by LF is an error, and so is a backslash followed by
  # spaces or tabs only up to the end of its line (gcc and clang join such lines with a
  # warning; C does not), since both would change where lines end.
  newlines =
    file: src:
    let
      text = builtins.replaceStrings [ "\r\n" ] [ "\n" ] src;
      cr = firstAt file "\r" text;
      spaced = firstAt file "\\\\[ \t]+\n" text;
    in
    if cr != null then
      fail cr "carriage return without a line feed"
    else if spaced != null then
      fail spaced "backslash and newline separated by space"
    else
      text;

  # Translation phases 1 to 3 of the file named file with contents src: line ends
  # (newlines), lines spliced, comments removed, preprocessing tokens. -> { toks; end; }
  # with end the position after the last character. A token is
  # { kind; text; file; line; col; ws; bol; } (kind as in ppKind, without comments; ws
  # tells that whitespace or a comment precedes it, bol that it is the first token of a
  # line). No token is checked here except that a comment must end, so the text of a
  # skipped group may be anything else.
  ppLex =
    file: src:
    let
      sp = splice (newlines file src);
      pieces = split ppRe sp.text;
      n = (length pieces - 1) / 2;
      first = {
        end = {
          line = 1;
          col = 1;
        };
        nl = true;
        ws = false;
      };
      # Element i: the i-th match, after the whitespace that precedes it. nl and ws carry
      # a newline and whitespace across comments to the next token.
      raw = genList (
        i:
        let
          prev = if i == 0 then first else elemAt raw (i - 1);
          gap = elemAt pieces (2 * i);
          start = advance prev.end gap;
          text = head (elemAt pieces (2 * i + 1));
          kind = ppKind text;
          nl = prev.nl || start.line != prev.end.line;
          ws = prev.ws || gap != "";
          at = sp.pos start // {
            inherit file;
          };
        in
        if kind == "open" then
          fail at "unterminated comment"
        else
          {
            end = advance start text;
            nl = kind == "comment" && nl;
            ws = kind == "comment";
            tok =
              if kind == "comment" then
                null
              else
                at
                // {
                  inherit kind text ws;
                  bol = nl;
                };
          }
      ) n;
      forced = foldl' (acc: r: builtins.seq r.tok (builtins.seq r.end acc)) null raw;
      endPos = advance (if n == 0 then first.end else (elemAt raw (n - 1)).end) (elemAt pieces (2 * n));
    in
    builtins.seq forced {
      toks = map (r: r.tok) (filter (r: r.tok != null) raw);
      end = sp.pos endPos // {
        inherit file;
      };
    };

  # The kind (as in ppKind) of text if it is exactly one valid preprocessing token, or null
  # (for the `##` operator).
  ppOne =
    text:
    let
      pieces = split ppRe text;
      kind = ppKind (head (elemAt pieces 1));
    in
    if
      length pieces != 3
      || head pieces != ""
      || elemAt pieces 2 != ""
      || kind == "comment"
      || kind == "open"
      || (kind == "other" && stringLength text > 1)
    then
      null
    else
      kind;

  # The token of the compiler for the preprocessing token t (translation phase 7, before
  # string literals are joined): literals are checked and their values computed, and the
  # tokens that the lexer rejects are rejected with its messages.
  fromPpToken =
    t:
    let
      pos = {
        inherit (t) file line col;
      };
      c = substring 0 1 t.text;
    in
    if t.kind == "punct" && hasAttr t.text digraphs then
      unsupported pos "digraph '${t.text}'"
    else if t.text == "#" || t.text == "##" then
      fail pos "stray '${t.text}' in program"
    else if t.kind == "other" && c == "\"" then
      fail pos "missing terminating '\"' character"
    else if t.kind == "other" && c == "'" then
      fail pos "unterminated character literal"
    else
      classify pos t.text;

  # The tokens of the compiler for the preprocessed tokens toks, adjacent string literals
  # joined, ending in an "eof" token at end ({ file; line; col; }). Converted in order, so
  # the first error wins. Each token also has seq, its index in the list: the tokens of
  # one macro expansion share a position, so seq (not the position) identifies a token.
  fromPp =
    toks: end:
    let
      conv = map fromPpToken toks;
      forced = foldl' (acc: t: builtins.seq t acc) null conv;
      all = joinStrings conv ++ [
        (
          end
          // {
            kind = "eof";
            text = "";
          }
        )
      ];
    in
    builtins.seq forced (genList (k: elemAt all k // { seq = k; }) (length all));
in
{
  inherit
    lex
    lexNamed
    ppLex
    ppOne
    fromPpToken
    fromPp
    digraphs
    ;
}
