# OptiDX
A tool to use when you are lazy to setup all the high end pc gaming mods
> **Universal Game Mod Installer for Linux Gaming & Steam Deck**

**OptiDX** is an automated Steam launch wrapper and mod installer for Linux. It automatically detects the game it is running next to, resolves and installs matching **RenoDX** or **Luma** HDR/graphics mods, and configures **OptiScaler**, **ReShade**, and **DLSS Enabler** out of the box.

Designed specifically for Steam Runtime, Heroic, Lutris, and Bottles environments with **zero launch overhead** once installed.

---

## Features

* **Smart Game Detection:** Automatically identifies games using Steam AppIDs, `appmanifest` files, PE header metadata, and launcher configs (Heroic, Lutris, Bottles).
* **Deterministic Matching:** Evaluates the official RenoDX Wiki mod database using an AWK-based scoring engine—no fuzzy matches or wrong-game mod installations.
* **OptiScaler Integration:** Seamlessly deploys OptiScaler (`dxgi.dll`) configured with Frame Generation and Reshade support.
* **Auto-Fallback Engine Mods:** Automatically applies generic Unreal Engine or Unity RenoDX addons if no title-specific mod exists.
* **Clean Steam Runtime Isolation:** Cleverly handles Steam's `LD_LIBRARY_PATH` environment to prevent `curl` DNS failure inside sandboxed runtimes.
* **Zero Launch Overhead:** Once installed, subsequent game launches skip processing and execute the game binary immediately.

---

## Quick Start (Steam)

1. Download or copy `OptiDXv2.sh` to a persistent directory (e.g., `~/scripts/OptiDXv2.sh`) and make it executable:
   ```bash
   chmod +x OptiDXv2.sh
Open Steam, right-click your game $\rightarrow$ Properties $\rightarrow$ Launch Options.Add OptiDXv2.sh before %command%:Bash/path/to/OptiDXv2.sh %command%
Launch the game normally. OptiDX will run the setup, install the required DLLs/addons into the game's executable directory, and start your game.Command Line Flags & OptionsOptiDX flags must be passed before the %command% parameter. Everything after %command% is passed directly to the game untouched.FlagDescription--renodxOnly install RenoDX or Luma mods (skips OptiScaler and DLSS Enabler).--lumaOnly search and install Luma mods.--updateForce re-running the installation and update checks, even if already installed.--uninstallSafely removes every file tracked in the OptiDX manifest without touching game files.-h, --helpDisplay usage information and exit.Usage ExamplesForce an Update/Reinstall:Bash/path/to/OptiDXv2.sh --update %command%
Uninstall OptiDX Mods from Game Directory:Bash/path/to/OptiDXv2.sh --uninstall %command%
Install RenoDX/Luma Addons Only:Bash/path/to/OptiDXv2.sh --renodx %command%
DependenciesOptiDX uses standard Linux command-line utilities. Ensure the following packages are installed on your host system:curl, unzip, awk, sed, grep, findp7zip / 7z / 7zz (required for extracting OptiScaler and ReShade installers)How It WorksFast-Path Checking: Reads .optidx-installed. If present, it executes the game binary instantly via exec env.Game Resolution: Parses the working directory hierarchy, PE ProductName headers, and local Steam/Heroic metadata to extract accurate candidate titles.Index Matching: Fetches and parses Mods.md from the RenoDX Wiki in a single deterministic AWK pass.Payload Injection: Downloads and places OptiScaler, ReShade64.dll, dlss-enabler-headless.dll, and .addon64/.addon32 files into the target folder (e.g., <Game>/Binaries/Win64).Manifest Tracking: Logs all created paths in .optidx-files so --uninstall can perform a 100% clean teardown later.Troubleshooting & LogsLog files are automatically saved next to the target game executable at optidx.log.If you experience network issues or HTTP 000 errors during a Steam launch:Run the script manually from a terminal inside the game directory once to prime the local cache:Bashcd "/path/to/game/dir"
/path/to/OptiDXv2.sh --update
Relaunch the game directly from Steam.
