# OptiDX
A tool to use when you are lazy to setup all the high end pc gaming mods
> **Universal Game Mod Installer for Linux Gaming & Steam Deck**

**OptiDX** is an automated Steam launch wrapper and mod installer for Linux. Written in Python, it automatically detects the game it is running next to, resolves and installs matching **RenoDX** or **Luma** HDR/graphics mods, and configures **OptiScaler**, **ReShade**, and **DLSS Enabler** out of the box.

Designed specifically for Steam Runtime, Heroic, Lutris, and Bottles environments with **zero launch overhead** once installed.

---

## Features

* **Smart Game Detection:** Automatically identifies games using Steam AppIDs, `appmanifest` files, PE header metadata, and launcher configs (Heroic, Lutris, Bottles).
* **Smart Name Expansion:** Handles shortened executable names (e.g., `Karma.exe` or `KarmaU54-Win64-Shipping.exe`) and maps them to their full game titles.
* **Built-in Game Quirks System:** Built-in and user-configurable quirk database for handling game-specific DLL naming (`d3d12.dll` vs `dxgi.dll`), engine quirks, and launch overrides.
* **OptiScaler & DLSS Enabler Integration:** Deploys OptiScaler configured with Frame Generation, ReShade support, and DLSS Enabler integration.
* **Auto-Fallback Engine Mods:** Automatically applies generic Unreal Engine or Unity RenoDX addons if no title-specific mod exists.
* **Concurrent Metadata Fetching:** Warmed network caches retrieve index metadata in parallel for faster overall setup runs.
* **Clean Steam Runtime Isolation:** Strips `LD_LIBRARY_PATH` overrides for spawned network tools to prevent `curl` DNS failures inside sandboxed runtimes.
* **Zero Launch Overhead:** Once installed, subsequent game launches bypass setup processing entirely and execute the game binary immediately.

---

## Quick Start (Steam)

1. Download or copy `optidx.py` to a persistent directory (e.g., `~/scripts/optidx.py`) and make it executable:
   `chmod +x ~/scripts/optidx.py`

2. Open Steam, right-click your game -> **Properties** -> **Launch Options**.

3. Add `optidx.py` before `%command%`:
   `/path/to/optidx.py %command%`

4. Launch the game normally. OptiDX will run the setup, install the required DLLs/addons into the game's executable directory, and start your game.

---

## Command Line Flags & Options

OptiDX flags must be passed **BEFORE** the `%command%` parameter. Everything after `%command%` is passed directly to the game untouched.

* `--renodx`: Only install RenoDX or Luma mods (skips OptiScaler and DLSS Enabler).
* `--luma`: Only search and install Luma mods.
* `--update`: Force re-running installation and update checks, overwriting existing proxy DLLs with fresh releases.
* `--uninstall`: Safely removes every file tracked in the OptiDX manifest without touching original game files.
* `--dry-run`: Simulates game detection and title matching without downloading or writing files.
* `--list-quirks`: Displays all built-in database quirks and active user overrides.
* `-h, --help`: Display usage information and exit.

### Usage Examples

**Force an Update / Reinstall:**
`/path/to/optidx.py --update %command%`

**Uninstall OptiDX Mods from Game Directory:**
`/path/to/optidx.py --uninstall %command%`

**Install RenoDX / Luma Addons Only:**
`/path/to/optidx.py --renodx %command%`

**Simulate Setup (Dry Run):**
`/path/to/optidx.py --dry-run`

---

## Dependencies

OptiDX runs on standard **Python 3.6+** and requires minimal system binaries:

* `python3` (built-in `json`, `zipfile`, `concurrent.futures`, `re` modules)
* `curl`, `unzip`
* `7z` / `7za` / `7zz` (required for extracting OptiScaler and ReShade installers)

*(Note: `awk`, `sed`, `grep`, and `find` are no longer required.)*

---

## How It Works

1. **Fast-Path Checking:** Reads `.optidx-installed`. If present, it executes the game binary instantly via `os.execvp`.
2. **Game Resolution:** Scans binary directories, PE `ProductName` headers, folder parents, and local Steam/Heroic metadata to extract candidate titles. Engine version tags (e.g., `U54`, `UE5`) are cleaned automatically.
3. **Index & Mirror Matching:** Matches candidate titles against the official RenoDX Wiki index and snapshot mirror releases using an expanded matching algorithm.
4. **Game Quirks Resolution:** Checks built-in database entries or `~/.config/optidx/quirks.conf` for custom DLL target names or skip rules.
5. **Payload Injection:** Downloads and places OptiScaler, `ReShade64.dll`, `dlss-enabler-headless.dll`, and `.addon64`/`.addon32` files into the target binary folder (e.g., `Binaries/Win64`).
6. **Manifest Tracking:** Logs all created paths in `.optidx-files` so `--uninstall` can perform a 100% clean teardown later.

---

## Custom Game Quirks

You can add custom rules for unlisted or troublesome games by creating `~/.config/optidx/quirks.conf`:

```ini
# Format: normalized_game_title = key=value;key=value
mygame = optiscaler_dll=d3d12.dll
othergame = skip_reshade=true;optiscaler_dll=version.dll

Run /path/to/optidx.py --list-quirks to inspect active database rules.
```
## Troubleshooting & Logs

Log files are saved next to the target game executable at optidx.log.

If you experience network issues or HTTP 000 errors during a Steam launch:

   Run the script manually from a terminal inside the game directory once to prime the local cache:
    cd "/path/to/game/dir"
    /path/to/optidx.py --update

   Relaunch the game directly from Steam.
