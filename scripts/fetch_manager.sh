#!/bin/bash
# scripts/fetch_manager.sh

set -euo pipefail

VARIANT="${1}"
GH_TOKEN="${2}"
UPSTREAM_HASH="${3:-}"

# Inherit the repository variable from the YAML environment
REPO="${UPSTREAM_REPO}"

echo ">>> Searching $REPO for a Release Manager..."

DOWNLOAD_URLS=""

# ReSukiSU (Frozen Museum Piece)
if [[ "${ROOT_MANAGER}" == "ReSukiSU" ]]; then
    echo ">>> Legacy ReSukiSU target detected. Bypassing API hunt..."
    echo ">>> Fetching frozen v4.2.0-rc3 Release APK..."
    
    mkdir -p manager_apk
    curl -s -L \
      -o "manager_apk/ReSukiSU_v4.2.0-rc3_35171-arm64-v8a-release.apk" \
      "https://github.com/Baka-SU/BakaSU/releases/download/v4.2.0-rc3/ReSukiSU_v4.2.0-rc3_35171-arm64-v8a-release.apk"
    
    echo ">>> Manager successfully staged for final upload!"
    ls -1 manager_apk/
    exit 0
fi

# ==========================================
# 1. EXACT HASH MATCH
# ==========================================
echo ">>> Checking for exact upstream hash: ${UPSTREAM_HASH}"
EXACT_RUNS=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?head_sha=${UPSTREAM_HASH}&status=success&per_page=100")

RUN_IDS=$(echo "$EXACT_RUNS" | jq -r '.workflow_runs[]?.id // empty')

for ID in $RUN_IDS; do
    echo ">>> Checking exact-match Run ID: $ID for artifacts..."
    ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts")
    
    # MODIFIED: Output the actual artifact name along with the URL
    DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
      .artifacts[]? 
      | select(.name | test("(?i)(manager|kernelsu[_-]v|bakasu|sukisu)"))
      | select(.name | test("(?i)(debug|mappings|gradle)") | not)
      | select(.name | test("(?i)(armeabi-v7a|universal|x86_64|riscv64)") | not)
      | select(.expired == false)
      | "ARTIFACT|\(.name)|\(.archive_download_url)" // empty')

    if [ -n "$DOWNLOAD_URLS" ]; then
        echo ">>> Success! Found unexpired exact Manager artifacts in Run ID: $ID"
        break
    fi
done

# ==========================================
# 2. WALK BACKWARDS THROUGH RECENT COMMITS
# ==========================================
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Exact match missing or lacked artifacts. Walking backward through recent successful ${TARGET_BRANCH} branch runs..."
    
    RECENT_RUNS=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
      "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW_FILE}/runs?branch=${TARGET_BRANCH}&status=success&per_page=100")

    RECENT_RUN_IDS=$(echo "$RECENT_RUNS" | jq -r '.workflow_runs[]?.id // empty')
    
    for ID in $RECENT_RUN_IDS; do
        echo ">>> Checking previous Run ID: $ID for artifacts..."
        ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
          "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts")
        
        # MODIFIED: Output the actual artifact name along with the URL
        DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
          .artifacts[]? 
          | select(.name | test("(?i)(manager|kernelsu[_-]v|bakasu|sukisu)"))
          | select(.name | test("(?i)(debug|mappings|gradle)") | not)
          | select(.name | test("(?i)(armeabi-v7a|universal|x86_64|riscv64)") | not)
          | select(.expired == false)
          | "ARTIFACT|\(.name)|\(.archive_download_url)" // empty')

        if [ -n "$DOWNLOAD_URLS" ]; then
            echo ">>> Success! Found unexpired fallback Manager artifacts in Run ID: $ID"
            break
        fi
    done
fi

# ==========================================
# 3. DOWNLOAD OR GRACEFUL EXIT
# ==========================================
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Warning: Exhausted search. Failed to locate ANY valid Manager artifacts for $REPO."
    echo "[-] Continuing CI run to completion without staging Manager APKs."
    exit 0
fi

mkdir -p manager_apk

IFS=$'\n'
for ENTRY in $DOWNLOAD_URLS; do
  TYPE=$(echo "$ENTRY" | cut -d'|' -f1)
  ART_NAME=$(echo "$ENTRY" | cut -d'|' -f2)
  URL=$(echo "$ENTRY" | cut -d'|' -f3)
  
  if [[ "$TYPE" == *"ZIP"* ]] || [[ "$TYPE" == "ARTIFACT" ]]; then
      echo ">>> Downloading archive: $ART_NAME..."
      curl -s -L \
        -H "Authorization: token $GH_TOKEN" \
        -o "${ART_NAME}.zip" "$URL"
      
      echo ">>> Extracting $ART_NAME..."
      # Extract into an isolated subfolder to prevent APK name collisions
      mkdir -p "manager_apk/${ART_NAME}"
      unzip -q -o "${ART_NAME}.zip" -d "manager_apk/${ART_NAME}/"
      rm "${ART_NAME}.zip"
  fi
done
unset IFS

echo ">>> Cleaning up unnecessary architectures..."
# Only preserve the arm64-v8a files
find manager_apk/ -type f \( -name "*armeabi-v7a*" -o -name "*universal*" -o -name "*x86_64*" -o -name "*riscv64*" \) -exec rm -f {} +

echo ">>> Flattening directory and applying collision-safe naming..."
# Move all APKs to the root of manager_apk/ and prepend their artifact origin name
find manager_apk/ -mindepth 2 -type f -name "*.apk" | while read -r apk_path; do
    parent_dir=$(basename $(dirname "$apk_path"))
    base_name=$(basename "$apk_path")
    mv "$apk_path" "manager_apk/${parent_dir}_${base_name}"
done

# Clean up the empty extraction subdirectories
find manager_apk/ -mindepth 1 -type d -empty -delete

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/
