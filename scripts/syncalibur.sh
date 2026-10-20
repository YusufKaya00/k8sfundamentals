#!/usr/bin/env bash
# ==============================================================================
# ⚔️  Syncalibur (syncalibur.sh) - Cross-Platform Git Auto-Sync Daemon
# ------------------------------------------------------------------------------
# Watches a git repository (or a specific subdirectory inside one) and
# automatically stages, commits, and pushes changes in the background.
#
# Supported operating systems & auto-start backends:
#   - Linux (systemd) : ~/.config/systemd/user/<service>.service
#   - Linux (fallback): crontab @reboot + ~/.config/autostart/<service>.desktop
#   - macOS (launchd) : ~/Library/LaunchAgents/com.syncalibur.<service>.plist
#   - Windows         : Startup folder hidden VBS launcher (Git Bash / MSYS2)
#
# Configuration is loaded from (highest priority first):
#   1. Environment variables already set in the shell
#   2. Config file specified by $SYNCALIBUR_CONFIG
#   3. scripts/syncalibur.env (next to this script)
#   4. Built-in defaults (watches the repository containing this script)
#
# Usage : ./scripts/syncalibur.sh {install|uninstall|start|stop|restart|status|logs|run}
# Docs  : ./scripts/README.md
# ==============================================================================

set -uo pipefail
# NOTE: `set -e` is intentionally omitted. The daemon loop must survive
# transient git/network errors rather than exiting unexpectedly.

# ==============================================================================
# Cross-platform portability helpers (Linux, macOS Bash 3.2+, Windows Git Bash)
# ==============================================================================

OS_KERNEL="$(uname -s 2>/dev/null || echo Unknown)"

# Convert Windows paths (e.g. C:\Users\...) to POSIX paths when running under
# Git Bash / MSYS2 / Cygwin, and expand a leading ~ to $HOME.
normalize_path_input() {
  local raw="$1"
  raw="${raw/#\~/${HOME}}"
  if command -v cygpath >/dev/null 2>&1 && [[ "${raw}" =~ ^[A-Za-z]:[\\/] ]]; then
    cygpath -u "${raw}"
  else
    printf '%s\n' "${raw}"
  fi
}

