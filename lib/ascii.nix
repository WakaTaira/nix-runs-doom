# ASCII conversion tables between byte values and one-character strings.
# Nix has no chr/ord builtins, so both directions are table lookups built once.
let
  inherit (builtins)
    bitAnd
    div
    genList
    elemAt
    fromJSON
    substring
    stringLength
    listToAttrs
    ;

  hexDigit = i: substring i 1 "0123456789abcdef";

  # NUL cannot live in a Nix string, so it maps to ""; non-ASCII maps to "?".
  charOf =
    n:
    if n == 0 then
      ""
    else if n < 128 then
      fromJSON "\"\\u00${hexDigit (div n 16)}${hexDigit (bitAnd n 15)}\""
    else
      "?";
  charList = genList charOf 256;

  codeTable = listToAttrs (
    genList (i: {
      name = charOf (i + 1);
      value = i + 1;
    }) 127
  );
in
rec {
  # Byte value -> one-character string.
  chr = n: elemAt charList n;

  # One-character string -> byte value.
  ord = c: codeTable.${c};

  # String -> list of byte values.
  bytesOf = s: genList (i: ord (substring i 1 s)) (stringLength s);
}
