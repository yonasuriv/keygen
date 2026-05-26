#!/usr/bin/env bash
# keygen.sh
# Secure password/key generator with polished terminal output.
# Requires: bash, od, tr. Optional: uuidgen, curl or wget.
#
# Wordlist resolution order (memorable mode):
#   1. URL ($REMOTE_WORDLIST_URL), cached on first download
#   2. Local file ($LOCAL_WORDLIST_PATH, installed share, bundled wordlist, or XDG cache)
#   3. Built-in fallback list
#
# Delete the cache file to force a fresh download on next run.

set -Eeuo pipefail
IFS=$'\n\t'

if ((BASH_VERSINFO[0] < 4)); then
  printf 'error: %s requires Bash 4 or newer\n' "${0##*/}" >&2
  exit 1
fi

APP_NAME="keygen"
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
APP_VERSION="1.0.0"

LOCAL_META_PATH="$SCRIPT_DIR/.meta"
REMOTE_META_URL="${KEYGEN_META_URL:-https://raw.githubusercontent.com/yonasuriv/${APP_NAME}/refs/heads/main/.meta}"
REMOTE_SCRIPT_URL="${KEYGEN_SCRIPT_URL:-https://raw.githubusercontent.com/yonasuriv/${APP_NAME}/refs/heads/main/${APP_NAME}.sh}"
REMOTE_WORDLIST_URL="${REMOTE_WORDLIST_URL:-https://raw.githubusercontent.com/yonasuriv/${APP_NAME}/refs/heads/main/wordlist/en-memorable.txt}"

INSTALL_TARGET_CUSTOM="false"
if [[ -n "${PREFIX:-}" ]]; then
  INSTALL_PREFIX="$PREFIX"
  INSTALL_TARGET_CUSTOM="true"
elif (( EUID == 0 )); then
  INSTALL_PREFIX="/usr"
else
  INSTALL_PREFIX="${HOME}/.local"
fi
[[ -n "${KEYGEN_BIN_DIR:-}" || -n "${KEYGEN_SHARE_DIR:-}" ]] && INSTALL_TARGET_CUSTOM="true"
INSTALL_BIN_DIR="${KEYGEN_BIN_DIR:-$INSTALL_PREFIX/bin}"
INSTALL_SHARE_DIR="${KEYGEN_SHARE_DIR:-$INSTALL_PREFIX/share/$APP_NAME}"
INSTALL_CONFIG_DIR="$INSTALL_SHARE_DIR/config"
INSTALL_WORDLIST_DIR="$INSTALL_SHARE_DIR/wordlist"
INSTALLED_META_PATH="$INSTALL_SHARE_DIR/.meta"
DEFAULT_CONFIG_PATH="$SCRIPT_DIR/config/default.conf"

# Configurable defaults are loaded from the default conf file.
# These initializations satisfy set -u while preserving environment variables.
# Emergency fallbacks are applied by set_config_defaults() only if the configs
# do not set a value.
TYPE="${TYPE:-}"
LENGTH="${LENGTH:-}"
MEMO_WORDS="${MEMO_WORDS:-}"
CASE="${CASE:-}"
ALLOW="${ALLOW:-}"
MEMO_SEPARATOR="${MEMO_SEPARATOR:-}"
COUNT="${COUNT:-}"
PLAIN="${PLAIN:-}"
SPINNER="${SPINNER:-}"
ACTION="${ACTION:-generate}"
MEMO_CAPITALIZE="${MEMO_CAPITALIZE:-}"
MEMO_NUM_PER_WORD="${MEMO_NUM_PER_WORD:-}"
SAFE_MODE="${SAFE_MODE:-}"

set_config_defaults() {
  [[ -z "$TYPE" ]] && TYPE="random"
  [[ -z "$LENGTH" ]] && LENGTH=16
  [[ -z "$MEMO_WORDS" ]] && MEMO_WORDS=3
  [[ -z "$CASE" ]] && CASE="default"
  [[ -z "$ALLOW" ]] && ALLOW="letters,numbers"
  [[ -z "$MEMO_SEPARATOR" ]] && MEMO_SEPARATOR="hyphen"
  [[ -z "$COUNT" ]] && COUNT=1
  [[ -z "$PLAIN" ]] && PLAIN="false"
  [[ -z "$SPINNER" ]] && SPINNER="true"
  [[ -z "$MEMO_CAPITALIZE" ]] && MEMO_CAPITALIZE="true"
  [[ -z "$MEMO_NUM_PER_WORD" ]] && MEMO_NUM_PER_WORD="true"
  [[ -z "$SAFE_MODE" ]] && SAFE_MODE="false"
  [[ -z "${REMOTE_WORDLIST_MIN_LEN:-}" ]] && REMOTE_WORDLIST_MIN_LEN=4
  [[ -z "${REMOTE_WORDLIST_TIMEOUT:-}" ]] && REMOTE_WORDLIST_TIMEOUT=5

  return 0
}

SPINNER_PID=""

DEFAULT_WORDLIST_URL="$REMOTE_WORDLIST_URL"
DEFAULT_WORDLIST_PATH="${XDG_CACHE_HOME:-${HOME}/.cache}/keygen/wordlist.txt"

WORDS_LIST=()
WORDS_LOADED="false"

# Last-resort fallback. Only used when URL fetch and local path both fail.
HARDCODED_WORDS=(
  amber anchor apple arctic atlas autumn beacon binary blossom border canyon
  carbon cedar cipher cobalt comet copper coral cosmos crystal delta desert
  dragon ember engine falcon fiber forest galaxy garden glacier harbor hazel
  horizon ivory jasmine kernel ladder lagoon lantern lunar magnet marble matrix
  meadow meteor mirror nebula neon nickel ocean olive orbit orchid panda pebble
  pepper photon pine pixel plasma prairie quartz radar raven river rocket
  saffron salmon satin shadow signal silver solar sphere spiral summit syntax
  timber token tundra velvet vector violet willow winter zephyr acorn alpine
  azure basil breezy brick bronze canvas charm chrome circuit cloud clover
  crown fabric field flint frost golden grove island jade jungle kite lemon
  lotus maple mint moss noble nova pearl prism quiet ruby sable sage slate
  storm swift tiger tulip vapor vivid wave whale zenith
)

# Color Variables
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
CYAN=$'\033[1;36m'
RESET=$'\033[0m'