# Portable replacement for `readlink -f` (works on macOS BSD userland too).
resolve_path() {
  local target="$1"
  if [[ -d "${target}" ]]; then
    (cd "${target}" 2>/dev/null && pwd -P)
    return
  fi
  local dir base
  dir="$(dirname "${target}")"
  base="$(basename "${target}")"
  if [[ -L "${target}" ]] && command -v readlink >/dev/null 2>&1; then
    local link
    link="$(readlink "${target}")"
    [[ "${link}" == /* ]] || link="${dir}/${link}"
    dir="$(dirname "${link}")"
    base="$(basename "${link}")"
  fi
  (cd "${dir}" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "${base}")
}

# Detect whether `stat` uses GNU flags (-c) or BSD/macOS flags (-f).
if stat -c '%s' . >/dev/null 2>&1; then
  STAT_FLAVOR="gnu"
else
  STAT_FLAVOR="bsd"
fi

# Print file size in bytes (portable across GNU and BSD/macOS).
file_size_bytes() {
  if [[ "${STAT_FLAVOR}" == "gnu" ]]; then
    stat -c '%s' -- "$1" 2>/dev/null || echo 0
  else
    stat -f '%z' -- "$1" 2>/dev/null || echo 0
  fi
}

# Print "<size> <mtime>" signature for change detection.
file_signature() {
  if [[ "${STAT_FLAVOR}" == "gnu" ]]; then
    stat -c '%s %Y' -- "$1" 2>/dev/null || echo gone
  else
    stat -f '%z %m' -- "$1" 2>/dev/null || echo gone
  fi
}

# Run a command with a timeout in seconds. Returns 124 on timeout.
# Uses GNU `timeout` when available; falls back to a background watchdog on macOS.
run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
    return $?
  fi

  "$@" &
  local cmd_pid=$!
  (
    sleep "${secs}"
    kill -TERM "${cmd_pid}" 2>/dev/null || true
  ) &
  local watchdog_pid=$!

  wait "${cmd_pid}" 2>/dev/null
  local rc=$?
  if kill -0 "${watchdog_pid}" 2>/dev/null; then
    kill "${watchdog_pid}" 2>/dev/null || true
    wait "${watchdog_pid}" 2>/dev/null || true
    return "${rc}"
  fi
  return 124
}

# Detect which background service manager to use on this OS.
detect_service_backend() {
  case "${OS_KERNEL}" in
    Darwin*)
      echo "launchd"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "windows-startup"
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units >/dev/null 2>&1; then
        echo "systemd"
      else
        echo "cron"
      fi
      ;;
  esac
}

SERVICE_BACKEND="$(detect_service_backend)"

# ==============================================================================
# Configuration file loading
# ==============================================================================

SCRIPT_PATH="$(resolve_path "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
LOGO_ANSI_FILE="${SCRIPT_DIR}/assets/syncalibur-logo.ansi"

# Supported configuration keys in syncalibur.env (both SYNCALIBUR_* and AUTO_SYNC_* are accepted).
CONFIG_KEYS=" SYNCALIBUR_REPO_PATH SYNCALIBUR_SERVICE_NAME SYNCALIBUR_REMOTE SYNCALIBUR_POLL_INTERVAL
  SYNCALIBUR_DEBOUNCE_WAIT SYNCALIBUR_MAX_DEBOUNCE SYNCALIBUR_MAX_FILE_SIZE_MB SYNCALIBUR_SENSITIVE_PATTERNS
  SYNCALIBUR_RETRY_BASE SYNCALIBUR_RETRY_MAX SYNCALIBUR_PUSH_TIMEOUT SYNCALIBUR_LOG_MAX_KB
  AUTO_SYNC_REPO_PATH AUTO_SYNC_SERVICE_NAME AUTO_SYNC_REMOTE AUTO_SYNC_POLL_INTERVAL
  AUTO_SYNC_DEBOUNCE_WAIT AUTO_SYNC_MAX_DEBOUNCE AUTO_SYNC_MAX_FILE_SIZE_MB AUTO_SYNC_SENSITIVE_PATTERNS
  AUTO_SYNC_RETRY_BASE AUTO_SYNC_RETRY_MAX AUTO_SYNC_PUSH_TIMEOUT AUTO_SYNC_LOG_MAX_KB "

# Safely parse a KEY=VALUE env file without executing shell code.
# Shell environment variables set prior to invocation take precedence.
load_config() {
  local file="$1" line key value n=0 is_set=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$(( n + 1 ))
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    if ! [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      echo "⚠️  ${file}:${n}: ignoring malformed line: ${line}" >&2
      continue
    fi
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if [[ "${CONFIG_KEYS}" != *[[:space:]]"${key}"[[:space:]]* ]]; then
      echo "⚠️  ${file}:${n}: unknown key '${key}' (ignored)" >&2
      continue
    fi
    if [[ "${value}" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ || "${value}" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    # Bash 3.2-safe check for whether variable `${key}` is already set in env.
    eval "[[ -n \"\${${key}+x}\" ]] && is_set=1 || is_set=0"
    (( is_set )) && continue
    printf -v "${key}" '%s' "${value}"
  done < "${file}"
}

DEFAULT_ENV_FILE="${SCRIPT_DIR}/syncalibur.env"
CONFIG_FILE="${SYNCALIBUR_CONFIG:-${AUTO_SYNC_CONFIG:-${DEFAULT_ENV_FILE}}}"

# If the user runs `install /path/to/repo`, write/update syncalibur.env first.
save_repo_path_to_env() {
  local target_path="$1"
  local env_file="${SYNCALIBUR_CONFIG:-${AUTO_SYNC_CONFIG:-${DEFAULT_ENV_FILE}}}"
  if [[ -f "${env_file}" ]]; then
    local tmp
    tmp="$(mktemp)"
    grep -vE '^[[:space:]]*(export[[:space:]]+)?(SYNCALIBUR_REPO_PATH|AUTO_SYNC_REPO_PATH)=' "${env_file}" > "${tmp}" || true
    printf 'SYNCALIBUR_REPO_PATH="%s"\n' "${target_path}" >> "${tmp}"
    mv "${tmp}" "${env_file}"
  else
    cat > "${env_file}" << EOF
# Syncalibur configuration (generated by 'install')
# Path to the git repository (or subfolder inside a repo) to watch and sync:
SYNCALIBUR_REPO_PATH="${target_path}"
EOF
  fi
  CONFIG_FILE="$(resolve_path "${env_file}")"
  SYNCALIBUR_REPO_PATH="${target_path}"
}

if [[ "${1:-}" == "install" && -n "${2:-}" ]]; then
  INSTALL_ARG_PATH="$(normalize_path_input "${2}")"
  if [[ ! -d "${INSTALL_ARG_PATH}" ]]; then
    echo "❌ Specified directory does not exist: ${2}" >&2
    exit 1
  fi
  INSTALL_ARG_PATH="$(resolve_path "${INSTALL_ARG_PATH}")"
  save_repo_path_to_env "${INSTALL_ARG_PATH}"
fi

if [[ -f "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="$(resolve_path "${CONFIG_FILE}")"
  load_config "${CONFIG_FILE}"
elif [[ -n "${SYNCALIBUR_CONFIG:-${AUTO_SYNC_CONFIG:-}}" ]]; then
  echo "❌ Config file not found: ${CONFIG_FILE}" >&2
  exit 1
else
  CONFIG_FILE=""
fi

# ==============================================================================
# Repository & scope resolution
# ==============================================================================

WATCH_PATH="${SYNCALIBUR_REPO_PATH:-${AUTO_SYNC_REPO_PATH:-}}"
if [[ -n "${WATCH_PATH}" ]]; then
  WATCH_PATH="$(normalize_path_input "${WATCH_PATH}")"
  [[ "${WATCH_PATH}" == /* ]] || WATCH_PATH="$(dirname "${CONFIG_FILE:-${SCRIPT_PATH}}")/${WATCH_PATH}"
  if [[ ! -d "${WATCH_PATH}" ]]; then
    echo "❌ SYNCALIBUR_REPO_PATH does not exist: ${WATCH_PATH}" >&2
    exit 1
  fi
else
  WATCH_PATH="${SCRIPT_DIR}"
fi
WATCH_PATH="$(resolve_path "${WATCH_PATH}")"

REPO_ROOT="$(git -C "${WATCH_PATH}" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "❌ '${WATCH_PATH}' is not inside a git repository." >&2
  echo "   Set SYNCALIBUR_REPO_PATH in ${DEFAULT_ENV_FILE}" >&2
  echo "   or run: ${SCRIPT_PATH} install /path/to/your/repo" >&2
  exit 1
}
REPO_ROOT="$(resolve_path "${REPO_ROOT}")"
GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --absolute-git-dir)"

# Relative path from REPO_ROOT to WATCH_PATH ("." watches the entire repo).
SCOPE="$(git -C "${WATCH_PATH}" rev-parse --show-prefix 2>/dev/null || true)"
SCOPE="${SCOPE%/}"
SCOPE="${SCOPE:-.}"

# Runtime files live inside .git/ so they are never tracked by git.
PID_FILE="${GIT_DIR}/syncalibur.pid"
LOCK_FILE="${GIT_DIR}/syncalibur.lock"
LOG_FILE="${GIT_DIR}/syncalibur.log"

SERVICE_NAME="${SYNCALIBUR_SERVICE_NAME:-${AUTO_SYNC_SERVICE_NAME:-syncalibur}}"
if ! [[ "${SERVICE_NAME}" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
  echo "❌ SYNCALIBUR_SERVICE_NAME may only contain letters, digits and _ . @ - (got '${SERVICE_NAME}')." >&2
  exit 1
fi

# OS-specific service file paths
UNIT_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/${SERVICE_NAME}.service"
PLIST_LABEL="com.syncalibur.${SERVICE_NAME}"
PLIST_FILE="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
DESKTOP_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/autostart/${SERVICE_NAME}.desktop"

win_startup_vbs_path() {
  local appdata_posix=""
  if command -v cygpath >/dev/null 2>&1 && [[ -n "${APPDATA:-}" ]]; then
    appdata_posix="$(cygpath -u "${APPDATA}")"
  elif [[ -d "${HOME}/AppData/Roaming" ]]; then
    appdata_posix="${HOME}/AppData/Roaming"
  fi
  if [[ -n "${appdata_posix}" ]]; then
    printf '%s/Microsoft/Windows/Start Menu/Programs/Startup/%s.vbs\n' "${appdata_posix}" "${SERVICE_NAME}"
  else
    printf '%s/.config/syncalibur/%s.vbs\n' "${HOME}" "${SERVICE_NAME}"
  fi
}

# ==============================================================================
# Tunable parameters
# ==============================================================================

POLL_INTERVAL="${SYNCALIBUR_POLL_INTERVAL:-${AUTO_SYNC_POLL_INTERVAL:-3}}"          # Seconds between change checks
DEBOUNCE_WAIT="${SYNCALIBUR_DEBOUNCE_WAIT:-${AUTO_SYNC_DEBOUNCE_WAIT:-5}}"          # Seconds files must remain untouched before commit
MAX_DEBOUNCE="${SYNCALIBUR_MAX_DEBOUNCE:-${AUTO_SYNC_MAX_DEBOUNCE:-60}}"            # Maximum seconds to wait if files change continuously
MAX_FILE_SIZE_MB="${SYNCALIBUR_MAX_FILE_SIZE_MB:-${AUTO_SYNC_MAX_FILE_SIZE_MB:-50}}" # Skip files larger than this MiB limit (0 = unlimited)
RETRY_BASE="${SYNCALIBUR_RETRY_BASE:-${AUTO_SYNC_RETRY_BASE:-30}}"                  # Initial backoff delay after a failed push (seconds)
RETRY_MAX="${SYNCALIBUR_RETRY_MAX:-${AUTO_SYNC_RETRY_MAX:-900}}"                    # Maximum backoff delay between push retries (seconds)
PUSH_TIMEOUT="${SYNCALIBUR_PUSH_TIMEOUT:-${AUTO_SYNC_PUSH_TIMEOUT:-120}}"           # Timeout in seconds for `git push`
LOG_MAX_KB="${SYNCALIBUR_LOG_MAX_KB:-${AUTO_SYNC_LOG_MAX_KB:-1024}}"                # Maximum log file size in KiB before trimming
REMOTE_OVERRIDE="${SYNCALIBUR_REMOTE:-${AUTO_SYNC_REMOTE:-}}"                       # Remote name (defaults to "all" if present, else "origin")

DEFAULT_SENSITIVE_PATTERNS='*.tfstate *.tfstate.* *.tfvars .env .env.* *.pem *.key *.p12 *.pfx id_rsa* id_ecdsa* id_ed25519* kubeconfig *.kubeconfig credentials.json'
EFFECTIVE_SENSITIVE="${SYNCALIBUR_SENSITIVE_PATTERNS-${AUTO_SYNC_SENSITIVE_PATTERNS-${DEFAULT_SENSITIVE_PATTERNS}}}"
read -r -a SENSITIVE_PATTERNS <<< "${EFFECTIVE_SENSITIVE}"

for var in POLL_INTERVAL DEBOUNCE_WAIT MAX_DEBOUNCE MAX_FILE_SIZE_MB RETRY_BASE RETRY_MAX PUSH_TIMEOUT LOG_MAX_KB; do
  if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
    echo "❌ ${var} must be a non-negative integer (got '${!var}')." >&2
    exit 1
  fi
done
if (( POLL_INTERVAL < 1 || DEBOUNCE_WAIT < 1 || RETRY_BASE < 1 )); then
  echo "❌ POLL_INTERVAL, DEBOUNCE_WAIT and RETRY_BASE must be at least 1 second." >&2
  exit 1
fi
MAX_FILE_BYTES=$(( MAX_FILE_SIZE_MB * 1024 * 1024 ))

# Fail immediately instead of hanging if git ever asks for interactive input.
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never

# ==============================================================================
# Terminal Theme, Avatar Renderer & Styled Log Formatter
# ==============================================================================

# Palette inspired by the Syncalibur emblem (Orokin Gold + Sentient Cyan + Dark Armor)
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GOLD=$'\033[38;2;245;194;66m'
C_CYAN=$'\033[38;2;56;189;248m'
C_GREEN=$'\033[38;2;52;211;153m'
C_RED=$'\033[38;2;248;113;113m'
C_AMBER=$'\033[38;2;251;191;36m'
C_SLATE=$'\033[38;2;148;163;184m'
C_WHITE=$'\033[38;2;241;245;249m'

# Fallback 16-row ASCII emblem if `assets/syncalibur-logo.ansi` is absent.
fallback_logo_line() {
  case "$1" in
    1)  printf '%s' "          ${C_GOLD}▄▄████████▄▄${C_RESET}          " ;;
    2)  printf '%s' "       ${C_GOLD}▄██▀▀${C_WHITE}   ██   ${C_GOLD}▀▀██▄${C_RESET}       " ;;
    3)  printf '%s' "     ${C_GOLD}▄█▀${C_SLATE}     ▄████▄     ${C_GOLD}▀█▄${C_RESET}     " ;;
    4)  printf '%s' "    ${C_GOLD}██${C_SLATE}      ██▀${C_CYAN}██${C_SLATE}▀██      ${C_GOLD}██${C_RESET}    " ;;
    5)  printf '%s' "   ${C_GOLD}██${C_SLATE}      ███ ${C_CYAN}██${C_SLATE} ███      ${C_GOLD}██${C_RESET}   " ;;
    6)  printf '%s' "  ${C_GOLD}██   ▄▄${C_WHITE}▀███${C_SLATE}▄▄▄▄▄▄${C_WHITE}███▀${C_GOLD}▄▄   ██${C_RESET}  " ;;
    7)  printf '%s' " ${C_GOLD}◄███▀▀${C_SLATE}    ▀█${C_GOLD}▄████▄${C_SLATE}█▀    ${C_GOLD}▀▀███►${C_RESET} " ;;
    8)  printf '%s' "  ${C_GOLD}██▄▄     ██${C_CYAN}██▀▀██${C_GOLD}██     ▄▄██${C_RESET}  " ;;
    9)  printf '%s' "  ${C_GOLD}██ ▀▀██▄▄██${C_CYAN}██▄▄██${C_GOLD}██▄▄██▀▀ ██${C_RESET}  " ;;
    10) printf '%s' "   ${C_GOLD}██${C_WHITE}   ▀▀███${C_GOLD}▀████▀${C_WHITE}███▀▀   ${C_GOLD}██${C_RESET}   " ;;
    11) printf '%s' "    ${C_GOLD}██${C_WHITE}     ▀█▄${C_WHITE}▀██▀${C_WHITE}▄█▀     ${C_GOLD}██${C_RESET}    " ;;
    12) printf '%s' "     ${C_GOLD}▀█▄${C_SLATE}   ${C_GOLD}◄█►${C_WHITE}████${C_GOLD}◄█►${C_SLATE}   ${C_GOLD}▄█▀${C_RESET}     " ;;
    13) printf '%s' "       ${C_GOLD}▀██▄▄${C_SLATE} ▀████▀ ${C_GOLD}▄▄██▀${C_RESET}       " ;;
    14) printf '%s' "          ${C_GOLD}▀▀████████▀▀${C_RESET}          " ;;
    15) printf '%s' "             ${C_WHITE}▀████▀${C_RESET}             " ;;
    16) printf '%s' "               ${C_GOLD}▀▀${C_RESET}               " ;;
  esac
}

# Format a raw `[YYYY-MM-DD HH:MM:SS] message` log line with Syncalibur badges & colors.
format_log_line() {
  local raw="$1"
  if [[ "${raw}" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}:[0-9]{2}:[0-9]{2})\]\ (.*)$ ]]; then
    local ts="${BASH_REMATCH[2]}"
    local msg="${BASH_REMATCH[3]}"
    local badge_color="${C_SLATE}"
    local badge_text="◈ INFO     "
    local msg_color="${C_WHITE}"

    case "${msg}" in
      *"Syncalibur started"*|*"başlatıldı"*)
        badge_color="${C_GOLD}"; badge_text="⚔️  ONLINE  "; msg_color="${C_GOLD}${C_BOLD}" ;;
      *"Poll:"*|*"Kontrol aralığı:"*)
        badge_color="${C_CYAN}"; badge_text="⚙ CONFIG   "; msg_color="${C_SLATE}" ;;
      *"Changes detected"*|*"Değişiklik algılandı"*)
        badge_color="${C_CYAN}"; badge_text="◉ DETECTED "; msg_color="${C_CYAN}" ;;
      *"Committed"*|*"Commit oluşturuldu"*)
        badge_color="${C_GREEN}"; badge_text="✔ COMMIT   "; msg_color="${C_GREEN}" ;;
      *"Pushing to"*|*"Uzak depoya"*)
        badge_color="${C_GOLD}"; badge_text="▲ PUSHING  "; msg_color="${C_GOLD}" ;;
      *"Push succeeded"*|*"Başarıyla pushlandı"*)
        badge_color="${C_GREEN}${C_BOLD}"; badge_text="★ SYNCED   "; msg_color="${C_GREEN}${C_BOLD}" ;;
      *"Not committing"*)
        badge_color="${C_AMBER}"; badge_text="🛡 GUARD    "; msg_color="${C_AMBER}" ;;
      *"Push failed"*|*"timed out"*|*"failed"*|*"Another Syncalibur"*)
        badge_color="${C_RED}${C_BOLD}"; badge_text="✖ ERROR    "; msg_color="${C_RED}" ;;
      *"Retrying"*)
        badge_color="${C_AMBER}"; badge_text="↻ RETRY    "; msg_color="${C_AMBER}" ;;
      *"paused"*)
        badge_color="${C_AMBER}"; badge_text="⏸ PAUSED   "; msg_color="${C_AMBER}" ;;
      *"stopped"*|*"durduruldu"*)
        badge_color="${C_RED}"; badge_text="■ STOPPED  "; msg_color="${C_SLATE}" ;;
    esac

    printf '%s[%s]%s %s⟪%s⟫%s %s%s%s\n' \
      "${C_SLATE}" "${ts}" "${C_RESET}" \
      "${badge_color}" "${badge_text}" "${C_RESET}" \
      "${msg_color}" "${msg}" "${C_RESET}"
  else
    printf '           %s│ %s%s\n' "${C_SLATE}" "${raw}" "${C_RESET}"
  fi
}

# Print the side-by-side Syncalibur Emblem + Status Dashboard (16 rows).
print_syncalibur_dashboard() {
  local pid state_str autostart_str branch remote target_str unpushed_str cfg_short watch_short log_short
  if pid="$(daemon_pid)"; then
    state_str="${C_GREEN}${C_BOLD}● ONLINE${C_RESET} ${C_SLATE}(PID ${pid})${C_RESET}"
  else
    state_str="${C_RED}${C_BOLD}○ OFFLINE${C_RESET}"
  fi

  if is_service_installed; then
    autostart_str="${C_GREEN}✔ Enabled${C_RESET} ${C_SLATE}(${SERVICE_NAME} • ${SERVICE_BACKEND})${C_RESET}"
  else
    autostart_str="${C_AMBER}○ Not installed${C_RESET} ${C_SLATE}(${SERVICE_BACKEND})${C_RESET}"
  fi

  remote="$(cd "${REPO_ROOT}" && get_remote)"
  if branch="$(cd "${REPO_ROOT}" && get_branch)"; then
    target_str="${C_CYAN}${remote}/${branch}${C_RESET}"
    local up_cnt
    up_cnt="$(cd "${REPO_ROOT}" && unpushed_count "${remote}" "${branch}")"
    if (( up_cnt == 0 )); then
      unpushed_str="${C_GREEN}0 commits (in sync)${C_RESET}"
    else
      unpushed_str="${C_AMBER}${up_cnt} commit(s) pending push${C_RESET}"
    fi
  else
    target_str="${C_AMBER}${remote} (detached HEAD)${C_RESET}"
    unpushed_str="${C_AMBER}paused${C_RESET}"
  fi

  cfg_short="${CONFIG_FILE:-<defaults>}"
  cfg_short="${cfg_short/#${HOME}/~}"
  watch_short="${WATCH_PATH/#${HOME}/~}"
  log_short="${LOG_FILE/#${HOME}/~}"

  local -a info_lines=(
    "${C_GOLD}╭──────────────────────────────────────────────────────────╮${C_RESET}"
    "${C_GOLD}│${C_RESET}  ⚔️  ${C_GOLD}${C_BOLD}S Y N C A L I B U R${C_RESET}   ${C_SLATE}•${C_RESET}   ${C_CYAN}Autonomous Git Sync${C_RESET}       ${C_GOLD}│${C_RESET}"
    "${C_GOLD}╰──────────────────────────────────────────────────────────╯${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Status    :${C_RESET} ${state_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}OS / Mode :${C_RESET} ${C_WHITE}${OS_KERNEL} (${SERVICE_BACKEND})${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Autostart :${C_RESET} ${autostart_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Config    :${C_RESET} ${C_SLATE}${cfg_short}${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Watching  :${C_RESET} ${C_WHITE}${watch_short}${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Scope     :${C_RESET} ${C_SLATE}${SCOPE}${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Target    :${C_RESET} ${target_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Sync State:${C_RESET} ${unpushed_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Timing    :${C_RESET} ${C_SLATE}Poll ${POLL_INTERVAL}s • Debounce ${DEBOUNCE_WAIT}s (max ${MAX_DEBOUNCE}s)${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Shield    :${C_RESET} ${C_SLATE}≤ ${MAX_FILE_SIZE_MB} MiB • Secret guard active${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Log File  :${C_RESET} ${C_SLATE}${log_short}${C_RESET}"
    "  ${C_SLATE}──────────────────────────────────────────────────────────${C_RESET}"
    "  ${C_SLATE}Commands  : ${C_CYAN}status${C_SLATE} | ${C_CYAN}logs${C_SLATE} | ${C_CYAN}restart${C_SLATE} | ${C_CYAN}stop${C_SLATE} | ${C_CYAN}install${C_RESET}"
  )

  local -a logo_lines=()
  local line
  if [[ -f "${LOGO_ANSI_FILE}" ]]; then
    while IFS= read -r line; do
      logo_lines+=("${line}")
    done < "${LOGO_ANSI_FILE}"
  fi

  printf '\n'
  local i=0
  while (( i < 16 )); do
    if (( ${#logo_lines[@]} >= 16 )); then
      printf '  %s   %s\n' "${logo_lines[$i]}" "${info_lines[$i]}"
    else
      printf '  %s   %s\n' "$(fallback_logo_line $(( i + 1 )))" "${info_lines[$i]}"
    fi
    i=$(( i + 1 ))
  done
  printf '\n'
}

# ==============================================================================
# Logging & sleep helpers
# ==============================================================================

log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "${line}" >> "${LOG_FILE}"
  if [[ "${SYNCALIBUR_BACKGROUND:-0}" != "1" ]]; then
    if [[ -t 1 ]]; then
      format_log_line "${line}"
    else
      printf '%s\n' "${line}"
    fi
  fi
}

LAST_NOTICE=""
notice() {
  [[ "$*" == "${LAST_NOTICE}" ]] && return 0
  LAST_NOTICE="$*"
  log "$@"
}

# Track already-warned blocked paths in a newline-separated string (Bash 3.2 compatible).
WARNED_PATHS=""
warn_blocked() {
  local path="$1" reason="$2"
  case $'\n'"${WARNED_PATHS}"$'\n' in
    *$'\n'"${path}"$'\n'*) return 0 ;;
  esac
  WARNED_PATHS="${WARNED_PATHS}"$'\n'"${path}"
  log "🚫 Not committing '${path}': ${reason}. Add it to .gitignore to silence this warning."
}

trim_log() {
  local max_bytes=$(( LOG_MAX_KB * 1024 )) size tmp
  [[ -f "${LOG_FILE}" ]] || return 0
  size="$(file_size_bytes "${LOG_FILE}")"
  (( size > max_bytes )) || return 0
  tmp="$(mktemp)" || return 0
  if tail -c "$(( max_bytes / 2 ))" "${LOG_FILE}" | tail -n +2 > "${tmp}"; then
    cat "${tmp}" > "${LOG_FILE}"
  fi
  rm -f "${tmp}"
}

NAP_PID=""
nap() {
  sleep "${1:-${POLL_INTERVAL}}" &
  NAP_PID=$!
  wait "${NAP_PID}" 2>/dev/null || true
  NAP_PID=""
}

# ==============================================================================
# Git helpers (called with current working directory = REPO_ROOT)
# ==============================================================================

get_remote() {
  if [[ -n "${REMOTE_OVERRIDE}" ]]; then
    echo "${REMOTE_OVERRIDE}"
  elif git remote | grep -qx "all"; then
    echo "all"
  else
    echo "origin"
  fi
}

get_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null
}

repo_busy() {
  local marker
  for marker in index.lock MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    if [[ -e "${GIT_DIR}/${marker}" ]]; then
      echo "${marker}"
      return 0
    fi
  done
  return 1
}

unpushed_count() {
  local remote="$1" branch="$2"
  if git rev-parse -q --verify "refs/remotes/${remote}/${branch}" >/dev/null 2>&1; then
    git rev-list --count "refs/remotes/${remote}/${branch}..HEAD" 2>/dev/null || echo 0
  else
    git rev-list --count HEAD 2>/dev/null || echo 0
  fi
}

has_changes_in_scope() {
  [[ -n "$(git status --porcelain -uall -- "${SCOPE}" 2>/dev/null)" ]]
}

# Compute a portable SHA-1 fingerprint of all modified paths + their sizes/mtimes
# within SCOPE using `git hash-object` (works on Linux, macOS, and Windows).
snapshot() {
  git -c core.quotePath=false status --porcelain -uall -- "${SCOPE}" 2>/dev/null \
    | sed -E 's/^.{3}//; s/^.* -> //; s/^"(.*)"$/\1/' \
    | while IFS= read -r path; do
        printf '%s %s\n' "${path}" "$(file_signature "${path}")"
      done \
    | git hash-object --stdin
}

wait_for_quiet() {
  local previous current waited=0
  previous="$(snapshot)"
  while (( waited < MAX_DEBOUNCE )); do
    nap "${DEBOUNCE_WAIT}"
    waited=$(( waited + DEBOUNCE_WAIT ))
    current="$(snapshot)"
    [[ "${current}" == "${previous}" ]] && return 0
    previous="${current}"
  done
  log "⏳ Files still changing after ${MAX_DEBOUNCE}s; committing anyway."
}

# Emit NUL-separated paths of added/modified files within SCOPE.
changed_paths() {
  local entry xy
  while IFS= read -r -d '' entry; do
    xy="${entry:0:2}"
    if [[ "${xy}" == R* || "${xy}" == C* ]]; then
      IFS= read -r -d '' _
    fi
    [[ "${xy}" == *D* ]] && continue
    printf '%s\0' "${entry:3}"
  done < <(git status --porcelain -z -uall -- "${SCOPE}" 2>/dev/null)
}

block_reason() {
  local path="$1" name="${1##*/}" pattern size
  case "${name}" in
    *.example | *.sample | *.template | *.dist) ;;
    *)
      if (( ${#SENSITIVE_PATTERNS[@]} > 0 )); then
        for pattern in "${SENSITIVE_PATTERNS[@]}"; do
          [[ -z "${pattern}" ]] && continue
          # shellcheck disable=SC2053
          if [[ "${name}" == ${pattern} ]]; then
            echo "looks sensitive (matches '${pattern}')"
            return 0
          fi
        done
      fi
      ;;
  esac
  if (( MAX_FILE_BYTES > 0 )) && [[ -f "${path}" && ! -L "${path}" ]]; then
    size="$(file_size_bytes "${path}")"
    if (( size > MAX_FILE_BYTES )); then
      echo "too large ($(( size / 1024 / 1024 )) MiB > ${MAX_FILE_SIZE_MB} MiB limit)"
      return 0
    fi
  fi
  return 1
}

commit_changes() {
  local path reason msg count line
  local -a excludes=() files=()

  # 1) Exclude oversized/sensitive files before `git add` so large blobs are
  #    never hashed into .git/objects.
  while IFS= read -r -d '' path; do
    if reason="$(block_reason "${path}")"; then
      excludes+=(":(exclude,literal)${path}")
      warn_blocked "${path}" "${reason}"
    fi
  done < <(changed_paths)

  # 2) Stage everything else inside SCOPE.
  if ! git add -A -- "${SCOPE}" "${excludes[@]}" >> "${LOG_FILE}" 2>&1; then
    log "❌ 'git add' failed (details in ${LOG_FILE})."
    return 1
  fi

  # 3) Safety net: unstage any blocked file that the user staged manually.
  while IFS= read -r -d '' path; do
    if reason="$(block_reason "${path}")"; then
      git reset -q -- "${path}" 2>/dev/null || git rm -q --cached -- "${path}" >/dev/null 2>&1
      warn_blocked "${path}" "${reason}"
    fi
  done < <(git diff --cached --name-only -z --diff-filter=ACMR)

  git diff --cached --quiet && return 1

  while IFS= read -r line; do
    [[ -n "${line}" ]] && files+=("${line}")
  done < <(git -c core.quotePath=false diff --cached --name-only)

  count=${#files[@]}
  msg="auto: ${files[0]}"
  (( count > 1 )) && msg+=", ${files[1]}"
  (( count > 2 )) && msg+=" (+$(( count - 2 )) more)"
  msg+=" ($(date '+%H:%M:%S'))"

  if git commit -q -m "${msg}" >> "${LOG_FILE}" 2>&1; then
    log "✅ Committed ${count} file(s): ${msg}"
    return 0
  fi
  log "❌ 'git commit' failed (details in ${LOG_FILE})."
  return 1
}

push_error_summary() {
  local line summary="" count=0
  while IFS= read -r line; do
    line="${line#remote:}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue
    if [[ -z "${summary}" ]]; then
      summary="${line}"
    else
      summary="${summary} | ${line}"
    fi
    count=$(( count + 1 ))
    (( count >= 3 )) && break
  done < <(grep -iE 'rejected|error|fatal|denied|exceed|too large|LFS|could not' <<< "$1")
  echo "${summary:-unknown error, see ${LOG_FILE}}"
}

push_changes() {
  local remote="$1" branch="$2" output rc
  log "📤 Pushing to '${remote}' (${branch})..."
  output="$(run_with_timeout "${PUSH_TIMEOUT}" git push "${remote}" "${branch}" 2>&1)"
  rc=$?
  printf '%s\n' "${output}" >> "${LOG_FILE}"
  if (( rc == 0 )); then
    log "🎉 Push succeeded."
    return 0
  fi
  if (( rc == 124 )); then
    log "⚠️  Push timed out after ${PUSH_TIMEOUT}s."
  else
    log "⚠️  Push failed: $(push_error_summary "${output}")"
  fi
  return 1
}

# ==============================================================================
# Daemon loop
# ==============================================================================

daemon_pid() {
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null)" || return 1
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && echo "${pid}"
}

acquire_single_instance_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9> "${LOCK_FILE}"
    flock -w 5 9 || return 1
    return 0
  fi
  local existing_pid
  if existing_pid="$(daemon_pid)" && [[ "${existing_pid}" != "$$" ]]; then
    return 1
  fi
  return 0
}

on_exit() {
  [[ -n "${NAP_PID}" ]] && kill "${NAP_PID}" 2>/dev/null || true
  rm -f "${PID_FILE}"
  log "🛑 Syncalibur stopped."
}

run_daemon() {
  cd "${REPO_ROOT}" || exit 1
  mkdir -p "$(dirname "${LOG_FILE}")"

  if ! acquire_single_instance_lock; then
    log "❌ Another Syncalibur instance is already running for ${REPO_ROOT}."
    exit 1
  fi
  echo "$$" > "${PID_FILE}"
  trap on_exit EXIT
  trap 'exit 0' INT TERM

  # When running interactively in a terminal (`./scripts/syncalibur.sh run`),
  # render the full Syncalibur emblem & dashboard header first.
  if [[ "${SYNCALIBUR_BACKGROUND:-0}" != "1" && -t 1 ]]; then
    print_syncalibur_dashboard
  fi

  local remote branch busy head snap
  local idle_snapshot="" checked_head="" push_pending=0 next_retry=0 retry_delay="${RETRY_BASE}"

  log "⚔️  Syncalibur started. Repo: ${REPO_ROOT} (scope: ${SCOPE}) | Remote: $(get_remote)"
  log "⏱️  Poll: ${POLL_INTERVAL}s | Debounce: ${DEBOUNCE_WAIT}s (max ${MAX_DEBOUNCE}s) | Max file size: ${MAX_FILE_SIZE_MB} MiB"

  while true; do
    trim_log
    remote="$(get_remote)"

    if ! branch="$(get_branch)"; then
      notice "⏸️  Detached HEAD; paused until a branch is checked out."
      nap; continue
    fi
    if busy="$(repo_busy)"; then
      notice "⏸️  Git operation in progress (${busy}); paused."
      nap; continue
    fi
    LAST_NOTICE=""

    # --- 1) Stage & commit local file changes --------------------------------
    if has_changes_in_scope; then
      snap="$(snapshot)"
      if [[ "${snap}" != "${idle_snapshot}" ]]; then
        log "📝 Changes detected; waiting for writes to settle..."
        wait_for_quiet
        repo_busy >/dev/null && continue
        if commit_changes; then
          idle_snapshot="$(snapshot)"
          push_pending=1; next_retry=0; retry_delay="${RETRY_BASE}"
        else
          idle_snapshot="$(snapshot)"
        fi
      fi
    fi

    # --- 2) Detect unpushed commits (startup, manual commits, branch switch) -
    head="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"
    if [[ -n "${head}" && "${head}" != "${checked_head}" ]]; then
      checked_head="${head}"
      if (( $(unpushed_count "${remote}" "${branch}") > 0 )); then
        push_pending=1
      fi
    fi

    # --- 3) Push to remote, retrying with exponential backoff ----------------
    if (( push_pending )) && (( $(date +%s) >= next_retry )); then
      if push_changes "${remote}" "${branch}"; then
        push_pending=0
        retry_delay="${RETRY_BASE}"
      else
        next_retry=$(( $(date +%s) + retry_delay ))
        log "🔁 Retrying the push in ${retry_delay}s."
        retry_delay=$(( retry_delay * 2 > RETRY_MAX ? RETRY_MAX : retry_delay * 2 ))
      fi
    fi

    nap
  done
}

# ==============================================================================
# Cross-platform Service Management (install / uninstall / start / stop / status)
# ==============================================================================

is_service_installed() {
  case "${SERVICE_BACKEND}" in
    systemd)         [[ -f "${UNIT_FILE}" ]] ;;
    launchd)         [[ -f "${PLIST_FILE}" ]] ;;
    windows-startup) [[ -f "$(win_startup_vbs_path)" ]] ;;
    cron)            crontab -l 2>/dev/null | grep -Fq "# syncalibur:${SERVICE_NAME}" || [[ -f "${DESKTOP_FILE}" ]] ;;
  esac
}

