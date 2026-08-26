#!/usr/bin/env bash

###############################################################################
# OptiDX v2.0 - Universal Game Mod Installer
#
# Detects the game it was launched next to, resolves it against the RenoDX
# wiki mod table, and installs the matching .addon64/.addon32 snapshot along
# with OptiScaler, ReShade and the DLSS enabler.
#
# Changes vs 1.5 (all verified against the live wiki + release mirrors):
#   * No longer aborts mid-run. 3.5 ran under `set -e` with `pipefail` and
#     captured `grep`/`fzf` output into bare assignments; the first wiki row
#     without an addon URL (the table header separator) killed the whole
#     script before a single mod was ever matched.
#   * Title matching is a deterministic scorer over the wiki's official Name
#     column, evaluating every row and taking the BEST hit. 3.5 used fzf
#     subsequence matching and took the FIRST alphabetical hit, which mapped
#     e.g. "Hogwarts Legacy" onto the "Haste" addon.
#   * Addon slugs come from the URL basename, so they work regardless of which
#     of the wiki's 14 maintainer hosts a row points at. Downloads prefer the
#     aggregated GitHub snapshot mirror and fall back to the row's own URL.
#   * Whole wiki is parsed and searched in two awk passes instead of several
#     thousand forked grep/sed/tr processes.
###############################################################################

set -uo pipefail
export LC_ALL=C

###############################################################################
# GLOBALS
###############################################################################

SCRIPT_VERSION="2.0"
MARKER=".optidx-installed"
MANIFEST=".optidx-files"          # every path OptiDX created, for --uninstall

REPO_OPTISCALER="Cha1N1/OptiScaler"
REPO_LUMA="Filoppi/Luma-Framework"
REPO_DLSS="Cha1N1/dlss-enabler-bleeding-edge"

RENODX_WIKI="https://raw.githubusercontent.com/wiki/clshortfuse/renodx/Mods.md"
RENODX_BASE="https://github.com/marat569/renodx/releases/download/snapshot"
RENODX_MIRROR_API="https://api.github.com/repos/marat569/renodx/releases/tags/snapshot"
RENODX_UE_FALLBACK="$RENODX_BASE/renodx-ue-extended.addon64"
RENODX_UNITY_FALLBACK="https://notvoosh.github.io/renodx-unity/renodx-unityengine.addon64"

RESHADE_URL="https://reshade.me/downloads/ReShade_Setup_Addon.exe"
D3DCOMPILER_URL="https://raw.githubusercontent.com/Joshua-Ashton/d3dcompiler_47/master/d3dcompiler_47.dll"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/optidx"

START_DIR="$PWD"
# Steam sets the working directory to the GAME ROOT, but for Unreal titles the
# payload belongs in <Game>/Binaries/Win64. The log follows the payload rather
# than littering the game root, so it is resolved only once that directory is
# known; until then lines are buffered in memory.
LOG_FILE=""
LOG_BUFFER=()
TMP_DIR=""

# Scratch space and the cache directory are created on FIRST USE, not at
# startup. As a Steam launch wrapper the common case is "already installed":
# that path must reach exec() without touching the filesystem at all.
need_workspace() {
    [[ -n "$TMP_DIR" ]] && return 0
    mkdir -p "$CACHE_DIR" 2>/dev/null
    TMP_DIR="$(mktemp -d)" || { TMP_DIR=""; return 1; }
    [[ -d "$CACHE_DIR" ]] || CACHE_DIR="$TMP_DIR"
    trap 'rm -rf "$TMP_DIR"' EXIT
    return 0
}

# Minimum match score required before an addon is installed. Deliberately
# strict: installing nothing is better than installing the wrong game's mod.
MIN_SCORE=700

# Engine-generic addons are never auto-selected by name matching.
MIRROR_BLOCKLIST=" generic devkit fpslimiter _univ ue-extended unityengine unity fe "

UE_IGNORE_REGEX="crashpad|easyanticheat|crashreportclient|unrealcefsubprocess|unreallightmass|epicwebhelper|shadercompileworker|dxcheck|unitycrashhandler|dxsetup|vcredist|dotnetfx|oalinst|touchup"
SYSTEM_DIR_REGEX="^(binaries|win64|win32|wingdk|engine|contents|game|games|app|bin|data|test|tmp|home|drive_c|steamapps|common|mnt|media|storage|users|public|desktop|documents|downloads|steamlibrary|steam|gog games|galaxy|epic games|ubisoft.*|origin games|ea games|xboxgames|program files.*|[a-z]:)$"

GAME_EXE=""
GAME_DIR=""
GAME_NAME=""
GAME_KEY=""
GAME_DISPLAY=""
LAUNCHER_TITLE=""
STEAM_APPID=""
STEAM_STORE_TITLE=""
GAME_IS_UE=false
GAME_IS_UNITY=false
GAME_BITS=""

CANDIDATE_TITLES=()

RENODX_ONLY=false
LUMA_ONLY=false
FORCE_UPDATE=false
DO_UNINSTALL=false
DRY_RUN=false
LIST_QUIRKS=false
INSTALLED_FILES=()
MOD_FOUND=false
GAME_ARGS=()
HAVE_7Z=0
FETCH_LAST_CODE=""
NET_DIAG_DONE=0
SEVENZIP=""

# Game Quirks default state (resolved per game)
QUIRK_OPTISCALER_DLL="dxgi.dll"
QUIRK_SKIP_OPTISCALER=false
QUIRK_SKIP_RESHADE=false
QUIRK_SKIP_DLSS_ENABLER=false
QUIRK_EXTRA_DLL_COPIES=""
QUIRKS_MATCHED=""

# Built-in Game Quirks database
# Key: normalized game title (lowercase, alphanumeric characters only)
# Value: semicolon-delimited key=value pairs
declare -A GAME_QUIRKS=(
    ["arknightsendfield"]="optiscaler_dll=d3d12.dll"
    ["endfield"]="optiscaler_dll=d3d12.dll"
    ["forspoken"]="optiscaler_dll=d3d12.dll"
    ["forzahorizon6"]="optiscaler_dll=d3d12.dll"
    ["atomicrops"]="skip_reshade=true"
    ["dysonsphereprogram"]="skip_reshade=true"
    ["minecraft"]="skip_reshade=true"
    ["immortalsofaveum"]="optiscaler_dll=d3d12.dll"                   # bypasses signature verification
    ["deadoralive6lastround"]="optiscaler_dll=d3d12.dll"              # only d3d12.dll or version.dll work, all else crashes
    ["marvelsmidnightsuns"]="optiscaler_dll=d3d12.dll"                # anti-cheat/anti-tamper blocks default naming
    ["asterigoscurseofthestars"]="optiscaler_dll=d3d12.dll"           # required for DLSS on Nvidia, else crash
    ["nevernesstoeverness"]="optiscaler_dll=d3d12.dll"                # (or version.dll — wiki lists both)
    ["zenlesszonezero"]="optiscaler_dll=d3d12.dll"                    # required, plus needs -use-d3d12 launch arg
    ["grandtheftautoiiidefinitiveedition"]="optiscaler_dll=d3d12.dll"       # "may be required" + -dx12 launch opt, City Glow off
    ["grandtheftautosanandreasdefinitiveedition"]="optiscaler_dll=d3d12.dll" # same caveats as GTA3 DE
    ["grandtheftautovicecitydefinitiveedition"]="optiscaler_dll=d3d12.dll"  # same caveats as GTA3 DE
    ["monsterhunterrise"]="optiscaler_dll=d3d12.dll"                        # wiki says "optimal", not strictly required
    ["neverforspeedunbound"]="optiscaler_dll=d3d12.dll"                     # only needed on Linux specifically (dxgi.dll on Windows)
)

