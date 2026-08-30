#!/usr/bin/env python3
###############################################################################
# OptiDX v2.0 (Python port) - Universal Game Mod Installer
#
# 1:1 behavioural port of OptiDXv2.sh: same flags, same marker/manifest files,
# same quirks database & user config, same cache layout, same install flow.
#
# What changed vs the bash version, and why:
#   * JSON (GitHub/Steam API, Heroic config) is parsed with the `json` module
#     instead of sed/grep line-splitting. Far shorter and it can't be fooled by
#     minified vs. pretty-printed payloads the way line-oriented sed was.
#   * `awk` scoring/index-building (mkindex.awk, match.awk) is now plain Python
#     functions (spaced/tight/roman/score/match_candidates). Same algorithm,
#     same score constants, same tie-break-on-deprecation rule.
#   * Game/file discovery uses os.walk instead of forking `find`.
#   * curl is still shelled out to (with LD_LIBRARY_PATH/LD_PRELOAD stripped,
#     same as the bash run_clean() trick) because the Steam Runtime DNS bug
#     this works around is a property of the *curl binary*, not of bash.
#   * unzip/7z are still shelled out to for archive extraction (.zip also has
#     a pure-Python zipfile fallback/first-try).
#   * awk/sed/grep/find are no longer required dependencies of this script.
#
# Known open issues carried over unmodified from the bash version (not fixed
# here, since this is a straight port):
#   * --dry-run does not guard find_renodx_mod()/find_luma_mod() - a "dry run"
#     still downloads and writes the matched mod.
#   * FGInput is patched to `nvngxfg` in OptiScaler.ini; unverified whether
#     that's a valid input (vs. output) value.
#   * Roman-numeral normalisation only covers i-x.
#   * No checksum/signature verification on downloaded binaries.
#   * Log file contains raw ANSI colour codes (same as bash printf '%b').
###############################################################################

import atexit
import concurrent.futures
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------- #
# GLOBALS
# --------------------------------------------------------------------------- #

SCRIPT_VERSION = "2.0"
MARKER = ".optidx-installed"
MANIFEST = ".optidx-files"

REPO_OPTISCALER = "Cha1N1/OptiScaler"
REPO_LUMA = "Filoppi/Luma-Framework"
REPO_DLSS = "Cha1N1/dlss-enabler-bleeding-edge"

RENODX_WIKI = "https://raw.githubusercontent.com/wiki/clshortfuse/renodx/Mods.md"
RENODX_BASE = "https://github.com/marat569/renodx/releases/download/snapshot"
RENODX_MIRROR_API = "https://api.github.com/repos/marat569/renodx/releases/tags/snapshot"
RENODX_UE_FALLBACK = RENODX_BASE + "/renodx-ue-extended.addon64"
RENODX_UNITY_FALLBACK = "https://notvoosh.github.io/renodx-unity/renodx-unityengine.addon64"

RESHADE_URL = "https://reshade.me/downloads/ReShade_Setup_Addon.exe"
D3DCOMPILER_URL = "https://raw.githubusercontent.com/Joshua-Ashton/d3dcompiler_47/master/d3dcompiler_47.dll"

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "optidx"

START_DIR = os.getcwd()
TMP_DIR = None
LOG_FILE = None
LOG_BUFFER = []

MIN_SCORE = 700
MIRROR_BLOCKLIST = {"generic", "devkit", "fpslimiter", "_univ", "ue-extended", "unityengine", "unity", "fe"}

UE_IGNORE_REGEX = re.compile(
    r"crashpad|easyanticheat|crashreportclient|unrealcefsubprocess|unreallightmass|"
    r"epicwebhelper|shadercompileworker|dxcheck|unitycrashhandler|dxsetup|vcredist|"
    r"dotnetfx|oalinst|touchup", re.I)
SYSTEM_DIR_REGEX = re.compile(
    r"^(binaries|win64|win32|wingdk|engine|contents|game|games|app|bin|data|test|tmp|"
    r"home|drive_c|steamapps|common|mnt|media|storage|users|public|desktop|documents|"
    r"downloads|steamlibrary|steam|gog games|galaxy|epic games|ubisoft.*|origin games|"
    r"ea games|xboxgames|program files.*|[a-z]:)$", re.I)

GAME_EXE = GAME_DIR = GAME_NAME = GAME_KEY = GAME_DISPLAY = ""
LAUNCHER_TITLE = STEAM_APPID = STEAM_STORE_TITLE = ""
GAME_IS_UE = False
GAME_IS_UNITY = False
GAME_BITS = ""
CANDIDATE_TITLES = []

RENODX_ONLY = LUMA_ONLY = FORCE_UPDATE = DO_UNINSTALL = DRY_RUN = LIST_QUIRKS = False
INSTALLED_FILES = []
MOD_FOUND = False
GAME_ARGS = []
HAVE_7Z = False
SEVENZIP = None
FETCH_LAST_CODE = ""
NET_DIAG_DONE = False

QUIRK_OPTISCALER_DLL = "dxgi.dll"
QUIRK_SKIP_OPTISCALER = False
QUIRK_SKIP_RESHADE = False
QUIRK_SKIP_DLSS_ENABLER = False
QUIRK_EXTRA_DLL_COPIES = ""
QUIRKS_MATCHED = ""

USER_QUIRKS_CONF = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "optidx" / "quirks.conf"

# Built-in Game Quirks database (key: norm()'d title -> semicolon-delimited kv pairs)
GAME_QUIRKS = {
    "arknightsendfield": "optiscaler_dll=d3d12.dll",
    "endfield": "optiscaler_dll=d3d12.dll",
    "forspoken": "optiscaler_dll=d3d12.dll",
    "forzahorizon6": "optiscaler_dll=d3d12.dll",
    "atomicrops": "skip_reshade=true",
    "dysonsphereprogram": "skip_reshade=true",
    "minecraft": "skip_reshade=true",
    "immortalsofaveum": "optiscaler_dll=d3d12.dll",                    # bypasses signature verification
    "deadoralive6lastround": "optiscaler_dll=d3d12.dll",               # only d3d12.dll or version.dll work, all else crashes
    "marvelsmidnightsuns": "optiscaler_dll=d3d12.dll",                 # anti-cheat/anti-tamper blocks default naming
    "asterigoscurseofthestars": "optiscaler_dll=d3d12.dll",            # required for DLSS on Nvidia, else crash
    "nevernesstoeverness": "optiscaler_dll=d3d12.dll",                 # (or version.dll - wiki lists both)
    "zenlesszonezero": "optiscaler_dll=d3d12.dll",                     # required, plus needs -use-d3d12 launch arg
    "grandtheftautoiiidefinitiveedition": "optiscaler_dll=d3d12.dll",        # "may be required" + -dx12 launch opt
    "grandtheftautosanandreasdefinitiveedition": "optiscaler_dll=d3d12.dll", # same caveats as GTA3 DE
    "grandtheftautovicecitydefinitiveedition": "optiscaler_dll=d3d12.dll",   # same caveats as GTA3 DE
    "monsterhunterrise": "optiscaler_dll=d3d12.dll",                         # wiki says "optimal", not strictly required
    "neverforspeedunbound": "optiscaler_dll=d3d12.dll",                      # Linux-only (dxgi.dll on Windows)
}

C = dict(INFO='\033[36m', OK='\033[32m', WARN='\033[33m', ERR='\033[31m',
          BOLD='\033[1m', WHITE='\033[97m', RESET='\033[0m')

ROMAN_MAP = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5",
             "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"}

###############################################################################
# LOGGING (stdout is reserved for function return values; logs go to stderr)
###############################################################################


def _log(msg):
    print(msg, file=sys.stderr)
    if LOG_FILE:
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        except OSError:
            pass
    else:
        LOG_BUFFER.append(msg)


def set_log_dir(d):
    global LOG_FILE
    if not os.path.isdir(d):
        return
    LOG_FILE = os.path.join(d, "optidx.log")
    if LOG_BUFFER:
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write("\n".join(LOG_BUFFER) + "\n")
        except OSError:
            pass
        LOG_BUFFER.clear()


def info(msg):
    _log(f"  {C['INFO']}>>{C['RESET']} {msg}")


def success(msg):
    _log(f"  {C['OK']}\u2713{C['RESET']}  {msg}")


def warn(msg):
    _log(f"  {C['WARN']}!{C['RESET']}  {msg}")


