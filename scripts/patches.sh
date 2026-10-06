#!/usr/bin/env bash
# Kernel source patching: SUSFS, path_umount backport, hide_stuff, manual hooks.
#
# Everything here is idempotent and version-aware. Each step is skipped with a
# clear message when it is unnecessary (feature already present) rather than
# failing, because these trees are frequently already partially patched.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
# Resolved from this file's location, not $PWD -- several helpers below run
# with the working directory changed into the kernel tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

# susfs_branch_for KVER -- map a kernel version onto a susfs4ksu branch.
#
# susfs4ksu is branched per kernel version. The GKI branches are named after
# the Android release they ship with; where a kernel version spans two Android
# releases (5.10 -> android12/android13, 5.15 -> android13/android14) we pick
# the older, which is the one the vast majority of trees are based on.
# Override with SUSFS_BRANCH when that guess is wrong.
susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6)  echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")
		[ -n "$branch" ] || die "no susfs4ksu branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"
		info "kernel ${kver} -> susfs branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" \
		|| die "susfs4ksu has no branch '${branch}'.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"
	retry 3 git clone -q --depth=1 -b "$branch" "$repo" "$susfs_dir" \
		|| die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"
	[ -d "$kp" ] || die "unexpected susfs4ksu layout: ${kp} missing"

	# 1. Drop in the SUSFS sources. The non-GKI branches carry sus_su.c too.
	info "copying SUSFS sources into the kernel tree"
	cp -v "${kp}/fs/"*.c              "${KERNEL_DIR}/fs/"            2>/dev/null || true
	cp -v "${kp}/include/linux/"*.h   "${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# 2. Patch the kernel itself.
	local kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"
	[ -f "$kernel_patch" ] || {
		# Fall back to whatever 50_* patch the branch actually ships.
		kernel_patch=$(find "$kp" -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -n1)
	}
	[ -n "$kernel_patch" ] && [ -f "$kernel_patch" ] \
		|| die "no 50_add_susfs_in_*.patch found in ${kp}"

	( cd "$KERNEL_DIR" && apply_patch "$kernel_patch" 1 ) \
		|| die "the SUSFS kernel patch did not apply cleanly.
       This usually means SUSFS_BRANCH does not match your kernel. Detected
       kernel ${kver}, used branch '${branch}'."

	# 3. Patch the KernelSU side -- but only when the variant does not already
	#    ship SUSFS support. SukiSU-Ultra's 'builtin' branch, for instance,
	#    declares CONFIG_KSU_SUSFS itself; applying the patch on top conflicts.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-the selected variant} already bundles SUSFS at ref '${KSU_REF_RESOLVED:-}'; skipping 10_enable_susfs_for_ksu.patch"
	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory ${ksu_dir} not found; skipping the KernelSU-side SUSFS patch"
	elif [ ! -f "$ksu_patch" ]; then
		warn "branch ${branch} ships no KernelSU/10_enable_susfs_for_ksu.patch; skipping"
	else
		( cd "$ksu_dir" && apply_patch "$ksu_patch" 1 ) || {
			warn "the KernelSU-side SUSFS patch did not apply."
			warn "susfs4ksu's non-GKI branches were last updated in early 2025 and still"
			warn "target the old flat KernelSU layout; modern forks have since moved to a"
			warn "modular kernel/ tree. Try a variant/ref whose layout matches, or a fork"
			warn "that bundles SUSFS itself (e.g. KSU_VARIANT=sukisu-ultra KSU_REF=builtin)."
			die "SUSFS integration failed"
		}
	fi

	# Record the SUSFS version for the build summary.
	local sv
	sv=$(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
		"${KERNEL_DIR}/include/linux/susfs.h" 2>/dev/null | head -n1)
	export_env SUSFS_VERSION "${sv:-unknown}"
	export_env SUSFS_BRANCH_RESOLVED "$branch"
	ok "SUSFS ${sv:-?} applied from branch ${branch}"
	summary "| SUSFS | \`${sv:-unknown}\` (branch \`${branch}\`) |"
	endgroup
}

