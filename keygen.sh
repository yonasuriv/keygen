#!/usr/bin/env bash
# keygen.sh
# Secure password/key generator with polished terminal output.
# Requires: bash, od, tr. Optional: uuidgen, curl or wget.
#
# Wordlist resolution order (memorable mode):
#   1. URL ($KEYSMITH_WORDLIST_URL), cached on first download
#   2. Local file ($KEYSMITH_WORDLIST_PATH, defaults to XDG cache)
#   3. Built-in fallback list
#
# Environment variables:
#   KEYSMITH_WORDLIST_URL      Source URL for the wordlist.
#   KEYSMITH_WORDLIST_PATH     Local file used as cache and fallback.
#                              Default: ${XDG_CACHE_HOME:-$HOME/.cache}/keygen/wordlist.txt
#   KEYSMITH_MIN_WORD_LEN      Minimum word length to accept. Default: 3
#   KEYSMITH_WORDLIST_TIMEOUT  Download timeout in seconds. Default: 5
#
# Delete the cache file to force a fresh download on next run.

set -Eeuo pipefail
IFS=$'\n\t'

if ((BASH_VERSINFO[0] < 4)); then
  printf 'error: %s requires Bash 4 or newer\n' "${0##*/}" >&2
  exit 1
fi

APP_NAME="keygen"
APP_VERSION="0.2.0"

TYPE="random"
LENGTH=16
WORDS=3
CASE_MODE="upper"
ALLOW="letters,numbers"
SEPARATOR="hyphen"
COUNT=1
PLAIN="false"
SPINNER="true"

SPINNER_PID=""

DEFAULT_WORDLIST_URL='https://raw.githubusercontent.com/first20hours/google-10000-english/refs/heads/master/google-10000-english-no-swears.txt'
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

usage() {
  cat <<'EOF'
keygen - secure password/key generator

Usage:
  keygen [options]

Options:
  -t, --type TYPE          random | memorable | uuid | hex | base64 | base64url | base32 | base58 | nanoid
                           Default: random
  -l, --length N           Length for random/key formats. Min 8, max 32. Default: 16
  -w, --words N            Words for memorable mode. Min 1, max 10. Default: 3
  -c, --case MODE          lower | upper | capitalize. Default: upper
  -a, --allow LIST         Comma list: letters,numbers,symbols,hyphen,space,period,comma,underscore,all
                           Default: letters,numbers
  -s, --separator SEP      hyphen | space | period | comma | underscore | none. Used by memorable mode.
                           Default: hyphen
  -n, --count N            Number of values to generate. Default: 1
      --plain              Print generated values only. No color, box, labels, or spinner.
      --no-spinner         Disable spinner.
  -h, --help               Show this help.

Environment (memorable mode):
  KEYSMITH_WORDLIST_URL      Source URL. Default: google-10000-english-no-swears
  KEYSMITH_WORDLIST_PATH     Local cache/fallback. Default: $XDG_CACHE_HOME/keygen/wordlist.txt
  KEYSMITH_MIN_WORD_LEN      Minimum word length. Default: 3
  KEYSMITH_WORDLIST_TIMEOUT  Download timeout (seconds). Default: 5

Examples:
  keygen
  keygen --length 24 --allow letters,numbers,symbols
  keygen --type memorable --words 4 --case capitalize --separator hyphen
  keygen --type uuid --count 3
  keygen --type base64url --length 32 --plain
EOF
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

fatal() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
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
      *) fatal "unsupported allow token: $item" ;;
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
  case "$TYPE" in
    random|memorable|uuid|hex|base64|base64url|base32|base58|nanoid) ;;
    *) fatal "unsupported type: $TYPE" ;;
  esac

  case "$CASE_MODE" in
    lower|upper|capitalize) ;;
    *) fatal "unsupported case mode: $CASE_MODE" ;;
  esac

  case "$SEPARATOR" in
    hyphen|space|period|comma|underscore|none) ;;
    *) fatal "unsupported separator: $SEPARATOR" ;;
  esac

  is_integer "$LENGTH" || fatal "--length must be an integer"
  is_integer "$WORDS" || fatal "--words must be an integer"
  is_integer "$COUNT" || fatal "--count must be an integer"

  (( LENGTH >= 8 && LENGTH <= 32 )) || fatal "--length must be between 8 and 32"
  (( WORDS >= 1 && WORDS <= 10 )) || fatal "--words must be between 1 and 10"
  (( COUNT >= 1 && COUNT <= 100 )) || fatal "--count must be between 1 and 100"

  ALLOW="$(normalize_allow "$ALLOW")"
}

