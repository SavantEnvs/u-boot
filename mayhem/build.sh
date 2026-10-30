#!/usr/bin/env bash
#
# mayhem/build.sh — builds the u-boot sandbox twice, out of tree (O=), into gitignored mayhem/out/:
#   out/test : normal gcc build, run by mayhem/test.sh (`u-boot -T -c "ut <suite>"`)
#   out/fuzz : clang build with CONFIG_FUZZ + $SANITIZER_FLAGS + $DEBUG_FLAGS, relinked once per target
#
# u-boot's libFuzzer entry (arch/sandbox/cpu/os.c) runs `fuzz $UBOOT_SB_FUZZ_TEST` in a sandbox thread, so
# every target is the SAME sandbox with a different FUZZ_TEST(): `fuzz_vring` (in-tree, test/fuzz/virtio.c)
# plus the four OSS-Fuzz harnesses (mayhem/harnesses/*.c, compiled with kbuild's own flags and linked in —
# upstream's Makefiles are untouched). mayhem/fuzz_select.c bakes the FUZZ_TEST choice into each binary.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`): an explicit empty SANITIZER_FLAGS is honoured. CONFIG_FUZZ selects CONFIG_ASAN, so ASan
# stays on even then; only UBSan goes away.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"
OUT_DIR="$SRC/mayhem/out"
TEST="$OUT_DIR/test"
FUZZ="$OUT_DIR/fuzz"
TARGETS="fuzz_vring fuzz_efi_load_image fuzz_fit_image_load fuzz_image_decomp fuzz_btrfs"

# ---------------------------------------------------------------- 1) test build: normal flags, gcc
mkdir -p "$TEST"
make O="$TEST" CC=gcc HOSTCC=gcc NO_SDL=1 sandbox_defconfig
make O="$TEST" CC=gcc HOSTCC=gcc NO_SDL=1 KCFLAGS="$COVERAGE_FLAGS" -j"$MAYHEM_JOBS"
test -x "$TEST/u-boot"

# ---------------------------------------------------------------- 2) fuzz build: sanitized clang
mkdir -p "$FUZZ"
make O="$FUZZ" CC="$CC" HOSTCC="$CC" NO_SDL=1 sandbox_defconfig
# CONFIG_FUZZ is clang-only and selects ASAN. LTO breaks the sancov link, and capsule authentication needs
# the efitools signing tools. OF_EMBED + the `test` tree (as OSS-Fuzz does) embeds the devicetree, so the
# binary does not need a u-boot.dtb beside it and can be copied to /mayhem/<target>.
./scripts/config --file "$FUZZ/.config" \
  --enable FUZZ --disable LTO --disable EFI_CAPSULE_AUTHENTICATE \
  --disable OF_SEPARATE --enable OF_EMBED --set-str DEFAULT_DEVICE_TREE test
make O="$FUZZ" CC="$CC" HOSTCC="$CC" NO_SDL=1 olddefconfig

# vla-bound is the one relaxed UBSan check: lib/hashtable.c:814 declares a VLA sized from the env hash table
# and aborts every execution at start-up. All other UBSan checks stay on and halting.
FUZZ_KCFLAGS="-Wno-unused-command-line-argument $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=vla-bound"
fuzz_make() {  # fuzz_make <extra PLATFORM_LIBS objects...>
  make O="$FUZZ" CC="$CC" HOSTCC="$CC" NO_SDL=1 NO_PYTHON=1 \
    PLATFORM_LIBS="-lrt -lpthread -fuse-ld=lld $SANITIZER_FLAGS $*" \
    KBUILD_LDFLAGS="-z noexecstack -z norelro" KCFLAGS="$FUZZ_KCFLAGS" -j"$MAYHEM_JOBS" u-boot
}

# LeakSanitizer off at build time (docs/rules/c.md): ASan stays, only leak detection goes.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ/lsan_off.o"

# Full sanitized build of u-boot itself (links a plain sandbox; relinked per target below).
fuzz_make "$FUZZ/lsan_off.o"

# Harnesses: reuse the exact compile command kbuild recorded for an in-tree object, swapping the file.
cmdline=$(sed -n '1s/^[^:]*:= //p' "$FUZZ/test/fuzz/.virtio.o.cmd")
cmdline=$(printf '%s' "$cmdline" | sed 's/ -Wp,-MMD,[^ ]*//')
compile_prefix="${cmdline%% -c -o *}"
mkdir -p "$FUZZ/mayhem"
HARNESS_OBJS=""
for h in efi_load_image fit_image_load image_decomp btrfs; do
  (cd "$FUZZ" && eval "$compile_prefix -c -o mayhem/fuzz_$h.o '$SRC/mayhem/harnesses/fuzz_$h.c'")
  HARNESS_OBJS="$HARNESS_OBJS $FUZZ/mayhem/fuzz_$h.o"
done

# Per-target relink: harness objects + the object that selects this target's FUZZ_TEST().
# The -standalone binary re-runs the link command kbuild just recorded, minus libFuzzer's runtime and main(),
# plus $STANDALONE_FUZZ_MAIN: one input file, run once, natural crash (ASan's runtime serves the coverage hooks).
$CC -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ/mayhem/standalone_main.o"
for t in $TARGETS; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -DFUZZ_TEST_NAME="\"$t\"" -c "$SRC/mayhem/fuzz_select.c" -o "$FUZZ/mayhem/select_$t.o"
  fuzz_make "$FUZZ/lsan_off.o $HARNESS_OBJS $FUZZ/mayhem/select_$t.o"
  cp "$FUZZ/u-boot" "$SRC/$t"
  link=$(sed -n '1s/^cmd_u-boot := [^;]*; //p' "$FUZZ/.u-boot.cmd")
  link=$(printf '%s' "$link" | sed 's/ -o u-boot / -o u-boot-standalone /; s/ -fsanitize=fuzzer / -fsanitize=fuzzer-no-link /')
  (cd "$FUZZ" && eval "$link $FUZZ/mayhem/standalone_main.o")
  cp "$FUZZ/u-boot-standalone" "$SRC/$t-standalone"
done
ls -la $(for t in $TARGETS; do echo "$SRC/$t $SRC/$t-standalone"; done)