# Does the selected variant+ref already contain SUSFS?
susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--} ref=${KSU_REF_RESOLVED:-}
	[ "$bundled" = "-" ] && return 1
	local r
	for r in $bundled; do
		[ "$r" = "$ref" ] && return 0
	done
	# Fall back to inspecting the tree, which is authoritative.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	[ -d "$ksu_dir" ] && grep -rqs 'CONFIG_KSU_SUSFS\|config KSU_SUSFS' "${ksu_dir}/kernel/Kconfig" 2>/dev/null
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# The SUSFS option set is NOT stable across branches, so it is discovered
	# from the Kconfig that was actually patched in rather than hardcoded.
	#
	# Concretely: the GKI branches ship SUSFS v2.x, which declares SUS_MAP and
	# has dropped the AUTO_ADD_*/SUS_OVERLAYFS/HAS_MAGIC_MOUNT knobs. The
	# non-GKI branches are still on v1.5.5 (last touched early 2025), which is
	# the exact opposite: it has the AUTO_ADD_* family and no SUS_MAP. A
	# hardcoded list is therefore wrong on one side or the other -- and wrong
	# in the silent direction, since an unknown symbol in a defconfig is simply
	# dropped, leaving the feature off with no warning.
	local syms
	syms=$(grep -rhoE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
			"$ksu_dir" "${KERNEL_DIR}/fs/Kconfig" "${KERNEL_DIR}/drivers/kernelsu" 2>/dev/null \
		| awk '{print $2}' | sort -u)

	if [ -z "$syms" ]; then
		die "found no KSU_SUSFS Kconfig symbols to enable.
       The SUSFS sources are in the tree but nothing declares its options, so
       the feature would silently compile out and you would ship a kernel that
       looks patched but hides nothing. Check that the KernelSU-side patch
       applied, or pick a variant that bundles SUSFS."
	fi

	local s enabled=0
	for s in $syms; do
		case "$s" in
			# sus_su is the legacy in-kernel su backend, superseded by the
			# manager; overlayfs hiding conflicts with magic mount. Both are
			# off in the reference builds.
			KSU_SUSFS_SUS_SU | KSU_SUSFS_SUS_OVERLAYFS)
				kconf_disable "$defconfig" "CONFIG_${s}" ;;
			*)
				kconf_enable "$defconfig" "CONFIG_${s}"; enabled=$((enabled + 1)) ;;
		esac
	done
	ok "enabled ${enabled} SUSFS options discovered from Kconfig"
	debug "SUSFS symbols: $(printf '%s ' $syms)"
}

# =============================================================== path_umount

# path_umount() landed upstream in Linux 5.9. KernelSU uses it to unmount its
# own overlays before handing control to an app that is checking for root, so
# on older trees it has to be backported or module unmounting silently no-ops.
#
# The body below is upstream's, unchanged. It is inserted immediately before
# the comment that introduces the umount syscall, which puts it after
# do_umount() -- its only forward dependency -- in every tree from 4.9 to 5.4.
path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"
	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup; return 0
	fi
	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -q '^int path_umount\|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup; return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'
	grep -q "$anchor" "$ns" \
		|| die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)
	# 'can_umount' is a separate helper upstream; guard it in case a partial
	# backport already added it.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

EOF
	fi
	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	# Insert before the line *above* the anchor comment body, i.e. at the '/*'
	# that opens it.
	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)
	# Walk back to the opening '/*' of that comment block.
	local start=$lineno
	while [ "$start" -gt 1 ] && ! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)
	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"
	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" || die "path_umount() insertion failed"
	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"
	endgroup
}

# ============================================================== extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

# Clone the shared patch/tool repo once, on demand.
sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"
	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 "$SUKISU_PATCH_REPO" "$dir" \
			|| die "failed to clone ${SUKISU_PATCH_REPO}"
	fi
	printf '%s' "$dir"
}

