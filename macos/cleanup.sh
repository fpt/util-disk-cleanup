#!/bin/bash
#
# cleanup.sh - macOS disk cleanup tool with dry-run and space estimation.
#
# Scans well-known cache and build-artifact locations, reports how much each
# would free, and optionally deletes them.
#
# DRY RUN IS THE DEFAULT. Nothing is deleted unless you pass --execute.
#
# Usage:
#   ./cleanup.sh                               Dry-run report of every category
#   ./cleanup.sh --execute                     Actually delete (alias: --run)
#   ./cleanup.sh --categories rust,pip,docker  Only these categories
#   ./cleanup.sh --exclude trash,huggingface   Everything except these
#   ./cleanup.sh --list                        Print categories and exit
#   ./cleanup.sh --scan-roots "~/src ~/work"   Roots scanned for Rust target/ dirs
#                                              (or set SCAN_ROOTS)
#
# Works with the stock /bin/bash (3.2).

# No `set -e`: locked / permission-denied files are skipped, never abort the run.
set -o pipefail

EXECUTE=0
LIST=0
CATEGORIES="all"
EXCLUDE=""
SCAN_ROOTS="${SCAN_ROOTS:-$HOME/Documents $HOME/src $HOME/projects $HOME/work $HOME/dev}"

usage() {
    sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --execute|--run)  EXECUTE=1 ;;
        --list)           LIST=1 ;;
        --categories)     CATEGORIES="${2:?--categories needs a value}"; shift ;;
        --categories=*)   CATEGORIES="${1#*=}" ;;
        --exclude)        EXCLUDE="${2:?--exclude needs a value}"; shift ;;
        --exclude=*)      EXCLUDE="${1#*=}" ;;
        --scan-roots)     SCAN_ROOTS="${2:?--scan-roots needs a value}"; shift ;;
        --scan-roots=*)   SCAN_ROOTS="${1#*=}" ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ]; then
    BOLD='\033[1m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; DIM='\033[2m'; RESET='\033[0m'
else
    BOLD=''; RED=''; YELLOW=''; GREEN=''; CYAN=''; DIM=''; RESET=''
fi

# On macOS the writable volume is /System/Volumes/Data. Plain `df /` reports the
# sealed read-only system snapshot, which massively understates real usage.
DATA_VOL="/System/Volumes/Data"
[ -d "$DATA_VOL" ] || DATA_VOL="/"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-cleanup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Helpers (all sizes are in KB)
# ---------------------------------------------------------------------------

human_size() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1048576)   printf "%.2f GB", kb / 1048576
        else if (kb >= 1024) printf "%.2f MB", kb / 1024
        else                 printf "%d KB", kb
    }'
}

# On-disk usage of the given paths; missing paths count as 0.
paths_kb() {
    local total=0 p kb
    for p in "$@"; do
        [ -n "$p" ] && [ -e "$p" ] || continue
        kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
        total=$((total + ${kb:-0}))
    done
    echo "$total"
}

# Refuse to operate on paths that would be catastrophic if a variable is empty.
is_safe_path() {
    case "$1" in
        ""|/|"$HOME"|"$HOME/") return 1 ;;
    esac
    return 0
}

# Clears the *contents* of the given folders (dotfiles included), leaving the
# folders themselves.
clear_contents() {
    local p
    for p in "$@"; do
        is_safe_path "$p" && [ -d "$p" ] || continue
        find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    done
    return 0
}

# Removes the given folders entirely.
remove_dirs() {
    local p
    for p in "$@"; do
        is_safe_path "$p" && [ -d "$p" ] || continue
        rm -rf "$p" 2>/dev/null
    done
    return 0
}

# ---------------------------------------------------------------------------
# Target definitions
# ---------------------------------------------------------------------------
# add_target <name> <group> <description> [path...]
#
# With paths, the target measures and clears the contents of those folders.
# A target can override or extend any step by defining a function named after it:
#   measure_<name>  print KB; must size exactly what clean_<name> removes
#   clean_<name>    perform deletion (only called with --execute)
#   detail_<name>   print an indented per-item breakdown
#   skip_<name>     print a reason string if the target is unavailable

