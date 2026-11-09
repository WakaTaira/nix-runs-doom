# 32-bit integer arithmetic helpers.
# Nix integers are 64-bit signed, so register values are always kept in
# unsigned form (0 .. 2^32-1) and truncated with mask32 after each operation.
let
  inherit (builtins)
    bitAnd
    bitOr
    bitXor
    div
    genList
    elemAt
    foldl'
    ;

  mask32 = 4294967295;
  sign32 = 2147483648;
  two32 = 4294967296;

  # Table of powers of two (shifts are emulated with multiplication and division).
  pow2List = genList (n: foldl' (a: _: a * 2) 1 (genList (x: x) n)) 63;
  pow2 = n: elemAt pow2List n;

  # Interpret an unsigned 32-bit value as a signed integer.
  toSigned = x: if x >= sign32 then x - two32 else x;

  # Normalize any integer to its unsigned 32-bit representation.
  u32 = x: bitAnd x mask32;

  add = a: b: bitAnd (a + b) mask32;
  sub = a: b: bitAnd (a - b) mask32;

  shl = x: n: bitAnd (x * pow2 n) mask32;
  srl = x: n: div x (pow2 n);

  # Arithmetic right shift. Nix `div` truncates toward zero, so negative values are corrected to floor.
  sra =
    x: n:
    let
      s = toSigned x;
      p = pow2 n;
    in
    u32 (if s >= 0 then div s p else -(div (-s + p - 1) p));

  # Bit-field extraction: x[lo + len - 1 : lo]
  bits =
    x: lo: len:
    bitAnd (div x (pow2 lo)) (pow2 len - 1);

  # Sign-extend a len-bit value and return it in unsigned 32-bit form.
  sext = x: len: if x >= pow2 (len - 1) then bitAnd (x - pow2 len) mask32 else x;

  lt = a: b: toSigned a < toSigned b;
in
{
  inherit
    mask32
    sign32
    two32
    pow2
    toSigned
    u32
    add
    sub
    shl
    srl
    sra
    bits
    sext
    lt
    bitAnd
    bitOr
    bitXor
    ;
}