# hide_stuff removes the most obvious KernelSU fingerprints from the build.
hide_stuff_apply() {
	group "Applying hide_stuff"
	local dir patch
	dir=$(sukisu_patch_dir)
	patch="${dir}/69_hide_stuff.patch"
	[ -f "$patch" ] || { warn "69_hide_stuff.patch not found in the patch repo; skipping"; endgroup; return 0; }
	( cd "$KERNEL_DIR" && apply_patch "$patch" 1 ) || warn "hide_stuff did not apply cleanly; continuing"
	endgroup
}

# Manual/syscall hook patches for pre-GKI trees, used when the fork expects the
# hooks to already exist in the kernel source rather than hooking via kprobes.
hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none} kver
	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ReSukiSU publishes scope-minimised hook patches keyed by kernel version.
	if [ "$variant" = "resukisu" ]; then
		local dir="${WORKSPACE}/ReSukiSU_Patches"
		[ -d "$dir" ] || retry 3 git clone -q --depth=1 \
			https://github.com/ReSukiSU/ReSukiSU_Patches.git "$dir" || true
		local p="${dir}/scope-minimized/kernel-${kver}.patch"
		if [ -f "$p" ]; then
			( cd "$KERNEL_DIR" && apply_patch "$p" 1 ) && { endgroup; return 0; }
		else
			info "ReSukiSU ships no scope-minimized patch for kernel ${kver}"
		fi
	fi

	# SukiSU's patch repo carries per-version hook patches too.
	if [ "$variant" = "sukisu-ultra" ]; then
		local dir p
		dir=$(sukisu_patch_dir)
		for p in "${dir}/${kver}/"*hook*.patch "${dir}/hooks/syscall_hooks.patch"; do
			[ -f "$p" ] || continue
			if ( cd "$KERNEL_DIR" && apply_patch "$p" 1 ); then endgroup; return 0; fi
		done
	fi

	# Fall back to the in-repo sed script, which is what this action shipped
	# historically and still works for the 4.9-5.4 KernelSU 0.9.x hook API.
	info "falling back to the bundled legacy hook script"
	( cd "$KERNEL_DIR" && bash "${REPO_ROOT}/patches/legacy_ksu_hooks.sh" )
	endgroup
}

# ======================================================================== KPM

# SukiSU-Ultra's Kernel Patch Module support needs a post-link step: the
# patch_linux tool rewrites the built Image and emits oImage.
kpm_patch_image() {
	local image=$1
	group "Applying KPM (patch_linux)"
	local dir tool
	dir=$(sukisu_patch_dir)
	tool="${dir}/kpm/patch_linux"
	[ -f "$tool" ] || die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"
	chmod +x "$tool"
	( cd "$(dirname "$image")" && "$tool" "$(basename "$image")" ) \
		|| die "patch_linux failed"
	local out
	out="$(dirname "$image")/oImage"
	[ -f "$out" ] || die "patch_linux did not produce oImage"
	mv -f "$out" "$image"
	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"
	endgroup
}

# ====================================================== Droidspaces & NTsync

# Droidspaces is a container runtime for Android. It needs the SysV IPC stack
# (CONFIG_SYSVIPC plus the IPC namespace), which vendor defconfigs normally
# leave off. NTsync is the Windows NT synchronisation primitive driver Wine and
# Proton containers use; it only landed upstream in 6.14, so it is backported
# here -- driver source plus a lockdep/Kconfig compatibility patch.
#
# Both options add fields to structs whose layout Android's frozen GKI ABI pins
# down, so on 5.10 the kABI fixups below are not optional. They park the new
# fields in the ANDROID_KABI_RESERVE() padding the structs already carry, which
# leaves every pre-existing offset *and* both struct sizes byte-identical to a
# kernel built without these options. Skip them and the tree still compiles --
# it just no longer matches the ABI the prebuilt vendor modules were built
# against, and the device hangs on the boot splash.
#
#   struct user_struct -- CONFIG_POSIX_MQUEUE's mq_bytes   -> KABI slot 1
#   struct task_struct -- CONFIG_SYSVIPC's sysvsem/sysvshm -> KABI slots 6-8
#
# SUSFS is deliberately not involved here; see ENABLE_SUSFS.

DROIDSPACES_PATCH_BASE=${DROIDSPACES_PATCH_BASE:-https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/main}