usage() {
  local cmd="${0##*/}"
  cmd="${cmd%.sh}"

  cat <<EOF

Usage:
  $cmd [type] [options]
  $cmd --safe

Options:
      --safe              Generate a .env-friendly and URL-safe value using the A-Za-z0-9._~- charset.

  -t, --type VALUE        Output mode.
                          Values: random, memorable, uuid, hex, base32, base58, base64, base64url, nanoid, token, {special types}
                          Default: random

  -c, --case VALUE        Letter casing for generated output.
                          Values: default, lower, upper, capitalize
                          Default: default

  -l, --length N          Length for random and key-based formats.
                          Range: 8-64
                          Default: 16

  -w, --words N           Number of words for memorable passwords.
                          Range: 1-10
                          Default: 3

  -s, --separator VALUE   Word separator for memorable mode.
                          Values: hyphen, space, period, comma, underscore, none
                          Default: hyphen

  -a, --allow VALUE       Comma-separated character classes to include.
                          Values: letters,numbers,symbols,hyphen,space,period,comma,underscore,all
                          Default: letters,numbers

  -n, --count N           Number of values to generate.
                          Default: 1

  -v, --version           Print the current version and check for updates.
  -u, --update            Update the installed or local script from GitHub.
  -i, --install           Install keygen. Uses /usr when run as root, otherwise ~/.local.
  -p, --plain             Print generated values only. Disables colors, boxes, and labels.
      --no-spinner        Disable the progress spinner.
  -h, --help              Show this help message.

Special types:
  jwt                     Generate a JWT secret.
  secret                  Generate a general-purpose secret.
  general                 Generate a general-purpose secret key for apps, APIs, and services.
  token                   Generate a URL-safe 32-byte Base64 secret without padding.
  django                  Generate a Django-style secret key.

Environment (memorable mode):
  LOCAL_WORDLIST_PATH        Local cache/fallback. Default: installed/bundled wordlist, then XDG cache
  REMOTE_WORDLIST_URL        Source URL. Default: project wordlist on GitHub
  REMOTE_WORDLIST_MIN_LEN    Minimum word length. Default: 4
  REMOTE_WORDLIST_TIMEOUT    Download timeout (seconds). Default: 5

Install/update environment:
  PREFIX                     Install prefix. Default: /usr as root, otherwise ~/.local
  KEYGEN_BIN_DIR             Override binary directory.
  KEYGEN_SHARE_DIR           Override shared data directory.

Examples:
  $cmd
  $cmd jwt
  $cmd base64
  $cmd --safe --plain
  $cmd --length 24 --allow letters,numbers,symbols
  $cmd --type memorable --words 4 --case capitalize --separator hyphen
  $cmd --type uuid --count 3
  $cmd --type base64url --length 32 --plain
EOF
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

fatal() {
  printf '%bERROR%b: %s\n' "$RED" "$RESET" "$1" >&2
  exit 1
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

read_meta_version() {
  local file="$1"
  [[ -r "$file" ]] || return 1

  local line version
  line="$(awk -F= '$1 == "APP_VERSION" { print $2; exit }' "$file" 2>/dev/null)" || return 1
  version="${line%\"}"
  version="${version#\"}"
  [[ -n "$version" ]] || return 1
  printf '%s' "$version"
}

init_app_version() {
  local version
  if version="$(read_meta_version "$LOCAL_META_PATH")"; then
    APP_VERSION="$version"
  elif version="$(read_meta_version "$INSTALLED_META_PATH")"; then
    APP_VERSION="$version"
  elif version="$(read_meta_version "$SCRIPT_DIR/../share/$APP_NAME/.meta")"; then
    APP_VERSION="$version"
  elif version="$(read_meta_version "/usr/share/$APP_NAME/.meta")"; then
    APP_VERSION="$version"
  elif version="$(read_meta_version "${HOME}/.local/share/$APP_NAME/.meta")"; then
    APP_VERSION="$version"
  fi
}

script_target_path() {
  if [[ "$SCRIPT_PATH" == /* ]]; then
    printf '%s' "$SCRIPT_PATH"
  else
    printf '%s/%s' "$SCRIPT_DIR" "${SCRIPT_PATH##*/}"
  fi
}

download_to_file() {
  local url="$1"
  local dest="$2"
  local timeout="${3:-15}"

  if has_command curl; then
    curl -fsSL --max-time "$timeout" "$url" -o "$dest"
  elif has_command wget; then
    wget -q --timeout="$timeout" "$url" -O "$dest"
  else
    return 1
  fi
}

fetch_remote_version() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/keygen-meta.XXXXXX")" || return 1
  if download_to_file "$REMOTE_META_URL" "$tmp" 10; then
    read_meta_version "$tmp"
    local rc=$?
    rm -f "$tmp" 2>/dev/null || true
    return "$rc"
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

version_is_newer() {
  local remote="$1"
  local current="$2"
  [[ "$remote" != "$current" ]] || return 1

  if has_command sort; then
    [[ "$(printf '%s\n%s\n' "$current" "$remote" | sort -V | tail -n 1)" == "$remote" ]]
  else
    [[ "$remote" > "$current" ]]
  fi
}

print_version() {
  init_app_version
  printf '%s %s\n' "$APP_NAME" "$APP_VERSION"

  local remote
  if remote="$(fetch_remote_version)"; then
    if version_is_newer "$remote" "$APP_VERSION"; then
      printf 'update available: %s\n' "$remote"
    else
      printf 'up to date\n'
    fi
  else
    printf 'update check unavailable\n' >&2
  fi
}

load_user_config() {
  local default_config="" user_config=""

  # Snapshot environment variables before config files can overwrite them
  local _TYPE _LENGTH _MEMO_WORDS _CASE _ALLOW _MEMO_SEPARATOR _COUNT _PLAIN _SPINNER
  local _MEMO_CAPITALIZE _MEMO_NUM_PER_WORD _SAFE_MODE _REMOTE_WORDLIST_MIN_LEN
  local _REMOTE_WORDLIST_URL _LOCAL_WORDLIST_PATH _REMOTE_WORDLIST_TIMEOUT
  [[ ${TYPE+x} ]] && _TYPE="$TYPE"
  [[ ${LENGTH+x} ]] && _LENGTH="$LENGTH"
  [[ ${MEMO_WORDS+x} ]] && _MEMO_WORDS="$MEMO_WORDS"
  [[ ${CASE+x} ]] && _CASE="$CASE"
  [[ ${ALLOW+x} ]] && _ALLOW="$ALLOW"
  [[ ${MEMO_SEPARATOR+x} ]] && _MEMO_SEPARATOR="$MEMO_SEPARATOR"
  [[ ${COUNT+x} ]] && _COUNT="$COUNT"
  [[ ${PLAIN+x} ]] && _PLAIN="$PLAIN"
  [[ ${SPINNER+x} ]] && _SPINNER="$SPINNER"
  [[ ${MEMO_CAPITALIZE+x} ]] && _MEMO_CAPITALIZE="$MEMO_CAPITALIZE"
  [[ ${MEMO_NUM_PER_WORD+x} ]] && _MEMO_NUM_PER_WORD="$MEMO_NUM_PER_WORD"
  [[ ${SAFE_MODE+x} ]] && _SAFE_MODE="$SAFE_MODE"
  [[ ${REMOTE_WORDLIST_MIN_LEN+x} ]] && _REMOTE_WORDLIST_MIN_LEN="$REMOTE_WORDLIST_MIN_LEN"
  [[ ${REMOTE_WORDLIST_URL+x} ]] && _REMOTE_WORDLIST_URL="$REMOTE_WORDLIST_URL"
  [[ ${LOCAL_WORDLIST_PATH+x} ]] && _LOCAL_WORDLIST_PATH="$LOCAL_WORDLIST_PATH"
  [[ ${REMOTE_WORDLIST_TIMEOUT+x} ]] && _REMOTE_WORDLIST_TIMEOUT="$REMOTE_WORDLIST_TIMEOUT"

  # Search for default.conf
  for config in \
    "$INSTALL_CONFIG_DIR/default.conf" \
    "$SCRIPT_DIR/config/default.conf" \
    "$SCRIPT_DIR/../share/$APP_NAME/config/default.conf" \
    "/usr/share/$APP_NAME/config/default.conf" \
    "/usr/local/share/$APP_NAME/config/default.conf" \
    "${HOME}/.local/share/$APP_NAME/config/default.conf"
  do
    [[ -r "$config" ]] || continue
    default_config="$config"
    break
  done

  # Search for user.conf
  for config in \
    "$INSTALL_CONFIG_DIR/user.conf" \
    "$SCRIPT_DIR/config/user.conf" \
    "$SCRIPT_DIR/../share/$APP_NAME/config/user.conf" \
    "/usr/share/$APP_NAME/config/user.conf" \
    "/usr/local/share/$APP_NAME/config/user.conf" \
    "${HOME}/.local/share/$APP_NAME/config/user.conf"
  do
    [[ -r "$config" ]] || continue
    user_config="$config"
    break
  done

  # Load default.conf first
  if [[ -n "$default_config" ]]; then
    # shellcheck source=/dev/null
    source "$default_config"
  fi

  # Load user.conf second (overrides defaults)
  if [[ -n "$user_config" ]]; then
    # shellcheck source=/dev/null
    source "$user_config"
  fi

  # Strip CRLF from loaded config values
  TYPE="${TYPE//$'\r'/}"
  LENGTH="${LENGTH//$'\r'/}"
  MEMO_WORDS="${MEMO_WORDS//$'\r'/}"
  CASE="${CASE//$'\r'/}"
  ALLOW="${ALLOW//$'\r'/}"
  MEMO_SEPARATOR="${MEMO_SEPARATOR//$'\r'/}"
  COUNT="${COUNT//$'\r'/}"
  PLAIN="${PLAIN//$'\r'/}"
  SPINNER="${SPINNER//$'\r'/}"
  MEMO_CAPITALIZE="${MEMO_CAPITALIZE//$'\r'/}"
  MEMO_NUM_PER_WORD="${MEMO_NUM_PER_WORD//$'\r'/}"
  SAFE_MODE="${SAFE_MODE//$'\r'/}"
  REMOTE_WORDLIST_MIN_LEN="${REMOTE_WORDLIST_MIN_LEN//$'\r'/}"
  REMOTE_WORDLIST_TIMEOUT="${REMOTE_WORDLIST_TIMEOUT//$'\r'/}"

  # Restore environment variables (env vars override config files)
  [[ ${_TYPE+x} ]] && TYPE="$_TYPE"
  [[ ${_LENGTH+x} ]] && LENGTH="$_LENGTH"
  [[ ${_MEMO_WORDS+x} ]] && MEMO_WORDS="$_MEMO_WORDS"
  [[ ${_CASE+x} ]] && CASE="$_CASE"
  [[ ${_ALLOW+x} ]] && ALLOW="$_ALLOW"
  [[ ${_MEMO_SEPARATOR+x} ]] && MEMO_SEPARATOR="$_MEMO_SEPARATOR"
  [[ ${_COUNT+x} ]] && COUNT="$_COUNT"
  [[ ${_PLAIN+x} ]] && PLAIN="$_PLAIN"
  [[ ${_SPINNER+x} ]] && SPINNER="$_SPINNER"
  [[ ${_MEMO_CAPITALIZE+x} ]] && MEMO_CAPITALIZE="$_MEMO_CAPITALIZE"
  [[ ${_MEMO_NUM_PER_WORD+x} ]] && MEMO_NUM_PER_WORD="$_MEMO_NUM_PER_WORD"
  [[ ${_SAFE_MODE+x} ]] && SAFE_MODE="$_SAFE_MODE"
  [[ ${_REMOTE_WORDLIST_MIN_LEN+x} ]] && REMOTE_WORDLIST_MIN_LEN="$_REMOTE_WORDLIST_MIN_LEN"
  [[ ${_REMOTE_WORDLIST_URL+x} ]] && REMOTE_WORDLIST_URL="$_REMOTE_WORDLIST_URL"
  [[ ${_LOCAL_WORDLIST_PATH+x} ]] && LOCAL_WORDLIST_PATH="$_LOCAL_WORDLIST_PATH"
  [[ ${_REMOTE_WORDLIST_TIMEOUT+x} ]] && REMOTE_WORDLIST_TIMEOUT="$_REMOTE_WORDLIST_TIMEOUT"

  return 0
}

config_bool() {
  local name="$1"
  local value="${2,,}"

  case "$value" in
    true|1|yes|on) printf 'true' ;;
    false|0|no|off) printf 'false' ;;
    *) fatal "$name must be true or false" ;;
  esac
}

