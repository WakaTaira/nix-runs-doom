# Spike variant `rvx` (option 1 with the custom instruction): identical to `rv`
# except that clang's 64-bit multiply and shift for FixedMul is the single
# custom instruction `fixmul` (see rv.nix).
import ./rv.nix { useFixmul = true; }
