# C lexer: source string -> list of tokens.
#
# A token is { kind; text; line; col; } with 1-based line and column (columns count
# bytes; a tab is one column). kind is one of:
#   "ident"    identifier (text is the name)
#   "keyword"  C keyword (text is the keyword)
#   "int"      integer literal; also has value (a non-negative Nix integer),
#              unsigned (bool, a u/U suffix) and long (0, 1 or 2: none, l/L, ll/LL)
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
# Rejected here: preprocessor directives, character and string literals, floating-point
# and octal literals, and characters that start no C token. Errors are thrown as
# "cc: <line>:<col>: <message>" ("unsupported: ..." for valid C outside the subset).
let
  inherit (builtins)
    elemAt
    filter
    foldl'
    fromJSON
    genList
    hasAttr
    head
    length
    listToAttrs
    map
    match
    split
    stringLength
    substring
    ;

  fail =
    line: col: msg:
    throw "cc: ${toString line}:${toString col}: ${msg}";
  unsupported =
    line: col: what:
    fail line col "unsupported: ${what}";

  # Space, tab, newline, carriage return, form feed and vertical tab.
  ws = " \t\n\r" + fromJSON ''"\f\u000b"'';

  tokenRe =
    "("
    + "/\\*([^*]|\\*+[^*/])*\\*+/" # block comment
    + "|//[^\n]*" # line comment
    + "|/\\*" # unterminated block comment
    + "|[0-9][0-9A-Za-z_.]*" # preprocessing number
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
    line: col: text:
    let
      hex = match "0[xX]([0-9A-Fa-f]+)([0-9A-Za-z_]*)" text;
      dec = match "(0|[1-9][0-9]*)([0-9A-Za-z_]*)" text;
      parts = if hex != null then hex else dec;
      body = if parts == null then "" else elemAt parts 0;
      suffix = if parts == null then null else parseSuffix (elemAt parts 1);
      sig = stripZeros body;
      tooLarge =
        if hex != null then
          stringLength sig > 16 || (stringLength sig == 16 && hexValues.${substring 0 1 sig} >= 8)
        else
          stringLength body > 19 || (stringLength body == 19 && body > maxInt64);
      isFloat =
        match ".*[.].*" text != null
        || (hex == null && match "[0-9]+[eE].*" text != null)
        || (hex != null && match "0[xX][0-9A-Fa-f]*[pP].*" text != null);
    in
    if isFloat then
      unsupported line col "floating-point literal '${text}'"
    else if match "0[0-9]+.*" text != null then
      unsupported line col "octal literal '${text}'"
    else if parts == null || suffix == null then
      fail line col "invalid integer literal '${text}'"
    else if tooLarge then
      unsupported line col "integer literal too large '${text}'"
    else
      {
        kind = "int";
        inherit text line col;
        value = if hex != null then hexValue body else fromJSON body;
        inherit (suffix) unsigned long;
      };

  # Classify the matched text at line:col: a token, or null for a comment.
  classify =
    line: col: text:
    let
      c = substring 0 1 text;
      c2 = substring 0 2 text;
    in
    if hasAttr c digits then
      intToken line col text
    else if hasAttr c identStart then
      {
        kind = if hasAttr text keywords then "keyword" else "ident";
        inherit text line col;
      }
    else if text == "/*" then
      fail line col "unterminated comment"
    else if c2 == "/*" || c2 == "//" then
      null
    else if hasAttr text puncts then
      {
        kind = "punct";
        inherit text line col;
      }
    else if c == "#" then
      unsupported line col "preprocessor directive"
    else if c == "\"" then
      unsupported line col "string literal"
    else if c == "'" then
      unsupported line col "character literal"
    else
      fail line col "unexpected character '${text}'";

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
        {
          line = pos.line + (k - 1) / 2;
          col = stringLength (elemAt lines (k - 1)) + 1;
        };

  lex =
    src:
    let
      pieces = split tokenRe src;
      n = (length pieces - 1) / 2;
      # Element i: the i-th match, after the whitespace that precedes it.
      raw = genList (
        i:
        let
          before =
            if i == 0 then
              {
                line = 1;
                col = 1;
              }
            else
              (elemAt raw (i - 1)).end;
          start = advance before (elemAt pieces (2 * i));
          text = head (elemAt pieces (2 * i + 1));
        in
        {
          tok = classify start.line start.col text;
          end = advance start text;
        }
      ) n;
      # Force positions and tokens in source order (first error wins, shallow recursion).
      forced = foldl' (acc: r: builtins.seq r.tok (builtins.seq r.end acc)) null raw;
      endPos = advance (
        if n == 0 then
          {
            line = 1;
            col = 1;
          }
        else
          (elemAt raw (n - 1)).end
      ) (elemAt pieces (2 * n));
      eof = {
        kind = "eof";
        text = "";
        inherit (endPos) line col;
      };
    in
    builtins.seq forced (map (r: r.tok) (filter (r: r.tok != null) raw) ++ [ eof ]);
in
{
  inherit lex;
}
