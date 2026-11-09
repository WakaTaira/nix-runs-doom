# Number and string formatting helpers shared by the bench reports.
let
  inherit (builtins)
    foldl'
    floor
    toString
    concatStringsSep
    stringLength
    genList
    div
    ;

  repeatStr = n: s: concatStringsSep "" (genList (_: s) n);
  padLeft = w: s: repeatStr (w - stringLength s) " " + s;
  padRight = w: s: s + repeatStr (w - stringLength s) " ";
  # Fixed-point decimal with `digits` fractional digits.
  fixed =
    digits: x:
    let
      scale = foldl' (a: _: a * 10) 1 (genList (i: i) digits);
      n = floor (x * scale + 0.5);
      frac = toString (n - div n scale * scale);
    in
    if digits == 0 then
      toString n
    else
      "${toString (div n scale)}.${repeatStr (digits - stringLength frac) "0"}${frac}";
  # Integers with thousands separators.
  grouped =
    n:
    let
      s = toString n;
      len = stringLength s;
      head = len - (div (len - 1) 3) * 3;
      groups = genList (i: builtins.substring (head + 3 * i) 3 s) (div (len - 1) 3);
    in
    concatStringsSep "," ([ (builtins.substring 0 head s) ] ++ groups);
in
{
  inherit
    repeatStr
    padLeft
    padRight
    fixed
    grouped
    ;
}
