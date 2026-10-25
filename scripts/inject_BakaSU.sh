#!/usr/bin/env bash
# scripts/inject_BakaSU.sh

echo ">>> Executing Integration Module for BakaSU..."

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 1. Cloning pristine official BakaSU upstream..."
    git clone -b "${TARGET_BRANCH}" "https://github.com/${UPSTREAM_REPO}.git" "${MANAGER_DIR}"
    
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
    cd common
    bash "${MANAGER_DIR}/kernel/setup.sh" "${TARGET_BRANCH}"
    cd ..
    
    cd "${MANAGER_DIR}"
    UPSTREAM_HASH=$(git log -n 1 --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}")
    UPSTREAM_BRANCH="${TARGET_BRANCH}"

    echo ">>> 2. Applying dynamic Kleaf bypass & Kconfig overrides..."
    sed -i 's/default KSU_TRACEPOINT_HOOK/default KSU_SUSFS/g' kernel/Kconfig
    sed -i 's/bool "Tracepoint Syscall Redirect"/bool "Tracepoint Syscall Redirect"\n\t\tdepends on n/g' kernel/Kconfig
    sed -i 's/depends on KSU != m/depends on n/g' kernel/Kconfig
    sed -i 's/ifeq ($(shell test -e $(srctree)\/fs\/susfs.c.*/ifeq (0,0)/g' kernel/Kbuild
    sed -i 's/cat $(srctree)\/include\/linux\/susfs.h |/cat $(srctree)\/include\/linux\/susfs.h 2>\/dev\/null |/g' kernel/Kbuild
    cd ..
else
    echo ">>> Safe fallback channel detected. Cloning custom pipeline branch..."
    git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"
    
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
    cd common
    bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
    cd ..
    
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    
    cd "${MANAGER_DIR}"
    
    echo ">>> Locating official upstream sync point for ${UPSTREAM_REPO}..."
    git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"
    RAW_BASE=$(git merge-base HEAD FETCH_HEAD)
    
    set +o pipefail
    UPSTREAM_HASH=$(git log -n 1 --first-parent "${RAW_BASE}" --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    set -o pipefail

    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")
    
    cd ..
fi

# ---------------------------------------------------------
# BakaSU Hotfixes
# ---------------------------------------------------------

# We strip the $(error ...) directive to force compilation of our custom port.
SUSFS_COMPAT_MK="${MANAGER_DIR}/kernel/tools/susfs_compat.mk"
if [ -f "$SUSFS_COMPAT_MK" ]; then
    echo ">>> [HOTFIX] Neutering BakaSU strict SuSFS version gatekeeper..."
    sed -i '/Please wait susfs update/d' "$SUSFS_COMPAT_MK"
else
    echo ">>> [NOTICE] BakaSU gatekeeper file not found at $SUSFS_COMPAT_MK"
fi

# SELinux Hide LTO and Kernel Compat Patches
SELINUX_HIDE_FILE="${MANAGER_DIR}/kernel/feature/selinux_hide.c"
if [ -f "$SELINUX_HIDE_FILE" ]; then

    # Newer BakaSU exports the 50_patch SELinux symbols itself (my_* behind __maybe_static,
    # setprocattr renamed to my_setprocattr) and ships preinit, so the polyfills below must stay off.
    BAKASU_NATIVE_SUSFS=false
    if grep -q '__maybe_static ssize_t my_write_context' "$SELINUX_HIDE_FILE" && [ -f "${MANAGER_DIR}/kernel/preinit/preinit.c" ]; then
        BAKASU_NATIVE_SUSFS=true
        echo ">>> BakaSU exports the 50_patch symbols natively. Skipping SELinux hook polyfills..."
    fi

    # 1. Force compile manual hooks to satisfy 50_patch linker requirements
    if [ "$BAKASU_NATIVE_SUSFS" = "false" ]; then
        echo ">>> [HOTFIX] Exposing BakaSU static symbols for hooks.c linker..."
        sed -i 's|#include "compat/kernel_compat.h"|#include "compat/kernel_compat.h"\n\n/* Force compile manual hooks */\n#undef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE|g' "$SELINUX_HIDE_FILE"

        sed -i -E 's/(^|[^_[:alnum:]])static ssize_t my_write_context/\1ssize_t my_write_context/g' "$SELINUX_HIDE_FILE"
        sed -i -E 's/(^|[^_[:alnum:]])static ssize_t my_write_access/\1ssize_t my_write_access/g' "$SELINUX_HIDE_FILE"
    fi

    # 2. Non-void return fix for legacy kernels < 6.6
    K_VER=$(grep "^VERSION =" common/Makefile | tr -d ' ' | cut -d'=' -f2 || echo "0")
    K_PATCH=$(grep "^PATCHLEVEL =" common/Makefile | tr -d ' ' | cut -d'=' -f2 || echo "0")
    if ! { [ "$K_VER" = "6" ] && [ "$K_PATCH" -ge "6" ]; }; then
        if grep -q "void security_compute_av_user_with_policy" "$SELINUX_HIDE_FILE"; then
            echo ">>> [HOTFIX] Patching BakaSU non-void return error for legacy kernels..."
            sed -i 's/__maybe_static void security_compute_av_user_with_policy/__maybe_static int security_compute_av_user_with_policy/g' "$SELINUX_HIDE_FILE"
            sed -i 's/ksu_security_compute_av_user(policydb, sidtab, ssid, tsid, tclass, avd);/ksu_security_compute_av_user(policydb, sidtab, ssid, tsid, tclass, avd);\n\treturn 0;/g' "$SELINUX_HIDE_FILE"
        fi
    fi
    
    # 3. Polyfill 50_patch Linker Stubs (my_setprocattr & Preinit)
    if [ "$BAKASU_NATIVE_SUSFS" = "true" ] && ! grep -q "ksu_setup_preinit_file" "$SELINUX_HIDE_FILE"; then
        # preinit.o is only built when the UAPI headers are reachable, so keep weak fallbacks
        # that its strong definitions override whenever it is built.
        echo ">>> [HOTFIX] Injecting weak preinit fallbacks for 50_patch exec.c..."
        cat << 'EOF' >> "$SELINUX_HIDE_FILE"

/* BakaSU 50_patch Preinit Fallbacks (overridden by preinit/preinit.c when built) */
struct filename;
struct user_arg_ptr;

__attribute__((weak)) int ksu_setup_preinit_file(struct filename **filename_ptr, struct user_arg_ptr *argv_user) {
    return 0;
}

__attribute__((weak)) int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr,
                void *argv_user, void *envp_user,
                int *flags, int *retval, int *preinit_fd) {
    return 0;
}
EOF
    elif ! grep -q "ksu_setup_preinit_file" "$SELINUX_HIDE_FILE"; then
        echo ">>> [HOTFIX] Injecting safe C stubs to bypass preinit linker panics..."
        cat << 'EOF' >> "$SELINUX_HIDE_FILE"

