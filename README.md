# Universal GKI Kernel Builder CI
### (Pure GKI 2.0 only)

Welcome to the Universal GKI Kernel Builder! This repository hosts an automated, highly flexible GitHub Actions CI pipeline designed to compile custom GKI kernels directly from source.

Whether you need a pristine upstream kernel or a heavily modified build featuring custom VFS patches, Kconfig overrides, and systemless integrations, this pipeline builds exactly what you want, right when you want it.

## 🚀 Overview

The core philosophy of this project is **Dynamic Generation over Bulk Compilation**.

Unlike massive kernel distribution repositories that compile hundreds of generic permutations on a fixed schedule, this CI is designed to be a personal build engine. When you trigger a workflow, the pipeline dynamically resolves the correct Google manifest branches, fetches the absolute latest source code for your chosen root environment, and integrates custom patches and config overrides on the fly.

The result? You get one single, tailor-made kernel artifact and its exact matching manager APK, perfectly synced with the upstream ecosystem.

### ✨ Advantages
* **No Waiting for Updates:** You don't have to wait for a maintainer to trigger a batch build. If Google drops a new GKI update, or KernelSU merges a new commit, you can build it yourself immediately.
* **Bleeding Edge by Default:** The `dynamic` build channel pulls the latest upstream commits for the Linux kernel and your chosen root manager every single time you run it.
* **Precision Output:** Instead of sifting through hundreds of zip files to find your device's specific combination, the CI builds exactly what you ask for and packages it cleanly.
* **Guaranteed Version Matching:** The pipeline automatically fetches the exact Manager APK that matches the root environment source code used during compilation. No more signature mismatches or incompatible userspace apps.
* **Safe Fallbacks:** If the bleeding-edge upstream commits break compilation, you can instantly toggle the CI to the `stable` channel to build from verified, safe forks.

