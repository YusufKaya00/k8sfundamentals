#!/usr/bin/env bash
# ==============================================================================
# Syncalibur (syncalibur.sh) - Cross-Platform Git Auto-Sync Daemon
# ------------------------------------------------------------------------------
# Watches a git repository (or any folder, initializing git and creating the
# remote repository automatically when needed) and continuously stages, commits,
# and pushes changes in the background. If a sync/push fails, Syncalibur can
# automatically pop open a diagnostic terminal window and desktop notification.
#
# Supported operating systems & auto-start backends:
#   - Linux (systemd) : ~/.config/systemd/user/<service>.service
#   - Linux (fallback): crontab @reboot + ~/.config/autostart/<service>.desktop
#   - macOS (launchd) : ~/Library/LaunchAgents/com.syncalibur.<service>.plist
#   - Windows         : Startup folder hidden VBS launcher (Git Bash / MSYS2)
#
# Usage : ./scripts/syncalibur.sh {install [path]|uninstall|start|stop|restart|status|logs|alert|run}
# Docs  : ./scripts/README.md
# ==============================================================================

set -uo pipefail
# NOTE: `set -e` is intentionally omitted. The daemon loop must survive
# transient git/network errors rather than exiting unexpectedly.

# Ensure user-local CLI tools (like `gh` and `glab` in ~/.local/bin or Homebrew)
# are always in PATH, even when started by systemd/launchd/cron.
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# ==============================================================================
# Cross-platform portability helpers (Linux, macOS Bash 3.2+, Windows Git Bash)
# ==============================================================================

OS_KERNEL="$(uname -s 2>/dev/null || echo Unknown)"

normalize_path_input() {
  local raw="$1"
  raw="${raw/#\~/${HOME}}"
  if command -v cygpath >/dev/null 2>&1 && [[ "${raw}" =~ ^[A-Za-z]:[\\/] ]]; then
    cygpath -u "${raw}"
  else
    printf '%s\n' "${raw}"
  fi
}

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

if stat -c '%s' . >/dev/null 2>&1; then
  STAT_FLAVOR="gnu"
else
  STAT_FLAVOR="bsd"
fi

file_size_bytes() {
  if [[ "${STAT_FLAVOR}" == "gnu" ]]; then
    stat -c '%s' -- "$1" 2>/dev/null || echo 0
  else
    stat -f '%z' -- "$1" 2>/dev/null || echo 0
  fi
}

file_mtime_epoch() {
  if [[ "${STAT_FLAVOR}" == "gnu" ]]; then
    stat -c '%Y' -- "$1" 2>/dev/null || echo 0
  else
    stat -f '%m' -- "$1" 2>/dev/null || echo 0
  fi
}

file_signature() {
  if [[ "${STAT_FLAVOR}" == "gnu" ]]; then
    stat -c '%s %Y' -- "$1" 2>/dev/null || echo gone
  else
    stat -f '%z %m' -- "$1" 2>/dev/null || echo gone
  fi
}

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
LOGO_PNG_FILE="${SCRIPT_DIR}/assets/syncalibur-logo.png"

CONFIG_KEYS=" SYNCALIBUR_REPO_PATH SYNCALIBUR_AUTO_CREATE_REMOTE SYNCALIBUR_REPO_VISIBILITY
  SYNCALIBUR_ALERT_TERMINAL SYNCALIBUR_ALERT_COOLDOWN
  SYNCALIBUR_SERVICE_NAME SYNCALIBUR_REMOTE SYNCALIBUR_POLL_INTERVAL
  SYNCALIBUR_DEBOUNCE_WAIT SYNCALIBUR_MAX_DEBOUNCE SYNCALIBUR_MAX_FILE_SIZE_MB SYNCALIBUR_SENSITIVE_PATTERNS
  SYNCALIBUR_RETRY_BASE SYNCALIBUR_RETRY_MAX SYNCALIBUR_PUSH_TIMEOUT SYNCALIBUR_LOG_MAX_KB
  GITHUB_TOKEN GH_TOKEN GITLAB_TOKEN
  AUTO_SYNC_REPO_PATH AUTO_SYNC_SERVICE_NAME AUTO_SYNC_REMOTE AUTO_SYNC_POLL_INTERVAL
  AUTO_SYNC_DEBOUNCE_WAIT AUTO_SYNC_MAX_DEBOUNCE AUTO_SYNC_MAX_FILE_SIZE_MB AUTO_SYNC_SENSITIVE_PATTERNS
  AUTO_SYNC_RETRY_BASE AUTO_SYNC_RETRY_MAX AUTO_SYNC_PUSH_TIMEOUT AUTO_SYNC_LOG_MAX_KB "

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
    eval "[[ -n \"\${${key}+x}\" ]] && is_set=1 || is_set=0"
    (( is_set )) && continue
    printf -v "${key}" '%s' "${value}"
  done < "${file}"
}

DEFAULT_ENV_FILE="${SCRIPT_DIR}/syncalibur.env"
CONFIG_FILE="${SYNCALIBUR_CONFIG:-${AUTO_SYNC_CONFIG:-${DEFAULT_ENV_FILE}}}"

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
SYNCALIBUR_REPO_PATH="${target_path}"
SYNCALIBUR_AUTO_CREATE_REMOTE="true"
SYNCALIBUR_REPO_VISIBILITY="private"
SYNCALIBUR_ALERT_TERMINAL="true"
EOF
  fi
  CONFIG_FILE="$(resolve_path "${env_file}")"
  SYNCALIBUR_REPO_PATH="${target_path}"
}

if [[ "${1:-}" == "install" && -n "${2:-}" ]]; then
  INSTALL_ARG_PATH="$(normalize_path_input "${2}")"
  mkdir -p "${INSTALL_ARG_PATH}" 2>/dev/null || true
  if [[ ! -d "${INSTALL_ARG_PATH}" ]]; then
    echo "❌ Specified directory does not exist and could not be created: ${2}" >&2
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
# Repository & scope resolution (Zero-Friction Public Clone Fallback + git init)
# ==============================================================================

AUTO_CREATE_REMOTE="${SYNCALIBUR_AUTO_CREATE_REMOTE:-true}"
REPO_VISIBILITY="${SYNCALIBUR_REPO_VISIBILITY:-private}"
[[ "${REPO_VISIBILITY}" == "public" ]] || REPO_VISIBILITY="private"
ALERT_TERMINAL="${SYNCALIBUR_ALERT_TERMINAL:-true}"
ALERT_COOLDOWN="${SYNCALIBUR_ALERT_COOLDOWN:-600}"
[[ "${ALERT_COOLDOWN}" =~ ^[0-9]+$ ]] || ALERT_COOLDOWN=600

resolve_default_watch_fallback() {
  local fallback
  if fallback="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "${fallback}"
  else
    resolve_path "${SCRIPT_DIR}/.."
  fi
}