/* BakaSU 50_patch Preinit & Hook Linker Stubs */
struct filename;
struct user_arg_ptr;
struct task_struct;
struct selinux_state;

/* Safely bypasses SuSFS preinit interception to prevent Rescue Party */
int ksu_setup_preinit_file(struct filename **filename_ptr, struct user_arg_ptr *argv_user) {
    return 0; 
}

int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr,
                void *argv_user, void *envp_user,
                int *flags, int *retval, int *preinit_fd) {
    return 0;
}

/* Satisfies static hooks.c calls */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0) || defined(KSU_COMPAT_SETPROCATTR_USE_NEW_PROTOTYPE)
int __nocfi my_setprocattr(const char *name, void *value, size_t size) {
    return ksu_handle_selinux_setprocattr(name, value, size);
}
#else
int __nocfi my_setprocattr(struct task_struct *p, char *name, void *value, size_t size) {
    return ksu_handle_selinux_setprocattr(p, name, value, size);
}
#endif
EOF
    fi
fi    

# Un-hide static SELinux state variables to satisfy 50_patch linker requirements
echo ">>> [HOTFIX] Un-hiding BakaSU static SELinux state variables for 50_patch..."
    
    # Strip static prefixes so the 50_ patch can link to BakaSU's native state
    sed -i -E 's/(__maybe_static|static)[[:space:]]+bool ksu_selinux_hide/bool ksu_selinux_hide/g' "$SELINUX_HIDE_FILE"
    sed -i -E 's/(__maybe_static|static)[[:space:]]+struct page \*fake_status/struct page \*fake_status/g' "$SELINUX_HIDE_FILE"
    sed -i -E 's/(__maybe_static|static)[[:space:]]+DEFINE_STATIC_KEY_FALSE/DEFINE_STATIC_KEY_FALSE/g' "$SELINUX_HIDE_FILE"
    sed -i -E 's/(__maybe_static|static)[[:space:]]+void initialize_fake_status/void initialize_fake_status/g' "$SELINUX_HIDE_FILE"
    sed -i -E 's/(__maybe_static|static)[[:space:]]+struct selinux_policy \*backup_sepolicy/struct selinux_policy \*backup_sepolicy/g' "$SELINUX_HIDE_FILE"
    
    # Universal fake_state polyfill to survive LTO
    sed -i -E 's/^[ \t]*static[ \t]+struct selinux_state fake_state/struct selinux_state fake_state/g' "$SELINUX_HIDE_FILE"
    if ! grep -q "KSU_FAKE_STATE_POLYFILL" "$SELINUX_HIDE_FILE"; then
        cat << 'EOF' >> "$SELINUX_HIDE_FILE"

/* KSU_FAKE_STATE_POLYFILL */
__attribute__((weak)) struct selinux_state fake_state = {0};
EOF
    fi
    echo "  -> BakaSU legacy variables safely un-hidden."

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> BakaSU integration complete."
