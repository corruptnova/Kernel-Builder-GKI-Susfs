#!/usr/bin/env bash
# scripts/inject_SukiSU-Ultra.sh

echo ">>> Executing Integration Module for SukiSU-Ultra..."

# Override channel routing so both 'stable' and 'dynamic' runs pull the custom
# SuSFS pt_regs commits from the shoey63 fork (while leaving 'main' untouched).
if [ "${BUILD_CHANNEL}" != "main" ]; then
    echo ">>> [OVERRIDE] Routing SukiSU-Ultra base clone to shoey63/SukiSU-Ultra (stable)..."
    KSU_VARIANT_REPO_URL="https://github.com/shoey63/SukiSU-Ultra.git"
    KSU_VARIANT_REF="stable"
fi

echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
# Run setup.sh BEFORE rebasing so it links common/drivers/kernelsu without clobbering git history
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 2. Dynamic mode active: Fetching latest official upstream (${TARGET_BRANCH})..."
    git fetch --tags --force "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"

    echo ">>> 3. Rebasing '${KSU_VARIANT_REF}' onto bleeding-edge upstream/${TARGET_BRANCH}..."
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"

    if git rebase FETCH_HEAD; then
        echo "  -> On-the-fly rebase succeeded cleanly!"
        UPSTREAM_BRANCH="${TARGET_BRANCH}"
    else
        echo "  -> [WARNING] Rebase conflict detected with latest upstream!"
        git rebase --abort
        echo "  -> Aborted rebase and fell back to last known-good '${KSU_VARIANT_REF}' state."
        UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    fi
else
    echo ">>> 2. Safe fallback channel active: Fetching upstream sync point..."
    git fetch --quiet --tags --force "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"
    
    echo ">>> 3. Using pinned '${KSU_VARIANT_REF}' state without rebasing."
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

# 4. Calculate the official upstream sync point for version count and Manager APK matching
RAW_BASE=$(git merge-base HEAD FETCH_HEAD)

set +o pipefail
UPSTREAM_HASH=$(git log -n 1 --first-parent "${RAW_BASE}" --format="%H" -i --grep="ci skip" --grep="skip ci" --invert-grep -- manager/ kernel/ userspace/ ":!*Cargo.lock" ":!*Cargo.toml")
set -o pipefail

CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"

echo ">>> SukiSU-Ultra integration complete."
