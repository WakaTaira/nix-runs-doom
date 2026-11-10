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
# outside the subset).
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

  fail =
    line: col: msg:
    throw "cc: ${toString line}:${toString col}: ${msg}";
  unsupported =
    line: col: what:
    fail line col "unsupported: ${what}";

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
    line: col: text:
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
      unsupported line col "floating-point literal '${text}'"
    else if hex == null && match "0[0-7]*[89].*" text != null then
      fail line col "invalid digit in octal literal '${text}'"
    else if parts == null || suffix == null then
      fail line col "invalid integer literal '${text}'"
    else if tooLarge then
      unsupported line col "integer literal too large '${text}'"
    else
      {
        kind = "int";
        inherit
          text
          line
          col
          value
          ;
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

  # Byte value of the escape e (the text after the backslash) in the literal at line:col.
  escapeValue =
    line: col: e:
    let
      c = substring 0 1 e;
      digits = substring 1 (stringLength e - 1) e;
      oct = octValue e;
    in
    if hasAttr c octDigits then
      (if oct > 255 then fail line col "octal escape sequence out of range" else oct)
    else if c == "x" then
      if digits == "" then
        fail line col "\\x used with no following hex digits"
      else if stringLength (stripZeros digits) > 2 then
        fail line col "hex escape sequence out of range"
      else
        hexValue digits
    else if hasAttr e escapes then
      escapes.${e}
    else
      fail line col "unknown escape sequence '\\${e}'";

  # Byte values of the text s without escapes, in a `what` at line:col.
  plainBytes =
    line: col: what: s:
    genList (i: asciiCodes.${substring i 1 s} or (unsupported line col "non-ASCII byte in a ${what}")) (
      stringLength s
    );

  # Byte values of the contents (between the quotes) of a `what` at line:col, forced so
  # that its errors are raised with the token.
  decode =
    line: col: what: body:
    let
      bytes = concatLists (
        map (p: if isList p then [ (escapeValue line col (elemAt p 1)) ] else plainBytes line col what p) (
          split escapeRe body
        )
      );
    in
    builtins.deepSeq bytes bytes;

  # The text between the quotes of an unprefixed character or string literal.
  contents = text: substring 1 (stringLength text - 2) text;

  # A complete character literal ('...') as a token.
  charToken =
    line: col: text:
    let
      body = contents text;
      bytes = decode line col "character literal" body;
    in
    if body == "" then
      fail line col "empty character literal"
    else if length bytes != 1 then
      unsupported line col "character literal ${text}"
    else
      {
        kind = "char";
        inherit
          text
          line
          col
          ;
        value = head bytes;
      };

  # A complete string literal ("...") as a token.
  stringToken =
    line: col: text:
    let
      bytes = decode line col "string literal" (contents text);
    in
    builtins.seq bytes {
      kind = "string";
      inherit
        text
        line
        col
        bytes
        ;
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
    else if match "[.][0-9].*" text != null then
      unsupported line col "floating-point literal '${text}'"
    else if match "[LuU]'.*" text != null then
      unsupported line col "prefixed character literal ${text}"
    else if match "(u8|[LuU])\".*" text != null then
      unsupported line col "prefixed string literal"
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
      if stringLength text > 1 then
        stringToken line col text
      else
        fail line col "missing terminating '\"' character"
    else if c == "'" then
      if stringLength text > 1 then
        charToken line col text
      else
        fail line col "unterminated character literal"
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
in
{
  inherit lex;
}