normalize_config() {
  # Normalize values loaded from config files
  [[ -n "${TYPE:-}" ]] && TYPE="${TYPE,,}"
  [[ -n "${CASE:-}" ]] && CASE="${CASE,,}"
  [[ -n "${MEMO_SEPARATOR:-}" ]] && MEMO_SEPARATOR="${MEMO_SEPARATOR,,}"

  [[ -n "${PLAIN:-}" ]] && PLAIN="$(config_bool PLAIN "$PLAIN")"
  [[ -n "${SPINNER:-}" ]] && SPINNER="$(config_bool SPINNER "$SPINNER")"
  [[ -n "${MEMO_CAPITALIZE:-}" ]] && MEMO_CAPITALIZE="$(config_bool MEMO_CAPITALIZE "$MEMO_CAPITALIZE")"
  [[ -n "${MEMO_NUM_PER_WORD:-}" ]] && MEMO_NUM_PER_WORD="$(config_bool MEMO_NUM_PER_WORD "$MEMO_NUM_PER_WORD")"
  [[ -n "${SAFE_MODE:-}" ]] && SAFE_MODE="$(config_bool SAFE_MODE "$SAFE_MODE")"

  # Lowercase environment fallbacks
  [[ ${type+x} ]] && TYPE="${type,,}"
  [[ ${length+x} ]] && LENGTH="$length"
  [[ ${memo_words+x} ]] && MEMO_WORDS="$memo_words"
  [[ ${CASE+x} ]] && CASE="${CASE,,}"
  [[ ${allow+x} ]] && ALLOW="$allow"
  [[ ${memo_separator+x} ]] && MEMO_SEPARATOR="${memo_separator,,}"
  [[ ${count+x} ]] && COUNT="$count"
  [[ ${plain+x} ]] && PLAIN="$(config_bool plain "$plain")"
  [[ ${spinner+x} ]] && SPINNER="$(config_bool spinner "$spinner")"
  [[ ${memo_capitalize+x} ]] && MEMO_CAPITALIZE="$(config_bool memo_capitalize "$memo_capitalize")"
  [[ ${memo_num_per_word+x} ]] && MEMO_NUM_PER_WORD="$(config_bool memo_num_per_word "$memo_num_per_word")"
  [[ ${REMOTE_WORDLIST_MIN_LEN+x} ]] && REMOTE_WORDLIST_MIN_LEN="$REMOTE_WORDLIST_MIN_LEN"
  [[ ${remote_wordlist_url+x} ]] && REMOTE_WORDLIST_URL="$remote_wordlist_url"
  [[ ${local_wordlist_path+x} ]] && LOCAL_WORDLIST_PATH="$local_wordlist_path"
  [[ ${remote_wordlist_timeout+x} ]] && REMOTE_WORDLIST_TIMEOUT="$remote_wordlist_timeout"

  return 0
}