def error(msg):
    _log(f"  {C['ERR']}\u2717{C['RESET']}  {msg}")


def die(msg):
    error(msg)
    sys.exit(1)


def print_banner():
    _log(f"\n{C['BOLD']}{C['INFO']}"
         f"  ================================================\n"
         f"    OptiScaler + RenoDX ( v{SCRIPT_VERSION}, Python )\n"
         f"    Heroic, Lutris, Steam & UE Mod Engine - Linux\n"
         f"  ================================================{C['RESET']}")

###############################################################################
# REQUIREMENTS / WORKSPACE
###############################################################################


def need_workspace():
    global TMP_DIR, CACHE_DIR
    if TMP_DIR:
        return True
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    try:
        TMP_DIR = tempfile.mkdtemp(prefix="optidx.")
    except OSError:
        TMP_DIR = None
        return False
    if not CACHE_DIR.is_dir():
        CACHE_DIR = Path(TMP_DIR)
    atexit.register(lambda: shutil.rmtree(TMP_DIR, ignore_errors=True))
    return True


def check_requirements():
    global HAVE_7Z, SEVENZIP
    missing = [c for c in ("curl", "unzip") if not shutil.which(c)]
    if missing:
        # As a Steam launch wrapper the script must never be the reason a game
        # fails to start: degrade to a pass-through instead of dying.
        if GAME_ARGS:
            warn(f"Missing tools ({' '.join(missing)}) - skipping mod setup and launching the game")
            return False
        die(f"Missing required tools: {' '.join(missing)}")
    for cmd in ("7z", "7za", "7zz"):
        if shutil.which(cmd):
            SEVENZIP = cmd
            HAVE_7Z = True
            info(f"Found archive tool: {cmd}")
            break
    if not HAVE_7Z:
        warn("7z not found - OptiScaler/ReShade extraction will be skipped (install p7zip)")
    return True

###############################################################################
# NORMALISATION
###############################################################################


def norm(s):
    return re.sub(r'[^a-z0-9]', '', (s or '').lower())


def spaced(s):
    return re.sub(r'[^a-z0-9]+', ' ', (s or '').lower()).strip()


def tight(s):
    return s.replace(' ', '')


def roman(s):
    return " ".join(ROMAN_MAP.get(tok, tok) for tok in s.split(" "))


def load_json(path):
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return json.load(f)
    except Exception:
        return None

###############################################################################
# NETWORK
###############################################################################


def clean_env():
    # Steam launches games with LD_LIBRARY_PATH/LD_PRELOAD pointed at the Steam
    # Runtime. A host binary such as curl then loads the runtime's glibc while
    # the system's NSS resolver modules stay on the host, and name resolution
    # breaks (curl reports 000). Steam preserves the original search path in
    # SYSTEM_LD_LIBRARY_PATH; restore it, otherwise drop the variables.
    env = os.environ.copy()
    sys_ld = env.get("SYSTEM_LD_LIBRARY_PATH")
    if sys_ld:
        env["LD_LIBRARY_PATH"] = sys_ld
        env.pop("LD_PRELOAD", None)
    elif env.get("LD_LIBRARY_PATH") or env.get("LD_PRELOAD"):
        env.pop("LD_LIBRARY_PATH", None)
        env.pop("LD_PRELOAD", None)
    return env


def fetch(url, out, tries=3):
    global FETCH_LAST_CODE
    env = clean_env()
    insecure = []
    part = out + ".part"
    for i in range(1, tries + 1):
        auth = []
        token = os.environ.get("GITHUB_TOKEN")
        if token and url.startswith("https://api.github.com/"):
            auth = ["-H", f"Authorization: Bearer {token}"]
        cmd = ["curl", "-fsSL", *insecure, *auth, "--connect-timeout", "15",
               "--max-time", "600", "-A", UA, url, "-o", part]
        try:
            subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass
        if os.path.isfile(part) and os.path.getsize(part) > 0:
            os.replace(part, out)
            return True
        try:
            os.remove(part)
        except OSError:
            pass
        # Some Proton/Flatpak sandboxes ship a broken CA bundle; retry unverified.
        if i == 1 and not insecure:
            insecure = ["-k"]
            continue
        if i < tries:
            time.sleep(2)
    try:
        r = subprocess.run(["curl", "-s", "-k", "-o", "/dev/null", "-w", "%{http_code}",
                             "-A", UA, "--connect-timeout", "10", "--max-time", "30", url],
                            env=env, capture_output=True, text=True)
        FETCH_LAST_CODE = r.stdout.strip()
    except OSError:
        FETCH_LAST_CODE = ""
    return False


def net_diagnose():
    global NET_DIAG_DONE
    if NET_DIAG_DONE:
        return
    NET_DIAG_DONE = True
    if not (os.environ.get("LD_LIBRARY_PATH") or os.environ.get("STEAM_RUNTIME")
            or os.environ.get("STEAM_COMPAT_DATA_PATH")):
        return
    probe = "https://api.github.com/"

    def code(env):
        try:
            r = subprocess.run(["curl", "-s", "-k", "-o", "/dev/null", "-w", "%{http_code}",
                                 "--connect-timeout", "8", "--max-time", "15", probe],
                                env=env, capture_output=True, text=True)
            return r.stdout.strip()
        except OSError:
            return ""

    dirty = code(os.environ.copy())
    clean = code(clean_env())
    if dirty == "000" and clean not in ("000", ""):
        info("Network only works with the Steam Runtime library path removed - downloads now use a clean environment")
    elif clean in ("000", ""):
        warn("No network from inside the Steam Runtime (DNS unreachable, even with a clean library path).")
        warn("Workaround: run the script once from a terminal in the game folder to fill the cache, then relaunch from Steam:")
        warn(f'    cd "{START_DIR}" && "{os.path.abspath(sys.argv[0])}" --update')


def fetch_reason():
    c = FETCH_LAST_CODE or ""
    if c in ("000", ""):
        return "no connection - DNS or network unreachable"
    if c == "403":
        return "HTTP 403 - rate limited or blocked (set GITHUB_TOKEN to raise the API limit)"
    if c == "404":
        return "HTTP 404 - not found upstream"
    if c == "429":
        return "HTTP 429 - too many requests"
    if len(c) == 3 and c.startswith("5"):
        return f"HTTP {c} - upstream server error"
    return f"HTTP {c}"


def human_size(n):
    n = float(n)
    for unit in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def download_file(url, output, tries=3):
    info(f"Downloading {os.path.basename(output)}")
    if fetch(url, output, tries):
        try:
            sz = human_size(os.path.getsize(output))
        except OSError:
            sz = "ok"
        success(f"Downloaded {os.path.basename(output)} ({sz})")
        return True
    net_diagnose()
    error(f"Failed to download {os.path.basename(output)}: {fetch_reason()}")
    error(f"  {url}")
    return False


def cache_fetch(url, name, max_age=86400):
    cf = CACHE_DIR / name
    try:
        st = cf.stat()
        age = time.time() - st.st_mtime
        fresh = cf.is_file() and st.st_size > 0 and age < max_age
    except OSError:
        fresh = False
    if fresh:
        return str(cf)
    dl = os.path.join(TMP_DIR, f"cache.{os.getpid()}.{int(time.time() * 1000) % 1000000}.dl")
    if fetch(url, dl, 2) and os.path.getsize(dl) > 0:
        try:
            shutil.move(dl, cf)
            return str(cf)
        except OSError:
            pass
    try:
        os.remove(dl)
    except OSError:
        pass
    if cf.is_file() and cf.stat().st_size > 0:
        return str(cf)  # stale is better than nothing
    return None


def run_ok(cmd):
    try:
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0
    except OSError:
        return False


def extract_archive(archive, dest="."):
    os.makedirs(dest, exist_ok=True)
    low = archive.lower()
    if low.endswith(".zip"):
        try:
            with zipfile.ZipFile(archive) as z:
                z.extractall(dest)
            return True
        except Exception:
            pass
        if HAVE_7Z:
            return run_ok([SEVENZIP, "x", "-y", archive, f"-o{dest}"])
        return False
    if low.endswith(".7z") or low.endswith(".exe"):
        if not HAVE_7Z:
            return False
        return run_ok([SEVENZIP, "x", "-y", archive, f"-o{dest}"])
    return False

###############################################################################
# TITLE SOURCES
###############################################################################