T_NAME=(); T_GROUP=(); T_DESC=(); T_PATHS=()

add_target() {
    local name="$1" group="$2" desc="$3" paths="" p
    shift 3
    for p in "$@"; do paths="$paths$p"$'\n'; done
    T_NAME+=("$name"); T_GROUP+=("$group"); T_DESC+=("$desc"); T_PATHS+=("$paths")
}

LC="$HOME/Library/Caches"
have() { command -v "$1" >/dev/null 2>&1; }

# --- System ----------------------------------------------------------------

add_target trash 'System' 'Trash (~/.Trash) -- this is a real delete' "$HOME/.Trash"
skip_trash() {
    # Terminal needs Full Disk Access to read ~/.Trash on recent macOS.
    if [ -d "$HOME/.Trash" ] && ! ls "$HOME/.Trash" >/dev/null 2>&1; then
        echo 'no access; grant your terminal Full Disk Access'
    fi
}

# --- Browsers --------------------------------------------------------------

add_target chrome  'Browsers' 'Google/Chrome cache' "$LC/Google"
add_target edge    'Browsers' 'Edge cache' "$LC/Microsoft Edge"
add_target firefox 'Browsers' 'Firefox cache (all profiles)' "$LC/Firefox"

# --- Package caches --------------------------------------------------------

BREW_CACHE=""
have brew && BREW_CACHE="$(brew --cache 2>/dev/null)"
add_target homebrew 'Package caches' 'Homebrew download cache' "$BREW_CACHE"
skip_homebrew() { have brew || echo 'brew not installed'; }

add_target npm  'Package caches' 'npm cache' "$HOME/.npm/_cacache"
add_target yarn 'Package caches' 'Yarn cache' "$LC/Yarn"
add_target pip  'Package caches' 'pip download cache' "$LC/pip"
add_target uv   'Package caches' 'uv (Python) package cache' "${UV_CACHE_DIR:-$HOME/.cache/uv}"

# Only downloaded crates and extracted sources; the registry index is kept.
add_target cargo 'Package caches' 'Cargo registry cache + sources' \
    "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src"

GO_MODCACHE=""; GO_CACHE=""
if have go; then
    GO_MODCACHE="$(go env GOMODCACHE 2>/dev/null)"
    GO_CACHE="$(go env GOCACHE 2>/dev/null)"
fi
add_target go 'Package caches' 'Go module cache' "$GO_MODCACHE"
# Module cache files are read-only; `go clean` knows how to remove them.
clean_go() { go clean -modcache >/dev/null 2>&1; }
skip_go() { have go || echo 'go not installed'; }

add_target gobuild 'Package caches' 'Go build cache' "$GO_CACHE"
skip_gobuild() { have go || echo 'go not installed'; }

add_target goimports 'Package caches' 'goimports cache' "$LC/goimports"
add_target gradle    'Package caches' 'Gradle caches' "$HOME/.gradle/caches"
add_target cocoapods 'Package caches' 'CocoaPods cache' "$LC/CocoaPods"
add_target swiftpm   'Package caches' 'Swift Package Manager cache' "$LC/org.swift.swiftpm"

# --- Model caches ----------------------------------------------------------

HF_HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"
add_target huggingface 'Model caches' 'HuggingFace model cache (re-downloads on demand)' "$HF_HUB"
detail_huggingface() {
    local d
    for d in "$HF_HUB"/models--*; do
        [ -d "$d" ] || continue
        printf '%s\t%s\t%s\n' "$(paths_kb "$d")" \
            "$(basename "$d" | sed -e 's/^models--//' -e 's/--/\//g')" \
            "$(stat -f '%Sm' -t '%Y-%m-%d' "$d")"
    done | sort -rn | while IFS=$'\t' read -r kb model used; do
        printf "${DIM}      %10s  %-40s last used %s${RESET}\n" "$(human_size "$kb")" "$model" "$used"
    done
}