start_background_nohup() {
  local pid
  if pid="$(daemon_pid)"; then
    echo "⚠️  Syncalibur is already running (PID ${pid})."
    return 0
  fi
  mkdir -p "$(dirname "${LOG_FILE}")"
  SYNCALIBUR_BACKGROUND=1 SYNCALIBUR_CONFIG="${CONFIG_FILE}" \
    nohup bash "${SCRIPT_PATH}" run </dev/null >> "${LOG_FILE}" 2>&1 &
  sleep 1
  if pid="$(daemon_pid)"; then
    echo "✅ Syncalibur started in the background (PID ${pid})."
    echo "📋 Follow logs : ${SCRIPT_PATH} logs"
    echo "🛑 Stop daemon : ${SCRIPT_PATH} stop"
    return 0
  fi
  echo "❌ Failed to start. Check '${LOG_FILE}' for details." >&2
  return 1
}

stop_background_pid() {
  local pid
  if ! pid="$(daemon_pid)"; then
    echo "ℹ️  Syncalibur is not running."
    rm -f "${PID_FILE}"
    return 0
  fi
  echo "🛑 Stopping Syncalibur (PID ${pid})..."
  kill "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done
  kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
  rm -f "${PID_FILE}"
  echo "✅ Syncalibur stopped."
}