def add_candidate_title(raw):
    if not raw:
        return
    clean = raw.replace('"', '').replace('-', ' ').replace('_', ' ').strip()
    if len(clean) < 3:
        return
    nc = norm(clean)
    if not nc:
        return
    if any(norm(e) == nc for e in CANDIDATE_TITLES):
        return
    CANDIDATE_TITLES.append(clean)


def find_steam_library():
    d = START_DIR
    for _ in range(8):
        if os.path.isdir(os.path.join(d, "steamapps")):
            return os.path.join(d, "steamapps")
        if os.path.basename(d) == "steamapps":
            return d
        parent = os.path.dirname(d)
        if not parent:
            parent = "/"
        if parent == d:
            break
        d = parent
    return None


def steam_install_dir_name():
    m = re.search(r'steamapps/common/([^/]+)', START_DIR)
    return m.group(1) if m else None


def vdf_get(text, key):
    m = re.search(r'"' + re.escape(key) + r'"\s*"([^"]*)"', text, re.I)
    return m.group(1) if m else ""


def detect_steam_appid():
    global STEAM_APPID
    for rel in ("steam_appid.txt", "../steam_appid.txt", "../../steam_appid.txt"):
        if os.path.isfile(rel):
            try:
                digits = re.sub(r'\D', '', open(rel, errors="ignore").read())
            except OSError:
                digits = ""
            if digits and set(digits) != {"0"}:
                STEAM_APPID = digits
                return

    scd = os.environ.get("STEAM_COMPAT_DATA_PATH", "")
    if "/compatdata/" in scd:
        t = scd.split("/compatdata/", 1)[1]
        aid = re.sub(r'\D', '', t.split("/")[0])
        if aid:
            STEAM_APPID = aid
            return
    for var in ("SteamAppId", "SteamGameId"):
        v = re.sub(r'\D', '', os.environ.get(var, ""))
        if v:
            STEAM_APPID = v
            return

    # Last resort: find the appmanifest whose installdir matches our folder.
    lib = find_steam_library()
    dirname_ = steam_install_dir_name()
    if lib and dirname_:
        try:
            acfs = list(Path(lib).glob("appmanifest_*.acf"))
        except OSError:
            acfs = []
        for acf in acfs:
            try:
                text = acf.read_text(errors="ignore")
            except OSError:
                continue
            if f'"{dirname_}"'.lower() in text.lower():
                STEAM_APPID = re.sub(r'^appmanifest_', '', acf.stem)
                return


def detect_steam_store_title():
    global STEAM_STORE_TITLE
    if not STEAM_APPID:
        return
    cf = cache_fetch(f"https://store.steampowered.com/api/appdetails?appids={STEAM_APPID}&filters=basic",
                      f"steam_{STEAM_APPID}.json", 604800)
    data = load_json(cf)
    try:
        STEAM_STORE_TITLE = data[STEAM_APPID]["data"]["name"]
    except Exception:
        STEAM_STORE_TITLE = ""
    if STEAM_STORE_TITLE:
        info(f"Steam Store title for AppID {STEAM_APPID}: {STEAM_STORE_TITLE}")


def extract_steam_manifest_title():
    lib = find_steam_library()
    if not lib:
        return ""
    acf = None
    if STEAM_APPID and os.path.isfile(os.path.join(lib, f"appmanifest_{STEAM_APPID}.acf")):
        acf = os.path.join(lib, f"appmanifest_{STEAM_APPID}.acf")
    else:
        dirname_ = steam_install_dir_name()
        if dirname_:
            try:
                candidates = list(Path(lib).glob("appmanifest_*.acf"))
            except OSError:
                candidates = []
            for f in candidates:
                try:
                    if f'"{dirname_}"'.lower() in f.read_text(errors="ignore").lower():
                        acf = str(f)
                        break
                except OSError:
                    continue
    if not acf:
        return ""
    try:
        text = open(acf, errors="ignore").read()
    except OSError:
        return ""
    return vdf_get(text, "name")


def detect_heroic_lutris_bottles():
    global LAUNCHER_TITLE
    for var in ("HEROIC_APP_TITLE", "HEROIC_APP_NAME", "LUTRIS_GAME_NAME",
                "BOTTLES_GAME_NAME", "BOTTLE_NAME", "LUTRIS_GAME_SLUG"):
        v = os.environ.get(var)
        if v:
            LAUNCHER_TITLE = v
            return
    # Steam has already identified the game; scanning Heroic's library anyway
    # is a directory-name guess that can hijack a Steam copy of a game that
    # happens to share a folder name with an unrelated Heroic entry.
    if STEAM_APPID:
        return

    base = os.path.basename(START_DIR)
    cfg_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    for h_dir in (os.path.join(cfg_home, "heroic"),
                  os.path.join(str(Path.home()), ".var/app/com.heroicgameslauncher.hgl/config/heroic")):
        if not os.path.isdir(h_dir):
            continue
        candidates = [os.path.join(h_dir, "gamelist.json")]
        candidates += glob.glob(os.path.join(h_dir, "store_cache", "*.json"))
        candidates += glob.glob(os.path.join(h_dir, "GamesConfig", "*.json"))
        for f in candidates:
            if not os.path.isfile(f):
                continue
            try:
                text = open(f, errors="ignore").read()
            except OSError:
                continue
            found = _heroic_title_near(text, START_DIR)
            if not found:
                found = _heroic_title_near(text, f'"{base}"')
            if found:
                LAUNCHER_TITLE = found
                info(f"Extracted title from Heroic config: {LAUNCHER_TITLE}")
                return


def _heroic_title_near(text, needle):
    idx = text.find(needle)
    if idx == -1:
        return ""
    window = text[max(0, idx - 3000):idx]
    matches = re.findall(r'"title"\s*:\s*"([^"]*)"', window)
    return matches[-1] if matches else ""


def extract_pe_product_name(exe):
    try:
        data = open(exe, "rb").read(4_000_000)
    except OSError:
        return ""
    try:
        text = data.decode("utf-16-le", errors="ignore")
    except Exception:
        return ""
    for field in ("ProductName", "FileDescription"):
        idx = text.find(field)
        if idx == -1:
            continue
        tail = text[idx + len(field):idx + len(field) + 200]
        m = re.search(r"[A-Za-z0-9 :&!']{3,}", tail)
        if m:
            candidate = m.group(0).strip()
            if len(candidate) >= 3:
                return candidate
    return ""


def detect_exe_bitness(exe):
    try:
        with open(exe, "rb") as f:
            f.seek(0x3C)
            off_bytes = f.read(4)
            if len(off_bytes) < 4:
                return ""
            off = int.from_bytes(off_bytes, "little")
            f.seek(off + 4)
            machine = f.read(2)
            if len(machine) < 2:
                return ""
            val = int.from_bytes(machine, "little")
    except OSError:
        return ""
    if val in (0x8664, 0xAA64):
        return "64"
    if val in (0x014c, 0x01c4):
        return "32"
    return ""

###############################################################################
# GAME DETECTION
###############################################################################


