# Cross-compile a freestanding RV32I guest program with clang + lld.
# This runs as a derivation and is preparation only: the emulator itself never
# builds anything and reads the committed hex fixture produced from $out.
#
# Output:
#   $out/<name>.elf  the ELF executable
#   $out/<name>.hex  hex text of the ELF (the format lib/elf.nix reads)
#   $out/<name>.dis  disassembly listing for debugging
{ pkgs }:
{
  name,
  sources,
  linkerScript,
  march ? "rv32i",
  cflags ? [ "-O2" ],
}:
let
  inherit (pkgs) lib;
  srcDir = pkgs.linkFarm "${name}-src" (
    lib.mapAttrsToList (file: text: {
      name = file;
      path = pkgs.writeText file text;
    }) (sources // { "link.ld" = linkerScript; })
  );
  compileInputs = lib.filter (f: f != "link.ld") (builtins.attrNames sources);
in
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.llvmPackages.clang-unwrapped
      pkgs.llvmPackages.bintools-unwrapped
      pkgs.lld
    ];
  }
  ''
    mkdir -p $out
    cd ${srcDir}
    clang --target=riscv32-unknown-elf -march=${march} -mabi=ilp32 ${lib.escapeShellArgs cflags} \
      -ffreestanding -fno-builtin -nostdlib -fuse-ld=lld -Wl,-T,link.ld \
      -o $out/${name}.elf ${lib.escapeShellArgs compileInputs}
    llvm-objdump -d $out/${name}.elf > $out/${name}.dis
    od -An -v -tx1 $out/${name}.elf | tr -d ' \n' > $out/${name}.hex
  ''
