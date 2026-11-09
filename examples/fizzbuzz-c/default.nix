# FizzBuzz guest program in C, kept only as a transitional reference.
# It is compiled with clang (see toolchain/guest.nix) and compared against the
# Nix eDSL version in examples/fizzbuzz. It goes away once guests are all Nix.
{ buildGuest }:
buildGuest {
  name = "fizzbuzz";
  sources = {
    "start.S" = ''
      # Entry point: set up the stack, call main, and exit with its return value.
          .section .text.start
          .globl _start
      _start:
          la    sp, __stack_top
          call  main
          li    a7, 93
          ecall
    '';
    "fizzbuzz.c" = ''
      /*
       * FizzBuzz for RV32I (no M extension).
       * Division and modulo would emit libgcc / compiler-rt calls, so they are replaced
       * by period counters for 3 and 5 and an incrementing array of decimal digits.
       */
      #define N 100

      static long sys_write(int fd, const char *buf, unsigned long len) {
          register long a0 __asm__("a0") = fd;
          register long a1 __asm__("a1") = (long)buf;
          register long a2 __asm__("a2") = (long)len;
          register long a7 __asm__("a7") = 64;
          __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
          return a0;
      }

      static char line[16];

      int main(void) {
          char digits[4] = {'0', '0', '0', '0'}; /* least significant digit first */
          int ndigits = 1;
          int c3 = 0, c5 = 0;

          for (int i = 1; i <= N; i++) {
              /* increment the decimal counter */
              for (int k = 0;; k++) {
                  if (k == ndigits) { digits[k] = '1'; ndigits++; break; }
                  if (digits[k] == '9') { digits[k] = '0'; continue; }
                  digits[k]++;
                  break;
              }
              if (++c3 == 3) c3 = 0;
              if (++c5 == 5) c5 = 0;

              int n = 0;
              if (c3 == 0) { line[n++] = 'F'; line[n++] = 'i'; line[n++] = 'z'; line[n++] = 'z'; }
              if (c5 == 0) { line[n++] = 'B'; line[n++] = 'u'; line[n++] = 'z'; line[n++] = 'z'; }
              if (n == 0) {
                  for (int k = ndigits - 1; k >= 0; k--) line[n++] = digits[k];
              }
              line[n++] = '\n';
              sys_write(1, line, n);
          }
          return 0;
      }
    '';
  };
  linkerScript = ''
    ENTRY(_start)
    SECTIONS
    {
      . = 0x10000;
      .text : { *(.text.start) *(.text*) }
      .rodata : { *(.rodata*) *(.srodata*) }
      .data : { *(.data*) *(.sdata*) }
      .bss : { *(.bss*) *(.sbss*) *(COMMON) }
      . = ALIGN(16);
      . += 0x4000;
      __stack_top = .;
    }
  '';
}