def detect_game():
    global GAME_EXE, GAME_DIR, GAME_NAME, GAME_KEY, GAME_DISPLAY
    global GAME_IS_UE, GAME_IS_UNITY, GAME_BITS, STEAM_APPID

    info("Detecting game executable...")
    detect_steam_appid()
    detect_heroic_lutris_bottles()

    if STEAM_APPID and set(STEAM_APPID) == {"0"}:
        STEAM_APPID = ""
    if STEAM_APPID:
        info(f"Detected Steam AppID: {STEAM_APPID}")
        detect_steam_store_title()
    if LAUNCHER_TITLE:
        info(f"Detected Launcher Title: {LAUNCHER_TITLE}")

    best_exe = None
    best_score = -9999
    is_unity_flag = False
    scanned = 0
    stop = False

    for root, dirs, files in os.walk(START_DIR):
        rel_depth = root[len(START_DIR):].count(os.sep)
        if rel_depth >= 7:
            dirs[:] = []
        for fn in files:
            low = fn.lower()
            if low == "unityplayer.dll":
                is_unity_flag = True
                continue
            if not low.endswith(".exe"):
                continue
            if UE_IGNORE_REGEX.search(low):
                continue

            path = os.path.join(root, fn)
            scanned += 1
            if scanned > 500:
                stop = True
                break
            try:
                size = os.path.getsize(path)
            except OSError:
                size = 0

            score = 100
            if low.endswith("shipping.exe"):
                score += 100
            if low.endswith("game.exe"):
                score += 50
            if "win64" in low:
                score += 20
            lp = path.replace(os.sep, "/").lower()
            if "/binaries/win64/" in lp:
                score += 40
            if "/engine/" in lp:
                score -= 60
            if re.search(r'launcher.*\.exe$', low):
                score -= 60
            # Anti-cheat launcher shims sit beside the real binary and are
            # often marginally larger, which was enough to win on size alone.
            if re.search(r'(eac-win64|_eac\.exe|-eac\.exe)$', low):
                score -= 120
            # Prefer the plain project binary over decorated siblings.
            score -= len(fn) // 2

            size_bonus = min(size // 10_000_000, 30)
            score += size_bonus

            if score > best_score:
                best_score = score
                best_exe = path
        if stop:
            break

    GAME_IS_UNITY = is_unity_flag
    if not best_exe:
        return False

    GAME_EXE = best_exe
    try:
        GAME_DIR = os.path.realpath(os.path.dirname(best_exe))
    except OSError:
        GAME_DIR = START_DIR

    raw_name = re.sub(r'\.[eE][xX][eE]$', '', os.path.basename(best_exe))
    clean_exe_name = re.sub(r'[-_ ]*(U[0-9]{1,2}|UE[0-9]{1,2}|Win64|Win32|Shipping|Game|Demo|Client|Launcher)', '', raw_name, flags=re.I)

    # --- candidate titles, strongest evidence first -------------------------
    add_candidate_title(STEAM_STORE_TITLE)
    add_candidate_title(LAUNCHER_TITLE)

    manifest_title = extract_steam_manifest_title()
    if manifest_title:
        info(f"Extracted title from Steam appmanifest: {manifest_title}")
        add_candidate_title(manifest_title)

    current = START_DIR
    for depth in range(4):
        folder = os.path.basename(current)
        parent = os.path.dirname(current) or "/"
        if not folder or folder in ("/", "."):
            break
        if depth == 0:
            if folder.lower() not in ("binaries", "win64", "win32", "engine", "contents"):
                add_candidate_title(folder)
        else:
            if not SYSTEM_DIR_REGEX.match(folder.lower()) and len(folder) >= 3:
                add_candidate_title(folder)
        if parent == current:
            break
        current = parent

    pe_title = extract_pe_product_name(best_exe)
    if pe_title:
        info(f"Extracted PE Product Name: {pe_title}")
        add_candidate_title(pe_title)

    add_candidate_title(clean_exe_name)

    if not CANDIDATE_TITLES:
        add_candidate_title(raw_name)
        if not CANDIDATE_TITLES:
            CANDIDATE_TITLES.append(raw_name)

    GAME_NAME = CANDIDATE_TITLES[0]
    GAME_KEY = norm(GAME_NAME)
    GAME_DISPLAY = GAME_NAME

    if (raw_name.endswith("-Win64-Shipping") or raw_name.endswith("-Shipping")
            or "/Binaries/Win64/" in best_exe.replace(os.sep, "/")):
        GAME_IS_UE = True
        info("Unreal Engine architecture confirmed")
    if not GAME_IS_UNITY and glob.glob(os.path.join(START_DIR, "UnityCrashHandler*.exe")):
        GAME_IS_UNITY = True
    if GAME_IS_UNITY:
        info("Unity engine detected")

    GAME_BITS = detect_exe_bitness(best_exe)
    if GAME_BITS:
        info(f"Executable architecture: {GAME_BITS}-bit")

    success(f"Detected Game: {C['BOLD']}{C['WHITE']}{GAME_DISPLAY}{C['RESET']}")
    info("Candidate titles: " + " ".join(f"'{t}'" for t in CANDIDATE_TITLES))
    return True

###############################################################################
# GAME QUIRKS SYSTEM
###############################################################################


def resolve_game_quirks():
    global QUIRK_OPTISCALER_DLL, QUIRK_SKIP_OPTISCALER, QUIRK_SKIP_RESHADE
    global QUIRK_SKIP_DLSS_ENABLER, QUIRK_EXTRA_DLL_COPIES, QUIRKS_MATCHED

    QUIRK_OPTISCALER_DLL = "dxgi.dll"
    QUIRK_SKIP_OPTISCALER = QUIRK_SKIP_RESHADE = QUIRK_SKIP_DLSS_ENABLER = False
    QUIRK_EXTRA_DLL_COPIES = ""
    QUIRKS_MATCHED = ""

    user = {}
    if USER_QUIRKS_CONF.is_file():
        try:
            lines = USER_QUIRKS_CONF.read_text(errors="ignore").splitlines()
        except OSError:
            lines = []
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) == 2:
                k, v = norm(parts[0]), parts[1].strip()
                if k and v:
                    user[k] = v

    quirk_str = src = ""
    for title in CANDIDATE_TITLES:
        tk = norm(title)
        if not tk:
            continue
        if tk in user:
            quirk_str, src, QUIRKS_MATCHED = user[tk], f"user config ({USER_QUIRKS_CONF})", title
        elif tk in GAME_QUIRKS:
            quirk_str, src, QUIRKS_MATCHED = GAME_QUIRKS[tk], "built-in database", title
        if quirk_str:
            break

    if not quirk_str:
        return

    info(f"Applied game quirk for '{C['BOLD']}{C['WHITE']}{QUIRKS_MATCHED}{C['RESET']}' (from {src}): {quirk_str}")

    for kv in quirk_str.split(";"):
        kv = kv.strip()
        if not kv or "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        k = k.strip().lower()
        v = v.strip()
        if k == "optiscaler_dll":
            QUIRK_OPTISCALER_DLL = v
        elif k == "skip_optiscaler" and v in ("1", "true"):
            QUIRK_SKIP_OPTISCALER = True
        elif k == "skip_reshade" and v in ("1", "true"):
            QUIRK_SKIP_RESHADE = True
        elif k == "skip_dlss_enabler" and v in ("1", "true"):
            QUIRK_SKIP_DLSS_ENABLER = True
        elif k == "extra_dll_copies":
            QUIRK_EXTRA_DLL_COPIES = v

    if QUIRK_OPTISCALER_DLL != "dxgi.dll":
        info(f"Quirk override: OptiScaler proxy DLL set to '{C['BOLD']}{C['WHITE']}{QUIRK_OPTISCALER_DLL}{C['RESET']}'")


def list_all_quirks():
    print_banner()
    _log(f"\n{C['BOLD']}{C['WHITE']}Built-in Game Quirks Database:{C['RESET']}")
    for k in sorted(GAME_QUIRKS):
        print(f"  {C['INFO']}{k:<24}{C['RESET']} -> {GAME_QUIRKS[k]}", file=sys.stderr)
    if USER_QUIRKS_CONF.is_file():
        _log(f"\n{C['BOLD']}{C['WHITE']}User Game Quirks ({USER_QUIRKS_CONF}):{C['RESET']}")
        try:
            print(USER_QUIRKS_CONF.read_text(errors="ignore"), file=sys.stderr, end="")
        except OSError:
            pass
    else:
        _log(f"\n{C['INFO']}User config file not present ({USER_QUIRKS_CONF}){C['RESET']}")

###############################################################################
# SCORING / MATCHING (replaces match.awk)
###############################################################################


def score(q, k):
    lq, lk = len(q), len(k)
    if lq < 3 or lk < 3:
        return 0
    if q == k:
        return 1000
    # A trailing number is a sequel marker, never noise. A partial match must
    # also COVER most of the longer string - coverage is the real signal, not
    # raw distance (otherwise a stray short parent-dir name can hijack a match).
    if lq >= 5 and lk > lq and k[:lq] == q:
        rest = k[lq:]
        if rest.isdigit():
            return 0
        if lq / lk < 0.45:
            return 0
        d = lk - lq
        return 900 - d if d <= 24 else 0
    if lk >= 5 and lq > lk and q[:lk] == k:
        rest = q[lk:]
        if rest.isdigit():
            return 0
        if lk / lq < 0.45:
            return 0
        d = lq - lk
        return 880 - d if d <= 24 else 0
    if lq >= 7 and q in k and lq / lk >= 0.55:
        d = lk - lq
        return 760 - d if d <= 18 else 0
    if lk >= 7 and k in q and lk / lq >= 0.55:
        d = lq - lk
        return 740 - d if d <= 18 else 0
    return 0


