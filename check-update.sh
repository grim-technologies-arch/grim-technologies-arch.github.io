#!/bin/bash
#
# tools/check-update.sh - Claumi Update & Detection Tool
#
# Detects whether Claumi needs an update, checks Apple Silicon / Rosetta status,
# and prompts the user to upgrade to the latest release.
#
# Usage:
#   ./tools/check-update.sh              # check and prompt to update if needed
#   ./tools/check-update.sh --update     # update automatically without prompt
#   ./tools/check-update.sh --check-only # return 0 if up to date, 2 if update available
#
set -euo pipefail

SITE="${CLAUMI_SITE:-https://grim-technologies-arch.github.io}"
UPDATE_URL="$SITE/update.json"
REPO_ROOT="${CLAUMI_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; BLU=$'\033[36m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  BOLD=""; GRN=""; YEL=""; RED=""; BLU=""; DIM=""; RST=""
fi

say()  { printf "${BOLD}==>${RST} %s\n" "$*"; }
info() { printf "${BLU}[info]${RST} %s\n" "$*"; }
ok()   { printf "${GRN}[ok]${RST} %s\n" "$*"; }
warn() { printf "${YEL}[warn]${RST} %s\n" "$*"; }
err()  { printf "${RED}[error]${RST} %s\n" "$*" >&2; }

AUTO_UPDATE=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --update|-y|--yes) AUTO_UPDATE=1 ;;
    --check-only)      CHECK_ONLY=1 ;;
    *) echo "Usage: $0 [--update] [--check-only]" >&2; exit 1 ;;
  esac
  shift
done

echo "${BOLD}--- Claumi Detection & Update Tool ---${RST}"

# 1. Architecture & Rosetta Check
ARCH="$(uname -m)"
info "System architecture: $ARCH"
if [ "$ARCH" = "arm64" ]; then
  if /usr/bin/pgrep -q oahd || /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || [ -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ]; then
    ok "Apple Silicon: Rosetta 2 is installed and active"
  else
    warn "Apple Silicon: Rosetta 2 is NOT detected. Roblox requires Rosetta 2 on Apple Silicon."
    info "You can install Rosetta 2 with: softwareupdate --install-rosetta --agree-to-license"
  fi
fi

# 2. Determine Installed Version
INSTALLED_VER=""
if [ -f "$REPO_ROOT/src/version.hpp" ]; then
  INSTALLED_VER=$(sed -nE 's/.*CLAUMI_VERSION_STR[[:space:]]+"([^"]+)".*/\1/p' "$REPO_ROOT/src/version.hpp" | head -1)
fi

if [ -z "$INSTALLED_VER" ] && [ -f "/Applications/Claumi.app/Contents/Info.plist" ]; then
  INSTALLED_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/Claumi.app/Contents/Info.plist" 2>/dev/null || true)
fi

INSTALLED_VER="${INSTALLED_VER:-unknown}"
info "Installed version: v$INSTALLED_VER"

# 3. Fetch Remote update.json
info "Checking latest release from $UPDATE_URL..."
TMP_JSON="$(mktemp "${TMPDIR:-/tmp}/claumi-update.XXXXXX")"
cleanup() { rm -f "$TMP_JSON"; }
trap cleanup EXIT

if ! curl -fsSL --retry 2 --max-time 10 "$UPDATE_URL" -o "$TMP_JSON" 2>/dev/null; then
  err "Could not connect to update server at $UPDATE_URL"
  exit 1
fi

LATEST_VER=$(plutil -extract executor.version raw -o - "$TMP_JSON" 2>/dev/null || grep -o '"version": "[^"]*"' "$TMP_JSON" | head -1 | cut -d'"' -f4)
ROBLOX_PLAYER=$(plutil -extract roblox.player raw -o - "$TMP_JSON" 2>/dev/null || grep -o '"player": "[^"]*"' "$TMP_JSON" | head -1 | cut -d'"' -f4)

if [ -z "$LATEST_VER" ]; then
  err "Failed to parse latest version from $UPDATE_URL"
  exit 1
fi

info "Latest available version: v$LATEST_VER"

# 4. Compare Semver
compare_semver() {
  local v1="${1#v}" v2="${2#v}"
  if [ "$v1" = "$v2" ]; then echo 0; return; fi
  local IFS=.
  local -a a=($v1) b=($v2)
  for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
    local n1=${a[i]:-0} n2=${b[i]:-0}
    if ((10#$n1 > 10#$n2)); then echo 1; return; fi
    if ((10#$n1 < 10#$n2)); then echo -1; return; fi
  done
  echo 0
}

CMP=$(compare_semver "$LATEST_VER" "$INSTALLED_VER")

if [ "$CMP" -le 0 ]; then
  ok "Claumi is up to date! (v$INSTALLED_VER)"
  exit 0
fi

# 5. Update is Available
warn "A new version of Claumi is available: v$INSTALLED_VER -> v$LATEST_VER"
if [ -n "$ROBLOX_PLAYER" ]; then
  info "Target Roblox client: $ROBLOX_PLAYER"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 2
fi

DO_UPDATE=0
if [ "$AUTO_UPDATE" -eq 1 ]; then
  DO_UPDATE=1
elif [ -e /dev/tty ]; then
  printf "\n${BOLD}Would you like to update to Claumi v%s now? [Y/n]${RST} " "$LATEST_VER"
  read -r reply < /dev/tty 2>/dev/null || reply="y"
  case "$reply" in
    [yY][eE][sS]|[yY]|"") DO_UPDATE=1 ;;
    *) DO_UPDATE=0 ;;
  esac
fi

if [ "$DO_UPDATE" -eq 1 ]; then
  say "Starting Claumi update to v$LATEST_VER..."
  curl -fsSL "$SITE/install.sh" | bash
  ok "Claumi successfully updated to v$LATEST_VER!"
else
  info "Update deferred."
fi