install_scope() {
  if (( EUID == 0 )); then
    printf 'sudo'
  else
    printf 'normal user'
  fi
}

confirm_install() {
  local scope
  scope="$(install_scope)"

  printf '\nYou are running this command as %s.\n' "$scope"
  printf '\nThis will install %s to:\n' "$APP_NAME"
  printf '\n  Binary: %s/keygen\n' "$INSTALL_BIN_DIR"
  printf '  Shared data: %s\n' "$INSTALL_SHARE_DIR"
  printf '\nContinue? [Y/n] '

  if [[ ! -t 0 ]]; then
    printf '\n'
    fatal "Installation requires confirmation from an interactive shell"
  fi

  local answer
  IFS= read -r answer
  case "${answer,,}" in
    y|yes) ;;
    *) fatal "Installation cancelled" ;;
  esac
}

installation_candidates() {
  printf '%s\n' \
    "/usr/bin/keygen|system binary" \
    "/usr/share/keygen|system shared data" \
    "/usr/local/bin/keygen|legacy system binary" \
    "/usr/local/share/keygen|legacy system shared data" \
    "${HOME}/.local/bin/keygen|user binary" \
    "${HOME}/.local/share/keygen|user shared data"
}

check_existing_installations() {
  [[ "$INSTALL_TARGET_CUSTOM" == "true" ]] && return 0

  local target_bin="$INSTALL_BIN_DIR/keygen"
  local existing=()
  local candidate path label

  while IFS= read -r candidate; do
    path="${candidate%%|*}"
    label="${candidate#*|}"

    [[ "$path" == "$target_bin" || "$path" == "$INSTALL_SHARE_DIR" ]] && continue
    [[ -e "$path" ]] && existing+=("$label: $path")
  done < <(installation_candidates)

  if ((${#existing[@]} > 0)); then
    printf 'Existing installation found outside the selected target:\n' >&2
    for candidate in "${existing[@]}"; do
      printf '  %s\n' "$candidate" >&2
    done
    fatal "Remove the existing installation or set PREFIX/KEYGEN_BIN_DIR/KEYGEN_SHARE_DIR intentionally"
  fi
}

install_default_config() {
  local dest_default="$INSTALL_CONFIG_DIR/default.conf"
  local dest_user="$INSTALL_CONFIG_DIR/user.conf"

  # Install default.conf if not present
  if [[ ! -f "$dest_default" ]]; then
    local source=""
    local candidate
    for candidate in \
      "$DEFAULT_CONFIG_PATH" \
      "$INSTALL_SHARE_DIR/default.conf" \
      "$SCRIPT_DIR/../share/$APP_NAME/default.conf"
    do
      if [[ -f "$candidate" ]]; then
        source="$candidate"
        break
      fi
    done

    [[ -n "$source" ]] || fatal "default config not found"
    install -m 0644 "$source" "$dest_default"
  fi

  # Install user.conf if not present
  if [[ ! -f "$dest_user" ]]; then
    local user_source=""
    local user_candidate
    for user_candidate in \
      "$SCRIPT_DIR/config/user.conf" \
      "$SCRIPT_DIR/../share/$APP_NAME/config/user.conf" \
      "$INSTALL_SHARE_DIR/config/user.conf"
    do
      if [[ -f "$user_candidate" ]]; then
        user_source="$user_candidate"
        break
      fi
    done

    if [[ -n "$user_source" ]]; then
      install -m 0644 "$user_source" "$dest_user"
    fi
  fi
}

install_keygen() {
  init_app_version

  check_existing_installations
  confirm_install

  if [[ -e "$INSTALL_BIN_DIR/keygen" ]]; then
    fatal "Target already exists: $INSTALL_BIN_DIR/keygen"
  fi

  mkdir -p "$INSTALL_BIN_DIR" "$INSTALL_CONFIG_DIR" "$INSTALL_WORDLIST_DIR"
  install -m 0755 "$(script_target_path)" "$INSTALL_BIN_DIR/keygen"

  if [[ -f "$DEFAULT_CONFIG_PATH" ]]; then
    install -m 0644 "$DEFAULT_CONFIG_PATH" "$INSTALL_SHARE_DIR/default.conf"
  elif [[ -f "$SCRIPT_DIR/../share/$APP_NAME/default.conf" ]]; then
    install -m 0644 "$SCRIPT_DIR/../share/$APP_NAME/default.conf" "$INSTALL_SHARE_DIR/default.conf"
  fi

  install_default_config

  if [[ -f "$SCRIPT_DIR/wordlist/en-memorable.txt" && ! -f "$INSTALL_WORDLIST_DIR/en-memorable.txt" ]]; then
    install -m 0644 "$SCRIPT_DIR/wordlist/en-memorable.txt" "$INSTALL_WORDLIST_DIR/en-memorable.txt"
  fi

  if [[ -f "$LOCAL_META_PATH" ]]; then
    install -m 0644 "$LOCAL_META_PATH" "$INSTALLED_META_PATH"
  else
    printf 'APP_VERSION="%s"\n' "$APP_VERSION" > "$INSTALLED_META_PATH"
  fi

  printf 'installed %s to %s\n' "$APP_NAME" "$INSTALL_BIN_DIR/keygen"
  printf 'shared data: %s\n' "$INSTALL_SHARE_DIR"
}

update_keygen() {
  init_app_version

  local remote
  if ! remote="$(fetch_remote_version)"; then
    fatal "Could not check remote version"
  fi

  if ! version_is_newer "$remote" "$APP_VERSION"; then
    printf '%s %s is already up to date\n' "$APP_NAME" "$APP_VERSION"
    return 0
  fi

  local tmp_script tmp_meta target meta_target
  tmp_script="$(mktemp "${TMPDIR:-/tmp}/keygen-script.XXXXXX")" || fatal "Could not create temporary file"
  tmp_meta="$(mktemp "${TMPDIR:-/tmp}/keygen-meta.XXXXXX")" || {
    rm -f "$tmp_script" 2>/dev/null || true
    fatal "Could not create temporary file"
  }

  if ! download_to_file "$REMOTE_SCRIPT_URL" "$tmp_script" 30; then
    rm -f "$tmp_script" "$tmp_meta" 2>/dev/null || true
    fatal "Could not download update"
  fi
  if ! download_to_file "$REMOTE_META_URL" "$tmp_meta" 30; then
    rm -f "$tmp_script" "$tmp_meta" 2>/dev/null || true
    fatal "Could not download update metadata"
  fi

  if [[ ! -s "$tmp_script" ]]; then
    rm -f "$tmp_script" "$tmp_meta" 2>/dev/null || true
    fatal "Downloaded script is empty"
  fi

  if ! bash -n "$tmp_script"; then
    rm -f "$tmp_script" "$tmp_meta" 2>/dev/null || true
    fatal "Downloaded script failed syntax check"
  fi

  local shebang
  shebang="$(head -n 1 "$tmp_script")"
  if [[ "$shebang" != "#!/usr/bin/env bash"* && "$shebang" != "#!/bin/bash"* ]]; then
    rm -f "$tmp_script" "$tmp_meta" 2>/dev/null || true
    fatal "Downloaded script does not have a valid bash shebang"
  fi

  target="$(script_target_path)"
  meta_target="$LOCAL_META_PATH"
  if [[ "$target" == "$INSTALL_BIN_DIR/keygen" || -f "$INSTALLED_META_PATH" ]]; then
    meta_target="$INSTALLED_META_PATH"
  fi

  install -m 0755 "$tmp_script" "$target"
  mkdir -p "$(dirname "$meta_target")"
  install -m 0644 "$tmp_meta" "$meta_target"
  rm -f "$tmp_script" "$tmp_meta" 2>/dev/null || true

  printf 'Updated %s from %s to %s\n' "$APP_NAME" "$APP_VERSION" "$remote"
}

contains_allow() {
  local needle=","$1","
  local normalized=",${ALLOW// /},"
  [[ "$normalized" == *"$needle"* ]]
}

normalize_allow() {
  local raw="$1"
  raw="${raw// /}"
  raw="${raw,,}"

  local out=()
  local item
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    case "$item" in
      letter|letters|alpha) out+=("letters") ;;
      number|numbers|digit|digits) out+=("numbers") ;;
      symbol|symbols|special|specials) out+=("symbols") ;;
      hyphen|hyphens|dash|dashes) out+=("hyphen") ;;
      space|spaces) out+=("space") ;;
      period|periods|dot|dots) out+=("period") ;;
      comma|commas) out+=("comma") ;;
      underscore|underscores) out+=("underscore") ;;
      alnum) out+=("letters" "numbers") ;;
      all) out+=("letters" "numbers" "symbols" "hyphen" "space" "period" "comma" "underscore") ;;
      "") ;;
      *) fatal "Unsupported allow token: $item" ;;
    esac
  done

  if ((${#out[@]} == 0)); then
    fatal "--allow cannot be empty"
  fi

  local joined=""
  local seen=","
  for item in "${out[@]}"; do
    if [[ "$seen" != *",$item,"* ]]; then
      joined+="${joined:+,}$item"
      seen+="$item,"
    fi
  done

  printf '%s' "$joined"
}

validate_args() {
  # --safe short-circuits type-specific validation
  if [[ "$SAFE_MODE" == "true" ]]; then
    is_integer "$LENGTH" || fatal "--length must be an integer"
    is_integer "$COUNT" || fatal "--count must be an integer"
    (( LENGTH >= 8 && LENGTH <= 64 )) || fatal "--length must be between 8 and 64"
    (( COUNT >= 1 && COUNT <= 100 )) || fatal "--count must be between 1 and 100"
    return 0
  fi

  case "$TYPE" in
    random|memorable|passphrase|uuid|hex|base64|base64url|base32|base58|nanoid|jwt|secret|general|django|token) ;;
    *) fatal "Unsupported type: $TYPE" ;;
  esac

  case "$CASE" in
    default|lower|upper|capitalize) ;;
    *) fatal "Unsupported case mode: $CASE" ;;
  esac

  case "$MEMO_SEPARATOR" in
    hyphen|space|period|comma|underscore|none) ;;
    *) fatal "Unsupported separator: $MEMO_SEPARATOR" ;;
  esac

  is_integer "$LENGTH" || fatal "--length must be an integer"
  is_integer "$MEMO_WORDS" || fatal "--words must be an integer"
  is_integer "$COUNT" || fatal "--count must be an integer"

  (( LENGTH >= 8 && LENGTH <= 64 )) || fatal "--length must be between 8 and 64"
  (( MEMO_WORDS >= 1 && MEMO_WORDS <= 10 )) || fatal "--words must be between 1 and 10"
  (( COUNT >= 1 && COUNT <= 100 )) || fatal "--count must be between 1 and 100"

  ALLOW="$(normalize_allow "$ALLOW")"

  if [[ "$TYPE" == "memorable" && "$MEMO_CAPITALIZE" == "true" && "$CASE" == "default" ]]; then
    CASE="capitalize"
  fi
}

