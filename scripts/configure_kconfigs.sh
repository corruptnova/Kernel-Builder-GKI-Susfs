#!/usr/bin/env bash
# scripts/configure_kconfigs.sh
set -euo pipefail

ENABLE_NOMOUNT=${ENABLE_NOMOUNT:-false}
ENABLE_NET_OPTS=${ENABLE_NET_OPTS:-false}
BASE_VER=${BASE_VER:-}

COMBINED_FRAG="$(pwd)/tools/custom_combined.fragment"
> "$COMBINED_FRAG" # Initialize empty file

echo "=== Configuring Kconfigs & ABI Neutralization for Kernel $BASE_VER ==="

# 0. GUARD: built-in NoMount and user-supplied Prism engine both define CONFIG_NOMOUNT
if [ "$ENABLE_NOMOUNT" = "true" ] && [ -f "tools/user_source/fs/nomount.c" ]; then
    echo "[-] ERROR: Prism NoMount engine found in tools/user_source/fs/ but the built-in NoMount toggle is enabled."
    echo "    Untick 'Inject nomount VFS module'; the Prism engine is enabled via tools/custom.fragment."
    exit 1
fi

cd kernel_workspace

# 1. NEUTRALIZE LEGACY ABI PROTECTED EXPORTS (modpost bypass for 5.10-6.6)
for f in common/android/abi_gki_protected_exports* android/abi_gki_protected_exports*; do
    [ -f "$f" ] && > "$f" || true
done

cd common

    # 2. NEUTRALIZE STRICT SYMBOL LISTS & TRIMMING (ABI Bouncer Bypass)
    case "$BASE_VER" in
        5.10)
            echo ">>> Maintaining stock ABI/KMI strictness for 5.10 (Untouched to prevent bootloops)..."
            ;;
        5.15)
            echo ">>> Disabling strict ABI mode & trimming in legacy configs and BUILD.bazel for 5.15..."
            sed -i 's/KMI_SYMBOL_LIST_STRICT_MODE=1/KMI_SYMBOL_LIST_STRICT_MODE=0/g' build.config.* 2>/dev/null || true
            sed -i 's/TRIM_NONLISTED_KMI=1/TRIM_NONLISTED_KMI=0/g' build.config.* 2>/dev/null || true

            if grep -q 'name = "kernel_aarch64",' BUILD.bazel; then
                sed -i '/name = "kernel_aarch64",/a \    kmi_symbol_list_strict_mode = False,\n    trim_nonlisted_kmi = False,' BUILD.bazel
            fi
            ;;
        6.1|6.6|6.12)
            echo ">>> Disabling strict ABI mode in BUILD.bazel for $BASE_VER..."
            sed -i -E 's/(["\x27]?kmi_symbol_list_strict_mode["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel 2>/dev/null || true
            ;;
        *)
            echo ">>> No strict mode sed required for $BASE_VER."
            ;;
    esac
    
    # 3. DYNAMIC FRAGMENT ASSEMBLY
    if [ "$ENABLE_NOMOUNT" = "true" ] && [ -f "../../tools/nomount.fragment" ]; then
        echo ">>> Appending NoMount Kconfigs..."
        cat "../../tools/nomount.fragment" >> "$COMBINED_FRAG"
        echo "" >> "$COMBINED_FRAG"
    fi

    if [ "$ENABLE_NET_OPTS" = "true" ] && [ -f "../../tools/net_opts.fragment" ]; then
        echo ">>> Appending Network Optimization Kconfigs..."
        cat "../../tools/net_opts.fragment" >> "$COMBINED_FRAG"
        echo "" >> "$COMBINED_FRAG"
    fi

    if [ -f "../../tools/custom.fragment" ] && grep -q '^CONFIG_' "../../tools/custom.fragment"; then
        echo ">>> Appending User Kconfigs from custom.fragment..."
        cat "../../tools/custom.fragment" >> "$COMBINED_FRAG"
        echo "" >> "$COMBINED_FRAG"
    fi
    
    # 4. INTEGRATE COMBINED KCONFIG FRAGMENT
    if [ -s "$COMBINED_FRAG" ]; then
        
        if [ "$ENABLE_NOMOUNT" = "true" ]; then
            echo ">>> Dynamically wiring NoMount hooks into VFS tree..."
            grep -q "nomount" fs/Makefile || echo 'obj-$(CONFIG_NOMOUNT)		+= nomount/' >> fs/Makefile
            grep -q "nomount" fs/Kconfig || echo 'source "fs/nomount/Kconfig"' >> fs/Kconfig
        fi

        case "$BASE_VER" in
            5.10)
                echo ">>> Injecting Legacy 5.10 Kconfig Fragment..."
                cp "$COMBINED_FRAG" arch/arm64/configs/custom_legacy.fragment
                echo 'EXTRA_DEFCONFIG_FRAGMENTS="custom_legacy.fragment"' >> build.config.gki.aarch64
                ;;
            5.15)
                echo ">>> Injecting Bazel 5.15 Kconfig Fragment via legacy build.config..."
                cp "$COMBINED_FRAG" arch/arm64/configs/custom_legacy.fragment
                echo 'EXTRA_DEFCONFIG_FRAGMENTS="custom_legacy.fragment"' >> build.config.gki.aarch64
                ;;
            6.1)
                echo ">>> Injecting Bazel 6.1 Kconfig Fragment..."
                cp "$COMBINED_FRAG" custom_fragment
                sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' BUILD.bazel
                ;;
            *)
                echo ">>> Injecting Bazel 6.6+ Kconfig Fragment..."
                cp "$COMBINED_FRAG" custom_fragment
                
                if grep -q '"kernel_aarch64": {' BUILD.bazel; then
                    sed -i '/"kernel_aarch64": {/a \        "defconfig_fragments": ["custom_fragment"],' BUILD.bazel
                elif grep -q 'name = "kernel_aarch64",' BUILD.bazel; then
                    sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' BUILD.bazel
                else
                    echo "[-] ERROR: Could not find kernel_aarch64 injection point in BUILD.bazel!"
                    exit 1
                fi
                ;;
        esac
    fi

cd ../..
echo ">>> Configuration complete."