cmd_install() {
  if [[ -z "${CONFIG_FILE}" || ! -f "${CONFIG_FILE}" ]]; then
    save_repo_path_to_env "${WATCH_PATH}"
    echo "📝 Created config file: ${CONFIG_FILE} (watching ${WATCH_PATH})"
  fi

  case "${SERVICE_BACKEND}" in
    systemd)
      if ! is_service_installed && daemon_pid >/dev/null; then
        stop_background_pid
      fi
      mkdir -p "$(dirname "${UNIT_FILE}")"
      cat > "${UNIT_FILE}" << EOF
[Unit]
Description=Syncalibur - Git Auto-Sync Daemon for $(basename "${REPO_ROOT}")
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
Environment="SYNCALIBUR_CONFIG=${CONFIG_FILE}"
ExecStart=/usr/bin/env bash "${SCRIPT_PATH}" run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload \
        && systemctl --user enable "${SERVICE_NAME}" >/dev/null 2>&1 \
        && systemctl --user restart "${SERVICE_NAME}" \
        || { echo "❌ Could not enable/start systemd service '${SERVICE_NAME}'." >&2; return 1; }
      command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true
      ;;

    launchd)
      daemon_pid >/dev/null && stop_background_pid
      mkdir -p "$(dirname "${PLIST_FILE}")"
      cat > "${PLIST_FILE}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_PATH}</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO_ROOT}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SYNCALIBUR_CONFIG</key>
    <string>${CONFIG_FILE}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