parse_args() {
  while (($#)); do
    case "$1" in
      -t|--type)
        shift || fatal "missing value for --type"
        TYPE="${1,,}"
        ;;
      --type=*) TYPE="${1#*=}"; TYPE="${TYPE,,}" ;;
      -l|--length)
        shift || fatal "missing value for --length"
        LENGTH="$1"
        ;;
      --length=*) LENGTH="${1#*=}" ;;
      -w|--words)
        shift || fatal "missing value for --words"
        WORDS="$1"
        ;;
      --words=*) WORDS="${1#*=}" ;;
      -c|--case)
        shift || fatal "missing value for --case"
        CASE_MODE="${1,,}"
        ;;
      --case=*) CASE_MODE="${1#*=}"; CASE_MODE="${CASE_MODE,,}" ;;
      -a|--allow)
        shift || fatal "missing value for --allow"
        ALLOW="$1"
        ;;
      --allow=*) ALLOW="${1#*=}" ;;
      -s|--separator|--sep)
        shift || fatal "missing value for --separator"
        SEPARATOR="${1,,}"
        ;;
      --separator=*|--sep=*) SEPARATOR="${1#*=}"; SEPARATOR="${SEPARATOR,,}" ;;
      -n|--count)
        shift || fatal "missing value for --count"
        COUNT="$1"
        ;;
      --count=*) COUNT="${1#*=}" ;;
      --plain)
        PLAIN="true"
        SPINNER="false"
        ;;
      --no-spinner)
        SPINNER="false"
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
        fatal "unknown option: $1"
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
  (( max >= 1 )) || fatal "internal random bound out of range: $max"

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

  ((${#alphabet} > 0)) || fatal "generated charset is empty"

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
  local timeout="${KEYSMITH_WORDLIST_TIMEOUT:-5}"
  is_integer "$timeout" || timeout=5

  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "${dir}/.wordlist.XXXXXX" 2>/dev/null)" || return 1

  local ok=0
  if has_command curl; then
    curl -fsSL --max-time "$timeout" "$url" | awk '/^[a-z]+$/ && length($0) >= 4 && length($0) <= 10 { print }'-o "$tmp" 2>/dev/null && ok=1
  elif has_command wget; then
    wget -q --timeout="$timeout" "$url" -O "$tmp" 2>/dev/null && ok=1
  fi

  if (( ok == 1 )) && [[ -s "$tmp" ]]; then
    if mv -f "$tmp" "$dest" 2>/dev/null; then
      return 0
    fi
  fi

  rm -f "$tmp" 2>/dev/null || true
  return 1
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

  local min_len="${KEYSMITH_MIN_WORD_LEN:-3}"
  is_integer "$min_len" || fatal "KEYSMITH_MIN_WORD_LEN must be a positive integer"
  (( min_len >= 1 )) || fatal "KEYSMITH_MIN_WORD_LEN must be >= 1"

  local url="${KEYSMITH_WORDLIST_URL:-$DEFAULT_WORDLIST_URL}"
  local path="${KEYSMITH_WORDLIST_PATH:-$DEFAULT_WORDLIST_PATH}"

  # Step 1: if no local copy yet, try downloading from the URL.
  if [[ ! -s "$path" ]]; then
    fetch_wordlist "$url" "$path" || true
  fi

  # Step 2: read from the local file (just downloaded or pre-existing).
  if [[ -s "$path" ]] && load_words_from_file "$path" "$min_len"; then
    WORDS_LOADED="true"
    return 0
  fi

  # Step 3: built-in fallback.
  if load_words_from_hardcoded "$min_len"; then
    WORDS_LOADED="true"
    return 0
  fi

  fatal "no words available with KEYSMITH_MIN_WORD_LEN=$min_len"
}

# --- Generators ---------------------------------------------------------------

letter_charset() {
  case "$CASE_MODE" in
    lower) printf 'abcdefghijklmnopqrstuvwxyz' ;;
    upper) printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' ;;
    capitalize) printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' ;;
  esac
}

build_random_charset() {
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
  case "$SEPARATOR" in
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
  case "$CASE_MODE" in
    lower) printf '%s' "${word,,}" ;;
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
  for ((i = 0; i < WORDS; i++)); do
    idx="$(pick_index "${#WORDS_LIST[@]}")"
    word="$(format_word "${WORDS_LIST[idx]}")"
    out+="${out:+$sep}$word"
  done

  if contains_allow "numbers"; then
    out+="$sep$(random_token 2 '0123456789')"
  fi

  if contains_allow "symbols"; then
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

  case "$CASE_MODE" in
    lower|capitalize) printf '%s' "${value,,}" ;;
    upper) printf '%s' "${value^^}" ;;
  esac
}

generate_value() {
  case "$TYPE" in
    random)
      random_token "$LENGTH" "$(build_random_charset)"
      ;;
    memorable)
      generate_memorable
      ;;
    uuid)
      generate_uuid
      ;;
    hex)
      case "$CASE_MODE" in
        lower|capitalize) random_token "$LENGTH" '0123456789abcdef' ;;
        upper) random_token "$LENGTH" '0123456789ABCDEF' ;;
      esac
      ;;
    base64)
      random_token "$LENGTH" 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
      ;;
    base64url|nanoid)
      random_token "$LENGTH" 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'
      ;;
    base32)
      case "$CASE_MODE" in
        lower|capitalize) random_token "$LENGTH" 'abcdefghijklmnopqrstuvwxyz234567' ;;
        upper) random_token "$LENGTH" 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567' ;;
      esac
      ;;
    base58)
      random_token "$LENGTH" '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
      ;;
  esac
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

  if [[ "$TYPE" == "memorable" ]]; then
    key_label="words"
    key_value="$WORDS"
  elif [[ "$TYPE" == "uuid" ]]; then
    key_label="format"
    key_value="RFC 4122 v4"
  fi

  local rows=(
    "package|$APP_NAME v$APP_VERSION"
    "mode|$TYPE"
    "$key_label|$key_value"
    "case|$CASE_MODE"
  )

  if [[ "$TYPE" == "random" ]]; then
    rows+=("allow|$ALLOW")
  elif [[ "$TYPE" == "memorable" ]]; then
    rows+=("separator|$SEPARATOR" "allow|$ALLOW")
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
  parse_args "$@"
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
