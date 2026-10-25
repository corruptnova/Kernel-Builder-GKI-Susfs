#!/usr/bin/env bash
# scripts/inject_KernelSU.sh

echo ">>> Executing Integration Module for standard KernelSU..."

# 1. Universally clone the target branch handed down by the YAML
echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> [DYNAMIC] Executing Automated Dynamic Transplant for KernelSU..."
    
    # In dynamic, HEAD is already pristine upstream. Grab the hash!
    UPSTREAM_HASH=$(git log -n 1 --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    
    UPSTREAM_BRANCH="${TARGET_BRANCH}"

    echo ">>> 2. Fetching Simonpunk's dynamic 10_enable_susfs_for_ksu patch..."
    PATCH_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android15-6.6-dev/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

    if wget -qO 10_enable_susfs_for_ksu.patch "$PATCH_URL"; then
        echo ">>> 3. Applying SuSFS patch dynamically..."
        patch -p1 < 10_enable_susfs_for_ksu.patch || exit 1
        
        echo ">>> 4. Injecting SuSFS Macros & Compiler Overrides into Kbuild..."
        cat << 'EOF' >> kernel/Kbuild

# --- Force SuSFS Macros and Compiler Overrides ---
ccflags-y += -Wno-pointer-bool-conversion
ccflags-y += -DCONFIG_KSU_SUSFS=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_PATH=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_MOUNT=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_KSTAT=1
ccflags-y += -DCONFIG_KSU_SUSFS_SPOOF_UNAME=1
ccflags-y += -DCONFIG_KSU_SUSFS_ENABLE_LOG=1
ccflags-y += -DCONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=1
ccflags-y += -DCONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=1
ccflags-y += -DCONFIG_KSU_SUSFS_OPEN_REDIRECT=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_MAP=1
# --- Print SuSFS Version ---
ifeq ($(strip $(CONFIG_KSU_SUSFS)),y)
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info -- SuSFS version: $(SUSFS_VERSION))
endif
endif
EOF
        rm 10_enable_susfs_for_ksu.patch
    else
        echo "[-] CRITICAL: Failed to download the SuSFS patch."
        exit 1
    fi
else
    echo ">>> [STABLE] Safe fallback channel detected. Bypassing dynamic patching..."
    
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    
    echo ">>> Locating official upstream sync point for ${UPSTREAM_REPO}..."
    # Guarantee safe tag math with --tags --force
    git fetch --quiet --tags --force "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"
    RAW_BASE=$(git merge-base HEAD FETCH_HEAD)
    
    set +o pipefail
    UPSTREAM_HASH=$(git log -n 1 --first-parent "${RAW_BASE}" --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    set -o pipefail

    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")
fi

# Exit the MANAGER_DIR universally
cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> Standard KernelSU injection complete."