parse_args() {
  local type_set="false"

  while (($#)); do
    case "$1" in
      random|memorable|passphrase|uuid|hex|base64|base64url|base32|base58|nanoid|jwt|secret|general|django|token)
        [[ "$type_set" == "false" ]] || fatal "Multiple output types provided"
        TYPE="$1"
        type_set="true"
        ;;
      -t|--type)
        shift || fatal "Missing value for --type"
        TYPE="${1,,}"
        type_set="true"
        ;;
      --type=*) TYPE="${1#*=}"; TYPE="${TYPE,,}"; type_set="true" ;;
      -l|--length)
        shift || fatal "Missing value for --length"
        LENGTH="$1"
        ;;
      --length=*) LENGTH="${1#*=}" ;;
      -w|--words)
        shift || fatal "Missing value for --words"
        MEMO_WORDS="$1"
        ;;
      --words=*) MEMO_WORDS="${1#*=}" ;;
      -c|--case)
        shift || fatal "missing value for --case"
        CASE="${1,,}"
        ;;
      --case=*) CASE="${1#*=}"; CASE="${CASE,,}" ;;
      -a|--allow)
        shift || fatal "Missing value for --allow"
        ALLOW="$1"
        ;;
      --allow=*) ALLOW="${1#*=}" ;;
      -s|--separator|--sep)
        shift || fatal "Missing value for --separator"
        MEMO_SEPARATOR="${1,,}"
        ;;
      --separator=*|--sep=*) MEMO_SEPARATOR="${1#*=}"; MEMO_SEPARATOR="${MEMO_SEPARATOR,,}" ;;
      -n|--count)
        shift || fatal "Missing value for --count"
        COUNT="$1"
        ;;
      --count=*) COUNT="${1#*=}" ;;
      --safe)
        SAFE_MODE="true"
        ;;
      -p|--plain)
        PLAIN="true"
        SPINNER="false"
        ;;
      --no-spinner)
        SPINNER="false"
        ;;
      -v|--version)
        ACTION="version"
        ;;
      -u|--update)
        ACTION="update"
        ;;
      -i|--install)
        ACTION="install"
        ;;
      --uninstall)
        ACTION="uninstall"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        if [[ "$1" == -* ]]; then
          fatal "Unknown option: $1"
        fi
        if [[ "$type_set" == "false" ]]; then
          TYPE="${1,,}"
          type_set="true"
        else
          fatal "Unexpected argument: $1"
        fi
        ;;
    esac
    shift
  done
}

