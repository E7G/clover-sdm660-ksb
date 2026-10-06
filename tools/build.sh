#!/bin/bash
# Clover KS-SB Hybrid 4.19 - build driver.
#
#   tools/build.sh config     generate .config (defconfig + clover.config fragment)
#   tools/build.sh kernel     build arch/arm64/boot/Image.gz
#   tools/build.sh package    splice Image.gz into a copy of the stock boot image
#   tools/build.sh all        config + kernel + package
#
# Environment:
#   SRC    kernel tree        (default /home/kali/android/clover-ksb)
#   OUT    out-of-tree build  (default /home/kali/android/clover-ksb-out)
#   STOCK  stock boot image   (default $HOME/boot-0.19.4-lineage.img)
#   JOBS   make -j            (default nproc)
#   CLANG  clang binary       (default clang-22)
set -e

SRC=${SRC:-/home/kali/android/clover-ksb}
OUT=${OUT:-/home/kali/android/clover-ksb-out}
STOCK=${STOCK:-$HOME/boot-0.19.4-lineage.img}
JOBS=${JOBS:-$(nproc)}
CLANG=${CLANG:-clang-22}
FRAGMENT=arch/arm64/configs/vendor/xiaomi/clover.config
FRAG=${FRAG:-}

TC="CROSS_COMPILE=aarch64-linux-gnu- CC=$CLANG LD=ld.lld-22 AR=llvm-ar-22 NM=llvm-nm-22"
TC="$TC OBJCOPY=llvm-objcopy-22 OBJDUMP=llvm-objdump-22 STRIP=llvm-strip-22 READELF=llvm-readelf-22"
TC="$TC HOSTCC=$CLANG HOSTCXX=clang++-22 HOSTAR=llvm-ar-22 HOSTLD=ld.lld-22"
TC="$TC CLANG_TRIPLE=aarch64-linux-gnu-"

cd "$SRC"

apply_resukisu_susfs_compat() {
	local ksu="$SRC/drivers/ReSukiSU"
	local patch="$SRC/tools/patches/resukisu-susfs-legacy.patch"
	[ -f "$patch" ] || return 0
	[ -d "$ksu/.git" ] || [ -f "$ksu/.git" ] || {
		echo "error: ReSukiSU submodule is not initialized: $ksu" >&2
		exit 1
	}
	if git -C "$ksu" apply --check "$patch" >/dev/null 2>&1; then
		echo "=== applying ReSukiSU SUSFS v1.5.x compatibility patch"
		git -C "$ksu" apply "$patch"
	elif git -C "$ksu" apply --reverse --check "$patch" >/dev/null 2>&1; then
		echo "=== ReSukiSU SUSFS compatibility patch already applied"
	else
		echo "error: ReSukiSU SUSFS compatibility patch does not apply cleanly" >&2
		exit 1
	fi
}

do_config() {
	apply_resukisu_susfs_compat
	echo "=== config: sdm660_defconfig + $FRAGMENT"
	mkdir -p "$OUT"
	rm -f "$OUT/.config"
	make O="$OUT" ARCH=arm64 $TC vendor/xiaomi/sdm660_defconfig
	[ -f "$FRAGMENT" ] && scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "$FRAGMENT" >/dev/null
	for f in $FRAG; do [ -f "$f" ] && scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "$f" >/dev/null || true; done
	make O="$OUT" ARCH=arm64 $TC olddefconfig
	grep -E '^CONFIG_LOCALVERSION=|^CONFIG_MACH_XIAOMI_CLOVER=|^CONFIG_PSI=|^CONFIG_WQ_POWER_EFFICIENT_DEFAULT=|^CONFIG_KSU=|^CONFIG_CPU_FREQ_DEFAULT_GOV|^CONFIG_DRM_VKMS=|^CONFIG_DMABUF_HEAPS=' "$OUT/.config" || true
}

do_kernel() {
	apply_resukisu_susfs_compat
	echo "=== kernel: Image.gz"
	make O="$OUT" ARCH=arm64 $TC -j"$JOBS" Image.gz
	ls -l "$OUT/arch/arm64/boot/Image.gz"
}

do_package() {
	local k="$OUT/arch/arm64/boot/Image.gz"
	local rev
	rev=$(grep -oP '(?<=CONFIG_LOCALVERSION=")[^"]*' "$OUT/.config" || echo unknown)
	local out="$OUT/boot-${rev#-}.img"
	echo "=== package: $k -> $out"
	tools/bootimg.py repack "$STOCK" "$k" "$out"
	sha256sum "$out" | tee "$out.sha256"
	echo "=== flash with:"
	echo "    fastboot flash boot $out"
}

case "${1:-all}" in
	config)  do_config ;;
	kernel)  do_kernel ;;
	package) do_package ;;
	all)     do_config; do_kernel; do_package ;;
	*) echo "usage: $0 {config|kernel|package|all}" >&2; exit 2 ;;
esac