## ⚙️ Features
* **Multiple Root Managers:** Native integration support for `KernelSU`, `KernelSU-Next`, `SukiSU-Ultra`, and `ReSukiSU`.
* **Smart Stock Isolation:** Select `Stock` to guarantee a pristine Google source tree. Combine `Stock` with custom Kconfigs to build an "Enhanced Stock" kernel—perfect for APatch or Magisk users who need specific kernel features baked into the core without conflicting root source code pollution.
* **SuSFS Integration:** Automated patching and macro injection for SuSFS to enable advanced path hiding, kstat spoofing, and mount masking.
* **NoMount VFS:** Native integration of maxsteeel's NoMount for advanced kernel-level path redirection. The pipeline dynamically hooks the VFS tree and outputs a ready-to-flash KernelSU metamodule alongside the kernel.
* **PRISM NoMount Suite:** A dedicated `prism-nomount` branch that builds PRISM-NoMount-Suite into every kernel automatically (see [🧩 PRISM NoMount Suite](#-prism-nomount-suite)).
* **Performance Networking:** Built-in fragment support for TCP BBR congestion control and FQ_CODEL scheduling to minimize bufferbloat and optimize latency.
* **Unified Customization Engine:** A single master switch to intelligently inject custom Kconfig fragments, version-aware `.patch` files, and raw kernel source modifications on demand across versions 5.10 to 6.12.
* **Flexible Packaging:** Outputs a standard `AnyKernel3` (AK3) flashable zip by default. If you provide a full OTA URL, it will extract, patch, and repack a raw `boot.img` for direct fastboot flashing.

---

## 🧩 PRISM NoMount Suite

PRISM-NoMount-Suite lives in its own branch, **`prism-nomount`**. That branch is identical to `main` in every way except one: PRISM-NoMount-Suite is built into every kernel automatically. Because of that, the **Inject nomount VFS?** checkbox does not exist in the `prism-nomount` workflow.

### Building with PRISM NoMount Suite
1. Go to the **Actions** tab and select **Build Custom GKI**.
2. Click the **Run workflow** dropdown.
3. In the **Use workflow from** selector, choose **`prism-nomount`**.
4. Fill out the remaining parameters exactly as you would on `main`. Choose a KernelSU-based **Root Environment** (`KernelSU`, `KernelSU-Next`, `SukiSU-Ultra`, or `ReSukiSU`), since NoMount-Suite installs as a KernelSU metamodule.
5. Click **Run workflow**.

### Installing
1. Flash the kernel (AK3 zip or `boot.img`).
2. Install the matching Manager APK from the artifacts and reboot.
3. Download the **NoMount-Suite** module from [(https://github.com/Bouteillepleine/NoMount-Suite)] and install it through the manager. It is **not** included in the build artifacts.
4. Reboot.

> ⚠️ **Note:** Only one metamodule can be installed at a time on KernelSU-based managers, including ReSukiSU. Remove any existing metamodule (e.g., meta-overlayfs) before installing NoMount-Suite.

---

## 🛠️ How to Use

To start building your own custom kernels, follow these steps:

### 1. Fork the Repository
Click the **Fork** button at the top right of this page to create your own copy of the repository.

### 2. Add Your Custom Files (Optional)
If you plan to use the Customization Engine, place your files in the respective directories before running the workflow:
* **Custom Kconfigs:** Place or un-hash preconfigured flags in `tools/custom.fragment` (e.g., `CONFIG_NOMOUNT=y`, `CONFIG_TCP_CONG_BBR=y`).
* **User Patches:** Drop any `.patch` files into `tools/user_patches/`. The CI will intelligently apply them based on the kernel version prefix (e.g., `6.1-fix.patch` will only apply to 6.1 builds). *(Note: Blocked when `Stock` is selected)*
* **User Source:** Drop raw driver files or source overrides into `tools/user_source/` (e.g., placing NoMount source in `tools/user_source/fs/nomount/`). *(Note: Blocked when `Stock` is selected)*

### 3. Enable GitHub Actions
In your forked repository, navigate to the **Actions** tab. Click **"I understand my workflows, go ahead and enable them"**.

### 4. Trigger a Build
1. On the **Actions** tab, select **Build Custom GKI** from the left sidebar.
2. Click the **Run workflow** dropdown on the right side of the screen. *(Want PRISM NoMount Suite? Select the `prism-nomount` branch under **Use workflow from**.)*
3. Fill out the configuration parameters for your build:

| Parameter | Description |
| :--- | :--- |
| **Build Channel** | Choose `dynamic` (latest upstream commits) or `stable` (fallback to verified forks if dynamic fails). |
| **Build Name** | A custom name for your output artifact (e.g., `Pixel_10_Pro_Testing`). |
| **Kernel Version** | The exact GKI target version you wish to build (e.g., `6.12.11`). |
| **Root Environment** | Select your preferred root manager from the dropdown list (`KernelSU`, `KernelSU-Next`, `SukiSU-Ultra`, `ReSukiSU`, or `Stock`). |
| **Integrate Root Manager and SUSFS?** | Check to inject Kernel root and SUSFS. *(Ignored if `Stock` is selected)* |
| **Inject nomount VFS?** | The Master Switch. Check to dynamically wire NoMount source, inject custom Kconfigs (BBR), apply version-aware patches, and download the NoMount metamodule. **If `Stock` is selected, only `custom.fragment` Kconfigs will be applied.** *(`main` only, not present on `prism-nomount`)* |
| **OTA URL (Optional)** | Leave blank to output an `AnyKernel3` zip. Provide a direct link to a full OTA zip to output a pre-patched `boot.img`. |

4. Click **Run workflow**.

### 5. Download Your Artifacts
Once the CI pipeline completes successfully, scroll to the bottom of the workflow summary page. Under the **Artifacts** section, you will find your compiled kernel (either an AK3 zip or a zip containing a repacked boot image plus an AK3 zip), your NoMount metamodule (if enabled), and the exact Manager APK required to control it. Download, flash via Kernel Flasher or custom recovery, and enjoy!

> 🧩 Built from `prism-nomount`? Install the NoMount-Suite module after flashing. See [🧩 PRISM NoMount Suite](#-prism-nomount-suite).