color_init() {
  if [[ "$PLAIN" == "true" || -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    BOLD="" DIM="" RESET="" ACCENT="" MUTED="" OK="" WARN="" LINE=""
    return
  fi

  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'

  if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
    ACCENT=$'\033[38;2;124;156;255m'
    MUTED=$'\033[38;2;148;163;184m'
    OK=$'\033[38;2;52;211;153m'
    WARN=$'\033[38;2;251;191;36m'
    LINE=$'\033[38;2;71;85;105m'
  else
    ACCENT=$'\033[38;5;111m'
    MUTED=$'\033[38;5;245m'
    OK=$'\033[38;5;120m'
    WARN=$'\033[38;5;220m'
    LINE=$'\033[38;5;240m'
  fi
}

spinner_start() {
  [[ "$SPINNER" == "true" && "$PLAIN" != "true" && -t 2 ]] || return 0

  local msg="$1"
  (
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local frame
    while true; do
      for frame in "${frames[@]}"; do
        printf '\r%b%s%b %s' "$ACCENT" "$frame" "$RESET" "$msg" >&2
        sleep 0.06
      done
    done
  ) &
  SPINNER_PID="$!"
}

spinner_stop() {
  [[ -n "${SPINNER_PID:-}" ]] || return 0
  kill "$SPINNER_PID" >/dev/null 2>&1 || true
  wait "$SPINNER_PID" 2>/dev/null || true
  SPINNER_PID=""
  printf '\r\033[K' >&2
}

cleanup() {
  spinner_stop
}
trap cleanup EXIT INT TERM

random_byte() {
  od -An -N1 -tu1 /dev/urandom | tr -d ' '
}

# Uniform random integer in [0, max) via rejection sampling.
# Reads as many random bytes as needed to cover max (supports up to ~2^32).
pick_index() {
  local max="$1"
  (( max >= 1 )) || fatal "Internal random bound out of range: $max"

  local cap byte_count
  if (( max <= 256 )); then
    cap=256; byte_count=1
  elif (( max <= 65536 )); then
    cap=65536; byte_count=2
  elif (( max <= 16777216 )); then
    cap=16777216; byte_count=3
  else
    cap=4294967296; byte_count=4
  fi

  local limit=$(( (cap / max) * max ))
  local n i

  while true; do
    n=0
    for ((i = 0; i < byte_count; i++)); do
      n=$(( n * 256 + $(random_byte) ))
    done
    if (( n < limit )); then
      printf '%d' $(( n % max ))
      return 0
    fi
  done
}

pick_char() {
  local alphabet="$1"
  local max="${#alphabet}"
  local idx
  idx="$(pick_index "$max")"
  printf '%s' "${alphabet:idx:1}"
}

random_token() {
  local length="$1"
  local alphabet="$2"
  local out=""
  local i

  ((${#alphabet} > 0)) || fatal "Generated charset is empty"

  for ((i = 0; i < length; i++)); do
    out+="$(pick_char "$alphabet")"
  done

  printf '%s' "$out"
}

# --- Wordlist loading ---------------------------------------------------------

# Download wordlist URL to a destination path. Returns 0 on success.
fetch_wordlist() {
  local url="$1"
  local dest="$2"
  local timeout="${REMOTE_WORDLIST_TIMEOUT:-5}"
  is_integer "$timeout" || timeout=5

  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "${dir}/.wordlist.XXXXXX" 2>/dev/null)" || return 1

  local ok=0
  if has_command curl; then
    curl -fsSL --max-time "$timeout" "$url" 2>/dev/null |
      awk -v min="$REMOTE_WORDLIST_MIN_LEN" '/^[A-Za-z]+$/ && length($0) >= min && length($0) <= 30 { print }' > "$tmp" && ok=1
  elif has_command wget; then
    wget -q --timeout="$timeout" "$url" -O - 2>/dev/null |
      awk -v min="$REMOTE_WORDLIST_MIN_LEN" '/^[A-Za-z]+$/ && length($0) >= min && length($0) <= 30 { print }' > "$tmp" && ok=1
  fi

  if (( ok == 1 )) && [[ -s "$tmp" ]]; then
    if mv -f "$tmp" "$dest" 2>/dev/null; then
      return 0
    fi
  fi

  rm -f "$tmp" 2>/dev/null || true
  return 1
}

wordlist_path_candidates() {
  if [[ -n "${LOCAL_WORDLIST_PATH:-}" ]]; then
    printf '%s\n' "$LOCAL_WORDLIST_PATH"
    return 0
  fi

  printf '%s\n' \
    "$INSTALL_WORDLIST_DIR/en-memorable.txt" \
    "$SCRIPT_DIR/../share/$APP_NAME/wordlist/en-memorable.txt" \
    "/usr/share/$APP_NAME/wordlist/en-memorable.txt" \
    "/usr/local/share/$APP_NAME/wordlist/en-memorable.txt" \
    "${HOME}/.local/share/$APP_NAME/wordlist/en-memorable.txt" \
    "$SCRIPT_DIR/wordlist/en-memorable.txt" \
    "$DEFAULT_WORDLIST_PATH"
}

# Populate WORDS_LIST from a file, filtering by minimum word length.
# Returns 0 if at least one word was accepted.
load_words_from_file() {
  local file="$1"
  local min_len="$2"
  WORDS_LIST=()

  local word
  while IFS= read -r word || [[ -n "$word" ]]; do
    word="${word%$'\r'}"
    word="${word#"${word%%[![:space:]]*}"}"
    word="${word%"${word##*[![:space:]]}"}"

    [[ -z "$word" ]] && continue
    [[ "$word" =~ ^[A-Za-z][A-Za-z\'-]*$ ]] || continue
    (( ${#word} >= min_len )) || continue

    WORDS_LIST+=("$word")
  done < "$file"

  (( ${#WORDS_LIST[@]} > 0 ))
}

load_words_from_hardcoded() {
  local min_len="$1"
  WORDS_LIST=()

  local w
  for w in "${HARDCODED_WORDS[@]}"; do
    (( ${#w} >= min_len )) && WORDS_LIST+=("$w")
  done

  (( ${#WORDS_LIST[@]} > 0 ))
}

ensure_wordlist() {
  [[ "$WORDS_LOADED" == "true" ]] && return 0

  local min_len="${REMOTE_WORDLIST_MIN_LEN:-4}"
  is_integer "$min_len" || fatal "REMOTE_WORDLIST_MIN_LEN must be a positive integer"
  (( min_len >= 1 )) || fatal "REMOTE_WORDLIST_MIN_LEN must be >= 1"

  local url="${REMOTE_WORDLIST_URL:-$DEFAULT_WORDLIST_URL}"
  local path="${LOCAL_WORDLIST_PATH:-$DEFAULT_WORDLIST_PATH}"
  local candidate

  # Step 1: read from an explicit, installed, bundled, or cached wordlist.
  while IFS= read -r candidate; do
    if [[ -s "$candidate" ]] && load_words_from_file "$candidate" "$min_len"; then
      WORDS_LOADED="true"
      return 0
    fi
  done < <(wordlist_path_candidates)

  # Step 2: if no local copy worked, try downloading into the first writable candidate.
  if [[ -n "$path" ]]; then
    fetch_wordlist "$url" "$path" || true
  fi

  # Step 3: read from the local file just downloaded.
  if [[ -s "$path" ]] && load_words_from_file "$path" "$min_len"; then
    WORDS_LOADED="true"
    return 0
  fi

  # Step 4: built-in fallback.
  if load_words_from_hardcoded "$min_len"; then
    WORDS_LOADED="true"
    return 0
  fi

  fatal "No words available with REMOTE_WORDLIST_MIN_LEN=$min_len"
}

# --- Generators ---------------------------------------------------------------

letter_charset() {
  case "$CASE" in
    default) printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' ;;
    lower) printf 'abcdefghijklmnopqrstuvwxyz' ;;
    upper) printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' ;;
    capitalize) printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' ;;
  esac
}

build_random_charset() {
  if [[ "$SAFE_MODE" == "true" ]]; then
    printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~'
    return 0
  fi

  local charset=""

  contains_allow "letters" && charset+="$(letter_charset)"
  contains_allow "numbers" && charset+='0123456789'
  contains_allow "symbols" && charset+='!@#$%^&*()=+[]{}:;?'
  contains_allow "hyphen" && charset+='-'
  contains_allow "space" && charset+=' '
  contains_allow "period" && charset+='.'
  contains_allow "comma" && charset+=','
  contains_allow "underscore" && charset+='_'

  printf '%s' "$charset"
}

separator_value() {
  case "$MEMO_SEPARATOR" in
    hyphen) printf '-' ;;
    space) printf ' ' ;;
    period) printf '.' ;;
    comma) printf ',' ;;
    underscore) printf '_' ;;
    none) printf '' ;;
  esac
}

format_word() {
  local word="$1"
  case "$CASE" in
    default|lower) printf '%s' "${word,,}" ;;
    upper) printf '%s' "${word^^}" ;;
    capitalize)
      word="${word,,}"
      local first="${word:0:1}"
      printf '%s%s' "${first^^}" "${word:1}"
      ;;
  esac
}

generate_memorable() {
  ensure_wordlist

  local sep
  sep="$(separator_value)"

  local out=""
  local idx word i
  for ((i = 0; i < MEMO_WORDS; i++)); do
    idx="$(pick_index "${#WORDS_LIST[@]}")"
    word="$(format_word "${WORDS_LIST[idx]}")"
    if [[ "${MEMO_NUM_PER_WORD:-true}" == "true" ]] && contains_allow "numbers"; then
      word+="$(random_token 2 '0123456789')"
    fi
    out+="${out:+$sep}$word"
  done

  if [[ "${MEMO_NUM_PER_WORD:-true}" != "true" ]] && contains_allow "numbers"; then
    out+="$sep$(random_token 2 '0123456789')"
  fi

  if [[ "$SAFE_MODE" != "true" ]] && contains_allow "symbols"; then
    out+="$sep$(random_token 1 '!@#$%^&*?')"
  fi

  printf '%s' "$out"
}

generate_uuid_v4_fallback() {
  local hex
  hex="$(random_token 32 '0123456789abcdef')"

  local variant
  variant="$(pick_char '89ab')"

  hex="${hex:0:12}4${hex:13:3}${variant}${hex:17}"
  printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

generate_uuid() {
  local value
  if has_command uuidgen; then
    value="$(uuidgen)"
  else
    value="$(generate_uuid_v4_fallback)"
  fi

  case "$CASE" in
    default|lower|capitalize) printf '%s' "${value,,}" ;;
    upper) printf '%s' "${value^^}" ;;
  esac
}

openssl_required() {
  has_command openssl || fatal "openssl is required for this command"
}

generate_secret() {
  openssl_required
  openssl rand -hex 32
}

generate_general() {
  openssl_required
  openssl rand -base64 33
}

generate_safe() {
  openssl_required
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
}

generate_token() {
  openssl_required
  openssl rand -base64 33 | tr '+/' '-_' | tr -d '='
}

generate_django_secret() {
  openssl_required
  LC_ALL=C openssl rand -base64 50 | tr -dc 'A-Za-z0-9!@#$%^&*()_=+-'
  printf '\n'
}

generate_value() {
  local value=""

  case "$TYPE" in
    random)
      value="$(random_token "$LENGTH" "$(build_random_charset)")"
      ;;
    memorable|passphrase)
      value="$(generate_memorable)"
      ;;
    uuid)
      value="$(generate_uuid)"
      ;;
    jwt|secret)
      value="$(generate_secret)"
      ;;
    general)
      value="$(generate_general)"
      ;;
    safe)
      value="$(generate_safe)"
      ;;
    token)
      value="$(generate_token)"
      ;;
    django)
      value="$(generate_django_secret)"
      ;;
    hex)
      case "$CASE" in
        default|lower|capitalize) value="$(random_token "$LENGTH" '0123456789abcdef')" ;;
        upper) value="$(random_token "$LENGTH" '0123456789ABCDEF')" ;;
      esac
      ;;
    base64)
      value="$(random_token "$LENGTH" 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/')"
      ;;
    base64url|nanoid)
      value="$(random_token "$LENGTH" 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-')"
      ;;
    base32)
      case "$CASE" in
        lower|capitalize) value="$(random_token "$LENGTH" 'abcdefghijklmnopqrstuvwxyz234567')" ;;
        default|upper) value="$(random_token "$LENGTH" 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567')" ;;
      esac
      ;;
    base58)
      value="$(random_token "$LENGTH" '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz')"
      ;;
  esac

  if [[ "$SAFE_MODE" == "true" ]]; then
    value="$(printf '%s' "$value" | tr ' ' '-' | tr -d "'" | tr '+/' '-_' | tr -dc 'A-Za-z0-9-_.~')"
  fi

  printf '%s' "$value"
}