def match_candidates(candidates, rows, min_score=MIN_SCORE):
    """rows: iterable of (k1, k2, k3, k4, name, slug, ext, url, dead)."""
    qks = []
    for c in candidates:
        sp = spaced(c)
        qks.append((tight(sp), tight(roman(sp))) if sp else None)

    # 1. Standard high-confidence scoring run
    for ci, c in enumerate(candidates):
        qk = qks[ci]
        if qk is None:
            continue
        best = 0
        br = None
        for row in rows:
            keys = ((1, row[0]), (2, row[1]), (3, row[2]), (4, row[3]))
            for q in qk:
                if not q:
                    continue
                for f, k in keys:
                    if not k:
                        continue
                    s = score(q, k)
                    if s <= 0:
                        continue
                    if f >= 3:
                        s -= 30
                    if s > best:
                        best, br = s, row
                    elif s == best and br is not None and br[8] and not row[8]:
                        br = row
        if best >= min_score and br is not None:
            return {"score": best, "name": br[4], "slug": br[5], "ext": br[6],
                    "url": br[7], "matched": c, "dead": br[8]}

    # 2. Bash Parity Fallback: Short-name expansion ("Karma" -> "Karma: The Dark World")
    for ci, c in enumerate(candidates):
        sp = spaced(c)
        q = tight(sp)
        if len(q) < 3:
            continue
        for row in rows:
            # Check if row key starts with candidate or candidate starts with row key
            k = row[0]
            if (len(q) >= 4 and k.startswith(q)) or (len(k) >= 4 and q.startswith(k)):
                return {"score": 750, "name": row[4], "slug": row[5], "ext": row[6],
                        "url": row[7], "matched": c, "dead": row[8]}

    return None

###############################################################################
# RENODX RESOLUTION
###############################################################################


def build_renodx_index(md_path):
    rows = []
    seen = set()
    dead = False
    try:
        lines = open(md_path, encoding="utf-8", errors="ignore").read().splitlines()
    except OSError:
        return rows

    for line in lines:
        if re.match(r'^#+\s', line):
            h = line.lower()
            if re.search(r'deprecat|legacy|obsolete|retired|archiv|unsupported', h):
                dead = True
            elif re.match(r'^#[^#]', line):
                dead = False
            continue
        if not re.match(r'^\s*\|', line):
            continue

        m = re.search(r'https?://[^ )|]+\.addon64', line) or re.search(r'https?://[^ )|]+\.addon32', line)
        if not m:
            continue
        url = m.group(0)

        cells = line.split("|")
        if len(cells) < 2:
            continue
        name = cells[1]
        if re.search(r'\[[^\]]+\]\(', name):
            name = re.sub(r'^[^\[]*\[', '', name)
            name = re.sub(r'\].*$', '', name)
        name = re.sub(r'<[^>]*>', '', name).replace('`', '').strip()
        if not name:
            continue

        file_ = url.rsplit("/", 1)[-1]
        ext = file_.rsplit(".", 1)[-1]
        slug = re.sub(r'\.addon(64|32)$', '', re.sub(r'^renodx-', '', file_))

        sp = spaced(name)
        if not sp:
            continue
        k1, k2 = tight(sp), tight(roman(sp))
        if k1 in seen:
            continue
        seen.add(k1)

        # "Main Title: Subtitle" -> also index the main title, but only when
        # it is substantial (>= 2 words), so "AI: The Somnium Files" never
        # keys on "ai".
        k3 = k4 = ""
        if ":" in name:
            short = spaced(name.split(":", 1)[0])
            if len(short.split(" ")) >= 2:
                k3, k4 = tight(short), tight(roman(short))

        rows.append([k1, k2, k3, k4, name, slug, ext, url, bool(dead)])
    return rows


def renodx_index():
    idx = CACHE_DIR / "renodx_index.json"
    try:
        st = idx.stat()
        fresh = idx.is_file() and (time.time() - st.st_mtime) < 86400
    except OSError:
        fresh = False
    if fresh:
        cached = load_json(str(idx))
        if cached:
            return cached
    md = cache_fetch(RENODX_WIKI, "renodx_mods.md", 86400)
    if not md:
        return None
    rows = build_renodx_index(md)
    if rows:
        try:
            idx.write_text(json.dumps(rows))
        except OSError:
            pass
        return rows
    return None


def renodx_mirror_index():
    """Slugs published by the aggregated snapshot mirror: [[slug, ext], ...], 64-bit preferred."""
    out = CACHE_DIR / "renodx_mirror.json"
    try:
        st = out.stat()
        fresh = out.is_file() and (time.time() - st.st_mtime) < 21600
    except OSError:
        fresh = False
    if fresh:
        cached = load_json(str(out))
        if cached is not None:
            return cached

    data = load_json(cache_fetch(RENODX_MIRROR_API, "renodx_mirror_raw.json", 21600))
    if not data:
        data = load_json(cache_fetch("https://api.github.com/repos/marat569/renodx/releases?per_page=3",
                                      "renodx_mirror_alt.json", 21600))
    if not data:
        return None

    releases = data if isinstance(data, list) else [data]
    best = {}
    for rel in releases:
        for a in (rel or {}).get("assets", []) or []:
            n = a.get("name", "")
            m = re.match(r'renodx-(.+)\.addon(64|32)$', n)
            if not m:
                continue
            slug = m.group(1)
            ext = "addon" + m.group(2)
            if slug not in best or ext == "addon64":
                best[slug] = ext
    result = [[s, e] for s, e in best.items()]
    if result:
        try:
            out.write_text(json.dumps(result))
        except OSError:
            pass
    return result or None


def install_addon(slug, ext, wiki_url, label):
    global MOD_FOUND
    info(f"Resolved to: {C['BOLD']}{C['WHITE']}{label}{C['RESET']}")

    # The mirror publishes both variants for every slug, so when a wiki row
    # offers both prefer the one matching the game's real PE architecture.
    order = [ext]
    if GAME_BITS and f"addon{GAME_BITS}" != ext:
        order = [f"addon{GAME_BITS}", ext]

    mir = renodx_mirror_index()
    on_mirror = True
    if mir is not None:
        on_mirror = any(s == slug for s, _ in mir)

    if on_mirror:
        for e in order:
            fname = f"renodx-{slug}.{e}"
            if fetch(f"{RENODX_BASE}/{fname}", fname, 2):
                success(f"Installed RenoDX: {fname} (snapshot mirror)")
                track(fname)
                MOD_FOUND = True
                return True
    if wiki_url:
        fname = f"renodx-{slug}.{ext}"
        if fetch(wiki_url, fname, 2):
            success(f"Installed RenoDX: {fname} (maintainer host)")
            track(fname)
            MOD_FOUND = True
            return True
    if not on_mirror:  # mirror not indexed for this slug - try anyway
        for e in order:
            fname = f"renodx-{slug}.{e}"
            if fetch(f"{RENODX_BASE}/{fname}", fname, 2):
                success(f"Installed RenoDX: {fname} (snapshot mirror)")
                track(fname)
                MOD_FOUND = True
                return True
    error(f"Found a match ({label}) but every download source failed")
    return False


def find_renodx_mod():
    if LUMA_ONLY or not CANDIDATE_TITLES:
        return
    info("Searching for RenoDX mod...")

    rows = renodx_index()
    if rows is None:
        warn(f"Could not obtain the RenoDX wiki index ({fetch_reason()})")
        return
    info(f"Wiki index: {len(rows)} games")

    hit = match_candidates(CANDIDATE_TITLES, rows, MIN_SCORE)
    if hit:
        if hit["dead"]:
            warn("The wiki lists this mod under 'Deprecated' (nonfunctional or superseded) - installing anyway")
        label = f"{hit['name']}  [matched '{hit['matched']}', score {hit['score']}]"
        if install_addon(hit["slug"], hit["ext"], hit["url"], label):
            return

    # --- secondary: exact hit against a mirror slug --------------------------
    mir = renodx_mirror_index()
    if mir:
        for t in CANDIDATE_TITLES:
            tn = norm(t)
            if len(tn) < 5 or tn in MIRROR_BLOCKLIST:
                continue
            for mslug, mext in mir:
                if norm(mslug) in MIRROR_BLOCKLIST:
                    continue
                if norm(mslug) == tn:
                    if install_addon(mslug, mext, "", f"{t}  [exact snapshot slug]"):
                        return

    info("No RenoDX mod matched confidently for this game")