# The URLs live in config.env so that an upstream move is fixable without a code
# change; these fallbacks keep the step working with an older profile.
NTSYNC_BASE_PATCH=${NTSYNC_BASE_PATCH:-${DROIDSPACES_PATCH_BASE}/NTsync/ntsync_base.patch}
NTSYNC_COMPAT_PATCH=${NTSYNC_COMPAT_PATCH:-${DROIDSPACES_PATCH_BASE}/NTsync/ntsync_compat_android12-5.10.patch}
DROIDSPACES_KABI_PATCH_5_10=${DROIDSPACES_KABI_PATCH_5_10:-${DROIDSPACES_PATCH_BASE}/GKI/5.10/GKI_5.10_posix.patch}
DROIDSPACES_KABI_SYSVIPC_PATCH_5_10=${DROIDSPACES_KABI_SYSVIPC_PATCH_5_10:-${DROIDSPACES_PATCH_BASE}/GKI/5.10/GKI-5.10-sysvipc_kabi_6_7_8.patch}

# defconfig_path -- absolute path of the defconfig named by KERNEL_CONFIG.
#
# KERNEL_CONFIG is documented, and consumed by build.sh both as
# arch/$ARCH/configs/$KERNEL_CONFIG and as the `make <name>_defconfig` target,
# as a path relative to arch/<ARCH>/configs/ -- e.g. "unicorn_merged_defconfig"
# or "vendor/wayne_defconfig". A kernel-tree-relative or absolute value is
# accepted too, so that a stray setting cannot quietly send the options below
# nowhere.
defconfig_path() {
	local cfg=${KERNEL_CONFIG:-}
	[ -n "$cfg" ] || die "KERNEL_CONFIG is unset; cannot enable kernel options"
	case "$cfg" in
		/*)     printf '%s' "$cfg" ;;
		arch/*) printf '%s/%s' "$KERNEL_DIR" "$cfg" ;;
		*)      printf '%s/arch/%s/configs/%s' "$KERNEL_DIR" "${ARCH:-arm64}" "$cfg" ;;
	esac
}

# droidspaces_patch LABEL URL DEST -- download one patch and apply it at the
# root of the kernel tree.
droidspaces_patch() {
	local label=$1 url=$2 dest=$3
	info "  -> ${label}"
	fetch "$url" "$dest"
	( cd "$KERNEL_DIR" && apply_patch "$dest" 1 ) || die "${label} did not apply cleanly.
       Either KERNEL_CONFIG does not belong to this kernel tree, or something
       earlier already patched the same hunks.
       Patch URL: ${url}"
}

droidspaces_ntsync_apply() {
	group "Applying Droidspaces & NTsync"

	if ! is_true "${ENABLE_DROIDSPACES:-false}"; then
		info "Droidspaces is disabled (ENABLE_DROIDSPACES is not 'true'); skipping"
		endgroup
		return 0
	fi

	local kver defconfig
	kver=$(kernel_version "$KERNEL_DIR") \
		|| die "cannot read VERSION/PATCHLEVEL from ${KERNEL_DIR}/Makefile"
	defconfig=$(defconfig_path)

	[ -f "$defconfig" ] || die "defconfig not found: ${defconfig}
       KERNEL_CONFIG is '${KERNEL_CONFIG}', which is read relative to
       arch/${ARCH:-arm64}/configs/.
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH:-arm64}/configs/" | head -20 | tr '\n' ' ')"

	local dir="${WORKSPACE}/droidspaces_patches"
	rm -rf "$dir"
	mkdir -p "$dir"

	# -------------------------------------------------------- kABI fixups ---
	#
	# Both fixups are needed, because both options end up on. SYSVIPC is the one
	# Droidspaces asks for, and POSIX_MQUEUE comes with it for free -- its Kconfig
	# is `depends on SYSVIPC` with `default y`. Each inserts a field no vendor
	# kernel ever had:
	#
	#   struct user_struct.mq_bytes -> ANDROID_KABI_RESERVE(1)
	#       Without the fixup this is 725 exported symbol CRCs on this tree;
	#       user_struct is reachable from task/file/socket through cred.user.
	#   struct task_struct.sysvsem / .sysvshm -> slots 6 and 7-8
	#       task_struct is the widest struct in the kernel, so this carries the
	#       largest blast radius of anything this action switches on.
	#
	# The trick works because genksyms reads _ANDROID_KABI_REPLACE() as its _orig
	# argument alone (see the __GENKSYMS__ branch of include/linux/android_kabi.h),
	# so the text a CRC is computed over stays literally
	# `u64 android_kabi_reservedN;` -- byte-identical to the ROM. The real layout is
	# unchanged too: struct sysv_sem is one pointer, struct sysv_shm one list_head,
	# and two reserve slots are exactly the 16 bytes those need.
	#
	# On 5.15+ GKI trees gki_defconfig already enables both, so the layout already
	# accounts for them and there is nothing to do.
	local need_fixup=true
	if is_true "$(kconf_get "$defconfig" CONFIG_POSIX_MQUEUE)"; then
		need_fixup=false
	fi

	if [ "$need_fixup" = "false" ]; then
		info "CONFIG_POSIX_MQUEUE is already on in ${KERNEL_CONFIG}; the ABI already accounts for it, no kABI fixup needed"
	elif ver_ge "$kver" "5.11"; then
		die "kernel ${kver} needs CONFIG_SYSVIPC and CONFIG_POSIX_MQUEUE switched
       on, and this repo ships their kABI fixups only for 5.10 and older.
       Switching them on without a fixup adds mq_bytes to struct user_struct and
       sysvsem/sysvshm to struct task_struct -- 725 exported symbol CRCs and more
       on this tree -- and the kernel then hangs on the boot logo with no log at
       all.
       Fixups for other versions, if any: ${DROIDSPACES_PATCH_BASE}/GKI/"
	else
		if [ -z "$DROIDSPACES_KABI_PATCH_5_10" ] || [ -z "$DROIDSPACES_KABI_SYSVIPC_PATCH_5_10" ]; then
			die "kernel ${kver} needs both 5.10 kABI fixups, but
       DROIDSPACES_KABI_PATCH_5_10 or DROIDSPACES_KABI_SYSVIPC_PATCH_5_10 is
       empty. Switching SYSVIPC / POSIX_MQUEUE on without them changes
       struct task_struct and struct user_struct, and the device will not boot.
       Set both URLs in ${CONFIG_ENV:-config.env}."
		fi

		# DROIDSPACES_SLOT names the ANDROID_KABI_RESERVE() set the SYSVIPC patch
		# claims. Upstream also ships 1_2_3 / 3_4_5 / 5_6_7 for the devices that
		# need a different set; 6_7_8 is the one that fits 5.10. Both spellings are
		# in use -- "678" in config.env, "6_7_8" in the file name -- so compare
		# digits only. A mismatch usually means the wrong patch was swapped in,
		# which builds fine and then fails to boot.
		local slot_digits url_digits
		slot_digits=$(printf '%s' "${DROIDSPACES_SLOT:-}" | tr -cd '0-9')
		url_digits=$(printf '%s' "${DROIDSPACES_KABI_SYSVIPC_PATCH_5_10##*/}" | tr -cd '0-9')
		if [ -n "$slot_digits" ] && [ -n "$url_digits" ] &&
			! printf '%s' "$url_digits" | grep -q "$slot_digits"; then
			warn "DROIDSPACES_SLOT=${DROIDSPACES_SLOT}, but the SYSVIPC patch URL does not mention it:"
			warn "  ${DROIDSPACES_KABI_SYSVIPC_PATCH_5_10}"
			warn "double-check which slot set fits kernel ${kver}"
		fi

		# POSIX_MQUEUE first: it only touches struct user_struct and carries no
		# dependency on the SYSVIPC hunks.
		droidspaces_patch "kABI fixup: POSIX_MQUEUE in struct user_struct" \
			"$DROIDSPACES_KABI_PATCH_5_10" "${dir}/kabi_posix_mqueue.patch"
		droidspaces_patch "kABI fixup: SYSVIPC in struct task_struct (slots ${DROIDSPACES_SLOT:-6_7_8})" \
			"$DROIDSPACES_KABI_SYSVIPC_PATCH_5_10" "${dir}/kabi_sysvipc.patch"
	fi

	# ------------------------------------------------------------- NTsync ---
	if is_true "${ENABLE_NTSYNC:-false}"; then
		droidspaces_patch "NTsync: driver (drivers/misc/ntsync.c, uapi header)" \
			"$NTSYNC_BASE_PATCH" "${dir}/ntsync_base.patch"
		droidspaces_patch "NTsync: ${kver} compat (lockdep API, Kconfig, Makefile)" \
			"$NTSYNC_COMPAT_PATCH" "${dir}/ntsync_compat.patch"
	else
		info "NTsync is disabled (ENABLE_NTSYNC is not 'true'); skipping"
	fi

	# ------------------------------------------------------------ Kconfig ---
	#
	# kconf_enable is idempotent, so an option that config.env's EXTRA_DEFCONFIG
	# already sets is rewritten rather than duplicated: a defconfig holding two
	# lines for one symbol resolves last-wins and is a pain to debug.
	#
	# SYSVIPC is what Droidspaces actually needs -- a container running PostgreSQL,
	# or a Wine/Proton title, calls shmget/semget/msgget directly -- and it is also
	# what makes IPC_NS reachable at all:
	#   config IPC_NS
	#       depends on NAMESPACES && (SYSVIPC || POSIX_MQUEUE)
	# With neither option the symbol does not exist, so containers get no IPC
	# namespace either. The kABI fixup above is the only reason switching it on is
	# ABI-safe, and build.sh re-checks that the fixup really is in the tree before
	# it compiles.
	#
	# POSIX_MQUEUE comes along on its own (default y under SYSVIPC) and is listed
	# explicitly so the second kABI fixup cannot be skipped by a profile that trims
	# this list down.
	kconf_set_many "$defconfig" \
		CONFIG_SYSVIPC=y \
		CONFIG_IPC_NS=y \
		CONFIG_POSIX_MQUEUE=y \
		CONFIG_POSIX_MQUEUE_SYSCTL=y

	if is_true "${ENABLE_NTSYNC:-false}"; then
		kconf_enable "$defconfig" CONFIG_NTSYNC
	fi

	ok "Droidspaces & NTsync applied (kernel ${kver}, kABI slots ${DROIDSPACES_SLOT:-default})"
	summary "| Droidspaces | applied (kABI slots \`${DROIDSPACES_SLOT:-6_7_8}\`) |"
	if is_true "${ENABLE_NTSYNC:-false}"; then
		summary "| NTsync | applied |"
	fi
	endgroup
}