# --- Rendering ----------------------------------------------------------------

render_plain() {
  local values=("$@")
  local value
  for value in "${values[@]}"; do
    printf '%s\n' "$value"
  done
}

repeat_line() {
  local count="$1"
  local out=""
  local i
  for ((i = 0; i < count; i++)); do
    out+="─"
  done
  printf '%s' "$out"
}

render_box() {
  local values=("$@")
  local key_label="length"
  local key_value="$LENGTH"
  local width=57

  if [[ "$SAFE_MODE" == "true" ]]; then
    key_label="length"
    key_value="$LENGTH"
  else
    case "$TYPE" in
      memorable|passphrase)
        key_label="words"
        key_value="$MEMO_WORDS"
        ;;
      uuid)
        key_label="format"
        key_value="RFC 4122 v4"
        ;;
      jwt|secret)
        key_label="format"
        key_value="openssl rand -hex 32"
        ;;
      general)
        key_label="format"
        key_value="openssl rand -base64 33"
        ;;
      django)
        key_label="format"
        key_value="Django secret"
        ;;
      token)
        key_label="format"
        key_value="URL-safe base64"
        ;;
    esac
  fi

  local mode_display="$TYPE"
  [[ "$SAFE_MODE" == "true" ]] && mode_display="safe"

  local rows=(
    "mode|$mode_display"
    "$key_label|$key_value"
  )

  if [[ "$SAFE_MODE" != "true" ]]; then
    case "$TYPE" in
      random|memorable|uuid|hex|base32)
        rows+=("case|$CASE")
        ;;
    esac

    if [[ "$TYPE" == "random" ]]; then
      rows+=("allow|$ALLOW")
    elif [[ "$TYPE" =~ ^(memorable|passphrase)$ ]]; then
      rows+=("separator|$MEMO_SEPARATOR" "allow|$ALLOW")
    fi
  fi

  local row label value visible
  for row in "${rows[@]}"; do
    label="${row%%|*}"
    value="${row#*|}"
    visible=$((2 + 10 + 1 + ${#value}))
    (( visible > width )) && width="$visible"
  done

  for value in "${values[@]}"; do
    visible=$((2 + 10 + 1 + ${#value}))
    (( visible > width )) && width="$visible"
  done

  local horizontal
  horizontal="$(repeat_line "$width")"

  box_row() {
    local label="$1"
    local value="$2"
    local value_style="${3:-}"
    local visible=$((2 + 10 + 1 + ${#value}))
    local pad=$((width - visible))

    printf '%b│%b  %b%-10s%b %b%s%b%*s%b│%b\n' \
      "$LINE" "$RESET" \
      "$MUTED" "$label" "$RESET" \
      "$value_style" "$value" "$RESET" \
      "$pad" "" \
      "$LINE" "$RESET"
  }

  printf '%b╭%s╮%b\n' "$LINE" "$horizontal" "$RESET"
  for row in "${rows[@]}"; do
    box_row "${row%%|*}" "${row#*|}"
  done
  printf '%b├%s┤%b\n' "$LINE" "$horizontal" "$RESET"

  local i
  for ((i = 0; i < ${#values[@]}; i++)); do
    if ((${#values[@]} == 1)); then
      box_row "value" "${values[i]}" "$OK$BOLD"
    else
      box_row "#$((i + 1))" "${values[i]}" "$OK$BOLD"
    fi
  done

  printf '%b╰%s╯%b\n' "$LINE" "$horizontal" "$RESET"
}

main() {
  init_app_version
  load_user_config
  normalize_config
  set_config_defaults
  parse_args "$@"

  case "$ACTION" in
    version)
      print_version
      return 0
      ;;
    install)
      install_keygen
      return 0
      ;;
    update)
      update_keygen
      return 0
      ;;
    uninstall)
      fatal "Uninstall is not yet implemented. Remove the binary and shared data manually."
      return 0
      ;;
  esac

  validate_args
  color_init

  local values=()
  local i

  spinner_start "Generating secure material"
  for ((i = 0; i < COUNT; i++)); do
    values+=("$(generate_value)")
  done
  spinner_stop

  if [[ "$PLAIN" == "true" ]]; then
    render_plain "${values[@]}"
  else
    render_box "${values[@]}"
  fi
}

main "$@"
