# Per-function summary of the pc samples of runUntil (lib/cpu.nix, `profile = true`).
#
#   import ./profile.nix { syms; profile; top ? 30; }
#     -> [ { name; samples; percent; } ]
#
# syms is `symbols` of lib/elf.nix (functions ascending by address) and profile the
# sample counter { "<pc>" = samples; }. Samples are summed by the function that
# contains the pc ("?" when no function symbol does). The result holds the `top`
# functions with the most samples, most first (ties by name); percent is the share of
# all samples, rounded down to two decimals.
{
  syms,
  profile,
  top ? 30,
}:
let
  E = import ../lib/elf.nix;
  inherit (builtins)
    attrNames
    attrValues
    div
    foldl'
    genList
    groupBy
    length
    map
    mapAttrs
    sort
    ;

  sum = foldl' (a: b: a + b) 0;

  nameOf =
    pc:
    let
      n = E.lookup syms pc;
    in
    if n == null then "?" else n;

  samples = map (k: {
    name = nameOf (builtins.fromJSON k);
    n = profile.${k};
  }) (attrNames profile);

  byName = mapAttrs (_: es: sum (map (e: e.n) es)) (groupBy (e: e.name) samples);
  total = sum (attrValues byName);

  ranked = sort (a: b: if a.samples != b.samples then a.samples > b.samples else a.name < b.name) (
    map (name: {
      inherit name;
      samples = byName.${name};
    }) (attrNames byName)
  );

  count = if length ranked < top then length ranked else top;
in
genList (
  i:
  let
    e = builtins.elemAt ranked i;
  in
  e
  // {
    percent = div (e.samples * 10000) total / 100.0;
  }
) count