###############################################################################
# LUMA
###############################################################################


def find_luma_mod():
    global MOD_FOUND
    if RENODX_ONLY or MOD_FOUND or not CANDIDATE_TITLES:
        return

    data = load_json(cache_fetch(f"https://api.github.com/repos/{REPO_LUMA}/releases/latest",
                                  "luma_release.json", 3600))
    if not data:
        return

    seen = {}
    for a in data.get("assets", []) or []:
        n = a.get("name", "")
        u = a.get("browser_download_url", "")
        if not (n.endswith(".zip") and u):
            continue
        # "-Test" builds and engine-wide bundles are excluded. "-x32" is NOT
        # excluded outright: for some games it's the only build that exists,
        # normalised to the same key as the 64-bit build, used only if
        # nothing else won.
        if re.search(r'-Test|Generic|Unreal_Engine|Unity_Engine|Graphics_Analyzer', n):
            continue
        base = re.sub(r'^Luma[-_]', '', re.sub(r'\.zip$', '', n))
        is32 = base.endswith("-x32")
        base = re.sub(r'-x32$', '', base)
        k = tight(spaced(base))
        if not k:
            continue
        if k in seen and not (seen[k][2] == 32 and not is32):
            continue
        seen[k] = (n, u, 32 if is32 else 64)

    if not seen:
        return
    rows = [[k, k, "", "", n, "luma", "zip", u, False] for k, (n, u, _bits) in seen.items()]

    hit = match_candidates(CANDIDATE_TITLES, rows, MIN_SCORE)
    if not hit:
        return

    info(f"Found Luma mod: {hit['name']}  [matched '{hit['matched']}', score {hit['score']}]")
    zip_path = os.path.join(TMP_DIR, "luma-mod.zip")
    luma_dir = os.path.join(TMP_DIR, "luma")
    if not (download_file(hit["url"], zip_path, 2) and extract_archive(zip_path, luma_dir)):
        return

    # Luma ships its payload as a plain ".addon" (not just .addon64/.addon32).
    found = False
    for a in Path(luma_dir).rglob("*"):
        if a.is_file() and re.search(r'\.addon(64|32)?$', a.name):
            try:
                shutil.copyfile(a, a.name)
                found = True
                track(a.name)
            except OSError:
                pass

    if not found:
        warn("Luma archive contained no addon file")
        return

    # Shader/companion directory the addon loads at runtime.
    luma_assets = Path(luma_dir, "Luma")
    if luma_assets.is_dir():
        try:
            shutil.copytree(luma_assets, "Luma", dirs_exist_ok=True)
            track("Luma")
        except OSError:
            pass

    # Luma bundles its own proxy. Installing it over OptiScaler's proxy would
    # silently disable OptiScaler, so only take it when nothing else has
    # claimed that slot.
    luma_dxgi = Path(luma_dir, "dxgi.dll")
    if luma_dxgi.is_file():
        if not os.path.isfile(QUIRK_OPTISCALER_DLL):
            try:
                shutil.copyfile(luma_dxgi, QUIRK_OPTISCALER_DLL)
                track(QUIRK_OPTISCALER_DLL)
                info(f"Installed Luma's {QUIRK_OPTISCALER_DLL} proxy (no OptiScaler present)")
            except OSError:
                pass
        else:
            warn(f"Kept OptiScaler's {QUIRK_OPTISCALER_DLL}; Luma's proxy was not installed")

    MOD_FOUND = True
    success(f"Installed Luma mod ({hit['name']})")


def install_engine_fallback():
    global MOD_FOUND
    if MOD_FOUND or LUMA_ONLY:
        return
    if GAME_IS_UE:
        info("UE game - applying generic RenoDX UE addon")
        if fetch(RENODX_UE_FALLBACK, "renodx-ue-extended.addon64", 2):
            success("Installed RenoDX UE extended fallback")
            track("renodx-ue-extended.addon64")
            MOD_FOUND = True
            return
        warn("UE fallback download failed")
    if GAME_IS_UNITY:
        info("Unity game - applying generic RenoDX Unity addon")
        if fetch(RENODX_UNITY_FALLBACK, "renodx-unityengine.addon64", 2):
            success("Installed RenoDX Unity fallback")
            track("renodx-unityengine.addon64")
            MOD_FOUND = True
            return
        warn("Unity fallback download failed")
    warn("No game-specific RenoDX or Luma mod found (OptiScaler & ReShade still installed)")

###############################################################################
# OPTISCALER / RESHADE / DLSS
###############################################################################


def install_optiscaler():
    if RENODX_ONLY or LUMA_ONLY or QUIRK_SKIP_OPTISCALER:
        return
    info(f"Installing OptiScaler into {os.getcwd()}")

    # Resolve the build from /releases (never /tags - a tag can have no
    # release attached, and /tags is not chronological).
    data = load_json(cache_fetch(f"https://api.github.com/repos/{REPO_OPTISCALER}/releases/tags/nightly",
                                  "optiscaler_nightly.json", 3600))
    releases = [data] if data else None
    if not releases:
        data = load_json(cache_fetch(f"https://api.github.com/repos/{REPO_OPTISCALER}/releases?per_page=20",
                                      "optiscaler_releases.json", 3600))
        releases = data if isinstance(data, list) else ([data] if data else None)
    if not releases:
        warn(f"Could not query OptiScaler releases ({fetch_reason()})")
        return

    # Asset selection is name-agnostic: take any .7z, drop obvious non-payload
    # archives, and prefer one whose name mentions optiscaler.
    all7z = []
    for rel in releases:
        for a in (rel or {}).get("assets", []) or []:
            u = a.get("browser_download_url", "")
            if u.lower().endswith(".7z"):
                all7z.append(u)

    urls = []
    for u in all7z:
        b = u.rsplit("/", 1)[-1].lower()
        if re.search(r'(debug|symbol|pdb|source|src|sdk)', b):
            continue
        if "optiscaler" in b:
            urls.append(u)
    if not urls:
        urls = all7z
    if not urls:
        warn("No OptiScaler .7z asset in the latest releases")
        return
    urls = urls[:3]  # newest, plus 2 fallbacks

    got = False
    dest = os.path.join(TMP_DIR, "optiscaler.7z")
    for u in urls:
        tag = u.rstrip("/").split("/")[-2] if u.count("/") >= 2 else u
        info(f"OptiScaler build: {tag}")
        if download_file(u, dest, 2):
            got = True
            break
        warn("Falling back to the previous OptiScaler build")
    if not got:
        warn("Every OptiScaler download failed")
        return

    osc_dir = os.path.join(TMP_DIR, "osc")
    if not extract_archive(dest, osc_dir):
        warn("Could not extract OptiScaler (7z missing?)")
        return

    # Locate the payload root by looking for the DLL or the ini under any
    # name, so a repackaged archive layout does not silently install nothing.
    root = osc_dir
    if not glob.glob(os.path.join(osc_dir, "[Oo]pti[Ss]caler*")):
        found = None
        for p in Path(osc_dir).rglob("*"):
            if p.is_file() and re.match(r'optiscaler.*\.dll$|optiscaler\.ini$', p.name, re.I):
                found = p
                break
        if found:
            root = str(found.parent)

    try:
        entries = os.listdir(root)
    except OSError:
        entries = []
    for entry in entries:
        track(entry)
        src = os.path.join(root, entry)
        try:
            if os.path.isdir(src):
                shutil.copytree(src, entry, dirs_exist_ok=True)
            else:
                shutil.copyfile(src, entry)
        except OSError:
            pass

    # Find any extracted optiscaler*.dll
    matches = [f for f in os.listdir(".") if re.match(r'optiscaler.*\.dll$', f, re.I)]
    if matches:
        src_dll = matches[0]

        # Overwrite if FORCE_UPDATE (--update) is set OR if the target DLL doesn't exist yet
        if FORCE_UPDATE or not os.path.isfile(QUIRK_OPTISCALER_DLL):
            try:
                os.replace(src_dll, QUIRK_OPTISCALER_DLL)
                track(QUIRK_OPTISCALER_DLL)
            except OSError:
                try:
                    shutil.move(src_dll, QUIRK_OPTISCALER_DLL)
                    track(QUIRK_OPTISCALER_DLL)
                except OSError:
                    pass
        else:
            # Not an update run and file already exists: clean up the extra extracted DLL
            try:
                os.remove(src_dll)
            except OSError:
                pass
    if os.path.isfile(QUIRK_OPTISCALER_DLL):
        success(f"Installed OptiScaler ({QUIRK_OPTISCALER_DLL})")
    else:
        warn("OptiScaler DLL not found after extraction")

    if QUIRK_EXTRA_DLL_COPIES and os.path.isfile(QUIRK_OPTISCALER_DLL):
        for extra in QUIRK_EXTRA_DLL_COPIES.split(","):
            extra = extra.strip()
            if not extra:
                continue
            try:
                shutil.copyfile(QUIRK_OPTISCALER_DLL, extra)
                track(extra)
                info(f"Created extra DLL copy: {extra}")
            except OSError:
                pass

    if not os.path.isfile("d3dcompiler_47.dll"):
        if fetch(D3DCOMPILER_URL, "d3dcompiler_47.dll", 2):
            track("d3dcompiler_47.dll")
        else:
            warn("Optional d3dcompiler_47.dll skipped (system DLL will be used)")

    if os.path.isfile("OptiScaler.ini"):
        try:
            text = open("OptiScaler.ini", encoding="utf-8", errors="ignore").read()
            text = re.sub(r'(?m)^[#]*\s*Dx12Upscaler\s*=.*', 'Dx12Upscaler = ffx', text)
            text = re.sub(r'(?m)^[#]*\s*FGInput\s*=.*', 'FGInput = nvngxfg', text)
            text = re.sub(r'(?m)^[#]*\s*FGNvngxReplacement\s*=.*', 'FGNvngxReplacement = Arturs', text)
            text = re.sub(r'(?m)^[#]*\s*LoadReshade\s*=.*', 'LoadReshade = true', text)
            with open("OptiScaler.ini", "w", encoding="utf-8") as f:
                f.write(text)
            success("Configured OptiScaler.ini")
        except OSError:
            pass