add_target whisper 'Model caches' 'OpenAI Whisper model cache' "$HOME/.cache/whisper"
add_target torch   'Model caches' 'PyTorch hub cache' "${TORCH_HOME:-$HOME/.cache/torch}"

# --- Build artifacts -------------------------------------------------------

# Only target/ dirs next to a Cargo.toml, so Maven or other "target" dirs are
# left alone. find never descends into a target/, so nothing is double counted.
# The list is kept in a file so every step (each run in a subshell) sees the
# same dirs, and the post-clean measure sizes exactly what was removed.
RUST_LIST="$WORK/rust-targets"
rust_dirs() {
    if [ ! -f "$RUST_LIST" ]; then
        local root d
        : > "$RUST_LIST"
        for root in $SCAN_ROOTS; do
            root="${root/#\~/$HOME}"
            [ -d "$root" ] || continue
            find "$root" \
                \( -name Library -o -name .Trash -o -name node_modules -o -name .git \) -prune -o \
                -type d -name target -print -prune 2>/dev/null |
            while IFS= read -r d; do
                [ -f "${d%/target}/Cargo.toml" ] && echo "$d"
            done >> "$RUST_LIST"
        done
    fi
    cat "$RUST_LIST"
}
add_target rust 'Build artifacts' "Rust target/ dirs under ${SCAN_ROOTS//$HOME/~}"
measure_rust() {
    local total=0 d
    while IFS= read -r d; do
        total=$((total + $(paths_kb "$d")))
    done < <(rust_dirs)
    echo "$total"
}
clean_rust() {
    local d
    while IFS= read -r d; do remove_dirs "$d"; done < <(rust_dirs)
}
detail_rust() {
    local d
    while IFS= read -r d; do
        printf '%s\t%s\n' "$(paths_kb "$d")" "$d"
    done < <(rust_dirs) | sort -rn | while IFS=$'\t' read -r kb d; do
        [ "$kb" -gt 0 ] && printf "${DIM}      %10s  %s${RESET}\n" "$(human_size "$kb")" "${d/#$HOME/~}"
    done
}

add_target xcode 'Build artifacts' 'Xcode DerivedData' "$HOME/Library/Developer/Xcode/DerivedData"

# --- Apps ------------------------------------------------------------------

CODE_SUPPORT="$HOME/Library/Application Support/Code"
add_target vscode 'Apps' 'VS Code cache + updater (close VS Code first)' \
    "$CODE_SUPPORT/Cache" "$CODE_SUPPORT/CachedData" "$CODE_SUPPORT/CachedExtensionVSIXs" \
    "$CODE_SUPPORT/Code Cache" "$CODE_SUPPORT/GPUCache" "$LC/com.microsoft.VSCode.ShipIt"
add_target claude 'Apps' 'Claude Desktop updater + Claude CLI cache' \
    "$LC/com.anthropic.claudefordesktop.ShipIt" "$LC/claude-cli-nodejs"
add_target electron   'Apps' 'Electron download cache' "$LC/electron"
add_target playwright 'Apps' 'Playwright (Go) driver + browsers' "$LC/ms-playwright-go"
add_target arduino    'Apps' 'Arduino download staging + CLI cache' \
    "$HOME/Library/Arduino15/staging" "$LC/arduino"

# --- Docker ----------------------------------------------------------------

# Volumes are excluded: they may hold database or app state, not just cache.
add_target docker 'Docker' 'Unused images, containers, networks, build cache'
measure_docker() {
    # Docker reports SI units ("1.234GB (45%)").
    docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '
        $1 != "Local Volumes" {
            s = $2; sub(/ .*/, "", s)
            n = s; sub(/[A-Za-z]+$/, "", n)
            u = s; sub(/^[0-9.]+/, "", u)
            m = 1
            if (u == "kB" || u == "KB") m = 1e3
            else if (u == "MB") m = 1e6
            else if (u == "GB") m = 1e9
            else if (u == "TB") m = 1e12
            total += n * m / 1024
        }
        END { printf "%d\n", total }'
}
clean_docker() { docker system prune -af >/dev/null 2>&1; }
skip_docker() {
    if ! have docker; then echo 'docker not installed'
    elif ! docker info >/dev/null 2>&1; then echo 'daemon not running; start Docker Desktop'
    fi
}