WATCH_PATH="${SYNCALIBUR_REPO_PATH:-${AUTO_SYNC_REPO_PATH:-}}"
if [[ -n "${WATCH_PATH}" ]]; then
  WATCH_PATH="$(normalize_path_input "${WATCH_PATH}")"
  [[ "${WATCH_PATH}" == /* ]] || WATCH_PATH="$(dirname "${CONFIG_FILE:-${SCRIPT_PATH}}")/${WATCH_PATH}"
  if [[ ! -d "${WATCH_PATH}" ]]; then
    FALLBACK_WATCH_PATH="$(resolve_default_watch_fallback)"
    echo "⚠️  Configured SYNCALIBUR_REPO_PATH ('${WATCH_PATH}') not found on this machine; automatically using '${FALLBACK_WATCH_PATH}'." >&2
    WATCH_PATH="${FALLBACK_WATCH_PATH}"
  fi
else
  WATCH_PATH="$(resolve_default_watch_fallback)"
fi
WATCH_PATH="$(resolve_path "${WATCH_PATH}")"

if ! REPO_ROOT="$(git -C "${WATCH_PATH}" rev-parse --show-toplevel 2>/dev/null)"; then
  if [[ "${AUTO_CREATE_REMOTE}" == "true" || "${1:-}" == "install" ]]; then
    echo "⚙️  '${WATCH_PATH}' is not a git repository yet; initializing with 'git init -b main'..."
    git -C "${WATCH_PATH}" init -b main >/dev/null 2>&1 || {
      git -C "${WATCH_PATH}" init >/dev/null 2>&1
      git -C "${WATCH_PATH}" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    }
    REPO_ROOT="${WATCH_PATH}"
  else
    echo "❌ '${WATCH_PATH}' is not inside a git repository." >&2
    exit 1
  fi
fi
REPO_ROOT="$(resolve_path "${REPO_ROOT}")"
GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --absolute-git-dir)"

SCOPE="$(git -C "${WATCH_PATH}" rev-parse --show-prefix 2>/dev/null || true)"
SCOPE="${SCOPE%/}"
SCOPE="${SCOPE:-.}"

PID_FILE="${GIT_DIR}/syncalibur.pid"
LOCK_FILE="${GIT_DIR}/syncalibur.lock"
LOG_FILE="${GIT_DIR}/syncalibur.log"
AUTH_CACHE_FILE="${GIT_DIR}/syncalibur.auth"
FAIL_REPORT_FILE="${GIT_DIR}/syncalibur.failure"
ALERT_STATE_FILE="${GIT_DIR}/syncalibur.alert_ts"

# Service name is automatic: defaults to "syncalibur" for the primary config,
# or derives from a custom config filename if watching additional repositories.
if [[ -n "${SYNCALIBUR_SERVICE_NAME:-${AUTO_SYNC_SERVICE_NAME:-}}" ]]; then
  SERVICE_NAME="${SYNCALIBUR_SERVICE_NAME:-${AUTO_SYNC_SERVICE_NAME}}"
elif [[ -n "${CONFIG_FILE}" && "$(basename "${CONFIG_FILE}")" != "syncalibur.env" ]]; then
  SERVICE_NAME="syncalibur-$(basename "${CONFIG_FILE}" .env | tr -cd 'A-Za-z0-9_-')"
else
  SERVICE_NAME="syncalibur"
fi

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

POLL_INTERVAL="${SYNCALIBUR_POLL_INTERVAL:-${AUTO_SYNC_POLL_INTERVAL:-3}}"
DEBOUNCE_WAIT="${SYNCALIBUR_DEBOUNCE_WAIT:-${AUTO_SYNC_DEBOUNCE_WAIT:-5}}"
MAX_DEBOUNCE="${SYNCALIBUR_MAX_DEBOUNCE:-${AUTO_SYNC_MAX_DEBOUNCE:-60}}"
MAX_FILE_SIZE_MB="${SYNCALIBUR_MAX_FILE_SIZE_MB:-${AUTO_SYNC_MAX_FILE_SIZE_MB:-50}}"
RETRY_BASE="${SYNCALIBUR_RETRY_BASE:-${AUTO_SYNC_RETRY_BASE:-30}}"
RETRY_MAX="${SYNCALIBUR_RETRY_MAX:-${AUTO_SYNC_RETRY_MAX:-900}}"
PUSH_TIMEOUT="${SYNCALIBUR_PUSH_TIMEOUT:-${AUTO_SYNC_PUSH_TIMEOUT:-120}}"
LOG_MAX_KB="${SYNCALIBUR_LOG_MAX_KB:-${AUTO_SYNC_LOG_MAX_KB:-1024}}"
REMOTE_OVERRIDE="${SYNCALIBUR_REMOTE:-${AUTO_SYNC_REMOTE:-}}"

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

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never

# ==============================================================================
# Provider Authentication Probing & Automatic Remote Repository Creation
# ==============================================================================

get_remote() {
  if [[ -n "${REMOTE_OVERRIDE}" ]]; then
    echo "${REMOTE_OVERRIDE}"
  elif git -C "${REPO_ROOT}" remote | grep -qx "all"; then
    echo "all"
  else
    echo "origin"
  fi
}

get_branch() {
  git -C "${REPO_ROOT}" symbolic-ref --quiet --short HEAD 2>/dev/null
}

parse_remote_url() {
  local url="$1"
  local proto="SSH" host="" path="" provider="" owner=""

  if [[ "${url}" =~ ^https?://([^/]+)/(.+)$ ]]; then
    proto="HTTPS"
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
    host="${host#*@}"
  elif [[ "${url}" =~ ^ssh://([^/]+)/(.+)$ ]]; then
    proto="SSH"
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
    host="${host#*@}"
    host="${host%%:*}"
  elif [[ "${url}" =~ ^[^@]+@([^:]+):(.+)$ ]]; then
    proto="SSH"
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  else
    proto="Local"
    host="local"
    path="${url}"
  fi

  path="${path%.git}"
  path="${path#/}"
  owner="${path%%/*}"

  case "${host}" in
    *github.com*)                     provider="GitHub" ;;
    *gitlab.com*|*gitlab.*)           provider="GitLab" ;;
    *bitbucket.org*)                  provider="Bitbucket" ;;
    *dev.azure.com*|*visualstudio.*)  provider="Azure DevOps" ;;
    local)                            provider="Local Path" ;;
    *)                                provider="${host}" ;;
  esac

  printf '%s|%s|%s|%s\n' "${provider}" "${path}" "${proto}" "${owner}"
}

get_push_urls() {
  local remote="$1"
  git -C "${REPO_ROOT}" remote get-url --push --all "${remote}" 2>/dev/null \
    || git -C "${REPO_ROOT}" config --get-all "remote.${remote}.pushurl" 2>/dev/null \
    || git -C "${REPO_ROOT}" config --get-all "remote.${remote}.url" 2>/dev/null
}

describe_push_targets_inline() {
  local remote="$1" url parsed provider slug summary=""
  while IFS= read -r url; do
    [[ -z "${url}" ]] && continue
    parsed="$(parse_remote_url "${url}")"
    provider="${parsed%%|*}"
    slug="${parsed#*|}"
    slug="${slug%%|*}"
    if [[ -z "${summary}" ]]; then
      summary="${provider}: ${slug}"
    else
      summary="${summary}, ${provider}: ${slug}"
    fi
  done < <(get_push_urls "${remote}")
  echo "${summary:-${remote} (no URL yet)}"
}

detect_auth_credential() {
  local key_file
  for key_file in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_ecdsa" "${HOME}/.ssh/id_rsa"; do
    if [[ -f "${key_file}" ]]; then
      basename "${key_file}"
      return 0
    fi
  done
  local helper
  helper="$(git -C "${REPO_ROOT}" config --get credential.helper 2>/dev/null || true)"
  if [[ -n "${helper}" ]]; then
    echo "credential.${helper}"
    return 0
  fi
  echo "default"
}

# Probe live GitHub and GitLab authentication (via CLI, token, or SSH) and cache
# for 10 minutes in `.git/syncalibur.auth` so `status` stays instantaneous.
probe_provider_auth() {
  local now mtime
  now="$(date +%s)"
  if [[ -f "${AUTH_CACHE_FILE}" ]]; then
    mtime="$(file_mtime_epoch "${AUTH_CACHE_FILE}")"
    if (( now - mtime < 600 )); then
      cat "${AUTH_CACHE_FILE}"
      return 0
    fi
  fi

  local gh_user="" gh_via="" gl_user="" gl_via="" out

  # 1) GitHub auth detection (gh CLI -> GITHUB_TOKEN -> SSH)
  if command -v gh >/dev/null 2>&1; then
    out="$(gh auth status 2>&1 || true)"
    if [[ "${out}" =~ account[[:space:]]+([A-Za-z0-9_.-]+) ]]; then
      gh_user="${BASH_REMATCH[1]}"
      gh_via="gh+SSH"
    fi
  fi
  if [[ -z "${gh_user}" && -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] && command -v curl >/dev/null 2>&1; then
    out="$(curl -fsSL -m 4 -H "Authorization: token ${GH_TOKEN:-${GITHUB_TOKEN}}" https://api.github.com/user 2>/dev/null || true)"
    if [[ "${out}" =~ \"login\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      gh_user="${BASH_REMATCH[1]}"
      gh_via="token"
    fi
  fi
  if [[ -z "${gh_user}" ]] && command -v ssh >/dev/null 2>&1; then
    out="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 git@github.com 2>&1 || true)"
    if [[ "${out}" =~ Hi[[:space:]]+([^!]+)! ]]; then
      gh_user="${BASH_REMATCH[1]}"
      gh_via="SSH"
    fi
  fi

  # 2) GitLab auth detection (glab CLI -> GITLAB_TOKEN -> SSH)
  if command -v glab >/dev/null 2>&1; then
    out="$(glab auth status 2>&1 || true)"
    if [[ "${out}" =~ Logged[[:space:]]+in[[:space:]]+to[[:space:]]+[^[:space:]]+[[:space:]]+as[[:space:]]+([A-Za-z0-9_.-]+) ]]; then
      gl_user="${BASH_REMATCH[1]}"
      gl_via="glab"
    fi
  fi
  if [[ -z "${gl_user}" && -n "${GITLAB_TOKEN:-}" ]] && command -v curl >/dev/null 2>&1; then
    out="$(curl -fsSL -m 4 --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" https://gitlab.com/api/v4/user 2>/dev/null || true)"
    if [[ "${out}" =~ \"username\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      gl_user="${BASH_REMATCH[1]}"
      gl_via="token"
    fi
  fi
  if [[ -z "${gl_user}" ]] && command -v ssh >/dev/null 2>&1; then
    out="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 git@gitlab.com 2>&1 || true)"
    if [[ "${out}" =~ Welcome[[:space:]]+to[[:space:]]+GitLab,[[:space:]]*@([A-Za-z0-9_.-]+)! ]]; then
      gl_user="${BASH_REMATCH[1]}"
      gl_via="SSH"
    fi
  fi

  local line="${gh_user}|${gh_via}|${gl_user}|${gl_via}"
  mkdir -p "$(dirname "${AUTH_CACHE_FILE}")" 2>/dev/null || true
  printf '%s\n' "${line}" > "${AUTH_CACHE_FILE}" 2>/dev/null || true
  printf '%s\n' "${line}"
}

detect_user_identity() {
  local git_name git_email sys_user sys_host ssh_key auth_line gh_user gh_via gl_user gl_via
  git_name="$(git -C "${REPO_ROOT}" config --get user.name 2>/dev/null || true)"
  git_email="$(git -C "${REPO_ROOT}" config --get user.email 2>/dev/null || true)"
  sys_user="${USER:-$(id -un 2>/dev/null || echo user)}"
  sys_host="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo localhost)"
  ssh_key="$(detect_auth_credential)"
  auth_line="$(probe_provider_auth)"
  IFS='|' read -r gh_user gh_via gl_user gl_via <<< "${auth_line}"

  if [[ -z "${git_name}" ]]; then
    if [[ -n "${gh_user}" ]]; then
      git_name="${gh_user}"
    elif [[ -n "${gl_user}" ]]; then
      git_name="${gl_user}"
    elif [[ "${git_email}" =~ ^[0-9]+\+([^@]+)@users\.noreply\.github\.com$ ]]; then
      git_name="${BASH_REMATCH[1]}"
    elif [[ "${git_email}" =~ ^([^@]+)@ ]]; then
      git_name="${BASH_REMATCH[1]}"
    else
      git_name="${sys_user}"
    fi
  fi

  # Ensure git user.name and user.email are configured in the repo so commits never fail
  if [[ -z "$(git -C "${REPO_ROOT}" config --get user.name 2>/dev/null || true)" ]]; then
    git -C "${REPO_ROOT}" config user.name "${git_name}" 2>/dev/null || true
  fi
  if [[ -z "${git_email}" ]]; then
    git_email="${git_name}@users.noreply.github.com"
    git -C "${REPO_ROOT}" config user.email "${git_email}" 2>/dev/null || true
  fi

  printf '%s|%s|%s@%s|%s|%s|%s|%s|%s\n' \
    "${git_name}" "${git_email}" "${sys_user}" "${sys_host}" "${ssh_key}" \
    "${gh_user}" "${gh_via}" "${gl_user}" "${gl_via}"
}

# Create a missing repository on GitHub or GitLab when authorized, or configure
# `origin` automatically when the local repo has no remote URL yet.
auto_create_or_bind_remote() {
  [[ "${AUTO_CREATE_REMOTE}" == "true" ]] || return 1

  local target_slug="${1:-}" target_provider="${2:-}"
  local repo_name auth_line gh_user gh_via gl_user gl_via is_private="true"
  repo_name="$(basename "${REPO_ROOT}")"
  [[ "${REPO_VISIBILITY}" == "public" ]] && is_private="false"

  auth_line="$(probe_provider_auth)"
  IFS='|' read -r gh_user gh_via gl_user gl_via <<< "${auth_line}"

  # Case 1: Specific GitHub slug requested or no remote exists and GitHub is authorized
  if [[ "${target_provider}" == "GitHub" || ( -z "${target_provider}" && -n "${gh_user}" ) ]]; then
    local slug="${target_slug:-${gh_user}/${repo_name}}"
    local name_only="${slug#*/}"
    if command -v gh >/dev/null 2>&1 && [[ -n "${gh_user}" ]]; then
      log "✨ Creating ${REPO_VISIBILITY} GitHub repository '${slug}' via GitHub CLI..."
      if gh repo view "${slug}" >/dev/null 2>&1 || gh repo create "${slug}" "--${REPO_VISIBILITY}" >/dev/null 2>&1; then
        if ! git -C "${REPO_ROOT}" remote get-url origin >/dev/null 2>&1; then
          git -C "${REPO_ROOT}" remote add origin "git@github.com:${slug}.git" 2>/dev/null || true
        fi
        log "✅ GitHub repository ready: git@github.com:${slug}.git"
        return 0
      fi
    elif [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] && command -v curl >/dev/null 2>&1; then
      log "✨ Creating ${REPO_VISIBILITY} GitHub repository '${slug}' via GitHub API..."
      if curl -fsSL -m 10 -X POST \
        -H "Authorization: token ${GH_TOKEN:-${GITHUB_TOKEN}}" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/user/repos \
        -d "{\"name\":\"${name_only}\",\"private\":${is_private}}" >/dev/null 2>&1; then
        if ! git -C "${REPO_ROOT}" remote get-url origin >/dev/null 2>&1; then
          git -C "${REPO_ROOT}" remote add origin "git@github.com:${slug}.git" 2>/dev/null || true
        fi
        log "✅ GitHub repository ready: git@github.com:${slug}.git"
        return 0
      fi
    fi
  fi

  # Case 2: GitLab (glab CLI, GITLAB_TOKEN API, or native GitLab SSH push-to-create)
  if [[ "${target_provider}" == "GitLab" || ( -z "${target_provider}" && -n "${gl_user}" ) ]]; then
    local slug="${target_slug:-${gl_user}/${repo_name}}"
    local name_only="${slug#*/}"
    if command -v glab >/dev/null 2>&1 && [[ -n "${gl_user}" ]]; then
      log "✨ Creating ${REPO_VISIBILITY} GitLab project '${slug}' via GitLab CLI..."
      glab repo create "${slug}" "--${REPO_VISIBILITY}" >/dev/null 2>&1 || true
    elif [[ -n "${GITLAB_TOKEN:-}" ]] && command -v curl >/dev/null 2>&1; then
      log "✨ Creating ${REPO_VISIBILITY} GitLab project '${slug}' via GitLab API..."
      curl -fsSL -m 10 -X POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://gitlab.com/api/v4/projects?name=${name_only}&visibility=${REPO_VISIBILITY}" >/dev/null 2>&1 || true
    fi
    # GitLab natively supports creating a new private project on the first SSH `git push`!
    if [[ -n "${gl_user}" ]] && ! git -C "${REPO_ROOT}" remote get-url origin >/dev/null 2>&1; then
      git -C "${REPO_ROOT}" remote add origin "git@gitlab.com:${slug}.git" 2>/dev/null || true
      log "✅ Bound remote 'origin' -> git@gitlab.com:${slug}.git (GitLab push-to-create ready)"
      return 0
    fi
  fi

  return 1
}

