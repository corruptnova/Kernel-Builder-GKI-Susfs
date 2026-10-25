#!/usr/bin/env bash
# scripts/inject_KernelSU-Next.sh
# Dynamic SuSFS integration module for KernelSU-Next

echo ">>> Executing Integration Module for KernelSU-Next..."

# 1. Universally clone the target branch handed down by the YAML
echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

# Prevent setup.sh from performing a redundant clone
ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"

echo ">>> Executing native setup.sh to initialize branch..."
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> [DYNAMIC] Executing Automated Dynamic Transplant for KernelSU-Next..."
    
    # In dynamic, HEAD is already pristine upstream. Grab the hash before merging!
    UPSTREAM_HASH=$(git log -n 1 --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    
    echo "  -> Target Tag: $CALCULATED_TAG"
    echo "  -> Target Count: $CALCULATED_COUNT"

    echo ">>> 2. Fetching Pershoot's live laboratory..."
    git remote add pershoot https://github.com/pershoot/KernelSU-Next.git
    git fetch pershoot dev-susfs

    echo ">>> Configuring dummy Git identity for transplant operations..."
    git config --global user.email "runner@github.actions"
    git config --global user.name "GitHub Actions Canary"

    echo ">>> 3. Squashing and merging SuSFS features onto upstream tree..."
    if ! git merge --squash pershoot/dev-susfs; then
        echo "[-] CRITICAL: Merge conflict detected during squash merge!"
        git --no-pager diff --diff-filter=U
        exit 1
    fi
    
    git commit -m "Merge susfs features from pershoot"
    
    # Lock in variables for the Kbuild Gatekeeper
    UPSTREAM_BRANCH="${TARGET_BRANCH}"
    
else
    echo ">>> [STABLE] Safe fallback channel detected. Bypassing dynamic squash merge..."
    
    # Lock the upstream tracking variable to the stable branch
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    
    # Fetch official upstream branch and calculate pristine Merge-Base
    echo ">>> Locating official upstream sync point for ${UPSTREAM_REPO}..."
    # Added --tags --force here to guarantee the stable APK tag math never fails!
    git fetch --quiet --tags --force "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"
    RAW_BASE=$(git merge-base HEAD FETCH_HEAD)

    # Walk backward down the pristine mainline branch
    set +o pipefail
    UPSTREAM_HASH=$(git log -n 1 --first-parent "${RAW_BASE}" --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    set -o pipefail
    
    # Calculate exact versions for the Sandbox Gatekeeper
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v3.2.0")
fi

# Step back out to kernel_workspace
cd .. 

# ---------------------------------------------------------
# KernelSU-Next Hotfixes
# ---------------------------------------------------------

# Kbuild Strict Dependency Bypass
KBUILD_FILE="${MANAGER_DIR}/kernel/Kbuild"
if [ -f "$KBUILD_FILE" ]; then
    if grep -q "KernelSU requires either CONFIG_KPROBES" "$KBUILD_FILE"; then
        echo ">>> [HOTFIX] Bypassing strict Kbuild dependency check for the clean phase..."
        sed -i '/KernelSU requires either CONFIG_KPROBES/d' "$KBUILD_FILE"
    else
        echo ">>> [NOTICE] Strict Kbuild check not found! Upstream likely fixed this. You can remove this hotpatch."
    fi
fi

# Implicit Declaration Fix (task_pid_nr)
KDP_FILE="${MANAGER_DIR}/kernel/compat/samsung_kdp.c"
if [ -f "$KDP_FILE" ]; then
    if ! grep -q "#include <linux/pid.h>" "$KDP_FILE"; then
        echo ">>> [HOTFIX] Injecting linux/pid.h into samsung_kdp.c to fix implicit declaration..."
        sed -i '1i #include <linux/pid.h>' "$KDP_FILE"
    else
        echo ">>> [NOTICE] pid.h is already included in samsung_kdp.c. Upstream likely fixed this."
    fi
fi

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"

echo ">>> KernelSU-Next integration complete."