def pick_dlss_asset(data):
    """Extract the best .zip asset URL, skipping obvious non-payload archives,
    regardless of how the asset happens to be named."""
    if not data:
        return None
    releases = data if isinstance(data, list) else [data]
    for rel in releases:
        for a in (rel or {}).get("assets", []) or []:
            u = a.get("browser_download_url", "")
            b = u.rsplit("/", 1)[-1].lower()
            if not b.endswith(".zip"):
                continue
            if re.search(r'(debug|symbol|pdb|source|src)([._-]|$)', b):
                continue
            return u
    return None


def install_dlss_enabler():
    if RENODX_ONLY or LUMA_ONLY or QUIRK_SKIP_DLSS_ENABLER:
        return
    info("Installing DLSS Enabler...")

    url = pick_dlss_asset(load_json(cache_fetch(f"https://api.github.com/repos/{REPO_DLSS}/releases/tags/dlss-enabler",
                                                 "dlss_enabler.json", 3600)))
    if not url:
        url = pick_dlss_asset(load_json(cache_fetch(f"https://api.github.com/repos/{REPO_DLSS}/releases?per_page=5",
                                                     "dlss_enabler_all.json", 3600)))
        if url:
            info("DLSS Enabler: pinned tag unavailable, using newest release")
    if not url:
        warn("No DLSS Enabler asset found")
        return

    zpath = os.path.join(TMP_DIR, "dlss-enabler.zip")
    if not download_file(url, zpath, 2):
        return
    ddir = os.path.join(TMP_DIR, "dlss")
    if not extract_archive(zpath, ddir):
        return

    # The enabler's proxy usually ships as dxgi.dll, but some builds ship it
    # as version.dll instead (e.g. when dxgi.dll is already claimed).
    dll = None
    for p in Path(ddir).rglob("*"):
        if p.is_file() and p.name.lower() in ("dxgi.dll", "version.dll"):
            dll = p
            break
    if dll:
        os.makedirs("OptiScaler", exist_ok=True)
        try:
            shutil.copyfile(dll, os.path.join("OptiScaler", "dlss-enabler-headless.dll"))
            track("OptiScaler/dlss-enabler-headless.dll")
            success("Installed DLSS Enabler")
        except OSError:
            pass
    else:
        warn("DLSS Enabler proxy DLL (dxgi.dll/version.dll) not found inside the archive")


def ensure_reshade_proxy(src):
    # Nothing loads ReShade (and therefore the RenoDX addon) unless a proxy
    # DLL sits next to the game. If OptiScaler is absent/failed, promote
    # ReShade itself to proxy DLL so the addon loads.
    if not os.path.isfile(src) or os.path.isfile(QUIRK_OPTISCALER_DLL):
        return
    try:
        shutil.copyfile(src, QUIRK_OPTISCALER_DLL)
        track(QUIRK_OPTISCALER_DLL)
        warn(f"OptiScaler missing - installed ReShade as {QUIRK_OPTISCALER_DLL} so the addon loads")
    except OSError:
        pass


def install_reshade():
    if QUIRK_SKIP_RESHADE:
        return
    if os.path.isfile("ReShade64.dll"):
        info("ReShade already present")
        ensure_reshade_proxy("ReShade64.dll")
        return
    if not HAVE_7Z:
        warn("Skipping ReShade (needs 7z)")
        return
    info("Installing ReShade...")

    exe_path = os.path.join(TMP_DIR, "ReShade_Setup_Addon.exe")
    if not download_file(RESHADE_URL, exe_path, 2):
        return
    rdir = os.path.join(TMP_DIR, "reshade")
    if not extract_archive(exe_path, rdir):
        warn("Could not unpack the ReShade installer")
        return

    dll = None
    for p in Path(rdir).rglob("*"):
        if p.is_file() and p.name.lower() == "reshade64.dll":
            dll = p
            break
    if not dll:
        for p in Path(rdir).rglob("*"):
            if p.is_file() and re.search(r'reshade.*64.*\.dll$', p.name, re.I):
                dll = p
                break
    if dll:
        try:
            shutil.copyfile(dll, "ReShade64.dll")
            track("ReShade64.dll")
            success("Installed ReShade (ReShade64.dll)")
        except OSError:
            pass
        ensure_reshade_proxy("ReShade64.dll")
    else:
        warn("ReShade64.dll not found inside the installer")

###############################################################################
# INSTALL FLOW
###############################################################################


def track(path):
    if path:
        INSTALLED_FILES.append(path)


def write_manifest():
    if not INSTALLED_FILES:
        return
    try:
        with open(MANIFEST, "w", encoding="utf-8") as f:
            f.write("\n".join(sorted(set(INSTALLED_FILES))) + "\n")
    except OSError:
        pass


def uninstall_dir(d):
    manifest_path = os.path.join(d, MANIFEST)
    if not os.path.isfile(manifest_path):
        return False
    info(f"Uninstalling OptiDX files from {d}...")
    removed = 0
    try:
        lines = open(manifest_path, errors="ignore").read().splitlines()
    except OSError:
        lines = []
    for p in lines:
        # Refuse absolute paths and traversal - the manifest is ours, but a
        # corrupted one must never let a delete escape the game directory.
        if not p or p.startswith("/") or ".." in p:
            continue
        target = os.path.join(d, p)
        if os.path.exists(target) or os.path.islink(target):
            info(f"Removing: {p}")
            try:
                if os.path.isdir(target) and not os.path.islink(target):
                    shutil.rmtree(target, ignore_errors=True)
                else:
                    os.remove(target)
                removed += 1
            except OSError:
                pass
    for f in (manifest_path, os.path.join(d, MARKER)):
        try:
            os.remove(f)
        except OSError:
            pass
    success(f"Removed {removed} item(s) from {d}")
    return True


def cleanup_stale():
    # ".addon" included: Luma's payload uses that bare extension.
    for pat in ("*.addon64", "*.addon32", "*.addon"):
        for f in glob.glob(pat):
            try:
                os.remove(f)
            except OSError:
                pass
    for d in ("__MACOSX", ".dlss_tmp"):
        shutil.rmtree(d, ignore_errors=True)
    for f in ("optiscaler-edge.7z", "dlss-enabler.zip", "luma-mod.zip", "ReShade_Setup_Addon.exe"):
        try:
            os.remove(f)
        except OSError:
            pass


