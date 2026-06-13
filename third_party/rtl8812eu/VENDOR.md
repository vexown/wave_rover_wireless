# Vendored: rtl8812eu driver

This directory is a **vendored local copy** of the RTL8812EU Linux driver,
included so this project can be rebuilt independently of upstream availability.

## Provenance

- **Upstream:** https://github.com/svpcom/rtl8812eu
- **Tag:** `v5.15.0.1`
- **Commit:** `48e6e449e089fa954e4e15079bd864039e2960da`
- **Vendored on:** 2026-06-13
- **Upstream `.git` removed** (we track it as plain files in this repo).

## License

GPL-2.0-only. The driver ships **no standalone LICENSE file**; the terms are
stated in the header of every source file (Realtek, "version 2 of the GNU
General Public License"). Those headers are preserved unmodified.

This is a **separate, independent program** (a Linux kernel module) from the
GPL-3.0 wfb-ng code in the rest of this repository. The two are not linked or
combined — they are a **mere aggregate** under GPL §5, kept in this isolated
subdirectory. The driver is **not relicensed** and remains GPL-2.0-only.

## Local modifications

Only the build platform was changed, to target 64-bit Raspberry Pi (arm64),
which both Pis in this project use:

| File | Change |
|------|--------|
| `Makefile` line 181 | `CONFIG_PLATFORM_I386_PC = y` → `= n` |
| `Makefile` line 183 | `CONFIG_PLATFORM_ARM64_RPI = n` → `= y` |

No source (`.c`/`.h`) files were modified.

## Re-syncing with upstream (if ever needed)

```bash
git clone --depth 1 -b <tag> https://github.com/svpcom/rtl8812eu.git /tmp/rtl8812eu
cd /tmp/rtl8812eu
sed -i 's/^CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' Makefile
sed -i 's/^CONFIG_PLATFORM_ARM64_RPI = n/CONFIG_PLATFORM_ARM64_RPI = y/' Makefile
rm -rf .git
# then replace third_party/rtl8812eu/ with this, and update the commit/tag above
```

## Build

See [`../../INSTALL.md`](../../INSTALL.md) §2.1. In short, from this directory:
`sudo ./dkms-install.sh` (prerequisites: `dkms build-essential bc linux-headers-$(uname -r)`).
