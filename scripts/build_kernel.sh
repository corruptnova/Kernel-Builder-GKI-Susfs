#!/usr/bin/env bash
# scripts/build_kernel.sh
set -euo pipefail

ENABLE_NET_OPTS=${ENABLE_NET_OPTS:-false}
BASE_VER=${BASE_VER:-}

echo "=== Initializing Execution Engine ==="

cd kernel_workspace
mkdir -p ../out out/dist

echo ">>> Marking repo as clean (sanitizes all custom configuration & source modifications)..."
# Dynamically safeguards all modifications 
git -C common ls-files -m | xargs -r git -C common update-index --assume-unchanged

# Build method 
if [ "$BASE_VER" != "5.10" ] && [ -f "tools/bazel" ]; then
    echo ">>> Modern Kleaf/Bazel ecosystem detected for $BASE_VER..."
    
    # 5.15 Kleaf doesn't support the --notrim wrapper flag. 
    # (configure_kconfigs.sh handles it physically via the dictionary injection)
    TRIM_FLAGS=""
    if [ "$BASE_VER" = "5.15" ]; then
        echo "  -> 5.15 detected. Relying on physical Bazel dictionary patch (omitting --notrim)..."
    else
        TRIM_FLAGS="--notrim"
    fi
    
    # Enforce standard sandboxing, disable trimming dynamically, and inject MAKEFLAGS
    tools/bazel run --config=stamp \
      $TRIM_FLAGS \
      --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
      --action_env=STABLE_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_KERNEL_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_SKIP_ABI_CHECKS=true \
      --action_env=KLEAF_USER=android-build \
      //common:kernel_aarch64_dist \
      -- \
      --destdir=out/dist
else
    echo ">>> Legacy Hermetic Make ecosystem detected (5.10 or fallback)..."
    
    mkdir -p out/dist
    export DIST_DIR="out/dist"
    
    # Export standard environment variables for legacy build.sh
    export KERNEL_DIR="common"
    export BUILD_CONFIG="common/build.config.gki.aarch64"
    export SOURCE_DATE_EPOCH="$OFFICIAL_DATE"
    
    # Inject official hash and Make overrides
    export EXTRA_LINUX_VERSION="-g${OFFICIAL_HASH}"
    
    # Run the legacy orchestration script
    if [ -f "build/build.sh" ]; then
        echo "[+] Invoking build/build.sh..."
        bash build/build.sh
    else
        echo "[-] ERROR: Legacy build/build.sh orchestrator not found!" >&2
        exit 1
    fi
fi

IMAGE_PATH="$(find out/dist -type f -name 'Image' -print -quit)"
if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No compilation Image produced!" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"

cp -f "${IMAGE_PATH}" ../out/Image

echo ">>> Extracting kernel runtime version string..."
# Try matching the standard format first, then fall back to a looser grep for legacy banners
KERNEL_VERSION_STRING=$(strings ../out/Image | grep -E "Linux version [0-9]" | head -n 1 || true)

if [ -z "$KERNEL_VERSION_STRING" ]; then
    KERNEL_VERSION_STRING=$(strings ../out/Image | grep -i "Linux version" | head -n 1 || true)
fi

if [ -n "$KERNEL_VERSION_STRING" ]; then
    echo "    $KERNEL_VERSION_STRING"
else
    echo "    [!] Notice: Could not read raw banner string directly from compiled Image binary."
fi

# --- DYNAMIC KCONFIG VALIDATION REPORT ---
if [ -s "../tools/custom_combined.fragment" ]; then
    echo "::group::Custom Kconfig Integration Report"
    echo ""
    echo "=============================================="
    echo " CUSTOM KCONFIG VALIDATION REPORT             "
    echo "=============================================="

    FRAGMENT_FILE="../tools/custom_combined.fragment"
    
    if [ ! -f "$FRAGMENT_FILE" ]; then
        echo "[-] Notice: tools/custom.fragment not found. Skipping validation."
    else
        # Locate the definitive compiled configuration source
        CONFIG_SRC=""
        if [ -f "out/dist/config.gz" ]; then
            CONFIG_SRC="out/dist/config.gz"
        elif [ -f "out/dist/.config" ]; then
            CONFIG_SRC="out/dist/.config"
        else
            CONFIG_SRC=$(find out/ -type f \( -name "config.gz" -o -name ".config" \) 2>/dev/null | head -n 1 || true)
        fi

        if [ -z "$CONFIG_SRC" ]; then
            echo "[!] WARN: Could not locate compiled kernel configuration target."
        else
            echo ">>> Extracting definitions from: $CONFIG_SRC"
            echo "----------------------------------------------"
            
            # Extract requested configs from fragment, ignoring comments and empty lines
            REQUESTED_CONFIGS=$(grep -E '^CONFIG_' "$FRAGMENT_FILE" | cut -d'=' -f1 || true)
            
            if [ -z "$REQUESTED_CONFIGS" ]; then
                echo "  [-] No active custom configs found in fragment."
            else
                for CFG in $REQUESTED_CONFIGS; do
                    # Search compiled config for the requested variable
                    if [[ "$CONFIG_SRC" == *.gz ]]; then
                        VAL=$(zgrep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    else
                        VAL=$(grep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    fi

                    # Print clean validation status
                    if [ "$VAL" = "y" ]; then
                        printf "  [ PASS ] %-40s = %s\n" "$CFG" "$VAL"
                    elif [ "$VAL" = "m" ]; then
                        printf "  [ WARN ] %-40s = %s (Module)\n" "$CFG" "$VAL"
                    else
                        printf "  [ DROP ] %-40s = MISSING/OVERRIDDEN\n" "$CFG"
                    fi
                done
            fi
        fi
    fi

    echo "=============================================="
    echo "::endgroup::"
fi

cd ..
echo ">>> Build execution loop completed"