# --- Report only -----------------------------------------------------------
# Large and technically regenerable, but wiping them breaks a working toolchain
# until re-downloaded. Sized and listed (when > 512 MB), never deleted.
MANUAL=(
    "$HOME/Library/Arduino15/packages|re-install boards via Board Manager"
    "$HOME/Library/Android/sdk|re-install via SDK Manager; breaks AVDs"
    "$HOME/Library/Developer/CoreSimulator/Devices|xcrun simctl delete unavailable"
    "$HOME/.rustup|rustup toolchain uninstall <old>"
    "$HOME/temp|your own files"
)

# ---------------------------------------------------------------------------
# Target step dispatch
# ---------------------------------------------------------------------------

has_fn() { declare -F "$1" >/dev/null; }

# Fills TP with the paths registered for target $1.
target_paths() {
    TP=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && TP+=("$line")
    done <<< "${T_PATHS[$1]}"
}

measure_target() {
    local name="${T_NAME[$1]}" kb
    if has_fn "measure_$name"; then
        kb=$("measure_$name")
    else
        target_paths "$1"
        kb=$(paths_kb "${TP[@]}")
    fi
    echo "${kb:-0}"
}

clean_target() {
    local name="${T_NAME[$1]}"
    if has_fn "clean_$name"; then
        "clean_$name"
    else
        target_paths "$1"
        clear_contents "${TP[@]}"
    fi
}

# ---------------------------------------------------------------------------
# List mode
# ---------------------------------------------------------------------------

N=${#T_NAME[@]}

if [ "$LIST" -eq 1 ]; then
    echo ""
    echo "Available categories:"
    group=""
    for ((i = 0; i < N; i++)); do
        if [ "${T_GROUP[$i]}" != "$group" ]; then
            group="${T_GROUP[$i]}"
            echo ""
            echo -e "  ${CYAN}${group}${RESET}"
        fi
        printf '    %-14s %s\n' "${T_NAME[$i]}" "${T_DESC[$i]}"
    done
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Category selection
# ---------------------------------------------------------------------------

normalize() { echo "$1" | tr 'A-Z' 'a-z' | tr -d ' '; }
in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }

INC="$(normalize "$CATEGORIES")"
EXC="$(normalize "$EXCLUDE")"
ALL_NAMES=",$(IFS=,; echo "${T_NAME[*]}"),"

unknown=""
for name in $(echo "$INC,$EXC" | tr ',' ' '); do
    [ "$name" = "all" ] && continue
    in_list "$name" "$ALL_NAMES" || unknown="$unknown $name"
done
if [ -n "$unknown" ]; then
    echo -e "${YELLOW}WARNING: Unknown categories:${unknown}. Use --list to see available names.${RESET}" >&2
fi

SELECTED=()
for ((i = 0; i < N; i++)); do
    name="${T_NAME[$i]}"
    if { in_list all "$INC" || in_list "$name" "$INC"; } && ! in_list "$name" "$EXC"; then
        SELECTED+=("$i")
    fi
done

