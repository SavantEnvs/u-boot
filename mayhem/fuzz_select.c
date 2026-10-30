/* Picks which FUZZ_TEST() the sandbox runs. u-boot's libFuzzer entry
 * (arch/sandbox/cpu/os.c) reads $UBOOT_SB_FUZZ_TEST; one tiny object per
 * target bakes that choice in so each binary needs no environment. */
#include <stdlib.h>

#ifndef FUZZ_TEST_NAME
#error "build with -DFUZZ_TEST_NAME=\"<fuzz test>\""
#endif

__attribute__((constructor)) static void select_fuzz_test(void)
{
	setenv("UBOOT_SB_FUZZ_TEST", FUZZ_TEST_NAME, 0);
}
