/*
 * Fuzz test for fdt_chosen(): the devicetree fixup U-Boot runs on the OS devicetree before booting it
 * (bootm/booti/bootz via image-fdt.c, and the `fdt chosen` command). With CONFIG_OF_STDOUT_VIA_ALIAS it
 * copies /aliases/serialN into linux,stdout-path.
 */

#include <fdt_support.h>
#include <linux/libfdt.h>
#include <linux/string.h>
#include <test/fuzz.h>

/* Room for the properties fdt_chosen() adds, like the padding bootm gives the blob it relocates. */
#define FDT_PAD 4096

/* libfdt needs an 8-byte aligned blob; libFuzzer's input is not, so work on an aligned host copy. */
int host_posix_memalign(void **ptr, size_t align, size_t size) __asm__("posix_memalign");
void host_free(void *ptr) __asm__("free");

static int fuzz_fdt_chosen(const uint8_t *input, size_t size)
{
	void *fdt;

	if (size < sizeof(struct fdt_header))
		return 0;

	if (host_posix_memalign(&fdt, 8, size + FDT_PAD))
		return 0;
	memcpy(fdt, input, size);

	/*
	 * libfdt's contract (libfdt.h, fdt_check_full()): the accessors assume a well-formed blob, so an
	 * untrusted one is checked in full first. The devicetree is still arbitrary as far as its contents go.
	 */
	if (fdt_check_full(fdt, size) == 0 && fdt_open_into(fdt, fdt, size + FDT_PAD) == 0)
		fdt_chosen(fdt);

	host_free(fdt);
	return 0;
}
FUZZ_TEST(fuzz_fdt_chosen, 0);
