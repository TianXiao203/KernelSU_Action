#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	# Kept as a standalone switch for kernels that need kprobes for their own
	# reasons, independent of the hook mode.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact names predictable. Without this the
	# tree appends "-dirty" as soon as any patch above touches a tracked file.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

# ------------------------------------------------------- config fragments ---

# merge_config_fragments -- apply arch/arm64/configs/vendor/*.config on top of
# the .config the defconfig target just produced.
#
# On a GKI tree gki_defconfig carries only the core. The SoC and device options
# live in fragments under arch/arm64/configs/vendor/ and are merged on top by
# the ROM's own build (build.config + merge_config.sh). Skipping them still
# gives a kernel that compiles -- just one with no SoC support whatsoever: no
# ARCH_WAIPIO, no UFS controller, no clocks, no regulators, no zram, and none of
# the vendor modules the ROM's user space expects. It hangs on the first splash
# screen without printing anything, which is a miserable thing to debug from a
# CI log.
#
# The fragments go on AFTER the defconfig target because that is the only order
# in which a fragment can win over a value baked into the defconfig -- and the
# same order the ROM uses. `-m` tells merge_config.sh to stop before running
# make, so olddefconfig is issued here to resolve the new dependencies.
merge_config_fragments() {
	[ -n "${KERNEL_CONFIG_FRAGMENTS:-}" ] || return 0

	group "Merging kernel config fragments"

	local f frags=() args
	args=$(make_args)
	for f in ${KERNEL_CONFIG_FRAGMENTS}; do
		if [ -f "${KERNEL_DIR}/${f}" ]; then
			frags+=("${KERNEL_DIR}/${f}")
			info "  + ${f}"
		else
			warn "config fragment not found: ${f}"
		fi
	done
	[ "${#frags[@]}" -gt 0 ] || die "none of the KERNEL_CONFIG_FRAGMENTS exist under ${KERNEL_DIR}"

	[ -x "${KERNEL_DIR}/scripts/kconfig/merge_config.sh" ] \
		|| die "${KERNEL_DIR}/scripts/kconfig/merge_config.sh is missing; cannot merge fragments"

	"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${KERNEL_DIR}/out" \
		"${KERNEL_DIR}/out/.config" "${frags[@]}" \
		|| die "merge_config.sh failed"

	cd "$KERNEL_DIR"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args olddefconfig \
		|| die "olddefconfig failed after merging the config fragments"

	# A fragment that silently failed to apply would hand back exactly the same
	# unbootable kernel as not merging at all, so check the end state instead of
	# trusting the merge. These are the options this build exists for.
	local required="" sym missing=""
	if is_true "${ENABLE_DROIDSPACES:-false}"; then
		required="${required} CONFIG_SYSVIPC=y CONFIG_IPC_NS=y CONFIG_POSIX_MQUEUE=y"
	fi
	if is_true "${ENABLE_NTSYNC:-false}"; then
		required="${required} CONFIG_NTSYNC=y"
	fi
	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		required="${required} CONFIG_KSU=y"
	fi
	for sym in $required; do
		grep -qx "$sym" "${KERNEL_DIR}/out/.config" || missing="${missing} ${sym}"
	done
	[ -z "$missing" ] || die "these options are missing from out/.config after merging:${missing}
       A fragment probably did not apply, or KERNEL_CONFIG_FRAGMENTS is incomplete."

	ok "merged ${#frags[@]} fragment(s)"
	endgroup
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" \
		|| die "defconfig generation failed"

	merge_config_fragments

	info "make ${args}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	# KPM rewrites the image in place, so it has to happen after the build and
	# before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# Record the version string the kernel actually reports.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