# ==============================================================================
# Terminal Theme, PNG Avatar Renderer & Styled Log Formatter
# ==============================================================================

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

ensure_logo_ansi() {
  [[ -f "${LOGO_ANSI_FILE}" ]] && return 0
  [[ -f "${LOGO_PNG_FILE}" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "${LOGO_PNG_FILE}" "${LOGO_ANSI_FILE}" 2>/dev/null << 'PY' || return 1
import sys
from PIL import Image, ImageEnhance
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
bbox = im.getbbox()
if bbox:
    im = im.crop(bbox)
W, H = 38, 38
im = im.resize((W, H), Image.Resampling.LANCZOS)
rgb = ImageEnhance.Color(ImageEnhance.Contrast(ImageEnhance.Sharpness(im.convert("RGB")).enhance(1.6)).enhance(1.18)).enhance(1.22)
im = Image.merge("RGBA", (*rgb.split(), im.split()[3]))
px = im.load()
lines = []
for y in range(0, H, 2):
    row, in_reset = [], True
    for x in range(W):
        r1, g1, b1, a1 = px[x, y]
        r2, g2, b2, a2 = px[x, y + 1]
        t, b = a1 >= 90, a2 >= 90
        if not t and not b:
            if not in_reset:
                row.append("\033[0m"); in_reset = True
            row.append(" ")
        elif t and not b:
            row.append(f"\033[0m\033[38;2;{r1};{g1};{b1}m▀"); in_reset = False
        elif not t and b:
            row.append(f"\033[0m\033[38;2;{r2};{g2};{b2}m▄"); in_reset = False
        else:
            row.append(f"\033[38;2;{r1};{g1};{b1}m\033[48;2;{r2};{g2};{b2}m▀"); in_reset = False
    if not in_reset:
        row.append("\033[0m")
    lines.append("".join(row))
with open(dst, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

format_log_line() {
  local raw="$1"
  if [[ "${raw}" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}:[0-9]{2}:[0-9]{2})\]\ (.*)$ ]]; then
    local ts="${BASH_REMATCH[2]}"
    local msg="${BASH_REMATCH[3]}"
    local badge_color="${C_SLATE}"
    local badge_text="◈ INFO     "
    local msg_color="${C_WHITE}"

    case "${msg}" in
      *"Syncalibur started"*|*"Syncalibur online"*|*"başlatıldı"*)
        badge_color="${C_GOLD}"; badge_text="◈ ONLINE   "; msg_color="${C_GOLD}${C_BOLD}" ;;
      *"Targets:"*|*"Identity:"*|*"Poll:"*|*"Kontrol aralığı:"*)
        badge_color="${C_CYAN}"; badge_text="◈ TELEMETRY"; msg_color="${C_SLATE}" ;;
      *"Creating "*|*"repository ready"*|*"Bound remote"*)
        badge_color="${C_GOLD}"; badge_text="✦ AUTOREPO "; msg_color="${C_GOLD}" ;;
      *"Changes detected"*|*"Değişiklik algılandı"*)
        badge_color="${C_CYAN}"; badge_text="◉ DETECTED "; msg_color="${C_CYAN}" ;;
      *"Committed"*|*"Commit oluşturuldu"*)
        badge_color="${C_GREEN}"; badge_text="✔ COMMIT   "; msg_color="${C_GREEN}" ;;
      *"Pushing"*|*"Uzak depoya"*)
        badge_color="${C_GOLD}"; badge_text="▲ PUSHING  "; msg_color="${C_GOLD}" ;;
      *"Push succeeded"*|*"Başarıyla pushlandı"*)
        badge_color="${C_GREEN}${C_BOLD}"; badge_text="★ SYNCED   "; msg_color="${C_GREEN}${C_BOLD}" ;;
      *"Not committing"*)
        badge_color="${C_AMBER}"; badge_text="🛡 GUARD    "; msg_color="${C_AMBER}" ;;
      *"Push failed"*|*"timed out"*|*"failed"*|*"Another Syncalibur"*|*"SYNC FAILED"*)
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