COLOR_INFO='\033[36m'
COLOR_SUCCESS='\033[32m'
COLOR_WARN='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_BOLD='\033[1m'
COLOR_WHITE='\033[97m'
COLOR_RESET='\033[0m'

###############################################################################
# LOGGING (stdout is reserved for function return values; logs go to stderr)
###############################################################################

_log() {
    printf '%b\n' "$1" >&2
    if [[ -n "$LOG_FILE" ]]; then
        printf '%b\n' "$1" >>"$LOG_FILE" 2>/dev/null
    else
        LOG_BUFFER+=("$1")
    fi
}

# Point the log at the install directory and flush anything buffered so far.
set_log_dir() {
    [[ -d "$1" ]] || return 0
    LOG_FILE="$1/optidx.log"
    if (( ${#LOG_BUFFER[@]} )); then
        printf '%b\n' "${LOG_BUFFER[@]}" >>"$LOG_FILE" 2>/dev/null
        LOG_BUFFER=()
    fi
    return 0
}
info()    { _log "  ${COLOR_INFO}>>${COLOR_RESET} $*"; }
success() { _log "  ${COLOR_SUCCESS}✓${COLOR_RESET}  $*"; }
warn()    { _log "  ${COLOR_WARN}!${COLOR_RESET}  $*"; }
error()   { _log "  ${COLOR_ERROR}✗${COLOR_RESET}  $*"; }
die()     { error "$*"; exit 1; }

print_banner() {
    _log "\n${COLOR_BOLD}${COLOR_INFO}  ╔════════════════════════════════════════════╗
  ║    OptiScaler + RenoDX ( v$SCRIPT_VERSION)  ║
  ║    Heroic, Lutris, Steam & UE Mod Engine Powered by Linux  ║
  ╚════════════════════════════════════════════╝${COLOR_RESET}"
}

###############################################################################
# REQUIREMENTS
###############################################################################

check_requirements() {
    local missing=() cmd
    for cmd in curl unzip awk sed grep find; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        # As a Steam launch wrapper the script must never be the reason a game
        # fails to start: degrade to a pass-through instead of dying.
        if (( ${#GAME_ARGS[@]} )); then
            warn "Missing tools (${missing[*]}) - skipping mod setup and launching the game"
            return 1
        fi
        die "Missing required tools: ${missing[*]}"
    fi

    for cmd in 7z 7za 7zz; do
        if command -v "$cmd" >/dev/null 2>&1; then
            SEVENZIP="$cmd"; HAVE_7Z=1
            info "Found archive tool: $cmd"
            break
        fi
    done
    (( HAVE_7Z )) || warn "7z not found - OptiScaler/ReShade extraction will be skipped (install p7zip)"
}

###############################################################################
# NORMALISATION (pure bash, no subprocesses)
###############################################################################

norm() { local s="${1,,}"; printf '%s' "${s//[^a-z0-9]/}"; }

# GitHub and Steam return JSON that is sometimes pretty-printed and sometimes
# MINIFIED onto a single line. Line-oriented parsing must not depend on which.
# On a minified file a greedy `sed 's/.*"k".*"\(v\)".*/\1/'` matches the LAST
# occurrence in the whole document - that is how OptiScaler resolved to the
# oldest tag (edge-0.9.4-1, which has no release) and 404'd.
# Split between fields on the literal `","` sequence, which never occurs inside
# a JSON string value, so titles containing commas ("Warhammer 40,000: Space
# Marine 2") stay intact.
json_lines() { sed -e 's/","/"\n"/g' -e 's/[][{}]/\n/g' <"$1" 2>/dev/null; }

###############################################################################
# NETWORK
###############################################################################

# Steam launches games with LD_LIBRARY_PATH / LD_PRELOAD pointed at the Steam
# Runtime. A host binary such as curl then loads the runtime's glibc while the
# system's NSS resolver modules stay on the host, name resolution breaks, and
# every request dies before it leaves the machine (curl reports 000). That is
# why downloads succeed from a terminal but fail when the same script runs as a
# Steam launch wrapper. Steam preserves the original search path in
# SYSTEM_LD_LIBRARY_PATH; restore it, otherwise drop the variables entirely.
run_clean() {
    if [[ -n "${SYSTEM_LD_LIBRARY_PATH:-}" ]]; then
        LD_LIBRARY_PATH="$SYSTEM_LD_LIBRARY_PATH" LD_PRELOAD="" "$@"
    elif [[ -n "${LD_LIBRARY_PATH:-}${LD_PRELOAD:-}" ]] && command -v env >/dev/null 2>&1; then
        env -u LD_LIBRARY_PATH -u LD_PRELOAD "$@"
    else
        "$@"
    fi
}

# fetch URL OUTFILE [tries] - atomic; never leaves a truncated/empty file
fetch() {
    local url="$1" out="$2" tries="${3:-3}" i insecure=""
    # Optional: lifts the GitHub API limit from 60 to 5000 requests/hour. Only
    # ever sent to api.github.com, never to a mod-hosting mirror.
    local -a auth=()
    [[ -n "${GITHUB_TOKEN:-}" && "$url" == "https://api.github.com/"* ]] &&
        auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    for ((i = 1; i <= tries; i++)); do
        if run_clean curl -fsSL $insecure ${auth[@]+"${auth[@]}"} --connect-timeout 15 --max-time 600 \
                -A "$UA" "$url" -o "$out.part" 2>/dev/null && [[ -s "$out.part" ]]; then
            mv -f "$out.part" "$out"
            return 0
        fi
        rm -f "$out.part" 2>/dev/null
        # Some Proton/Flatpak sandboxes ship a broken CA bundle; retry unverified.
        if (( i == 1 )) && [[ -z "$insecure" ]]; then insecure="-k"; continue; fi
        (( i < tries )) && sleep 2
    done
    # Everything failed - probe once for a status code so the log explains WHY
    # instead of just "Failed to download".
    FETCH_LAST_CODE=$(run_clean curl -s -k -o /dev/null -w '%{http_code}' -A "$UA" \
                      --connect-timeout 10 --max-time 30 "$url" 2>/dev/null)
    return 1
}

# Run once, the first time a download fails, to say whether the Steam Runtime's
# library path is what is breaking name resolution.
net_diagnose() {
    (( NET_DIAG_DONE )) && return 0
    NET_DIAG_DONE=1
    [[ -z "${LD_LIBRARY_PATH:-}${STEAM_RUNTIME:-}${STEAM_COMPAT_DATA_PATH:-}" ]] && return 0
    local dirty clean probe="https://api.github.com/"
    dirty=$(curl -s -k -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$probe" 2>/dev/null)
    clean=$(run_clean curl -s -k -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$probe" 2>/dev/null)
    if [[ "$dirty" == "000" && "$clean" != "000" && -n "$clean" ]]; then
        info "Network only works with the Steam Runtime library path removed - downloads now use a clean environment"
    elif [[ "$clean" == "000" || -z "$clean" ]]; then
        warn "No network from inside the Steam Runtime (DNS unreachable, even with a clean library path)."
        warn "Workaround: run the script once from a terminal in the game folder to fill the cache, then relaunch from Steam:"
        warn "    cd \"$START_DIR\" && \"$0\" --update"
    fi
    return 0
}

fetch_reason() {
    case "${FETCH_LAST_CODE:-}" in
        000|"")  printf 'no connection - DNS or network unreachable' ;;
        403)     printf 'HTTP 403 - rate limited or blocked (set GITHUB_TOKEN to raise the API limit)' ;;
        404)     printf 'HTTP 404 - not found upstream' ;;
        429)     printf 'HTTP 429 - too many requests' ;;
        5??)     printf 'HTTP %s - upstream server error' "$FETCH_LAST_CODE" ;;
        *)       printf 'HTTP %s' "$FETCH_LAST_CODE" ;;
    esac
}

download_file() {
    local url="$1" output="$2" tries="${3:-3}"
    info "Downloading $(basename "$output")"
    if fetch "$url" "$output" "$tries"; then
        local sz
        sz=$(du -h "$output" 2>/dev/null | cut -f1)
        success "Downloaded $(basename "$output") (${sz:-ok})"
        return 0
    fi
    net_diagnose
    error "Failed to download $(basename "$output"): $(fetch_reason)"
    error "  $url"
    return 1
}

# cache_fetch URL CACHE_NAME MAX_AGE -> prints path to cached file
# Only replaces the cache on a successful download, so a transient failure
# can never poison the cache with an empty file.
cache_fetch() {
    local url="$1" name="$2" max_age="${3:-86400}"
    local cf="$CACHE_DIR/$name" age now mtime
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$cf" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [[ -s "$cf" ]] && (( age < max_age )); then
        printf '%s' "$cf"; return 0
    fi
    # Unique scratch name: cache_fetch is also called from concurrent warmers.
    local dl="$TMP_DIR/cache.$$.$RANDOM.dl"
    if fetch "$url" "$dl" 2 && [[ -s "$dl" ]]; then
        mv -f "$dl" "$cf"
        printf '%s' "$cf"; return 0
    fi
    rm -f "$dl" 2>/dev/null
    [[ -s "$cf" ]] && { printf '%s' "$cf"; return 0; }   # stale is better than nothing
    return 1
}

extract_archive() {
    local archive="$1" dest="${2:-.}"
    mkdir -p "$dest" 2>/dev/null
    case "${archive,,}" in
        *.zip)
            unzip -oq "$archive" -d "$dest" 2>/dev/null && return 0
            (( HAVE_7Z )) && "$SEVENZIP" x -y "$archive" "-o$dest" >/dev/null 2>&1 && return 0
            return 1 ;;
        *.7z|*.exe)
            (( HAVE_7Z )) || return 1
            "$SEVENZIP" x -y "$archive" "-o$dest" >/dev/null 2>&1 || return 1
            return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# AWK PROGRAMS
###############################################################################
# Written once into TMP_DIR. Between them they replace the ~1000 forked
# grep/sed/tr calls the previous tier loops performed per install.

write_awk_programs() {
    cat >"$TMP_DIR/mkindex.awk" <<'AWKINDEX'
# RenoDX wiki (Mods.md) -> index TSV
#   key_full  key_full_roman  key_short  key_short_roman  name  slug  ext  url
function spaced(s,   r) { r = tolower(s); gsub(/[^a-z0-9]+/, " ", r);
                          gsub(/^ +| +$/, "", r); return r }
function tight(s,    r) { r = s; gsub(/ /, "", r); return r }
function roman(s,   n, a, i, t, out) {
    n = split(s, a, " "); out = ""
    for (i = 1; i <= n; i++) {
        t = a[i]
        if      (t == "i")    t = "1";  else if (t == "ii")   t = "2"
        else if (t == "iii")  t = "3";  else if (t == "iv")   t = "4"
        else if (t == "v")    t = "5";  else if (t == "vi")   t = "6"
        else if (t == "vii")  t = "7";  else if (t == "viii") t = "8"
        else if (t == "ix")   t = "9";  else if (t == "x")    t = "10"
        out = out (out == "" ? "" : " ") t
    }
    return out
}
# The wiki's "# Deprecated mods" section says its entries are "either
# nonfunctional or have better alternative" (17 rows: Haste, Doom Eternal,
# Ace Combat 7, ...). They are still indexed, but flagged so a live mod always
# outranks them and the user is told when one is used.
# Matched loosely, and cleared by the next TOP-level heading, so renaming the
# section or adding a live one after it keeps behaving sensibly.
/^#+[[:space:]]/ {
    h = tolower($0)
    if (h ~ /deprecat|legacy|obsolete|retired|archiv|unsupported/) dead = 1
    else if ($0 ~ /^#[^#]/)                                        dead = 0
}

# Real table rows always begin with a pipe. The "### Unity Engine" section body
# carries a bare "64-bit:[![Snapshot](...)](...)" line that otherwise parses
# into a junk row named "![Snapshot".
/^[[:space:]]*\|/ {
    line = $0
    # Prefer the 64-bit asset on rows that list both.
    url = ""
    if (match(line, /https?:\/\/[^ )|]+\.addon64/))      url = substr(line, RSTART, RLENGTH)
    else if (match(line, /https?:\/\/[^ )|]+\.addon32/)) url = substr(line, RSTART, RLENGTH)
    if (url == "") next

    split(line, cell, "\\|")
    name = cell[2]
    if (name ~ /\[[^]]+\]\(/) { sub(/^[^[]*\[/, "", name); sub(/\].*$/, "", name) }
    gsub(/<[^>]*>/, "", name)
    gsub(/`/, "", name)
    sub(/^[ \t]+/, "", name); sub(/[ \t]+$/, "", name)
    if (name == "") next

    file = url; sub(/^.*\//, "", file)
    ext  = file; sub(/^.*\./, "", ext)
    slug = file; sub(/^renodx-/, "", slug); sub(/\.addon(64|32)$/, "", slug)

    sp = spaced(name)
    if (sp == "") next
    k1 = tight(sp); k2 = tight(roman(sp))
    if (k1 in seen) next
    seen[k1] = 1

    # "Main Title: Subtitle" -> also index the main title, but only when it is
    # substantial (>= 2 words), so "AI: The Somnium Files" never keys on "ai".
    k3 = ""; k4 = ""
    if (index(name, ":") > 0) {
        short = name; sub(/:.*$/, "", short); short = spaced(short)
        if (split(short, tok, " ") >= 2) { k3 = tight(short); k4 = tight(roman(short)) }
    }
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", k1, k2, k3, k4, name, slug, ext, url, (dead ? "1" : "")
}
AWKINDEX

    cat >"$TMP_DIR/match.awk" <<'AWKMATCH'
# file 1 = candidate titles (one per line, best first)
# file 2 = index TSV
# prints one 0x1F-separated record: score name slug ext url matched_candidate
# (0x1F rather than TAB: bash `read` collapses runs of TAB, which would shift
#  fields whenever an index column is legitimately empty.)
BEGIN { FS = "\t"; SEP = sprintf("%c", 31) }
function spaced(s,   r) { r = tolower(s); gsub(/[^a-z0-9]+/, " ", r);
                          gsub(/^ +| +$/, "", r); return r }
function tight(s,    r) { r = s; gsub(/ /, "", r); return r }
function roman(s,   n, a, i, t, out) {
    n = split(s, a, " "); out = ""
    for (i = 1; i <= n; i++) {
        t = a[i]
        if      (t == "i")    t = "1";  else if (t == "ii")   t = "2"
        else if (t == "iii")  t = "3";  else if (t == "iv")   t = "4"
        else if (t == "v")    t = "5";  else if (t == "vi")   t = "6"
        else if (t == "vii")  t = "7";  else if (t == "viii") t = "8"
        else if (t == "ix")   t = "9";  else if (t == "x")    t = "10"
        out = out (out == "" ? "" : " ") t
    }
    return out
}
# Deterministic, explainable scoring. No subsequence matching: a query only
# scores if it is equal to, a prefix of, or a contiguous substring of the key.
function score(q, k,   lq, lk, d, rest) {
    lq = length(q); lk = length(k)
    if (lq < 3 || lk < 3) return 0
    if (q == k) return 1000
    # A trailing number is a sequel marker, never noise: "dyinglight2" must not
    # match "dyinglight", nor "borderlands" match "borderlands2".
    # A partial match must also COVER most of the longer string. Without this,
    # a stray 5-char parent directory ("final") prefixes "finalfantasy10" and
    # hijacks the install. Coverage is the real signal; raw distance is not.
    if (lq >= 5 && lk > lq && substr(k, 1, lq) == q) {
        rest = substr(k, lq + 1); if (rest ~ /^[0-9]+$/) return 0
        if (lq / lk < 0.45) return 0
        d = lk - lq; return d <= 24 ? 900 - d : 0
    }
    if (lk >= 5 && lq > lk && substr(q, 1, lk) == k) {
        rest = substr(q, lk + 1); if (rest ~ /^[0-9]+$/) return 0
        if (lk / lq < 0.45) return 0
        d = lq - lk; return d <= 24 ? 880 - d : 0
    }
    if (lq >= 7 && index(k, q) > 0 && lq / lk >= 0.55) { d = lk - lq; return d <= 18 ? 760 - d : 0 }
    if (lk >= 7 && index(q, k) > 0 && lk / lq >= 0.55) { d = lq - lk; return d <= 18 ? 740 - d : 0 }
    return 0
}
NR == FNR {
    if ($0 == "") next
    sp = spaced($0); if (sp == "") next
    nc++; qtext[nc] = $0
    qk[nc, 1] = tight(sp); qk[nc, 2] = tight(roman(sp))
    next
}
{ nr++; K[nr,1]=$1; K[nr,2]=$2; K[nr,3]=$3; K[nr,4]=$4
  NM[nr]=$5; SL[nr]=$6; EX[nr]=$7; UR[nr]=$8; DP[nr]=$9 }

# Candidates are ordered strongest-evidence-first (Steam store title, launcher
# title, manifest name, game folder, ... exe name). Resolve strictly in that
# order and stop at the first candidate that clears the threshold, rather than
# pooling every candidate and letting a weak one out-score a strong one - an
# exe named "DyingLightGame.exe" must not override a "Dying Light 2" folder.
END {
    for (c = 1; c <= nc; c++) {
        best = 0; br = 0
        for (r = 1; r <= nr; r++) {
            for (v = 1; v <= 2; v++) {
                q = qk[c, v]; if (q == "") continue
                for (f = 1; f <= 4; f++) {
                    k = K[r, f]; if (k == "") continue
                    s = score(q, k)
                    if (s <= 0) continue
                    if (f >= 3) s -= 30          # short-title key is weaker evidence
                    # Deprecation breaks TIES only. Scoring it down instead lets
                    # a different game win outright: "Dying Light 2 Stay Human"
                    # scored 871 on the (deprecated) dyinglight2 row and 870 on
                    # the live dyinglight row, so a -150 penalty installed
                    # Dying Light 1's addon into Dying Light 2.
                    if (s > best) { best = s; br = r }
                    else if (s == best && br > 0 && DP[br] == "1" && DP[r] != "1") br = r
                }
            }
        }
        if (best >= MINSCORE && br > 0) {
            printf "%d%s%s%s%s%s%s%s%s%s%s%s%s\n", best, SEP, NM[br], SEP, SL[br], SEP,
                   EX[br], SEP, UR[br], SEP, qtext[c], SEP, DP[br]
            exit
        }
    }
}
AWKMATCH
}

###############################################################################
# TITLE SOURCES
###############################################################################

add_candidate_title() {
    local raw="${1-}"
    [[ -z "$raw" ]] && return 0
    local clean="${raw//\"/}"
    clean="${clean//[-_]/ }"
    clean="${clean#"${clean%%[![:space:]]*}"}"
    clean="${clean%"${clean##*[![:space:]]}"}"
    (( ${#clean} < 3 )) && return 0

    local nc existing
    nc=$(norm "$clean")
    [[ -z "$nc" ]] && return 0
    if (( ${#CANDIDATE_TITLES[@]} )); then
        for existing in "${CANDIDATE_TITLES[@]}"; do
            [[ "$(norm "$existing")" == "$nc" ]] && return 0
        done
    fi
    CANDIDATE_TITLES+=("$clean")
}

# Walk upwards looking for a Steam library root (a dir containing steamapps/).
find_steam_library() {
    # Parameter expansion instead of basename/dirname: this loop runs up to 8
    # times and those would be 16 forks on the game-launch critical path.
    local d="$START_DIR" parent i
    for ((i = 0; i < 8; i++)); do
        [[ -d "$d/steamapps" ]] && { printf '%s' "$d/steamapps"; return 0; }
        [[ "${d##*/}" == "steamapps" ]] && { printf '%s' "$d"; return 0; }
        parent="${d%/*}"
        [[ -z "$parent" ]] && parent="/"
        [[ "$parent" == "$d" ]] && break
        d="$parent"
    done
    return 1
}

# Name of the steamapps/common/<X> folder this game lives in.
steam_install_dir_name() {
    local p="$START_DIR"
    [[ "$p" =~ steamapps/common/([^/]+) ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
    return 1
}

detect_steam_appid() {
    # Ubisoft/EA/Epic titles frequently ship a steam_appid.txt containing "0",
    # which is not a real AppID - accepting it triggers a pointless storefront
    # lookup and reports a bogus "Detected Steam AppID: 0".
    local f
    for f in "steam_appid.txt" "../steam_appid.txt" "../../steam_appid.txt"; do
        if [[ -f "$f" ]]; then
            STEAM_APPID=$(tr -cd '0-9' <"$f" 2>/dev/null)
            [[ "$STEAM_APPID" =~ ^0*$ ]] && STEAM_APPID=""
            [[ -n "$STEAM_APPID" ]] && return 0
        fi
    done

    if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" && "$STEAM_COMPAT_DATA_PATH" == */compatdata/* ]]; then
        local t="${STEAM_COMPAT_DATA_PATH##*/compatdata/}"
        STEAM_APPID="${t%%/*}"
        STEAM_APPID="${STEAM_APPID//[^0-9]/}"
        [[ -n "$STEAM_APPID" ]] && return 0
    fi
    if [[ -n "${SteamAppId:-}" ]]; then
        STEAM_APPID="${SteamAppId//[^0-9]/}"
        [[ -n "$STEAM_APPID" ]] && return 0
    fi
    if [[ -n "${SteamGameId:-}" ]]; then
        STEAM_APPID="${SteamGameId//[^0-9]/}"
        [[ -n "$STEAM_APPID" ]] && return 0
    fi

    # Last resort: find the appmanifest whose installdir matches our folder.
    local lib dirname_ acf
    lib=$(find_steam_library) || return 0
    dirname_=$(steam_install_dir_name) || return 0
    for acf in "$lib"/appmanifest_*.acf; do
        [[ -f "$acf" ]] || continue
        if grep -qiF "\"$dirname_\"" "$acf" 2>/dev/null; then
            local b="${acf##*/}"; b="${b#appmanifest_}"
            STEAM_APPID="${b%%.acf}"
            return 0
        fi
    done
    return 0
}

detect_steam_store_title() {
    [[ -z "$STEAM_APPID" ]] && return 0
    local cf
    cf=$(cache_fetch "https://store.steampowered.com/api/appdetails?appids=${STEAM_APPID}&filters=basic" \
                     "steam_${STEAM_APPID}.json" 604800) || return 0
    # "name":"..." - portable, no grep -P
    STEAM_STORE_TITLE=$(json_lines "$cf" |
                        sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [[ -n "$STEAM_STORE_TITLE" ]] &&
        info "Steam Store title for AppID $STEAM_APPID: $STEAM_STORE_TITLE"
    return 0
}

extract_steam_manifest_title() {
    local lib acf="" dirname_
    lib=$(find_steam_library) || return 0
    if [[ -n "$STEAM_APPID" && -f "$lib/appmanifest_${STEAM_APPID}.acf" ]]; then
        acf="$lib/appmanifest_${STEAM_APPID}.acf"
    else
        dirname_=$(steam_install_dir_name) || return 0
        local f
        for f in "$lib"/appmanifest_*.acf; do
            [[ -f "$f" ]] || continue
            grep -qiF "\"$dirname_\"" "$f" 2>/dev/null && { acf="$f"; break; }
        done
    fi
    [[ -z "$acf" ]] && return 0
    # NOTE: v3.5 used '"name"s*"K[^"]+' here - the backslashes had been lost, so
    # this always returned empty and the manifest title was never used.
    sed -n 's/.*"name"[[:space:]]*"\([^"]*\)".*/\1/p' "$acf" 2>/dev/null | head -1
    return 0
}

detect_heroic_lutris_bottles() {
    LAUNCHER_TITLE="${HEROIC_APP_TITLE:-${HEROIC_APP_NAME:-${LUTRIS_GAME_NAME:-${BOTTLES_GAME_NAME:-${BOTTLE_NAME:-${LUTRIS_GAME_SLUG:-}}}}}}"
    [[ -n "$LAUNCHER_TITLE" ]] && return 0

    # Scanning Heroic's library is a guess driven by directory names. If Steam
    # has already identified the game, that is authoritative - doing this anyway
    # made a Steam copy of Control resolve to an unrelated Heroic entry
    # ("Showgunners") and become the primary title.
    [[ -n "$STEAM_APPID" ]] && return 0

    local base h_dir f found
    base="${START_DIR##*/}"
    for h_dir in "${XDG_CONFIG_HOME:-$HOME/.config}/heroic" \
                 "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic"; do
        [[ -d "$h_dir" ]] || continue
        for f in "$h_dir"/gamelist.json "$h_dir"/store_cache/*.json "$h_dir"/GamesConfig/*.json; do
            [[ -f "$f" ]] || continue
            # NOTE: v3.5 used '"title":s*"K[^"]+' - also missing its backslashes.
            # Anchor on the full install path first - that identifies exactly one
            # library entry. Only fall back to the folder name, and then match it
            # QUOTED ("Control") so it hits a JSON value rather than any line
            # merely containing the word (e.g. "useSteamController").
            found=$(json_lines "$f" | grep -iF -B 60 "$START_DIR" 2>/dev/null |
                    sed -n 's/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -1)
            [[ -z "$found" ]] && found=$(json_lines "$f" | grep -iF -B 12 "\"$base\"" 2>/dev/null |
                    sed -n 's/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -1)
            if [[ -n "$found" ]]; then
                LAUNCHER_TITLE="$found"
                info "Extracted title from Heroic config: $LAUNCHER_TITLE"
                return 0
            fi
        done
    done
    return 0
}

extract_pe_product_name() {
    local exe="$1" name=""
    [[ -f "$exe" ]] || return 0
    command -v strings >/dev/null 2>&1 || return 0
    local field
    for field in ProductName FileDescription; do
        name=$(strings -e l "$exe" 2>/dev/null | grep -A 1 -iF "$field" | tail -1 |
               tr -cd '[:alnum:] :&!'"'" | sed 's/^ *//; s/ *$//')
        (( ${#name} >= 3 )) && { printf '%s' "$name"; return 0; }
    done
    return 0
}

# Read the PE header to learn whether the game is 32- or 64-bit: e_lfanew at
# offset 0x3C points at "PE\0\0", followed by the 2-byte Machine field.
# Prints "32", "64", or nothing.
detect_exe_bitness() {
    local exe="$1" off machine
    [[ -f "$exe" ]] || return 0
    command -v od >/dev/null 2>&1 || return 0
    off=$(od -An -tu4 -j60 -N4 "$exe" 2>/dev/null | tr -d ' ')
    [[ "$off" =~ ^[0-9]+$ ]] || return 0
    machine=$(od -An -tx2 -j$((off + 4)) -N2 "$exe" 2>/dev/null | tr -d ' ')
    case "$machine" in
        8664|aa64) printf '64' ;;
        014c|01c4) printf '32' ;;
    esac
    return 0
}

###############################################################################
# GAME DETECTION
###############################################################################

detect_game() {
    info "Detecting game executable..."
    detect_steam_appid
    detect_heroic_lutris_bottles

    [[ "$STEAM_APPID" =~ ^0*$ ]] && STEAM_APPID=""      # "0" is a placeholder, not an AppID
    [[ -n "$STEAM_APPID" ]] && { info "Detected Steam AppID: $STEAM_APPID"; detect_steam_store_title; }
    [[ -n "$LAUNCHER_TITLE" ]] && info "Detected Launcher Title: $LAUNCHER_TITLE"

    # ONE filesystem walk that also carries each file's size, instead of a walk
    # plus a basename+stat fork per candidate (~400 processes on a large game).
    # Unity detection rides along in the same pass rather than re-walking.
    local best_exe="" best_score=-9999 exe base lower score size
    local find_out
    find_out=$(find . -maxdepth 7 -type f \( -iname "*.exe" -o -iname "UnityPlayer.dll" \) \
                    -printf '%s\t%p\n' 2>/dev/null | head -500)
    # Busybox/BSD find has no -printf; fall back to paths only (size term drops out).
    [[ -z "$find_out" ]] && find_out=$(find . -maxdepth 7 -type f \( -iname "*.exe" -o -iname "UnityPlayer.dll" \) \
                                            2>/dev/null | head -500 | sed 's/^/0\t/')

    while IFS=$'\t' read -r size exe; do
        [[ -z "$exe" ]] && continue
        base="${exe##*/}"
        lower="${base,,}"

        if [[ "$lower" == "unityplayer.dll" ]]; then GAME_IS_UNITY=true; continue; fi
        [[ "$lower" == *.exe ]] || continue
        [[ "$lower" =~ $UE_IGNORE_REGEX ]] && continue

        score=100
        [[ "$lower" == *shipping.exe ]]  && score=$(( score + 100 ))
        [[ "$lower" == *game.exe ]]      && score=$(( score + 50 ))
        [[ "$lower" == *win64* ]]        && score=$(( score + 20 ))
        # Path tests are case-insensitive: some titles ship binaries/win64.
        [[ "${exe,,}" == */binaries/win64/* ]] && score=$(( score + 40 ))
        [[ "${exe,,}" == */engine/* ]]         && score=$(( score - 60 ))
        [[ "$lower" == *launcher*.exe ]]       && score=$(( score - 60 ))
        # Anti-cheat launcher shims sit beside the real binary and are often
        # marginally larger, which was enough to win on size alone.
        [[ "$lower" == *eac-win64* || "$lower" == *_eac.exe || "$lower" == *-eac.exe ]] &&
            score=$(( score - 120 ))
        # Prefer the plain project binary over decorated siblings
        # (Proj-Win64-Shipping beats ProjServer-/ProjEAC-Win64-Shipping).
        score=$(( score - ${#base} / 2 ))

        # Cap the size contribution so a big non-game binary cannot outrank a
        # correctly-identified shipping executable.
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        size=$(( size / 10000000 ))
        (( size > 30 )) && size=30
        score=$(( score + size ))

        if (( score > best_score )); then best_score=$score; best_exe="$exe"; fi
    done <<< "$find_out"

    [[ -z "$best_exe" ]] && return 1

    GAME_EXE="$best_exe"
    GAME_DIR="$(cd "$(dirname "$best_exe")" 2>/dev/null && pwd)" || GAME_DIR="$START_DIR"

    local raw_name clean_exe_name
    raw_name="${best_exe##*/}"; raw_name="${raw_name%.[eE][xX][eE]}"
    clean_exe_name=$(printf '%s' "$raw_name" | sed -E 's/[-_ ]*(Win64|Win32|Shipping|Game|Demo|Client|Launcher)//gi')

    # --- candidate titles, strongest evidence first -------------------------
    add_candidate_title "$STEAM_STORE_TITLE"
    add_candidate_title "$LAUNCHER_TITLE"

    local manifest_title
    manifest_title=$(extract_steam_manifest_title)
    [[ -n "$manifest_title" ]] && {
        info "Extracted title from Steam appmanifest: $manifest_title"
        add_candidate_title "$manifest_title"
    }

    # Folder hierarchy, nearest first.
    local current="$START_DIR" folder parent depth
    for ((depth = 0; depth < 4; depth++)); do
        folder="${current##*/}"
        parent="${current%/*}"; [[ -z "$parent" ]] && parent="/"
        [[ -z "$folder" || "$folder" == "/" || "$folder" == "." ]] && break
        if (( depth == 0 )); then
            [[ ! "${folder,,}" =~ ^(binaries|win64|win32|engine|contents)$ ]] && add_candidate_title "$folder"
        else
            [[ ! "${folder,,}" =~ $SYSTEM_DIR_REGEX ]] && (( ${#folder} >= 3 )) && add_candidate_title "$folder"
        fi
        [[ "$parent" == "$current" ]] && break
        current="$parent"
    done

    local pe_title
    pe_title=$(extract_pe_product_name "$best_exe")
    [[ -n "$pe_title" ]] && {
        info "Extracted PE Product Name: $pe_title"
        add_candidate_title "$pe_title"
    }

    add_candidate_title "$clean_exe_name"

    if (( ${#CANDIDATE_TITLES[@]} == 0 )); then
        add_candidate_title "$raw_name"
        (( ${#CANDIDATE_TITLES[@]} == 0 )) && CANDIDATE_TITLES=("$raw_name")
    fi

    GAME_NAME="${CANDIDATE_TITLES[0]}"
    GAME_KEY="$(norm "$GAME_NAME")"
    GAME_DISPLAY="$GAME_NAME"

    if [[ "$raw_name" == *-Win64-Shipping || "$raw_name" == *-Shipping || "$best_exe" == */Binaries/Win64/* ]]; then
        GAME_IS_UE=true
        info "Unreal Engine architecture confirmed"
    fi
    # UnityPlayer.dll was already picked up by the single scan above; the crash
    # handler is only consulted if that missed, and it is in UE_IGNORE_REGEX so
    # it never reaches the exe scoring.
    if [[ "$GAME_IS_UNITY" == false ]] &&
       compgen -G "./UnityCrashHandler*.exe" >/dev/null 2>&1; then
        GAME_IS_UNITY=true
    fi
    [[ "$GAME_IS_UNITY" == true ]] && info "Unity engine detected"

    GAME_BITS=$(detect_exe_bitness "$best_exe")
    [[ -n "$GAME_BITS" ]] && info "Executable architecture: ${GAME_BITS}-bit"

    success "Detected Game: ${COLOR_BOLD}${COLOR_WHITE}$GAME_DISPLAY${COLOR_RESET}"
    info "Candidate titles: $(printf "'%s' " "${CANDIDATE_TITLES[@]}")"
    return 0
}

###############################################################################
# GAME QUIRKS SYSTEM
###############################################################################

USER_QUIRKS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/optidx/quirks.conf"

resolve_game_quirks() {
    QUIRK_OPTISCALER_DLL="dxgi.dll"
    QUIRK_SKIP_OPTISCALER=false
    QUIRK_SKIP_RESHADE=false
    QUIRK_SKIP_DLSS_ENABLER=false
    QUIRK_EXTRA_DLL_COPIES=""
    QUIRKS_MATCHED=""

    local title title_key quirk_str="" src=""

    # 1. Load user config overrides if present
    local -a user_keys=() user_vals=()
    if [[ -f "$USER_QUIRKS_CONF" ]]; then
        local line k v
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == "#"* ]] && continue
            k=$(norm "${line%%[[:space:]]*}")
            v="${line#*[[:space:]]}"
            v="${v#"${v%%[![:space:]]*}"}"
            [[ -n "$k" && -n "$v" ]] && { user_keys+=("$k"); user_vals+=("$v"); }
        done <"$USER_QUIRKS_CONF"
    fi

    # 2. Match candidates against user config first, then built-in database
    for title in "${CANDIDATE_TITLES[@]}"; do
        title_key=$(norm "$title")
        [[ -z "$title_key" ]] && continue

        if (( ${#user_keys[@]} )); then
            local i
            for (( i=0; i<${#user_keys[@]}; i++ )); do
                if [[ "${user_keys[i]}" == "$title_key" ]]; then
                    quirk_str="${user_vals[i]}"
                    src="user config ($USER_QUIRKS_CONF)"
                    QUIRKS_MATCHED="$title"
                    break
                fi
            done
        fi

        if [[ -z "$quirk_str" && -n "${GAME_QUIRKS[$title_key]:-}" ]]; then
            quirk_str="${GAME_QUIRKS[$title_key]}"
            src="built-in database"
            QUIRKS_MATCHED="$title"
        fi

        [[ -n "$quirk_str" ]] && break
    done

    [[ -z "$quirk_str" ]] && return 0

    info "Applied game quirk for '${COLOR_BOLD}${COLOR_WHITE}${QUIRKS_MATCHED}${COLOR_RESET}' (from $src): $quirk_str"

    local kv pair_key pair_val
    IFS=';' read -ra pairs <<< "$quirk_str"
    for kv in "${pairs[@]}"; do
        kv="${kv#"${kv%%[![:space:]]*}"}"
        kv="${kv%"${kv##*[![:space:]]}"}"
        [[ -z "$kv" || "$kv" != *"="* ]] && continue
        pair_key="${kv%%=*}"
        pair_val="${kv#*=}"
        pair_key="${pair_key,,}"
        case "$pair_key" in
            optiscaler_dll)    QUIRK_OPTISCALER_DLL="$pair_val" ;;
            skip_optiscaler)   [[ "$pair_val" == "1" || "$pair_val" == "true" ]] && QUIRK_SKIP_OPTISCALER=true ;;
            skip_reshade)      [[ "$pair_val" == "1" || "$pair_val" == "true" ]] && QUIRK_SKIP_RESHADE=true ;;
            skip_dlss_enabler) [[ "$pair_val" == "1" || "$pair_val" == "true" ]] && QUIRK_SKIP_DLSS_ENABLER=true ;;
            extra_dll_copies)  QUIRK_EXTRA_DLL_COPIES="$pair_val" ;;
        esac
    done

    if [[ "$QUIRK_OPTISCALER_DLL" != "dxgi.dll" ]]; then
        info "Quirk override: OptiScaler proxy DLL set to '${COLOR_BOLD}${COLOR_WHITE}${QUIRK_OPTISCALER_DLL}${COLOR_RESET}'"
    fi
    return 0
}

list_all_quirks() {
    print_banner
    _log "\n${COLOR_BOLD}${COLOR_WHITE}Built-in Game Quirks Database:${COLOR_RESET}"
    local k
    for k in "${!GAME_QUIRKS[@]}"; do
        printf '  %b%-24s%b -> %s\n' "$COLOR_INFO" "$k" "$COLOR_RESET" "${GAME_QUIRKS[$k]}" >&2
    done
    if [[ -f "$USER_QUIRKS_CONF" ]]; then
        _log "\n${COLOR_BOLD}${COLOR_WHITE}User Game Quirks ($USER_QUIRKS_CONF):${COLOR_RESET}"
        cat "$USER_QUIRKS_CONF" >&2
    else
        _log "\n${COLOR_INFO}User config file not present ($USER_QUIRKS_CONF)${COLOR_RESET}"
    fi
}

###############################################################################
# RENODX RESOLUTION
###############################################################################

# Build (and cache) the wiki index: one awk pass, refreshed daily.
renodx_index() {
    local idx="$CACHE_DIR/renodx_index.tsv" md now mtime
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$idx" 2>/dev/null || echo 0)
    if [[ -s "$idx" ]] && (( now - mtime < 86400 )); then
        printf '%s' "$idx"; return 0
    fi
    if md=$(cache_fetch "$RENODX_WIKI" "renodx_mods.md" 86400); then
        if awk -f "$TMP_DIR/mkindex.awk" "$md" >"$TMP_DIR/idx.tmp" 2>/dev/null && [[ -s "$TMP_DIR/idx.tmp" ]]; then
            mv -f "$TMP_DIR/idx.tmp" "$idx"
        fi
    fi
    [[ -s "$idx" ]] && { printf '%s' "$idx"; return 0; }
    return 1
}

# Slugs published by the aggregated snapshot mirror: "slug<TAB>ext", 64-bit
# preferred. Covers a handful of games whose wiki row is Nexus-only.
renodx_mirror_index() {
    local out="$CACHE_DIR/renodx_mirror.tsv" json now mtime
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$out" 2>/dev/null || echo 0)
    if [[ -s "$out" ]] && (( now - mtime < 21600 )); then
        printf '%s' "$out"; return 0
    fi
    # Pinned "snapshot" tag first, newest release as a fallback if it is ever
    # renamed - the mirror is an optimisation, so failure here is never fatal.
    json=$(cache_fetch "$RENODX_MIRROR_API" "renodx_mirror.json" 21600) ||
    json=$(cache_fetch "https://api.github.com/repos/marat569/renodx/releases?per_page=3" \
                       "renodx_mirror_alt.json" 21600) || json=""
    if [[ -n "$json" ]]; then
        grep -oE '"name": *"renodx-[^"]+\.addon(64|32)"' "$json" 2>/dev/null |
            sed 's/.*"\(renodx-[^"]*\)"/\1/' |
            awk '{ f=$0; sub(/^renodx-/,"",f); ext=f; sub(/^.*\./,"",ext);
                   slug=f; sub(/\.addon(64|32)$/,"",slug);
                   if (!(slug in best) || ext == "addon64") { best[slug]=ext } }
                 END { for (s in best) printf "%s\t%s\n", s, best[s] }' >"$TMP_DIR/mir.tmp" 2>/dev/null
        [[ -s "$TMP_DIR/mir.tmp" ]] && mv -f "$TMP_DIR/mir.tmp" "$out"
    fi
    [[ -s "$out" ]] && { printf '%s' "$out"; return 0; }
    return 1
}

# Install renodx-<slug>.<ext>: aggregated GitHub mirror first, then the wiki's
# own per-maintainer URL (the wiki spreads links across 14 different hosts,
# and neither source is a superset of the other).
install_addon() {
    local slug="$1" ext="$2" wiki_url="${3-}" label="$4"

    info "Resolved to: ${COLOR_BOLD}${COLOR_WHITE}${label}${COLOR_RESET}"

    # The mirror publishes both variants for every slug, so when a wiki row
    # offers both (Dishonored) prefer the one matching the game's real PE
    # architecture; otherwise honour the row's own extension.
    local -a order=("$ext")
    if [[ -n "$GAME_BITS" && "addon${GAME_BITS}" != "$ext" ]]; then
        order=("addon${GAME_BITS}" "$ext")
    fi

    # 51 of the wiki's slugs are absent from the snapshot mirror, and the
    # maintainer GitHub Pages hosts visibly rate-limit under rapid probing.
    # Consult the mirror's published asset list (already cached for the
    # secondary matcher) instead of discovering absence via two failed fetches.
    local mir on_mirror=1
    if mir=$(renodx_mirror_index); then
        awk -F'\t' -v s="$slug" '$1 == s { found = 1 } END { exit !found }' "$mir" || on_mirror=0
    fi

    local e file
    if (( on_mirror )); then
        for e in "${order[@]}"; do
            file="renodx-${slug}.${e}"
            if fetch "$RENODX_BASE/$file" "$file" 2; then
                success "Installed RenoDX: $file (snapshot mirror)"
                track "$file"; MOD_FOUND=true; return 0
            fi
        done
    fi
    if [[ -n "$wiki_url" ]] && fetch "$wiki_url" "renodx-${slug}.${ext}" 2; then
        success "Installed RenoDX: renodx-${slug}.${ext} (maintainer host)"
        track "renodx-${slug}.${ext}"; MOD_FOUND=true; return 0
    fi
    if (( ! on_mirror )); then           # mirror not indexed for this slug - try anyway
        for e in "${order[@]}"; do
            file="renodx-${slug}.${e}"
            if fetch "$RENODX_BASE/$file" "$file" 2; then
                success "Installed RenoDX: $file (snapshot mirror)"
                track "$file"; MOD_FOUND=true; return 0
            fi
        done
    fi
    error "Found a match ($label) but every download source failed"
    return 1
}

find_renodx_mod() {
    [[ "$LUMA_ONLY" == true ]] && return 0
    (( ${#CANDIDATE_TITLES[@]} )) || return 0
    info "Searching for RenoDX mod..."

    local idx
    if ! idx=$(renodx_index); then
        warn "Could not obtain the RenoDX wiki index ($(fetch_reason))"
        return 0
    fi
    info "Wiki index: $(wc -l <"$idx" | tr -d ' ') games"

    printf '%s\n' "${CANDIDATE_TITLES[@]}" >"$TMP_DIR/cands.txt"

    # --- primary: official wiki Name column ---------------------------------
    local hit score name slug ext url matched dep
    hit=$(awk -v MINSCORE="$MIN_SCORE" -f "$TMP_DIR/match.awk" "$TMP_DIR/cands.txt" "$idx" 2>/dev/null)
    if [[ -n "$hit" ]]; then
        IFS=$'\037' read -r score name slug ext url matched dep <<<"$hit"
        [[ "$dep" == "1" ]] &&
            warn "The wiki lists this mod under 'Deprecated' (nonfunctional or superseded) - installing anyway"
        install_addon "$slug" "$ext" "$url" "$name  [matched '$matched', score $score]" && return 0
    fi

    # --- secondary: exact hit against a mirror slug --------------------------
    local mir
    if mir=$(renodx_mirror_index); then
        local t tn mslug mext
        for t in "${CANDIDATE_TITLES[@]}"; do
            tn=$(norm "$t")
            (( ${#tn} < 5 )) && continue
            [[ "$MIRROR_BLOCKLIST" == *" $tn "* ]] && continue
            while IFS=$'\t' read -r mslug mext; do
                [[ -z "$mslug" ]] && continue
                [[ "$MIRROR_BLOCKLIST" == *" $mslug "* ]] && continue
                if [[ "$(norm "$mslug")" == "$tn" ]]; then
                    install_addon "$mslug" "$mext" "" "$t  [exact snapshot slug]" && return 0
                fi
            done <"$mir"
        done
    fi

    info "No RenoDX mod matched confidently for this game"
    return 0
}

###############################################################################
# LUMA
###############################################################################

find_luma_mod() {
    [[ "$RENODX_ONLY" == true || "$MOD_FOUND" == true ]] && return 0
    (( ${#CANDIDATE_TITLES[@]} )) || return 0

    local json
    json=$(cache_fetch "https://api.github.com/repos/$REPO_LUMA/releases/latest" "luma_release.json" 3600) || return 0

    # Pair each asset name with its download URL, then build a pseudo-index in
    # the same 8-column shape the shared scorer expects.
    #   * "-Test" builds and engine-wide bundles are excluded.
    #   * "-x32" is NOT excluded outright: for some games (BioShock Series,
    #     Borderlands 2) it is the only build that exists. It is normalised to
    #     the same key as the 64-bit build and only used if nothing else won.
    awk '
        /"name": *"[^"]+\.zip"/ {
            if (match($0, /"[A-Za-z0-9][^"]*\.zip"/)) nm = substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        /"browser_download_url":/ {
            if (nm != "" && match($0, /"https?:\/\/[^"]+\.zip"/))
                printf "%s\t%s\n", nm, substr($0, RSTART + 1, RLENGTH - 2)
            nm = ""
        }
    ' < <(json_lines "$json") >"$TMP_DIR/luma.tsv" 2>/dev/null
    [[ -s "$TMP_DIR/luma.tsv" ]] || return 0

    awk -F'\t' '
        function spaced(s,  r){ r=tolower(s); gsub(/[^a-z0-9]+/," ",r); gsub(/^ +| +$/,"",r); return r }
        function tight(s,   r){ r=s; gsub(/ /,"",r); return r }
        $1 ~ /-Test|Generic|Unreal_Engine|Unity_Engine|Graphics_Analyzer/ { next }
        {
            base = $1
            sub(/\.zip$/, "", base)
            sub(/^Luma[-_]/, "", base)
            is32 = (base ~ /-x32$/)
            sub(/-x32$/, "", base)
            k = tight(spaced(base))
            if (k == "") next
            if ((k in seen) && !(seen[k] == 32 && !is32)) next   # 64-bit wins
            seen[k] = is32 ? 32 : 64
            name[k] = $1; url[k] = $2
        }
        END { for (k in name) printf "%s\t%s\t\t\t%s\t%s\t%s\t%s\n", k, k, name[k], "luma", "zip", url[k] }
    ' "$TMP_DIR/luma.tsv" >"$TMP_DIR/luma_idx.tsv" 2>/dev/null
    [[ -s "$TMP_DIR/luma_idx.tsv" ]] || return 0

    printf '%s\n' "${CANDIDATE_TITLES[@]}" >"$TMP_DIR/cands.txt"
    local hit score name _slug _ext url matched _dep
    hit=$(awk -v MINSCORE="$MIN_SCORE" -f "$TMP_DIR/match.awk" "$TMP_DIR/cands.txt" "$TMP_DIR/luma_idx.tsv" 2>/dev/null)
    [[ -z "$hit" ]] && return 0
    IFS=$'\037' read -r score name _slug _ext url matched _dep <<<"$hit"

    info "Found Luma mod: $name  [matched '$matched', score $score]"
    if download_file "$url" "$TMP_DIR/luma-mod.zip" 2 && extract_archive "$TMP_DIR/luma-mod.zip" "$TMP_DIR/luma"; then
        local a found=false
        # Luma ships its payload as a PLAIN ".addon" (e.g.
        # "Luma-Batman Arkham Knight.addon"), not .addon64/.addon32 - v3.5 only
        # looked for the latter, so a successful install always reported failure.
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            cp -f "$a" "./${a##*/}" 2>/dev/null && { found=true; track "${a##*/}"; }
        done < <(find "$TMP_DIR/luma" -type f \( -name "*.addon" -o -name "*.addon64" -o -name "*.addon32" \) 2>/dev/null)

        if [[ "$found" == true ]]; then
            # Shader/companion directory the addon loads at runtime.
            [[ -d "$TMP_DIR/luma/Luma" ]] && cp -rf "$TMP_DIR/luma/Luma" . 2>/dev/null && track "Luma"
            # Luma bundles its own proxy. Installing it over the top of
            # OptiScaler's proxy would silently disable OptiScaler, so only
            # take it when nothing else has claimed that slot.
            if [[ ! -f "$QUIRK_OPTISCALER_DLL" && -f "$TMP_DIR/luma/dxgi.dll" ]]; then
                cp -f "$TMP_DIR/luma/dxgi.dll" "$QUIRK_OPTISCALER_DLL" 2>/dev/null &&
                    { track "$QUIRK_OPTISCALER_DLL"; info "Installed Luma's $QUIRK_OPTISCALER_DLL proxy (no OptiScaler present)"; }
            elif [[ -f "$QUIRK_OPTISCALER_DLL" && -f "$TMP_DIR/luma/dxgi.dll" ]]; then
                warn "Kept OptiScaler's $QUIRK_OPTISCALER_DLL; Luma's proxy was not installed"
            fi
            MOD_FOUND=true
            success "Installed Luma mod ($name)"
            return 0
        fi
        warn "Luma archive contained no addon file"
    fi
    return 0
}

install_engine_fallback() {
    [[ "$MOD_FOUND" == true || "$LUMA_ONLY" == true ]] && return 0

    if [[ "$GAME_IS_UE" == true ]]; then
        info "UE game - applying generic RenoDX UE addon"
        if fetch "$RENODX_UE_FALLBACK" "renodx-ue-extended.addon64" 2; then
            success "Installed RenoDX UE extended fallback"
            track "renodx-ue-extended.addon64"; MOD_FOUND=true; return 0
        fi
        warn "UE fallback download failed"
    fi

    if [[ "$GAME_IS_UNITY" == true ]]; then
        info "Unity game - applying generic RenoDX Unity addon"
        # NOTE: v3.5 pointed at renodx-unity.addon64 on the snapshot mirror,
        # which is a 404. The Unity build lives on the maintainer's own host.
        if fetch "$RENODX_UNITY_FALLBACK" "renodx-unityengine.addon64" 2; then
            success "Installed RenoDX Unity fallback"
            track "renodx-unityengine.addon64"; MOD_FOUND=true; return 0
        fi
        warn "Unity fallback download failed"
    fi

    warn "No game-specific RenoDX or Luma mod found (OptiScaler & ReShade still installed)"
    return 0
}

###############################################################################
# OPTISCALER / RESHADE / DLSS
###############################################################################

install_optiscaler() {
    [[ "$RENODX_ONLY" == true || "$LUMA_ONLY" == true || "$QUIRK_SKIP_OPTISCALER" == true ]] && return 0
    info "Installing OptiScaler into $PWD"

    # Resolve the build from /releases, never /tags. A tag can exist with no
    # release attached (edge-0.9.4-1), and /tags is paginated 30-per-page and
    # is NOT chronological - so picking the "first edge-* tag" and hand-building
    # "<tag>/optiscaler-edge.7z" resolves to a tag that has no assets and 404s.
    # /releases comes back newest-first and carries the real asset URLs.
local json url=""
    # First attempt: Try fetching the pinned 'nightly' tag directly
    json=$(cache_fetch "https://api.github.com/repos/$REPO_OPTISCALER/releases/tags/nightly" \
                       "optiscaler_nightly.json" 3600) || \
    # Fallback: Fall back to latest releases if the nightly tag query fails
    json=$(cache_fetch "https://api.github.com/repos/$REPO_OPTISCALER/releases?per_page=20" \
                       "optiscaler_releases.json" 3600) || {
        warn "Could not query OptiScaler releases ($(fetch_reason))"; return 0; }

    # Asset selection is deliberately name-agnostic so a future rename
    # (optiscaler-edge.7z -> OptiScaler_stable_0.9.5.7z, etc.) keeps working:
    # take any .7z, drop obvious non-payload archives, and prefer one whose
    # name mentions optiscaler when the release carries several.
    local -a all7z=() urls=()
    local u b
    # `|| [[ -n "$u" ]]` so a final line with no trailing newline is not dropped.
    while IFS= read -r u || [[ -n "$u" ]]; do [[ -n "$u" ]] && all7z+=("$u"); done < <(
        json_lines "$json" |
        sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\.7z\)".*/\1/p')
    for u in ${all7z[@]+"${all7z[@]}"}; do
        b="${u##*/}"; b="${b,,}"
        [[ "$b" =~ (debug|symbol|pdb|source|src|sdk) ]] && continue
        [[ "$b" == *optiscaler* ]] && urls+=("$u")
    done
    (( ${#urls[@]} )) || urls=(${all7z[@]+"${all7z[@]}"})
    (( ${#urls[@]} )) || { warn "No OptiScaler .7z asset in the latest releases"; return 0; }
    (( ${#urls[@]} > 3 )) && urls=("${urls[@]:0:3}")   # newest, plus 2 fallbacks

    local got=0
    for u in "${urls[@]}"; do
        info "OptiScaler build: $(basename "$(dirname "$u")")"
        download_file "$u" "$TMP_DIR/optiscaler.7z" 2 && { got=1; break; }
        warn "Falling back to the previous OptiScaler build"
    done
    (( got )) || { warn "Every OptiScaler download failed"; return 0; }

    extract_archive "$TMP_DIR/optiscaler.7z" "$TMP_DIR/osc" || {
        warn "Could not extract OptiScaler (7z missing?)"; return 0; }

    # Copy the payload out, flattening any wrapper directory the archive uses.
    # Locate the payload root by looking for the DLL or the ini under any name
    # ("OptiScaler.dll", "optiscaler.dll", a future versioned variant), so a
    # repackaged archive layout does not silently install nothing.
    local root f
    root="$TMP_DIR/osc"
    if ! compgen -G "$root/[Oo]pti[Ss]caler*" >/dev/null 2>&1; then
        f=$(find "$TMP_DIR/osc" -maxdepth 4 \( -iname "optiscaler*.dll" -o -iname "optiscaler.ini" \) 2>/dev/null | head -1)
        [[ -n "$f" ]] && root="$(dirname "$f")"
    fi
    # Record every path the archive contributes, before copying, so --uninstall
    # can remove exactly these and leave the game's own files alone.
    local rel
    while IFS= read -r rel; do [[ -n "$rel" ]] && track "$rel"; done < <(
        cd "$root" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -printf '%P\n' 2>/dev/null)
    cp -rf "$root"/. . 2>/dev/null

    # Any optiscaler*.dll becomes the target proxy DLL (default: dxgi.dll), whatever it is called.
    if [[ ! -f "$QUIRK_OPTISCALER_DLL" ]]; then
        f=$(find . -maxdepth 1 -iname "optiscaler*.dll" 2>/dev/null | head -1)
        [[ -n "$f" ]] && { mv -f "$f" "$QUIRK_OPTISCALER_DLL"; track "$QUIRK_OPTISCALER_DLL"; }
    fi
    [[ -f "$QUIRK_OPTISCALER_DLL" ]] && success "Installed OptiScaler ($QUIRK_OPTISCALER_DLL)" || warn "OptiScaler DLL not found after extraction"

    if [[ -n "$QUIRK_EXTRA_DLL_COPIES" && -f "$QUIRK_OPTISCALER_DLL" ]]; then
        local extra_dll
        IFS=',' read -ra extra_dlls <<< "$QUIRK_EXTRA_DLL_COPIES"
        for extra_dll in "${extra_dlls[@]}"; do
            extra_dll="${extra_dll#"${extra_dll%%[![:space:]]*}"}"
            extra_dll="${extra_dll%"${extra_dll##*[![:space:]]}"}"
            [[ -n "$extra_dll" ]] && cp -f "$QUIRK_OPTISCALER_DLL" "$extra_dll" 2>/dev/null && {
                track "$extra_dll"
                info "Created extra DLL copy: $extra_dll"
            }
        done
    fi

    if [[ ! -f "d3dcompiler_47.dll" ]]; then
        fetch "$D3DCOMPILER_URL" "d3dcompiler_47.dll" 2 && track "d3dcompiler_47.dll" ||
            warn "Optional d3dcompiler_47.dll skipped (system DLL will be used)"
    fi

    if [[ -f "OptiScaler.ini" ]]; then
        sed -i -e "s/^[#]*[[:space:]]*Dx12Upscaler[[:space:]]*=.*/Dx12Upscaler = ffx/" \
               -e "s/^[#]*[[:space:]]*FGInput[[:space:]]*=.*/FGInput = nvngxfg/" \
               -e "s/^[#]*[[:space:]]*FGNvngxReplacement[[:space:]]*=.*/FGNvngxReplacement = Arturs/" \
               -e "s/^[#]*[[:space:]]*LoadReshade[[:space:]]*=.*/LoadReshade = true/" \
               "OptiScaler.ini" 2>/dev/null && success "Configured OptiScaler.ini"
    fi
    return 0
}

# Extract the best .zip asset URL from a GitHub releases JSON payload, skipping
# obvious non-payload archives (source dumps, debug symbols) so a release with
# several attachments still resolves to the real build regardless of how the
# asset happens to be named (e.g. "dlss-enabler.zip" vs
# "DLSS Enabler 4.9.0.6 TRUNK.zip" - GitHub url-encodes the spaces, so the
# ".zip" suffix match still applies either way).
pick_dlss_asset() {
    local json="$1" u b
    while IFS= read -r u || [[ -n "$u" ]]; do
        [[ -z "$u" ]] && continue
        b="${u##*/}"; b="${b,,}"
        [[ "$b" =~ (debug|symbol|pdb|source|src)([._-]|$) ]] && continue
        printf '%s' "$u"
        return 0
    done < <(json_lines "$json" |
             sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\.[zZ][iI][pP]\)".*/\1/p')
    return 1
}

install_dlss_enabler() {
    [[ "$RENODX_ONLY" == true || "$LUMA_ONLY" == true || "$QUIRK_SKIP_DLSS_ENABLER" == true ]] && return 0
    info "Installing DLSS Enabler..."

    local json url="" dll
    # Pinned tag first; if it is ever renamed or retired, fall back to whatever
    # the newest release publishes rather than silently installing nothing.
    if json=$(cache_fetch "https://api.github.com/repos/$REPO_DLSS/releases/tags/dlss-enabler" "dlss_enabler.json" 3600); then
        url=$(pick_dlss_asset "$json")
    fi
    if [[ -z "$url" ]] && json=$(cache_fetch "https://api.github.com/repos/$REPO_DLSS/releases?per_page=5" \
                                             "dlss_enabler_all.json" 3600); then
        url=$(pick_dlss_asset "$json")
        [[ -n "$url" ]] && info "DLSS Enabler: pinned tag unavailable, using newest release"
    fi
    [[ -z "$url" ]] && { warn "No DLSS Enabler asset found"; return 0; }

    download_file "$url" "$TMP_DIR/dlss-enabler.zip" 2 || return 0
    extract_archive "$TMP_DIR/dlss-enabler.zip" "$TMP_DIR/dlss" || return 0
    # The enabler's proxy usually ships as dxgi.dll, but some builds ship it as
    # version.dll instead (e.g. when dxgi.dll is already claimed by another
    # proxy for the game in question) - accept either name.
    dll=$(find "$TMP_DIR/dlss" \( -iname "dxgi.dll" -o -iname "version.dll" \) 2>/dev/null | head -1)
    if [[ -n "$dll" ]]; then
        mkdir -p "OptiScaler"
        cp -f "$dll" "OptiScaler/dlss-enabler-headless.dll" &&
            { track "OptiScaler/dlss-enabler-headless.dll"; success "Installed DLSS Enabler"; }
    else
        warn "DLSS Enabler proxy DLL (dxgi.dll/version.dll) not found inside the archive"
    fi
    return 0
}

# Nothing loads ReShade (and therefore nothing loads the RenoDX addon) unless a
# proxy DLL sits next to the game. OptiScaler normally is that proxy - it ships
# as dxgi.dll (or d3d12.dll per quirk) with LoadReshade=true. If OptiScaler is
# absent or its download failed, promote ReShade itself to proxy DLL so the addon loads.
ensure_reshade_proxy() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    [[ -f "$QUIRK_OPTISCALER_DLL" ]] && return 0
    cp -f "$src" "$QUIRK_OPTISCALER_DLL" 2>/dev/null && {
        track "$QUIRK_OPTISCALER_DLL"
        warn "OptiScaler missing - installed ReShade as $QUIRK_OPTISCALER_DLL so the addon loads"
    }
    return 0
}

install_reshade() {
    [[ "$QUIRK_SKIP_RESHADE" == true ]] && return 0
    [[ -f "ReShade64.dll" ]] && { info "ReShade already present"; ensure_reshade_proxy "ReShade64.dll"; return 0; }
    (( HAVE_7Z )) || { warn "Skipping ReShade (needs 7z)"; return 0; }
    info "Installing ReShade..."

    download_file "$RESHADE_URL" "$TMP_DIR/ReShade_Setup_Addon.exe" 2 || return 0
    extract_archive "$TMP_DIR/ReShade_Setup_Addon.exe" "$TMP_DIR/reshade" || {
        warn "Could not unpack the ReShade installer"; return 0; }

    local dll
    dll=$(find "$TMP_DIR/reshade" -iname "ReShade64.dll" 2>/dev/null | head -1)
    [[ -z "$dll" ]] && dll=$(find "$TMP_DIR/reshade" -iname "*ReShade*64*.dll" 2>/dev/null | head -1)
    if [[ -n "$dll" ]]; then
        cp -f "$dll" "ReShade64.dll" && { track "ReShade64.dll"; success "Installed ReShade (ReShade64.dll)"; }
        ensure_reshade_proxy "ReShade64.dll"
    else
        warn "ReShade64.dll not found inside the installer"
    fi
    return 0
}

###############################################################################
# INSTALL FLOW
###############################################################################

# Record a path OptiDX created, so --uninstall reverts exactly this install and
# never deletes a file the game shipped with.
track() { [[ -n "${1-}" ]] && INSTALLED_FILES+=("$1"); return 0; }

write_manifest() {
    (( ${#INSTALLED_FILES[@]} )) || return 0
    printf '%s\n' "${INSTALLED_FILES[@]}" | sort -u >"$MANIFEST" 2>/dev/null
    return 0
}

uninstall_dir() {
    local dir="$1" removed=0 p
    [[ -f "$dir/$MANIFEST" ]] || return 1
    info "Uninstalling OptiDX files from $dir..."
    while IFS= read -r p; do
        # Refuse absolute paths and traversal - the manifest is ours, but a
        # corrupted one must never let rm -rf escape the game directory.
        [[ -z "$p" || "$p" == /* || "$p" == *".."* ]] && continue
        if [[ -e "$dir/$p" || -L "$dir/$p" ]]; then
            info "Removing: $p"
            rm -rf -- "$dir/$p" 2>/dev/null && removed=$(( removed + 1 ))
        fi
    done <"$dir/$MANIFEST"
    rm -f "$dir/$MANIFEST" "$dir/$MARKER" 2>/dev/null
    success "Removed $removed item(s) from $dir"
    return 0
}

cleanup_stale() {
    # ".addon" included: Luma's payload uses that bare extension, so v3.5 left
    # stale copies behind on every re-run.
    rm -f ./*.addon64 ./*.addon32 ./*.addon 2>/dev/null
    rm -rf "__MACOSX" ".dlss_tmp" 2>/dev/null
    rm -f "optiscaler-edge.7z" "dlss-enabler.zip" "luma-mod.zip" "ReShade_Setup_Addon.exe" 2>/dev/null
    return 0
}

verify_installation() {
    info "Verifying installation in $PWD"
    local found=false a addons

    if [[ -f "$QUIRK_OPTISCALER_DLL" ]]; then
        success "OptiScaler active ($QUIRK_OPTISCALER_DLL)"
        found=true
    fi
    addons=$(find . -maxdepth 1 -type f \( -name "*.addon64" -o -name "*.addon32" -o -name "*.addon" \) 2>/dev/null)
    if [[ -n "$addons" ]]; then
        while IFS= read -r a; do [[ -n "$a" ]] && success "Mod installed: $(basename "$a")"; done <<<"$addons"
        found=true
    fi
    [[ -f "ReShade64.dll" ]] && { success "ReShade installed"; found=true; }
    [[ -f "OptiScaler/dlss-enabler-headless.dll" ]] && { success "DLSS Enabler installed"; found=true; }
    [[ -f "OptiScaler.ini" ]] && success "OptiScaler.ini present"

    [[ "$found" == false ]] && { warn "Nothing was installed"; return 1; }
    return 0
}

# The four metadata endpoints are independent and each costs a full round trip.
# Warming them concurrently turns four sequential RTTs into roughly one; the
# installers below then read warm cache files. Writes go to distinct paths, and
# a failure here is a no-op because each installer still fetches on demand.
warm_metadata_caches() {
    [[ "$RENODX_ONLY" == true || "$LUMA_ONLY" == true ]] || {
        cache_fetch "https://api.github.com/repos/$REPO_OPTISCALER/releases/tags/nightly" \
            "optiscaler_nightly.json" 3600 >/dev/null 2>&1 &
        cache_fetch "https://api.github.com/repos/$REPO_DLSS/releases/tags/dlss-enabler" \
                    "dlss_enabler.json" 3600 >/dev/null 2>&1 &
    }
    cache_fetch "$RENODX_WIKI" "renodx_mods.md" 86400 >/dev/null 2>&1 &
    cache_fetch "$RENODX_MIRROR_API" "renodx_mirror.json" 21600 >/dev/null 2>&1 &
    wait
    return 0
}

do_install() {
    print_banner
    info "Install directory: $PWD"
    info "Target game: ${COLOR_BOLD}${COLOR_WHITE}$GAME_DISPLAY${COLOR_RESET}"

    resolve_game_quirks

    if [[ "$DRY_RUN" == true ]]; then
        info "Dry run enabled — skipping file downloads and modifications."
        find_renodx_mod
        [[ "$MOD_FOUND" == false ]] && find_luma_mod
        success "Dry run simulation complete."
        return 0
    fi

    warm_metadata_caches
    cleanup_stale
    install_optiscaler
    install_dlss_enabler
    install_reshade

    find_renodx_mod
    [[ "$MOD_FOUND" == false ]] && find_luma_mod
    install_engine_fallback

    # Only record success if something actually landed. Writing the marker after
    # a run where every download failed made the next launch take the "already
    # installed" fast path and never retry.
    if ! verify_installation; then
        warn "Nothing was installed - not marking as complete, so the next launch retries"
        warn "Check connectivity; GitHub also rate-limits to 60 API calls/hour unauthenticated"
        return 0
    fi

    # Written in both places: the launcher re-enters at the game root, but the
    # payload lives in the binary directory.
    write_manifest
    printf '%s\nv%s\n' "$PWD" "$SCRIPT_VERSION" >"$MARKER" 2>/dev/null
    # The launcher re-enters at the game root, so a marker lives there too - it
    # records the payload directory so the fast path knows where to log without
    # re-running detection.
    [[ "$PWD" != "$START_DIR" ]] && printf '%s\nv%s\n' "$PWD" "$SCRIPT_VERSION" >"$START_DIR/$MARKER" 2>/dev/null
    sync 2>/dev/null

    _log "\n${COLOR_SUCCESS}${COLOR_BOLD}  All done! Installation complete.${COLOR_RESET}"
    return 0
}

usage() {
    cat >&2 <<USAGE
OptiDX v$SCRIPT_VERSION - OptiScaler + RenoDX installer

  optidx.sh [options] [-- <command to launch the game>]

  --renodx       Only install RenoDX/Luma mods (skip OptiScaler/DLSS)
  --luma         Only install Luma mods
  --update       Re-run installation even if already installed
  --uninstall    Remove everything OptiDX installed, then launch normally
  --dry-run      Simulate game detection and mod matching without installing
  --list-quirks  Display all built-in and user-defined game quirks
  --help         Show this message

Options must come BEFORE the game command; everything after the first
non-option argument is forwarded to the game untouched.

Steam launch options:   /path/to/OptiDXv2.sh %command%
USAGE
}

launch_now() {
    cd "$START_DIR" 2>/dev/null
    [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR" 2>/dev/null
    trap - EXIT
    # `env` so leading VAR=VALUE assignments in Steam's %command% are applied
    # rather than treated as the name of the program to run.
    exec env "${GAME_ARGS[@]}" 2>/dev/null || exec "${GAME_ARGS[@]}"
}

main() {
    # OptiDX flags are only recognised BEFORE the game command. Steam expands
    # %command% into arguments we must forward untouched - scanning the whole
    # list would let a game's own "-h" print usage and abort the launch, or a
    # game's "--update" silently force a reinstall.
    local arg opts=true
    local -a LOG_HDR=()
    for arg in "$@"; do
        if [[ "$opts" == true ]]; then
            case "$arg" in
                --renodx)      RENODX_ONLY=true;  continue ;;
                --luma)        LUMA_ONLY=true;    continue ;;
                --update)      FORCE_UPDATE=true; continue ;;
                --uninstall)   DO_UNINSTALL=true; continue ;;
                --dry-run)     DRY_RUN=true;      continue ;;
                --list-quirks) LIST_QUIRKS=true;  continue ;;
                --help|-h) usage; exit 0 ;;
                --)        opts=false; continue ;;
                *)         opts=false ;;      # first non-flag: the game command
            esac
        fi
        GAME_ARGS+=("$arg")
    done

    if [[ "$LIST_QUIRKS" == true ]]; then
        list_all_quirks
        exit 0
    fi

    local have_game=0
    (( ${#GAME_ARGS[@]} )) && have_game=1

    # ---- fast path -------------------------------------------------------
    # Already installed and just launching: hand off immediately. No log
    # header, no requirement probe, no mktemp, no awk programs written - on a
    # Steam launch this is the difference between ~0 and a visible stall
    # before the game window appears.
    if (( have_game )) && [[ "$FORCE_UPDATE" == false && "$DO_UNINSTALL" == false && -f "$MARKER" ]]; then
        # `read` is a builtin: the marker records the payload directory, so the
        # log line lands next to the mods without re-running detection.
        local installed_at=""
        read -r installed_at < "$MARKER" 2>/dev/null
        [[ -d "$installed_at" ]] || installed_at="$START_DIR"
        printf 'OptiDX v%s: already installed, launching (%(%Y-%m-%d %H:%M:%S)T)\n' \
               "$SCRIPT_VERSION" -1 >>"$installed_at/optidx.log" 2>/dev/null
        launch_now
    fi

    # Buffered until the install directory is known. printf's %(...)T is a bash
    # builtin - no fork, unlike $(date).
    LOG_BUFFER+=("--------------------------------------------------")
    printf -v arg 'OptiDX v%s run started: %(%Y-%m-%d %H:%M:%S)T' "$SCRIPT_VERSION" -1
    LOG_BUFFER+=("$arg" "--------------------------------------------------")

    if [[ "$DO_UNINSTALL" == true ]]; then
        local m found=0
        while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            uninstall_dir "$(dirname "$m")" && found=1
        done < <(find "$START_DIR" -maxdepth 6 -name "$MANIFEST" 2>/dev/null)
        rm -f "$START_DIR/$MARKER" 2>/dev/null
        (( found )) && success "OptiDX removed - the game is back to its original files" \
                    || warn "No OptiDX manifest found under $START_DIR (nothing to remove)"
        (( have_game )) || exit 0
        info "Launching game..."
        launch_now
    fi

    if check_requirements && need_workspace; then
        write_awk_programs
        if [[ -f "$MARKER" && "$FORCE_UPDATE" == false ]]; then
            info "Existing OptiDX setup found - launching directly"
        elif detect_game; then
            if [[ -n "$GAME_DIR" && -d "$GAME_DIR" && "$GAME_DIR" != "$PWD" ]]; then
                info "Entering binary directory: $GAME_DIR"
                cd "$GAME_DIR" || warn "Could not enter $GAME_DIR"
            fi
            set_log_dir "$PWD"      # log lives with the payload, not the game root
            do_install
        else
            set_log_dir "$START_DIR"
            error "Could not detect a game executable in $START_DIR"
            (( have_game )) || exit 1
            warn "Continuing to launch anyway"
        fi
    else
        set_log_dir "$START_DIR"
    fi

    (( have_game )) || return 0

    info "Launching game..."
    launch_now
}

main "$@"