def verify_installation():
    info(f"Verifying installation in {os.getcwd()}")
    found = False
    if os.path.isfile(QUIRK_OPTISCALER_DLL):
        success(f"OptiScaler active ({QUIRK_OPTISCALER_DLL})")
        found = True
    try:
        addons = [f for f in os.listdir(".") if os.path.isfile(f) and re.search(r'\.addon(64|32)?$', f)]
    except OSError:
        addons = []
    for a in addons:
        success(f"Mod installed: {a}")
    if addons:
        found = True
    if os.path.isfile("ReShade64.dll"):
        success("ReShade installed")
        found = True
    if os.path.isfile(os.path.join("OptiScaler", "dlss-enabler-headless.dll")):
        success("DLSS Enabler installed")
        found = True
    if os.path.isfile("OptiScaler.ini"):
        success("OptiScaler.ini present")
    if not found:
        warn("Nothing was installed")
        return False
    return True


def warm_metadata_caches():
    # The metadata endpoints are independent and each costs a full round
    # trip; warming them concurrently turns several sequential RTTs into
    # roughly one. A failure here is a no-op - each installer still fetches
    # on demand.
    tasks = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        if not (RENODX_ONLY or LUMA_ONLY):
            tasks.append(ex.submit(cache_fetch, f"https://api.github.com/repos/{REPO_OPTISCALER}/releases/tags/nightly",
                                    "optiscaler_nightly.json", 3600))
            tasks.append(ex.submit(cache_fetch, f"https://api.github.com/repos/{REPO_DLSS}/releases/tags/dlss-enabler",
                                    "dlss_enabler.json", 3600))
        tasks.append(ex.submit(cache_fetch, RENODX_WIKI, "renodx_mods.md", 86400))
        tasks.append(ex.submit(cache_fetch, RENODX_MIRROR_API, "renodx_mirror_raw.json", 21600))
        for t in tasks:
            try:
                t.result()
            except Exception:
                pass


def do_install():
    print_banner()
    info(f"Install directory: {os.getcwd()}")
    info(f"Target game: {C['BOLD']}{C['WHITE']}{GAME_DISPLAY}{C['RESET']}")

    resolve_game_quirks()

    if DRY_RUN:
        info("Dry run enabled - skipping file downloads and modifications.")
        find_renodx_mod()
        if not MOD_FOUND:
            find_luma_mod()
        success("Dry run simulation complete.")
        return

    warm_metadata_caches()
    cleanup_stale()
    install_optiscaler()
    install_dlss_enabler()
    install_reshade()

    find_renodx_mod()
    if not MOD_FOUND:
        find_luma_mod()
    install_engine_fallback()

    # Only record success if something actually landed, so a run where every
    # download failed still gets retried on the next launch.
    if not verify_installation():
        warn("Nothing was installed - not marking as complete, so the next launch retries")
        warn("Check connectivity; GitHub also rate-limits to 60 API calls/hour unauthenticated")
        return

    write_manifest()
    marker_body = f"{os.getcwd()}\nv{SCRIPT_VERSION}\n"
    try:
        with open(MARKER, "w") as f:
            f.write(marker_body)
    except OSError:
        pass
    # The launcher re-enters at the game root, but the payload lives in the
    # binary directory - a marker recording that path lives at both.
    if os.getcwd() != START_DIR:
        try:
            with open(os.path.join(START_DIR, MARKER), "w") as f:
                f.write(marker_body)
        except OSError:
            pass
    try:
        os.sync()
    except (AttributeError, OSError):
        pass

    _log(f"\n{C['OK']}{C['BOLD']}  All done! Installation complete.{C['RESET']}")

###############################################################################
# CLI / ENTRYPOINT
###############################################################################


def usage():
    print(f"""OptiDX v{SCRIPT_VERSION} (Python) - OptiScaler + RenoDX installer

  optidx.py [options] [-- <command to launch the game>]

  --renodx       Only install RenoDX/Luma mods (skip OptiScaler/DLSS)
  --luma         Only install Luma mods
  --update       Re-run installation even if already installed
  --uninstall    Remove everything OptiDX installed, then launch normally
  --dry-run      Simulate game detection and mod matching without installing
  --list-quirks  Display all built-in and user-defined game quirks
  --help         Show this message

Options must come BEFORE the game command; everything after the first
non-option argument is forwarded to the game untouched.

Steam launch options:   /path/to/optidx.py %command%
""", file=sys.stderr)


def launch_now():
    try:
        os.chdir(START_DIR)
    except OSError:
        pass
    if TMP_DIR:
        shutil.rmtree(TMP_DIR, ignore_errors=True)
    if not GAME_ARGS:
        return
    try:
        os.execvp(GAME_ARGS[0], GAME_ARGS)
    except OSError as e:
        error(f"Could not launch game: {e}")
        sys.exit(1)


def main(argv):
    global RENODX_ONLY, LUMA_ONLY, FORCE_UPDATE, DO_UNINSTALL, DRY_RUN, LIST_QUIRKS

    # OptiDX flags are only recognised BEFORE the game command; everything
    # after the first non-flag argument is forwarded to the game untouched.
    opts = True
    for arg in argv:
        if opts:
            if arg == "--renodx":
                RENODX_ONLY = True
                continue
            if arg == "--luma":
                LUMA_ONLY = True
                continue
            if arg == "--update":
                FORCE_UPDATE = True
                continue
            if arg == "--uninstall":
                DO_UNINSTALL = True
                continue
            if arg == "--dry-run":
                DRY_RUN = True
                continue
            if arg == "--list-quirks":
                LIST_QUIRKS = True
                continue
            if arg in ("--help", "-h"):
                usage()
                sys.exit(0)
            if arg == "--":
                opts = False
                continue
            opts = False  # first non-flag: the game command (still appended below)
        GAME_ARGS.append(arg)

    if LIST_QUIRKS:
        list_all_quirks()
        sys.exit(0)

    have_game = bool(GAME_ARGS)
    marker_path = os.path.join(START_DIR, MARKER)

    # ---- fast path -------------------------------------------------------
    # Already installed and just launching: hand off immediately.
    if have_game and not FORCE_UPDATE and not DO_UNINSTALL and os.path.isfile(marker_path):
        installed_at = ""
        try:
            with open(marker_path) as f:
                installed_at = f.readline().strip()
        except OSError:
            pass
        if not os.path.isdir(installed_at):
            installed_at = START_DIR
        try:
            with open(os.path.join(installed_at, "optidx.log"), "a", encoding="utf-8") as f:
                f.write(f"OptiDX v{SCRIPT_VERSION}: already installed, launching "
                         f"({time.strftime('%Y-%m-%d %H:%M:%S')})\n")
        except OSError:
            pass
        launch_now()
        return

    LOG_BUFFER.append("-" * 50)
    LOG_BUFFER.append(f"OptiDX v{SCRIPT_VERSION} run started: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    LOG_BUFFER.append("-" * 50)

    if DO_UNINSTALL:
        found = False
        for root, dirs, files in os.walk(START_DIR):
            rel_depth = root[len(START_DIR):].count(os.sep)
            if rel_depth >= 6:
                dirs[:] = []
            if MANIFEST in files:
                if uninstall_dir(root):
                    found = True
        try:
            os.remove(marker_path)
        except OSError:
            pass
        if found:
            success("OptiDX removed - the game is back to its original files")
        else:
            warn(f"No OptiDX manifest found under {START_DIR} (nothing to remove)")
        if not have_game:
            sys.exit(0)
        info("Launching game...")
        launch_now()
        return

    if check_requirements() and need_workspace():
        if os.path.isfile(marker_path) and not FORCE_UPDATE:
            info("Existing OptiDX setup found - launching directly")
        elif detect_game():
            if GAME_DIR and os.path.isdir(GAME_DIR) and GAME_DIR != os.getcwd():
                info(f"Entering binary directory: {GAME_DIR}")
                try:
                    os.chdir(GAME_DIR)
                except OSError:
                    warn(f"Could not enter {GAME_DIR}")
            set_log_dir(os.getcwd())  # log lives with the payload, not the game root
            do_install()
        else:
            set_log_dir(START_DIR)
            error(f"Could not detect a game executable in {START_DIR}")
            if not have_game:
                sys.exit(1)
            warn("Continuing to launch anyway")
    else:
        set_log_dir(START_DIR)

    if not have_game:
        return

    info("Launching game...")
    launch_now()


if __name__ == "__main__":
    main(sys.argv[1:])