if [ ${#SELECTED[@]} -eq 0 ]; then
    echo -e "${YELLOW}WARNING: No categories selected. Use --list to see available names.${RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

free_kb() { df -k "$DATA_VOL" | tail -1 | awk '{print $4}'; }
disk_line() {
    df -h "$DATA_VOL" | tail -1 | awk '{printf "%s total, %s used, %s available (%s used)", $2, $3, $4, $5}'
}

echo ""
echo -e "${CYAN}====================================${RESET}"
echo -e "${CYAN}      macOS Disk Cleanup Tool       ${RESET}"
echo -e "${CYAN}====================================${RESET}"
if [ "$EXECUTE" -eq 1 ]; then
    echo -e "Mode : ${RED}EXECUTE  <-- files will be deleted!${RESET}"
else
    echo -e "Mode : ${YELLOW}DRY-RUN  (pass --execute to delete)${RESET}"
fi
echo "Date : $(date '+%Y-%m-%d %H:%M')"
echo "Disk : $(disk_line)"
echo -e "${DIM}       (volume: $DATA_VOL)${RESET}"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

RESULTS="$WORK/results"
: > "$RESULTS"
total_kb=0
group=""

for i in "${SELECTED[@]}"; do
    name="${T_NAME[$i]}"
    desc="${T_DESC[$i]}"

    if [ "${T_GROUP[$i]}" != "$group" ]; then
        group="${T_GROUP[$i]}"
        echo ""
        echo -e "${CYAN}${group}${RESET}"
        echo -e "${CYAN}$(echo "$group" | sed 's/./-/g')${RESET}"
    fi

    if has_fn "skip_$name"; then
        reason=$("skip_$name")
        if [ -n "$reason" ]; then
            printf "${DIM}  %-14s %10s   %s  (skipped: %s)${RESET}\n" "$name" "-" "$desc" "$reason"
            continue
        fi
    fi

    size=$(measure_target "$i")
    if [ "$size" -gt 1048576 ]; then color="$YELLOW"
    elif [ "$size" -gt 102400 ]; then color="$GREEN"
    elif [ "$size" -gt 0 ]; then color=""
    else color="$DIM"
    fi
    printf "${color}  %-14s %10s   %s${RESET}\n" "$name" "$(human_size "$size")" "$desc"

    [ "$size" -gt 0 ] || continue
    has_fn "detail_$name" && "detail_$name"

    freed=$size
    if [ "$EXECUTE" -eq 1 ]; then
        clean_target "$i"
        after=$(measure_target "$i")
        freed=$((size - after))
        [ "$freed" -lt 0 ] && freed=0
        note=""
        [ "$after" -gt 0 ] && note=" ($(human_size "$after") left: in use or permission denied)"
        printf "${GREEN}  %-14s %10s   freed%s${RESET}\n" "" "$(human_size "$freed")" "$note"
    fi

    printf '%s\t%s\n' "$freed" "$name" >> "$RESULTS"
    total_kb=$((total_kb + freed))
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}====================================${RESET}"
echo -e "${CYAN}              Summary               ${RESET}"
echo -e "${CYAN}====================================${RESET}"

sort -rn "$RESULTS" | while IFS=$'\t' read -r kb name; do
    [ "$kb" -gt 0 ] || continue
    if [ "$kb" -gt 1048576 ]; then color="$YELLOW"
    elif [ "$kb" -gt 102400 ]; then color="$GREEN"
    else color=""
    fi
    printf "${color}  %-28s %10s${RESET}\n" "$name" "$(human_size "$kb")"
done

echo ""
if [ "$EXECUTE" -eq 1 ]; then
    printf "${BOLD}  %-28s %10s${RESET}\n" "Total freed" "$(human_size "$total_kb")"
    echo -e "${DIM}  Disk now: $(disk_line)${RESET}"
    if grep -q $'^[1-9][0-9]*\tdocker$' "$RESULTS"; then
        echo -e "${DIM}  (Docker space returns to the host only after Docker Desktop trims Docker.raw)${RESET}"
    fi
else
    printf "${BOLD}  %-28s %10s${RESET}\n" "Estimated reclaimable" "$(human_size "$total_kb")"
fi

manual_out=""
for entry in "${MANUAL[@]}"; do
    path="${entry%%|*}"
    hint="${entry#*|}"
    kb=$(paths_kb "$path")
    [ "$kb" -gt 524288 ] || continue
    manual_out="$manual_out$(printf '  %-50s %10s  %s' "${path/#$HOME/~}" "$(human_size "$kb")" "$hint")"$'\n'
done
if [ -n "$manual_out" ]; then
    echo ""
    echo -e "${BOLD}Not cleaned automatically -- review these yourself:${RESET}"
    printf '%s' "$manual_out"
fi

echo ""
if [ "$EXECUTE" -eq 0 ] && [ "$total_kb" -gt 0 ]; then
    echo -e "${YELLOW}  Run with --execute to free this space.${RESET}"
    echo ""
fi