# --------------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		susfs)        susfs_apply ;;
		path_umount)  path_umount_apply ;;
		hide_stuff)   hide_stuff_apply ;;
		hooks)        hooks_patch_apply ;;
		kpm)          kpm_patch_image "$2" ;;
		droidspaces)  droidspaces_ntsync_apply ;;
		all)
			# Order matters and this is the tested one (4.19 + SukiSU builtin
			# + SUSFS 1.5.5, no rejects):
			#   path_umount and the hook patches both key off textual anchors
			#   in files that SUSFS later rewrites, so they go first.
			#
			# Droidspaces/NTsync goes ahead of even those: its kABI hunks match
			# include/linux/sched.h and include/linux/sched/user.h
			# byte-for-byte only while those files are still stock, and it is
			# the one patch set the kernel cannot boot without, so it should be
			# the first thing to fail loudly if something is wrong.
			droidspaces_ntsync_apply

			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then path_umount_apply; fi

			# Driven by the *resolved* hook mode, not the raw setting, so that
			# KSU_HOOK_MODE=auto on a pre-GKI kernel still gets its hooks
			# patched in rather than only getting the Kconfig symbol set.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
			   [ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
				hooks_patch_apply
			fi

			if is_true "${ENABLE_SUSFS:-false}";      then susfs_apply;      fi
			if is_true "${ENABLE_HIDE_STUFF:-false}"; then hide_stuff_apply; fi
			;;
		*) die "unknown patch step '$1'" ;;
	esac
fi