print_syncalibur_dashboard() {
  ensure_logo_ansi

  local pid state_str autostart_str branch remote unpushed_str cfg_short watch_short
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

  remote="$(get_remote)"
  branch="$(get_branch || echo detached)"
  if [[ -f "${FAIL_REPORT_FILE}" ]]; then
    local fail_reason_short
    fail_reason_short="$(sed -n '4p' "${FAIL_REPORT_FILE}" 2>/dev/null | cut -c1-48)"
    unpushed_str="${C_RED}${C_BOLD}✖ SYNC FAILED:${C_RESET} ${C_RED}${fail_reason_short:-see ./scripts/syncalibur.sh alert}${C_RESET}"
  elif [[ "${branch}" != "detached" ]]; then
    local up_cnt
    up_cnt="$(cd "${REPO_ROOT}" && unpushed_count "${remote}" "${branch}")"
    if (( up_cnt == 0 )); then
      unpushed_str="${C_GREEN}✔ 0 unpushed commits (in sync)${C_RESET}"
    else
      unpushed_str="${C_AMBER}● ${up_cnt} commit(s) queued for push${C_RESET}"
    fi
  else
    unpushed_str="${C_AMBER}⏸ Detached HEAD (paused)${C_RESET}"
  fi

  # Detect user identity & verified provider accounts
  local id_raw git_user git_email sys_ident ssh_cred gh_user gh_via gl_user gl_via
  id_raw="$(detect_user_identity)"
  IFS='|' read -r git_user git_email sys_ident ssh_cred gh_user gh_via gl_user gl_via <<< "${id_raw}"

  local auth_badges=""
  if [[ -n "${gh_user}" ]]; then
    auth_badges="${C_GREEN}✔ GitHub: @${gh_user}${C_RESET} ${C_SLATE}(${gh_via})${C_RESET}"
  fi
  if [[ -n "${gl_user}" ]]; then
    [[ -n "${auth_badges}" ]] && auth_badges="${auth_badges}  ${C_SLATE}•${C_RESET}  "
    auth_badges="${auth_badges}${C_GREEN}✔ GitLab: @${gl_user}${C_RESET} ${C_SLATE}(${gl_via})${C_RESET}"
  fi
  [[ -z "${auth_badges}" ]] && auth_badges="${C_AMBER}SSH key (${ssh_cred})${C_RESET}"

  # Detect all push destinations from git remote URLs
  local -a dest_lines=()
  local url parsed provider slug proto owner idx=0
  while IFS= read -r url; do
    [[ -z "${url}" ]] && continue
    idx=$(( idx + 1 ))
    parsed="$(parse_remote_url "${url}")"
    IFS='|' read -r provider slug proto owner <<< "${parsed}"
    local p_color="${C_CYAN}"
    [[ "${provider}" == "GitHub" ]] && p_color="${C_WHITE}${C_BOLD}"
    [[ "${provider}" == "GitLab" ]] && p_color="${C_AMBER}${C_BOLD}"
    dest_lines+=("  ${C_GOLD}◈${C_RESET} ${C_BOLD}Push #${idx}   :${C_RESET} ${p_color}${provider}${C_RESET} ${C_SLATE}→${C_RESET} ${C_CYAN}${slug}${C_RESET} ${C_SLATE}[${branch} • ${proto}]${C_RESET}")
  done < <(get_push_urls "${remote}")

  if (( ${#dest_lines[@]} == 0 )); then
    dest_lines+=("  ${C_GOLD}◈${C_RESET} ${C_BOLD}Push Dest :${C_RESET} ${C_AMBER}None yet — will auto-create ${REPO_VISIBILITY} repo on first push${C_RESET}")
  fi

  local autorepo_str="${C_GREEN}✔ Enabled${C_RESET} ${C_SLATE}(auto-creates missing remote as '${REPO_VISIBILITY}')${C_RESET}"
  [[ "${AUTO_CREATE_REMOTE}" != "true" ]] && autorepo_str="${C_SLATE}Disabled${C_RESET}"
  [[ "${ALERT_TERMINAL}" == "true" ]] && autorepo_str="${autorepo_str} ${C_SLATE}•${C_RESET} ${C_CYAN}Alert Popup ON${C_RESET}"

  cfg_short="${CONFIG_FILE:-<defaults>}"
  cfg_short="${cfg_short/#${HOME}/~}"
  watch_short="${WATCH_PATH/#${HOME}/~}"

  local -a info_lines=(
    "${C_GOLD}╭──────────────────────────────────────────────────────────────────────╮${C_RESET}"
    "${C_GOLD}│${C_RESET}   ${C_GOLD}${C_BOLD}S Y N C A L I B U R${C_RESET}   ${C_SLATE}•${C_RESET}   ${C_CYAN}Autonomous Git Auto-Sync Daemon${C_RESET}          ${C_GOLD}│${C_RESET}"
    "${C_GOLD}╰──────────────────────────────────────────────────────────────────────╯${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Status    :${C_RESET} ${state_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}OS / Mode :${C_RESET} ${C_WHITE}${OS_KERNEL} (${SERVICE_BACKEND})${C_RESET}  ${C_SLATE}•${C_RESET}  ${autostart_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Author    :${C_RESET} ${C_WHITE}${C_BOLD}${git_user}${C_RESET} ${C_SLATE}<${git_email}> (${sys_ident})${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Verified  :${C_RESET} ${auth_badges}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Watching  :${C_RESET} ${C_WHITE}${watch_short}${C_RESET} ${C_SLATE}(scope: ${SCOPE})${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Config    :${C_RESET} ${C_SLATE}${cfg_short}${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Remote    :${C_RESET} ${C_CYAN}${remote}${C_RESET} ${C_SLATE}(${idx} target(s) • branch '${branch}')${C_RESET}"
  )

  local d_idx=0
  while (( d_idx < ${#dest_lines[@]} && d_idx < 3 )); do
    info_lines+=("${dest_lines[$d_idx]}")
    d_idx=$(( d_idx + 1 ))
  done

  info_lines+=(
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Auto-Repo :${C_RESET} ${autorepo_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Sync State:${C_RESET} ${unpushed_str}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Timing    :${C_RESET} ${C_SLATE}Poll ${POLL_INTERVAL}s • Debounce ${DEBOUNCE_WAIT}s (max ${MAX_DEBOUNCE}s)${C_RESET}"
    "  ${C_GOLD}◈${C_RESET} ${C_BOLD}Shield    :${C_RESET} ${C_SLATE}≤ ${MAX_FILE_SIZE_MB} MiB • Secret & .tfstate guard active${C_RESET}"
    "  ${C_SLATE}──────────────────────────────────────────────────────────────────────${C_RESET}"
    "  ${C_SLATE}Commands  : ${C_CYAN}status${C_SLATE} | ${C_CYAN}logs${C_SLATE} | ${C_CYAN}alert${C_SLATE} | ${C_CYAN}restart${C_SLATE} | ${C_CYAN}stop${C_SLATE} | ${C_CYAN}install${C_SLATE} | ${C_CYAN}uninstall${C_RESET}"
  )

  local -a logo_lines=()
  local line
  if [[ -f "${LOGO_ANSI_FILE}" ]]; then
    while IFS= read -r line; do
      logo_lines+=("${line}")
    done < "${LOGO_ANSI_FILE}"
  fi

  local total_rows=${#logo_lines[@]}
  (( ${#info_lines[@]} > total_rows )) && total_rows=${#info_lines[@]}

  printf '\n'
  local i=0
  local empty_logo="                                      "
  while (( i < total_rows )); do
    local l_part="${logo_lines[$i]:-${empty_logo}}"
    local r_part="${info_lines[$i]:-}"
    printf '  %s   %s\n' "${l_part}" "${r_part}"
    i=$(( i + 1 ))
  done
  printf '\n'
}

# ==============================================================================
# Proactive Failure Diagnostic Report & Automatic Terminal Popup Alert
# ==============================================================================

diagnose_failure_hint() {
  local raw="$1"
  if grep -qiE 'Permission denied \(publickey\)|Authentication failed|Could not read from remote repository' <<< "${raw}"; then
    echo "SSH key or token is not authorized for this remote. Check 'ssh -T git@github.com' / 'gh auth status'."
  elif grep -qiE 'Repository not found|project you were looking for could not be found' <<< "${raw}"; then
    echo "Remote repository does not exist or account lacks access. Authenticate 'gh auth login' or 'glab auth login' for auto-creation."
  elif grep -qiE 'fetch first|non-fast-forward|rejected.*main|rejected.*master' <<< "${raw}"; then
    echo "Remote has new commits not present locally. Run: git -C \"${REPO_ROOT}\" pull --rebase"
  elif grep -qiE 'GH001: Large files detected|exceeds GitHub.*file size limit|pack exceeds maximum allowed size' <<< "${raw}"; then
    echo "A large binary is in commit history. Remove it from history and lower SYNCALIBUR_MAX_FILE_SIZE_MB."
  elif grep -qiE 'GH013: Repository rule violations|Push cannot contain secrets' <<< "${raw}"; then
    echo "Remote push protection detected a secret in commit history. Remove the secret and add the file to .gitignore."
  elif grep -qiE 'Could not resolve host|Network is unreachable|Connection timed out|timed out after' <<< "${raw}"; then
    echo "Network/DNS connection failed. Syncalibur will automatically retry with exponential backoff once online."
  else
    echo "Inspect the git output below or run './scripts/syncalibur.sh logs' for full diagnostics."
  fi
}

record_sync_failure() {
  local stage="$1" reason="$2" details="$3" remote="${4:-$(get_remote)}" branch="${5:-$(get_branch || echo main)}"
  local ts targets hint
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  targets="$(describe_push_targets_inline "${remote}")"
  hint="$(diagnose_failure_hint "${details} ${reason}")"

  mkdir -p "$(dirname "${FAIL_REPORT_FILE}")" 2>/dev/null || true
  {
    printf '%s\n' "${ts}"
    printf '%s\n' "${stage}"
    printf '%s (%s)\n' "${targets}" "${branch}"
    printf '%s\n' "${reason}"
    printf '%s\n' "${hint}"
    printf '%s\n' "${details}"
  } > "${FAIL_REPORT_FILE}" 2>/dev/null || true
}

clear_sync_failure() {
  rm -f "${FAIL_REPORT_FILE}" "${ALERT_STATE_FILE}" 2>/dev/null || true
}

send_desktop_alert() {
  local title="$1" body="$2"
  case "${OS_KERNEL}" in
    Darwin*)
      command -v osascript >/dev/null 2>&1 && osascript -e "display notification \"${body//\"/\'}\" with title \"${title//\"/\'}\" sound name \"Basso\"" >/dev/null 2>&1 || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      command -v powershell.exe >/dev/null 2>&1 && powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command \
        "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('${body//\'/}', '${title//\'/}', 'OK', 'Warning')" >/dev/null 2>&1 &
      ;;
    *)
      if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical -i "${LOGO_PNG_FILE}" "${title}" "${body}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# Spawns a visible terminal window across Linux, macOS, and Windows displaying
# the styled Syncalibur "SYNC FAILED" diagnostic screen. Uses a cooldown file
# so background retries never spam multiple popup windows.
trigger_failure_alert() {
  local stage="$1" reason="$2" details="$3" remote="${4:-$(get_remote)}" branch="${5:-$(get_branch || echo main)}"
  record_sync_failure "${stage}" "${reason}" "${details}" "${remote}" "${branch}"

  [[ "${ALERT_TERMINAL}" == "true" ]] || return 0

  # Cooldown check: only pop open a terminal window if not already shown recently
  local now last_ts=0
  now="$(date +%s)"
  if [[ -f "${ALERT_STATE_FILE}" ]]; then
    last_ts="$(cat "${ALERT_STATE_FILE}" 2>/dev/null || echo 0)"
    [[ "${last_ts}" =~ ^[0-9]+$ ]] || last_ts=0
  fi
  if (( now - last_ts < ALERT_COOLDOWN )); then
    return 0
  fi
  printf '%s\n' "${now}" > "${ALERT_STATE_FILE}" 2>/dev/null || true

  send_desktop_alert "Syncalibur — Sync Failed ($(basename "${REPO_ROOT}"))" "${reason}"

  # Do not spawn a second popup terminal if already running interactively in a terminal
  if [[ "${SYNCALIBUR_BACKGROUND:-0}" != "1" && -t 1 ]]; then
    return 0
  fi

  local alert_cmd="SYNCALIBUR_CONFIG=\"${CONFIG_FILE}\" \"${SCRIPT_PATH}\" alert --wait"

  case "${OS_KERNEL}" in
    Darwin*)
      if command -v osascript >/dev/null 2>&1; then
        osascript -e "tell application \"Terminal\" to activate" \
                  -e "tell application \"Terminal\" to do script \"${alert_cmd//\"/\\\"}\"" >/dev/null 2>&1 &
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then
        local bash_win script_win
        bash_win="$(cygpath -w "$(command -v bash)")"
        script_win="$(cygpath -w "${SCRIPT_PATH}")"
        cmd.exe //c start "Syncalibur Alert - Sync Failed" "${bash_win}" "${script_win}" alert --wait >/dev/null 2>&1 &
      fi
      ;;
    *)
      # Ensure DISPLAY / XAUTHORITY / DBUS are available when running under systemd user service
      local uid
      uid="$(id -u 2>/dev/null || echo 1000)"
      [[ -z "${DISPLAY:-}" && -S /tmp/.X11-unix/X0 ]] && export DISPLAY=":0"
      [[ -z "${DISPLAY:-}" && -S /tmp/.X11-unix/X1 ]] && export DISPLAY=":1"
      [[ -z "${WAYLAND_DISPLAY:-}" && -S "/run/user/${uid}/wayland-0" ]] && export WAYLAND_DISPLAY="wayland-0"
      [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "/run/user/${uid}/bus" ]] && export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus"

      if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        return 0
      fi

      if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal --title="Syncalibur Alert — SYNC FAILED" -- bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v konsole >/dev/null 2>&1; then
        konsole -p tabtitle="Syncalibur Alert — SYNC FAILED" -e bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal --title="Syncalibur Alert — SYNC FAILED" -x bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v kitty >/dev/null 2>&1; then
        kitty --title "Syncalibur Alert — SYNC FAILED" bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v alacritty >/dev/null 2>&1; then
        alacritty -t "Syncalibur Alert — SYNC FAILED" -e bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v wezterm >/dev/null 2>&1; then
        wezterm start -- bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v tilix >/dev/null 2>&1; then
        tilix -t "Syncalibur Alert — SYNC FAILED" -e "bash -c '${alert_cmd}'" >/dev/null 2>&1 &
      elif command -v mate-terminal >/dev/null 2>&1; then
        mate-terminal --title="Syncalibur Alert — SYNC FAILED" -x bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator -e bash -c "${alert_cmd}" >/dev/null 2>&1 &
      elif command -v xterm >/dev/null 2>&1; then
        xterm -T "Syncalibur Alert — SYNC FAILED" -e bash -c "${alert_cmd}" >/dev/null 2>&1 &
      fi
      ;;
  esac
}

cmd_alert() {
  local mode="${1:-}"
  ensure_logo_ansi

  local ts stage targets reason hint details
  if [[ -f "${FAIL_REPORT_FILE}" ]]; then
    ts="$(sed -n '1p' "${FAIL_REPORT_FILE}")"
    stage="$(sed -n '2p' "${FAIL_REPORT_FILE}")"
    targets="$(sed -n '3p' "${FAIL_REPORT_FILE}")"
    reason="$(sed -n '4p' "${FAIL_REPORT_FILE}")"
    hint="$(sed -n '5p' "${FAIL_REPORT_FILE}")"
    details="$(tail -n +6 "${FAIL_REPORT_FILE}" | head -n 12)"
  else
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    stage="HEALTH CHECK"
    targets="$(describe_push_targets_inline "$(get_remote)") ($(get_branch || echo main))"
    if [[ "${mode}" == "--test" ]]; then
      reason="Simulated Sync Failure Alert (Test Mode)"
      hint="Popup terminal & diagnostic view verified! In real operation, this window opens automatically if a push or commit fails."
      details="remote: Test simulation triggered via './scripts/syncalibur.sh alert --test'"
    else
      reason="No active sync failures recorded — repository is healthy!"
      hint="Syncalibur automatically pops open this diagnostic window whenever a background commit or push fails."
      details=""
    fi
  fi

  local id_raw git_user git_email sys_ident ssh_cred gh_user gh_via gl_user gl_via
  id_raw="$(detect_user_identity)"
  IFS='|' read -r git_user git_email sys_ident ssh_cred gh_user gh_via gl_user gl_via <<< "${id_raw}"

  local header_color="${C_RED}"
  local title_text="✖  S Y N C   F A I L E D   —   D I A G N O S T I C   A L E R T"
  if [[ ! -f "${FAIL_REPORT_FILE}" && "${mode}" != "--test" ]]; then
    header_color="${C_GREEN}"
    title_text="✔  S Y N C A L I B U R   —   N O   A C T I V E   A L E R T S"
  fi

  local -a alert_lines=(
    "${header_color}╭──────────────────────────────────────────────────────────────────────╮${C_RESET}"
    "${header_color}│${C_RESET}  ${header_color}${C_BOLD}${title_text}${C_RESET}        ${header_color}│${C_RESET}"
    "${header_color}╰──────────────────────────────────────────────────────────────────────╯${C_RESET}"
    "  ${C_RED}◈${C_RESET} ${C_BOLD}Timestamp :${C_RESET} ${C_WHITE}${ts}${C_RESET}"
    "  ${C_RED}◈${C_RESET} ${C_BOLD}Stage     :${C_RESET} ${C_AMBER}${C_BOLD}${stage}${C_RESET}"
    "  ${C_RED}◈${C_RESET} ${C_BOLD}Repository:${C_RESET} ${C_WHITE}${REPO_ROOT}${C_RESET} ${C_SLATE}(scope: ${SCOPE})${C_RESET}"
    "  ${C_RED}◈${C_RESET} ${C_BOLD}Target(s) :${C_RESET} ${C_CYAN}${targets}${C_RESET}"
    "  ${C_RED}◈${C_RESET} ${C_BOLD}Identity  :${C_RESET} ${C_WHITE}${git_user}${C_RESET} ${C_SLATE}(GitHub: @${gh_user:-none} • GitLab: @${gl_user:-none} • Key: ${ssh_cred})${C_RESET}"
    "  ${C_SLATE}──────────────────────────────────────────────────────────────────────${C_RESET}"
    "  ${C_RED}${C_BOLD}✖ Error Summary:${C_RESET}"
    "    ${C_RED}${reason}${C_RESET}"
    ""
    "  ${C_GOLD}${C_BOLD}✦ Recommended Action:${C_RESET}"
    "    ${C_AMBER}${hint}${C_RESET}"
    "  ${C_SLATE}──────────────────────────────────────────────────────────────────────${C_RESET}"
    "  ${C_CYAN}${C_BOLD}Quick Recovery Commands:${C_RESET}"
    "    ${C_WHITE}./scripts/syncalibur.sh status${C_RESET}    ${C_SLATE}# Inspect live sync status & targets${C_RESET}"
    "    ${C_WHITE}./scripts/syncalibur.sh logs${C_RESET}      ${C_SLATE}# Follow live retry telemetry${C_RESET}"
    "    ${C_WHITE}./scripts/syncalibur.sh restart${C_RESET}   ${C_SLATE}# Force an immediate retry now${C_RESET}"
  )

  local -a logo_lines=()
  local line
  if [[ -f "${LOGO_ANSI_FILE}" ]]; then
    while IFS= read -r line; do
      logo_lines+=("${line}")
    done < "${LOGO_ANSI_FILE}"
  fi

  local total_rows=${#logo_lines[@]}
  (( ${#alert_lines[@]} > total_rows )) && total_rows=${#alert_lines[@]}

  printf '\n'
  local i=0
  local empty_logo="                                      "
  while (( i < total_rows )); do
    local l_part="${logo_lines[$i]:-${empty_logo}}"
    local r_part="${alert_lines[$i]:-}"
    printf '  %s   %s\n' "${l_part}" "${r_part}"
    i=$(( i + 1 ))
  done
  printf '\n'

  if [[ -n "${details}" ]]; then
    printf '  %s%sRaw Git / Transport Output:%s\n' "${C_RED}" "${C_BOLD}" "${C_RESET}"
    printf '  %s────────────────────────────────────────────────────────────────────────────────────────%s\n' "${C_SLATE}" "${C_RESET}"
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      printf '    %s│%s %s%s%s\n' "${C_RED}" "${C_RESET}" "${C_SLATE}" "${line}" "${C_RESET}"
    done <<< "${details}"
    printf '\n'
  fi

  if [[ "${mode}" == "--wait" ]]; then
    printf '  %sPress [Enter] to close this alert window, or [L] + [Enter] to stream live logs: %s' "${C_GOLD}${C_BOLD}" "${C_RESET}"
    local reply=""
    read -r reply || true
    if [[ "${reply}" =~ ^[Ll]$ ]]; then
      cmd_logs
    fi
  fi
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
# Repository state & commit/push helpers (cwd = REPO_ROOT)
# ==============================================================================

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
  local path reason msg count line err_out
  local -a excludes=() files=()

  while IFS= read -r -d '' path; do
    if reason="$(block_reason "${path}")"; then
      excludes+=(":(exclude,literal)${path}")
      warn_blocked "${path}" "${reason}"
    fi
  done < <(changed_paths)

  if ! err_out="$(git add -A -- "${SCOPE}" "${excludes[@]}" 2>&1)"; then
    printf '%s\n' "${err_out}" >> "${LOG_FILE}"
    log "❌ 'git add' failed (details in ${LOG_FILE})."
    trigger_failure_alert "GIT STAGE (git add)" "git add failed while staging changes in '${SCOPE}'" "${err_out}"
    return 1
  fi

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

  if err_out="$(git commit -m "${msg}" 2>&1)"; then
    printf '%s\n' "${err_out}" >> "${LOG_FILE}"
    log "✅ Committed ${count} file(s): ${msg}"
    return 0
  fi
  printf '%s\n' "${err_out}" >> "${LOG_FILE}"
  log "❌ 'git commit' failed (details in ${LOG_FILE})."
  trigger_failure_alert "GIT COMMIT" "git commit failed for '${msg}'" "${err_out}"
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
  done < <(grep -iE 'rejected|error|fatal|denied|exceed|too large|LFS|could not|not found' <<< "$1")
  echo "${summary:-unknown error, see ${LOG_FILE}}"
}

push_changes() {
  local remote="$1" branch="$2" output rc targets_desc err_summary
  # If no remote URL is configured yet, auto-create and bind origin first!
  if [[ -z "$(get_push_urls "${remote}")" ]]; then
    auto_create_or_bind_remote "" "" || true
    remote="$(get_remote)"
  fi

  targets_desc="$(describe_push_targets_inline "${remote}")"
  log "📤 Pushing '${branch}' -> ${targets_desc}..."
  output="$(run_with_timeout "${PUSH_TIMEOUT}" git push -u "${remote}" "${branch}" 2>&1)"
  rc=$?
  printf '%s\n' "${output}" >> "${LOG_FILE}"
  if (( rc == 0 )); then
    clear_sync_failure
    log "🎉 Push succeeded (${targets_desc})."
    return 0
  fi

  # If push failed because the remote repository does not exist yet on GitHub/GitLab,
  # automatically create it using the user's authorized CLI/token and retry immediately!
  if [[ "${AUTO_CREATE_REMOTE}" == "true" ]] && grep -qiE 'Repository not found|project you were looking for could not be found|does not appear to be a git repository' <<< "${output}"; then
    local url parsed provider slug created_any=0
    while IFS= read -r url; do
      [[ -z "${url}" ]] && continue
      parsed="$(parse_remote_url "${url}")"
      provider="${parsed%%|*}"
      slug="${parsed#*|}"
      slug="${slug%%|*}"
      if auto_create_or_bind_remote "${slug}" "${provider}"; then
        created_any=1
      fi
    done < <(get_push_urls "${remote}")

    if (( created_any )); then
      output="$(run_with_timeout "${PUSH_TIMEOUT}" git push -u "${remote}" "${branch}" 2>&1)"
      rc=$?
      printf '%s\n' "${output}" >> "${LOG_FILE}"
      if (( rc == 0 )); then
        clear_sync_failure
        log "🎉 Push succeeded after auto-creating remote repository (${targets_desc})."
        return 0
      fi
    fi
  fi

  if (( rc == 124 )); then
    err_summary="Push timed out after ${PUSH_TIMEOUT}s (${targets_desc})"
    log "⚠️  ${err_summary}."
  else
    err_summary="$(push_error_summary "${output}")"
    log "⚠️  Push failed: ${err_summary}"
  fi

  trigger_failure_alert "GIT PUSH (${remote}/${branch})" "${err_summary}" "${output}" "${remote}" "${branch}"
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

  if [[ "${SYNCALIBUR_BACKGROUND:-0}" != "1" && -t 1 ]]; then
    print_syncalibur_dashboard
  fi

  local remote branch busy head snap id_raw git_user git_email sys_ident ssh_cred gh_user gh_via gl_user gl_via
  local idle_snapshot="" checked_head="" push_pending=0 next_retry=0 retry_delay="${RETRY_BASE}"

  id_raw="$(detect_user_identity)"
  IFS='|' read -r git_user git_email sys_ident ssh_cred gh_user gh_via gl_user gl_via <<< "${id_raw}"

  # If the repository has no remote configured yet, auto-create/bind origin at startup
  remote="$(get_remote)"
  if [[ -z "$(get_push_urls "${remote}")" ]]; then
    auto_create_or_bind_remote "" "" || true
    remote="$(get_remote)"
  fi

  log "🚀 Syncalibur started. Repo: ${REPO_ROOT} (scope: ${SCOPE})"
  log "🎯 Targets: $(describe_push_targets_inline "${remote}")"
  log "👤 Identity: ${git_user} <${git_email}> (GitHub: ${gh_user:-n/a}, GitLab: ${gl_user:-n/a}, Key: ${ssh_cred})"
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
    <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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
  clear_sync_failure
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

  if [[ -f "${FAIL_REPORT_FILE}" ]]; then
    local f_ts f_stage f_reason f_hint
    f_ts="$(sed -n '1p' "${FAIL_REPORT_FILE}")"
    f_stage="$(sed -n '2p' "${FAIL_REPORT_FILE}")"
    f_reason="$(sed -n '4p' "${FAIL_REPORT_FILE}")"
    f_hint="$(sed -n '5p' "${FAIL_REPORT_FILE}")"
    printf '  %s%s✖ Active Sync Failure Alert (%s — %s):%s\n' "${C_RED}" "${C_BOLD}" "${f_stage}" "${f_ts}" "${C_RESET}"
    printf '    %sReason :%s %s\n' "${C_RED}" "${C_RESET}" "${f_reason}"
    printf '    %sFix    :%s %s\n\n' "${C_AMBER}" "${C_RESET}" "${f_hint}"
  fi

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
    printf '  %s────────────────────────────────────────────────────────────────────────────────────────%s\n' "${C_SLATE}" "${C_RESET}"
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
  printf '  %s%s◈ Live Syncalibur Telemetry%s %s(Press Ctrl+C to exit)%s\n' "${C_GOLD}" "${C_BOLD}" "${C_RESET}" "${C_SLATE}" "${C_RESET}"
  printf '  %s────────────────────────────────────────────────────────────────────────────────────────%s\n' "${C_SLATE}" "${C_RESET}"
  local line
  tail -n 20 -f "${LOG_FILE}" | while IFS= read -r line; do
    printf '  '
    format_log_line "${line}"
  done
}

usage() {
  print_syncalibur_dashboard
  cat << EOF
  ${C_GOLD}${C_BOLD}Usage:${C_RESET} $0 ${C_CYAN}{install [path]|uninstall|start|stop|restart|status|logs|alert [--test]|run}${C_RESET}

  ${C_GOLD}${C_BOLD}Commands:${C_RESET}
    ${C_CYAN}install [path]${C_RESET}  Configure auto-start on login/boot (Linux/macOS/Windows) and start now.
                    Optionally pass the directory path to watch (saved to syncalibur.env).
    ${C_CYAN}uninstall${C_RESET}       Stop Syncalibur and remove the auto-start service/launcher
    ${C_CYAN}start${C_RESET}           Start Syncalibur in the background
    ${C_CYAN}stop${C_RESET}            Stop the running daemon
    ${C_CYAN}restart${C_RESET}         Restart Syncalibur (run this after changing syncalibur.env)
    ${C_CYAN}status${C_RESET}          Show Syncalibur emblem, live dashboard, detected remotes & recent logs
    ${C_CYAN}logs${C_RESET}            Show Syncalibur emblem and stream live colorized telemetry
    ${C_CYAN}alert [--test]${C_RESET}  Display the Sync Failed diagnostic report (or simulate with --test)
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
  alert)      cmd_alert "${2:-}" ;;
  run)        run_daemon ;;
  *)          usage; exit 1 ;;
esac