EOF
      launchctl unload "${PLIST_FILE}" >/dev/null 2>&1 || true
      launchctl load -w "${PLIST_FILE}" || { echo "❌ launchctl load failed." >&2; return 1; }
      ;;

    windows-startup)
      local vbs_file bash_win script_win config_win
      vbs_file="$(win_startup_vbs_path)"
      mkdir -p "$(dirname "${vbs_file}")"
      if command -v cygpath >/dev/null 2>&1; then
        bash_win="$(cygpath -w "$(command -v bash)")"
        script_win="$(cygpath -w "${SCRIPT_PATH}")"
        config_win="$(cygpath -w "${CONFIG_FILE}")"
      else
        bash_win="bash.exe"
        script_win="${SCRIPT_PATH}"
        config_win="${CONFIG_FILE}"
      fi
      cat > "${vbs_file}" << EOF
Set WshShell = CreateObject("WScript.Shell")
Set WshEnv = WshShell.Environment("PROCESS")
WshEnv("SYNCALIBUR_CONFIG") = "${config_win}"
WshShell.Run """${bash_win}"" ""${script_win}"" start", 0, False
EOF
      daemon_pid >/dev/null && stop_background_pid
      start_background_nohup >/dev/null
      ;;

    cron)
      if command -v crontab >/dev/null 2>&1; then
        local cron_line="@reboot SYNCALIBUR_CONFIG=\"${CONFIG_FILE}\" \"${SCRIPT_PATH}\" start >/dev/null 2>&1 # syncalibur:${SERVICE_NAME}"
        (crontab -l 2>/dev/null | grep -Fv "# syncalibur:${SERVICE_NAME}" || true; echo "${cron_line}") | crontab - 2>/dev/null || true
      fi
      mkdir -p "$(dirname "${DESKTOP_FILE}")" 2>/dev/null || true
      cat > "${DESKTOP_FILE}" 2>/dev/null << EOF || true
[Desktop Entry]
Type=Application
Name=Syncalibur (${SERVICE_NAME})
Exec=/usr/bin/env SYNCALIBUR_CONFIG="${CONFIG_FILE}" "${SCRIPT_PATH}" start
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
      daemon_pid >/dev/null && stop_background_pid
      start_background_nohup >/dev/null
      ;;
  esac

  sleep 1
  print_syncalibur_dashboard
  echo "  ${C_GREEN}${C_BOLD}✔ Syncalibur installed and active!${C_RESET} It will start automatically on every boot/login."
  echo ""
}

cmd_uninstall() {
  case "${SERVICE_BACKEND}" in
    systemd)
      if [[ -f "${UNIT_FILE}" ]]; then
        systemctl --user disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f "${UNIT_FILE}"
        systemctl --user daemon-reload 2>/dev/null || true
      fi
      stop_background_pid >/dev/null 2>&1 || true
      echo "✅ Stopped, disabled and removed systemd service '${SERVICE_NAME}'."
      ;;
    launchd)
      if [[ -f "${PLIST_FILE}" ]]; then
        launchctl unload -w "${PLIST_FILE}" >/dev/null 2>&1 || true
        rm -f "${PLIST_FILE}"
      fi
      stop_background_pid >/dev/null 2>&1 || true
      echo "✅ Stopped and removed macOS LaunchAgent '${PLIST_LABEL}'."
      ;;
    windows-startup)
      rm -f "$(win_startup_vbs_path)"
      stop_background_pid
      echo "✅ Removed Windows Startup launcher and stopped Syncalibur."
      ;;
    cron)
      if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -Fv "# syncalibur:${SERVICE_NAME}" || true) | crontab - 2>/dev/null || true
      fi
      rm -f "${DESKTOP_FILE}"
      stop_background_pid
      echo "✅ Removed autostart entries and stopped Syncalibur."
      ;;
  esac
}

cmd_start() {
  case "${SERVICE_BACKEND}" in
    systemd)
      if is_service_installed; then
        systemctl --user start "${SERVICE_NAME}" && echo "✅ Started systemd user service '${SERVICE_NAME}'."
        return
      fi
      ;;
    launchd)
      if is_service_installed; then
        launchctl start "${PLIST_LABEL}" 2>/dev/null || launchctl load -w "${PLIST_FILE}" 2>/dev/null
        echo "✅ Started macOS LaunchAgent '${PLIST_LABEL}'."
        return
      fi
      ;;
  esac
  start_background_nohup
}

cmd_stop() {
  case "${SERVICE_BACKEND}" in
    systemd)
      if is_service_installed && systemctl --user is-active --quiet "${SERVICE_NAME}"; then
        systemctl --user stop "${SERVICE_NAME}" && echo "✅ Stopped systemd user service '${SERVICE_NAME}'."
        return
      fi
      ;;
    launchd)
      if is_service_installed; then
        launchctl unload "${PLIST_FILE}" >/dev/null 2>&1 || true
        stop_background_pid >/dev/null 2>&1 || true
        echo "✅ Stopped macOS LaunchAgent '${PLIST_LABEL}'."
        return
      fi
      ;;
  esac
  stop_background_pid
}

cmd_restart() {
  case "${SERVICE_BACKEND}" in
    systemd)
      if is_service_installed; then
        systemctl --user restart "${SERVICE_NAME}" && echo "✅ Restarted '${SERVICE_NAME}'."
        return
      fi
      ;;
    launchd)
      if is_service_installed; then
        launchctl unload "${PLIST_FILE}" >/dev/null 2>&1 || true
        launchctl load -w "${PLIST_FILE}" && echo "✅ Restarted '${PLIST_LABEL}'."
        return
      fi
      ;;
  esac
  stop_background_pid
  start_background_nohup
}

cmd_status() {
  cd "${REPO_ROOT}" || return 1
  print_syncalibur_dashboard

  local path reason
  local -a blocked=()
  while IFS= read -r -d '' path; do
    reason="$(block_reason "${path}")" && blocked+=("    ${C_AMBER}🛡 ${path}${C_RESET} ${C_SLATE}— ${reason}${C_RESET}")
  done < <(changed_paths)
  if (( ${#blocked[@]} > 0 )); then
    printf '  %s%sSkipped Files (%d):%s\n' "${C_AMBER}" "${C_BOLD}" "${#blocked[@]}" "${C_RESET}"
    printf '%s\n' "${blocked[@]}"
    printf '\n'
  fi

  if [[ -f "${LOG_FILE}" ]]; then
    printf '  %s%sRecent Activity%s\n' "${C_GOLD}" "${C_BOLD}" "${C_RESET}"
    printf '  %s──────────────────────────────────────────────────────────────────────────────%s\n' "${C_SLATE}" "${C_RESET}"
    local line
    while IFS= read -r line; do
      printf '  '
      format_log_line "${line}"
    done < <(tail -n 10 "${LOG_FILE}")
    printf '\n'
  fi
}

cmd_logs() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}"
  print_syncalibur_dashboard
  printf '  %s%s⚔️  Live Syncalibur Telemetry%s %s(Press Ctrl+C to exit)%s\n' "${C_GOLD}" "${C_BOLD}" "${C_RESET}" "${C_SLATE}" "${C_RESET}"
  printf '  %s──────────────────────────────────────────────────────────────────────────────%s\n' "${C_SLATE}" "${C_RESET}"
  local line
  tail -n 20 -f "${LOG_FILE}" | while IFS= read -r line; do
    printf '  '
    format_log_line "${line}"
  done
}

usage() {
  print_syncalibur_dashboard
  cat << EOF
  ${C_GOLD}${C_BOLD}Usage:${C_RESET} $0 ${C_CYAN}{install [path]|uninstall|start|stop|restart|status|logs|run}${C_RESET}

  ${C_GOLD}${C_BOLD}Commands:${C_RESET}
    ${C_CYAN}install [path]${C_RESET}  Configure auto-start on login/boot (Linux/macOS/Windows) and start now.
                    Optionally pass the directory path to watch (saved to syncalibur.env).
    ${C_CYAN}uninstall${C_RESET}       Stop Syncalibur and remove the auto-start service/launcher
    ${C_CYAN}start${C_RESET}           Start Syncalibur in the background
    ${C_CYAN}stop${C_RESET}            Stop the running daemon
    ${C_CYAN}restart${C_RESET}         Restart Syncalibur (run this after changing syncalibur.env)
    ${C_CYAN}status${C_RESET}          Show Syncalibur emblem, live dashboard, skipped files, and recent logs
    ${C_CYAN}logs${C_RESET}            Show Syncalibur emblem and stream live colorized telemetry
    ${C_CYAN}run${C_RESET}             Run the daemon in the foreground

EOF
}

case "${1:-}" in
  install)    cmd_install "${2:-}" ;;
  uninstall)  cmd_uninstall ;;
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  status)     cmd_status ;;
  logs | log) cmd_logs ;;
  run)        run_daemon ;;
  *)          usage; exit 1 ;;
esac
