#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
# https://github.com/vegardit/fast-apt-mirror.sh/
#
# shellcheck disable=SC2155 # (warning): Declare and assign separately to avoid masking return values
# shellcheck disable=SC1091 # (info): Not following: /etc/(lsb|os)-release was not specified as input

###################
# script init
###################
# execute script with bash if loaded with other shell interpreter
if [ -z "${BASH_VERSINFO:-}" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

if (return 0 2>/dev/null); then
  >&2 echo "ERROR: ${BASH_SOURCE[0]} should not be sourced!"
  return
fi

if [[ ${BASH_VERSINFO} -lt 4 ]]; then
  >&2 echo "ERROR: ${BASH_SOURCE[0]} requires Bash 4 or higher!"
  exit 1
fi

set -uo pipefail


readonly RC_INVALID_ARGS=3
readonly RC_MISC_ERROR=222

readonly APT_HTTP_TIMEOUT_SECS=30
readonly HTTP_DEFAULT_TIMEOUT_SECS=10
readonly HTTP_METADATA_TIMEOUT_SECS=5
readonly HTTP_PROBE_TIMEOUT_SECS=3
readonly SPEEDTEST_TIMEOUT_SECS=3
readonly HTTP_BACKEND_ENVVAR=FAST_APT_MIRROR_HTTP_BACKEND


#################################################
# configure logging/error reporting
#################################################
# alternative to set -e, which is ignored within function bodies:
set -o errtrace
# shellcheck disable=SC2154 # rc is referenced but not assigned.
trap 'rc=$?; if [[ $rc -ne '$RC_MISC_ERROR' && $rc -ne '$RC_INVALID_ARGS' ]]; then echo >&2 "$(date +%H:%M:%S) Error - exited with status $rc in $BASH_SOURCE at line $LINENO:"; cat -n "$BASH_SOURCE" | tail -n+$((LINENO - 3)) | head -n7 >&2; exit $rc; fi' ERR

# if TRACE_SCRIPTS=1 or TRACE_SCRIPTS contains a glob pattern that matches $0
# shellcheck disable=SC2053 # Quote the right-hand side of == in [[ ]] to prevent glob matching
if [[ ${TRACE_SCRIPTS:-} == "1" || "$0" == ${TRACE_SCRIPTS:-} ]]; then
  if [[ $- =~ x ]]; then
    # "set -x" was specified already, we only improve the PS4 in this case
    PS4='+\033[90m[$?] $BASH_SOURCE:$LINENO ${FUNCNAME[0]}()\033[0m '
  else
    # "set -x" was not specified, we use a DEBUG trap for better debug output
    set -o functrace

    __trace() {
      printf "\e[90m#[$?] ${BASH_SOURCE[1]}:$1 ${FUNCNAME[1]}() %*s\e[35m$BASH_COMMAND\e[m\n" "$(( 2 * (BASH_SUBSHELL + ${#FUNCNAME[*]} - 2) ))" >&2
    }
    trap '__trace $LINENO' DEBUG
  fi
fi


#################################################
# script body
#################################################
readonly DESC_CURRENT='Prints the currently configured APT mirror.'
readonly DESC_FIND="Finds and prints the URL of a fast APT mirror and optionally applies it using the '$(basename "$0") set' command."
readonly DESC_SET="Configures the given APT mirror in the sources file where it is defined and runs 'sudo apt-get update'."

# workaround to prevent: "xargs: environment is too large for exec" in some environments
function __xargs() {
  # Preserve the selected transport backend across worker subprocesses while
  # still keeping the xargs environment intentionally small.
  env -i HOME="$HOME" LC_CTYPE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" PATH="$PATH" TERM="${TERM:-}" USER="${USER:-}" "${HTTP_BACKEND_ENVVAR}=${!HTTP_BACKEND_ENVVAR:-}" xargs "$@"
}

function __sudo() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

function __has_command() {
  hash "$1" &>/dev/null
}

function __install_curl_if_missing() {
  if __has_command curl; then
    return 0
  fi

  >&2 echo "INFO: Required command 'curl' not found, trying to install it..."
  __sudo apt-get -o Acquire::http::Timeout="$APT_HTTP_TIMEOUT_SECS" update && \
  __sudo apt-get -o Acquire::http::Timeout="$APT_HTTP_TIMEOUT_SECS" install -y --no-install-recommends curl ca-certificates
}

function __http_backend_for_url() {
  local url=${1:-}
  local forced_backend=${!HTTP_BACKEND_ENVVAR:-}
  if [[ $forced_backend == 'curl' || $forced_backend == 'python' || $forced_backend == 'none' ]]; then
    printf '%s\n' "$forced_backend"
  elif __has_command curl; then
    printf 'curl\n'
  elif [[ $url == ftp://* ]]; then
    printf 'none\n'
  elif [[ $url == https://* ]]; then
    if __has_python_https_support "$url"; then
      printf 'python\n'
    else
      printf 'none\n'
    fi
  elif __has_command python3; then
    printf 'python\n'
  else
    printf 'none\n'
  fi
}

function __set_http_backend() {
  printf -v "$HTTP_BACKEND_ENVVAR" '%s' "$1"
  export "${HTTP_BACKEND_ENVVAR?}"
}

function __python_https_probe_url() {
  local dist_name=$1 dist_arch=$2
  case $dist_name in
    debian) printf 'https://www.debian.org/mirror/list\n' ;;
    kali)   printf 'https://http.kali.org/README?mirrorlist\n' ;;
    ubuntu|pop)
      if [[ $dist_arch == "arm64" || $dist_arch == "armhf" ]]; then
        printf 'https://ports.ubuntu.com/ubuntu-ports/\n'
      else
        printf 'https://archive.ubuntu.com/ubuntu/\n'
      fi
      ;;
    *) return 1 ;;
  esac
}

function __python_https_current_mirror_probe_url() {
  local dist_name=$1 dist_version_name=$2 dist_arch=$3 current_mirror=${4:-}
  [[ $current_mirror == https://* ]] || return 1

  # Probe a package metadata path the script will actually use. Some mirrors
  # reject the bare root URL while still serving package content correctly.
  case $dist_name in
    debian) printf '%s/dists/%s-updates/main/Contents-%s.gz\n' "${current_mirror%/}" "$dist_version_name" "$dist_arch" ;;
    kali)   printf '%s/dists/%s/main/Contents-%s.gz\n' "${current_mirror%/}" "$dist_version_name" "$dist_arch" ;;
    ubuntu|pop)
      if [[ $dist_arch == "arm64" || $dist_arch == "armhf" ]]; then
        printf '%s/dists/%s-security/InRelease\n' "${current_mirror%/}" "$dist_version_name"
      else
        printf '%s/dists/%s-security/Contents-%s.gz\n' "${current_mirror%/}" "$dist_version_name" "$dist_arch"
      fi
      ;;
    *) printf '%s/ls-lR.gz\n' "${current_mirror%/}" ;;
  esac
}

function __has_python_https_support() {
  local probe_url=${1:-}
  [[ $probe_url == https://* ]] || return 1

  if [[ ${__PYTHON_HTTPS_SUPPORT_CHECKED_URL:-} != "$probe_url" ]]; then
    __PYTHON_HTTPS_SUPPORT_CHECKED_URL=$probe_url
    # Import checks are not enough on slim images. Only prefer Python when it
    # can complete a real HTTPS request with certificate validation to a URL
    # that this run will actually need.
    if __has_command python3 && __http_python https-check "$probe_url" "$HTTP_METADATA_TIMEOUT_SECS" >/dev/null 2>&1
    then
      __PYTHON_HTTPS_SUPPORT=1
    else
      __PYTHON_HTTPS_SUPPORT=0
    fi
  fi

  [[ ${__PYTHON_HTTPS_SUPPORT:-0} -eq 1 ]]
}

function __http_python() {
  local mode=$1 url=$2 timeout=${3:-$HTTP_DEFAULT_TIMEOUT_SECS} extra=${4:-}
  python3 - "$mode" "$url" "$timeout" "$extra" <<'PY'
import signal
import ssl
import sys
import time
import urllib.error
import urllib.request

mode, url, timeout_arg, extra = sys.argv[1:5]

try:
    timeout = float(timeout_arg)
except ValueError:
    timeout = 10.0

ssl_context = ssl.create_default_context()
base_headers = {
    "Accept-Encoding": "identity",
    "User-Agent": "fast-apt-mirror.sh",
}

def make_request(candidate_url, method="GET", extra_headers=None):
    headers = dict(base_headers)
    if extra_headers:
        headers.update(extra_headers)
    request = urllib.request.Request(candidate_url, headers=headers)
    request.get_method = lambda: method
    return request

def open_request(request):
    return urllib.request.urlopen(request, timeout=timeout, context=ssl_context)

def get_response(candidate_url, extra_headers=None):
    return open_request(make_request(candidate_url, "GET", extra_headers))

def print_probe_result(status, headers):
    print(f"{status}\t{headers.get('Last-Modified', '')}")

def probe(candidate_url):
    try:
        response = open_request(make_request(candidate_url, "HEAD"))
    except urllib.error.HTTPError as exc:
        if exc.code in (405, 501):
            try:
                response = get_response(candidate_url)
            except urllib.error.HTTPError as exc2:
                print_probe_result(exc2.code, exc2.headers)
                return
        else:
            print_probe_result(exc.code, exc.headers)
            return
    try:
        print_probe_result(response.status, response.headers)
    finally:
        response.close()

def stream_get(candidate_url):
    response = get_response(candidate_url)
    try:
        out = sys.stdout.buffer
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            out.write(chunk)
    finally:
        response.close()

def print_effective_url(candidate_url):
    response = get_response(candidate_url)
    try:
        sys.stdout.write(response.geturl())
    finally:
        response.close()

def https_check(candidate_url):
    try:
        with get_response(candidate_url) as response:
            response.read(1)
    except urllib.error.HTTPError:
        pass

def speed_test(candidate_url, sample_end_arg):
    extra_headers = {}
    max_bytes = None
    if sample_end_arg.isdigit():
        extra_headers["Range"] = f"bytes=0-{sample_end_arg}"
        max_bytes = int(sample_end_arg) + 1
    def _raise_timeout(signum, frame):
        raise TimeoutError("speed test exceeded wall-clock timeout")
    try:
        previous_handler = signal.getsignal(signal.SIGALRM)
        signal.signal(signal.SIGALRM, _raise_timeout)
        signal.setitimer(signal.ITIMER_REAL, timeout)
    except (AttributeError, OSError, ValueError):
        previous_handler = None
    started_at = time.monotonic()
    response = get_response(candidate_url, extra_headers)
    bytes_read = 0
    try:
        try:
            while True:
                chunk_size = 65536
                if max_bytes is not None:
                    remaining = max_bytes - bytes_read
                    if remaining <= 0:
                        break
                    chunk_size = min(chunk_size, remaining)
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                bytes_read += len(chunk)
        finally:
            response.close()
    finally:
        if previous_handler is not None:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
    elapsed = time.monotonic() - started_at
    if bytes_read <= 0 or elapsed <= 0:
        print("0")
    else:
        print(int(bytes_read / elapsed))

if mode == "get":
    stream_get(url)
elif mode == "effective-url":
    print_effective_url(url)
elif mode == "probe":
    probe(url)
elif mode == "https-check":
    https_check(url)
elif mode == "speed":
    speed_test(url, extra)
else:
    raise SystemExit("unsupported mode")
PY
}

function __http_get() {
  local url=$1 timeout=${2:-$HTTP_DEFAULT_TIMEOUT_SECS}
  case "$(__http_backend_for_url "$url")" in
    curl) curl --max-time "$timeout" -fsSL "$url" ;;
    python) __http_python get "$url" "$timeout" ;;
    *) return 1 ;;
  esac
}

function __http_effective_url() {
  local url=$1 timeout=${2:-$HTTP_METADATA_TIMEOUT_SECS}
  case "$(__http_backend_for_url "$url")" in
    curl) curl --max-time "$timeout" -sSL -o /dev/null -w "%{url_effective}" "$url" ;;
    python) __http_python effective-url "$url" "$timeout" ;;
    *) return 1 ;;
  esac
}

function __http_probe() {
  local url=$1 timeout=${2:-$HTTP_PROBE_TIMEOUT_SECS}
  local http_status='' last_mod_line=''

  case "$(__http_backend_for_url "$url")" in
    curl)
      local headers
      headers=$(curl --max-time "$timeout" -sSIL "$url" 2>/dev/null) || return 1
      http_status=$(printf '%s\n' "$headers" | awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }')
      last_mod_line=$(printf '%s\n' "$headers" | grep -i "last-modified" | cut -d" " -f2- | head -n1)
      ;;
    python)
      local probe_result
      probe_result=$(__http_python probe "$url" "$timeout" 2>/dev/null) || return 1
      http_status=${probe_result%%$'\t'*}
      if [[ $probe_result == *$'\t'* ]]; then
        last_mod_line=${probe_result#*$'\t'}
      fi
      ;;
    *)
      return 1
      ;;
  esac

  [[ -n $http_status ]] || return 1
  printf '%s\t%s\n' "$http_status" "$last_mod_line"
}

function __http_speed() {
  local url=$1 timeout=${2:-$HTTP_DEFAULT_TIMEOUT_SECS} range_end=${3:-}
  case "$(__http_backend_for_url "$url")" in
    curl) curl -fL -r "0-$range_end" --max-time "$timeout" -sS -w '%{speed_download}' -o /dev/null "$url" ;;
    python) __http_python speed "$url" "$timeout" "$range_end" ;;
    *) return 1 ;;
  esac
}

function __probe_mirror() {
  local mirror_root=$1 last_modified_path=$2
  local probe_result http_status='' last_mod_line='' last_modified=0 status='error'

  probe_result=$(__http_probe "${mirror_root}${last_modified_path}" || true)
  if [[ -n $probe_result ]]; then
    http_status=${probe_result%%$'\t'*}
    if [[ $probe_result == *$'\t'* ]]; then
      last_mod_line=${probe_result#*$'\t'}
    fi
  fi

  if [[ -z $http_status ]]; then
    status='error'
  elif [[ $http_status == "404" ]]; then
    status='missing'
  elif [[ -n $last_mod_line ]]; then
    last_modified=$(LANG=C date -f- -u +%s <<<"$last_mod_line" 2>/dev/null || echo 0)
    if [[ $last_modified != 0 ]]; then
      status='ok'
    else
      status='nolastmod'
    fi
  else
    status='nolastmod'
  fi

  printf '%s %s %s\n' "$last_modified" "$status" "$mirror_root"
  >&2 echo -n "."
}

function __speed_test_mirror() {
  local mirror_root=$1 range_end=$2 timeout=${3:-$SPEEDTEST_TIMEOUT_SECS}
  local speed=0
  speed=$(__http_speed "${mirror_root}ls-lR.gz" "$timeout" "$range_end" 2>/dev/null || echo 0)
  printf '%s\t%s\n' "$speed" "$mirror_root"
  >&2 echo -n "."
}

function assert_option_is_int() {
  if ! [ "$2" -eq "$2" ] 2>/dev/null; then
    echo "Option $1: '$2' is not a valid integer"
    exit $RC_INVALID_ARGS
  fi
}

function assert_option_has_value() {
  if [[ $# -lt 2 || -z ${2:-} || ${2:-} == --* || ${2:-} == -[A-Za-z]* ]]; then
    echo "Option $1: missing value"
    exit $RC_INVALID_ARGS
  fi
}

function get_dist_name() {
  if [ -r /etc/os-release ]; then
    (source /etc/os-release; printf '%s\n' "${ID,,}")
    return
  fi

  if [ -r /etc/lsb-release ]; then # old Ubuntu, Mint…
    (source /etc/lsb-release; printf '%s\n' "${DISTRIB_ID,,}")
    return
  fi

  printf '%s\n' "${OSTYPE:-unknown}"
}

function get_dist_version_name() {
  if [ -r /etc/os-release ]; then
    (source /etc/os-release; printf '%s\n' "${VERSION_CODENAME:-${VERSION_ID:-unknown}}")
    return
  fi

  if [ -r /etc/lsb-release ]; then
    (source /etc/lsb-release; printf '%s\n' "${DISTRIB_CODENAME:-${DISTRIB_RELEASE:-unknown}}")
    return
  fi

  printf 'unknown\n'
}

function detect_country_code() {
  local country_info
  country_info=$(
    __http_get 'http://ip-api.com/json/?fields=status,message,countryCode' \
      | tr -d '\r\n'
  ) || {
    >&2 echo "WARNING: Failed to detect country code automatically."
    return 1
  }

  if [[ ! $country_info =~ \"status\"[[:space:]]*:[[:space:]]*\"success\" ]]; then
    local error_message=$(printf '%s\n' "$country_info" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    >&2 echo "WARNING: Failed to detect country code automatically: ${error_message:-unknown error}."
    return 1
  fi

  local country_code=$(printf '%s\n' "$country_info" | sed -n 's/.*"countryCode"[[:space:]]*:[[:space:]]*"\([A-Z][A-Z]\)".*/\1/p')
  if [[ ! $country_code =~ ^[A-Z][A-Z]$ ]]; then
    >&2 echo "WARNING: Failed to detect country code automatically: invalid response."
    return 1
  fi

  printf '%s\n' "$country_code"
}

function matches() {
  local text=$1 pattern=$2
  [[ $text =~ $pattern ]]
}

function unique() {
  # https://stackoverflow.com/a/11532197/5116073
  awk '!x[$0]++'
}

function max_lines() {
  # head variant that does not risk raising SIGPIPE broken pipe
  awk "NR<=$1"
}

function apt_suite_matches() {
  local suite=$1 target_suite
  shift
  [[ $# -gt 0 ]] || return 0
  for target_suite in "$@"; do
    # APT suites may use pockets such as "noble-updates" next to "noble".
    [[ $suite == "$target_suite" || $suite == "$target_suite-"* ]] && return 0
  done
  return 1
}

function get_dist_suite_names() {
  local dist_name=$1 dist_version_name=$2
  case $dist_name in
    debian)
      # Debian sources often use moving aliases instead of release codenames.
      printf '%s\n' "$dist_version_name" stable testing unstable sid oldstable oldoldstable experimental
      ;;
    kali)
      # kali-last-release images can advertise rolling while their APT source
      # intentionally tracks the last released snapshot.
      printf '%s\n' "$dist_version_name" kali-rolling kali-last-snapshot
      ;;
    *) printf '%s\n' "$dist_version_name" ;;
  esac
}

function read_main_mirror_from_deb822_file() {
  # https://repolib.readthedocs.io/en/latest/deb822-format.html#deb822-style-format
  local file=$1
  shift
  [[ -f $file ]] || return 0
  local line field_name field_value apt_type component suite
  local mirror_uri='' mirror_main='' mirror_suite='' mirror_type='' mirror_enabled='true'
  [[ $# -eq 0 ]] && mirror_suite=true
  # APT-generated .sources files keep these fields single-line; folded values are out of scope here.
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -z $line ]]; then
      # Deb822 stanzas can put Enabled/Types after URI, so decide only at stanza end.
      if [[ -n $mirror_uri && "$mirror_enabled" == "true" && "$mirror_type" == "true" && "$mirror_main" == "true" && "$mirror_suite" == "true" ]]; then
        echo "$mirror_uri"
        return
      fi
      mirror_uri=; mirror_main=; mirror_suite=; mirror_type=; mirror_enabled='true'
      [[ $# -eq 0 ]] && mirror_suite=true
      continue
    fi
    field_name=${line%%:*}
    field_value=${line#*:}
    if [[ ${field_name,,} == "enabled" ]]; then
      read -r field_value _ <<< "$field_value"
      [[ ${field_value,,} == "no" ]] && mirror_enabled='false'
    fi
    if [[ ${field_name,,} == "types" ]]; then
      # Match binary package sources only; deb-src cannot be configured as an APT mirror.
      for apt_type in $field_value; do
        if [[ $apt_type == "deb" ]]; then mirror_type=true; break; fi
      done
    fi
    if [[ ${field_name,,} == "uris" ]]; then read -r mirror_uri _ <<< "$field_value"; fi
    if [[ ${field_name,,} == "suites" ]]; then
      for suite in $field_value; do
        if apt_suite_matches "$suite" "$@"; then mirror_suite=true; break; fi
      done
    fi
    if [[ ${field_name,,} == "components" ]]; then
      for component in $field_value; do
        if [[ $component == "main" ]]; then mirror_main=true; break; fi
      done
    fi
  done < "$file"

  # Handle a final stanza without a trailing blank line.
  if [[ -n $mirror_uri && "$mirror_enabled" == "true" && "$mirror_type" == "true" && "$mirror_main" == "true" && "$mirror_suite" == "true" ]]; then
    echo "$mirror_uri"
  fi
}

function read_main_mirror_from_legacy_file() {
  # https://manpages.debian.org/sources.list.5
  local file=$1
  shift
  [[ -f $file ]] || return 0
  local line uri suite uri_index i
  local -a fields=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    fields=()
    read -r -a fields <<< "$line"
    [[ ${#fields[@]} -gt 0 && ${fields[0]} == "deb" ]] || continue

    uri_index=1
    if [[ ${fields[$uri_index]:-} == "["* ]]; then
      while [[ $uri_index -lt ${#fields[@]} ]]; do
        case ${fields[$uri_index]} in
          *"]") break ;;
        esac
        ((uri_index++))
      done
      ((uri_index++))
    fi

    uri=${fields[$uri_index]:-}
    [[ $uri =~ ^(https?|ftp):// || $uri == mirror+file:* ]] || continue

    suite=${fields[$((uri_index + 1))]:-}
    apt_suite_matches "$suite" "$@" || continue

    # Skip URI and suite, then scan components.
    for ((i = uri_index + 2; i < ${#fields[@]}; i++)); do
      if [[ ${fields[$i]} == "main" ]]; then
        echo "$uri"
        return
      fi
    done
  done < "$file"
}

function read_main_mirror_from_apt_file() {
  local file=$1
  shift
  case $file in
    *.sources) read_main_mirror_from_deb822_file "$file" "$@" ;;
    *.list) read_main_mirror_from_legacy_file "$file" "$@" ;;
  esac
}

# Usage: read_main_mirror_from_apt_files [suite...] -- [cfgfile...]
function read_main_mirror_from_apt_files() {
  local target_suites=()
  while [[ $# -gt 0 && $1 != "--" ]]; do
    target_suites+=("$1")
    shift
  done
  [[ ${1:-} == "--" ]] && shift

  local cfgfile mirror_url mirror_file
  for cfgfile in "$@"; do
    # Literal unmatched globs from the caller are harmless and filtered here.
    [[ -f $cfgfile ]] || continue
    mirror_url=$(read_main_mirror_from_apt_file "$cfgfile" "${target_suites[@]}")

    if [[ $mirror_url == "mirror+file:"* ]]; then
      mirror_file=${mirror_url/mirror+file:/}
      [[ -f $mirror_file ]] || continue
      mirror_url=$(awk 'NR==1 { print $1 }' "$mirror_file")
      cfgfile=$mirror_file
    fi

    if [[ -n $mirror_url ]]; then
      echo "$mirror_url"
      echo "$cfgfile"
      return
    fi
  done
}


function get_current_mirror() {
  ############################
  # returns two lines:
  # 1. mirror URL
  # 2. config file where the mirror URL was defined
  ############################
  >&2 echo -n "Current mirror: "
  local dist_name=$(get_dist_name)
  case $dist_name in
    debian|kali|ubuntu|pop)
       ;;
    *) >&2 echo "unknown (Unsupported operating system: $dist_name)"
       return $RC_MISC_ERROR
       ;;
  esac

  local current_mirror_cfgfile cfgfile
  local dist_version_name=$(get_dist_version_name)
  local dist_suite_names=()
  readarray -t dist_suite_names < <(get_dist_suite_names "$dist_name" "$dist_version_name")
  local current_mirror_cfgfiles=()
  # Prefer distro-owned source files before the broad sources.list.d fallback.
  case $dist_name in
    debian) current_mirror_cfgfiles+=('/etc/apt/sources.list.d/debian.sources') ;;
    kali)   current_mirror_cfgfiles+=('/etc/apt/sources.list') ;;
    ubuntu|pop)
        if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then # Ubuntu 24+
          current_mirror_cfgfiles+=('/etc/apt/sources.list.d/ubuntu.sources')
        else
          current_mirror_cfgfiles+=('/etc/apt/sources.list.d/system.sources')
        fi
      ;;
  esac

  current_mirror_cfgfiles+=('/etc/apt/sources.list')
  for cfgfile in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    current_mirror_cfgfiles+=("$cfgfile")
  done

  local current_mirror_info=()
  readarray -t current_mirror_info < <(read_main_mirror_from_apt_files "${dist_suite_names[@]}" -- "${current_mirror_cfgfiles[@]}")
  local current_mirror_url=${current_mirror_info[0]:-}
  current_mirror_cfgfile=${current_mirror_info[1]:-}

  if [[ -z $current_mirror_url ]]; then
    >&2 echo "unknown"
    return
  fi

  >&2 echo "$current_mirror_url ($current_mirror_cfgfile)"

  # if function is piped or output is caputured write the selected APT mirror to STDOUT
  if [[ ! -t 1 ]]; then
    echo "$current_mirror_url"
    echo "$current_mirror_cfgfile"
  fi
}


shopt -s extglob

function find_fast_mirror() {
  #
  # argument parsing
  #
  while [ $# -gt 0 ]; do
    case $1 in
      -p|--parallel)  assert_option_has_value "$1" "${2:-}"; assert_option_is_int "$1" "$2"; shift; local download_parallel=$1 ;;
      --healthchecks) assert_option_has_value "$1" "${2:-}"; assert_option_is_int "$1" "$2"; shift; local max_healthchecks=$1 ;;
      --speedtests)   assert_option_has_value "$1" "${2:-}"; assert_option_is_int "$1" "$2"; shift; local max_speedtests=$1 ;;
      --sample-size)  assert_option_has_value "$1" "${2:-}"; assert_option_is_int "$1" "$2"; shift; local sample_size_kb=$1 ;;
      --sample-time)  assert_option_has_value "$1" "${2:-}"; assert_option_is_int "$1" "$2"; shift; local sample_time_secs=$1 ;;
      --country)      assert_option_has_value "$1" "${2:-}"; shift; local country=${1^^} ;;
      --apply)             local apply=true ;;
      --exclude-current)   local exclude_current=true ;;
      --ignore-sync-state) local ignore_sync_state=true ;;
      --verbose)           local verbosity=$(( ${verbosity:-0} + 1 )) ;;
      -+(v))               local verbosity=$(( ${verbosity:-0} + ${#1} - 1 )) ;;
      --help)
        echo "Usage: $(basename "$0") find [OPTION]...";
        echo
        echo "$DESC_FIND"
        echo
        echo "Options:"
        echo "     --apply             - Replaces the current APT mirror in the sources file where it is defined and runs 'sudo apt-get update'"
        echo "     --country CODE      - The country code to use for selecting mirrors. NOTE: Only applies to Ubuntu based distros. Defaults to http://mirrors.ubuntu.com/mirrors.txt"
        echo "     --exclude-current   - If specified, don't include the currently configured APT mirror in the speed tests."
        echo "     --healthchecks N    - Number of mirrors from the mirrors list to check for availability and up-to-dateness - default is 20"
        echo "     --ignore-sync-state - Don't check up-to-dateness of mirrors as part of healthchecks"
        echo "     --speedtests N      - Maximum number of healthy mirrors to test for speed - default is 5"
        echo " -p, --parallel N        - Number of parallel speed tests. May result in incorrect results because of competing connections but finds a suitable mirror faster."
        echo "     --sample-size KB    - Number of kilobytes to download during the speed from each mirror - default is 200KB"
        echo "     --sample-time SECS  - Maximum number of seconds within the sample download from a mirror must finish - default is $SPEEDTEST_TIMEOUT_SECS"
        echo " -v, --verbose           - More output. Specify multiple times to increase verbosity."
        return ;;
    esac
    shift
  done

  local download_parallel=${download_parallel:-1}
  local max_speedtests=${max_speedtests:-5}
  local sample_size_kb=${sample_size_kb:-200}
  local sample_time_secs=${sample_time_secs:-$SPEEDTEST_TIMEOUT_SECS}
  local max_healthchecks=${max_healthchecks:-20}
  local verbosity=${verbosity:-0}
  local country=${country:-}
  local start_at=$(date +%s)

  local dist_name=$(get_dist_name)
  case $dist_name in
    debian|kali|ubuntu|pop)
      local dist_version_name=$(get_dist_version_name)
      local dist_arch=$(dpkg --print-architecture)
      ;;
    *) # use dummy values on unsupported Linux distributions so the speed test can still be executed
      local dist_name=debian
      local dist_version_name=stable
      local dist_arch=amd64
      ;;
  esac

  #
  # determine the current APT mirror
  #
  local current_mirror=$(get_current_mirror | max_lines 1 || true)

  # Keep --help side-effect free by selecting or installing the HTTP backend
  # only after argument parsing is complete and real network work is needed.
  if __has_command curl; then
    __set_http_backend 'curl'
  elif [[ $current_mirror == ftp://* && ${exclude_current:-} != "true" ]]; then
    # Python's stdlib fallback cannot probe ftp:// mirrors with the metadata
    # this script needs. Only require curl when that FTP current mirror will
    # actually stay in the comparison set.
    __set_http_backend 'none'
    __install_curl_if_missing || return $RC_MISC_ERROR
    __set_http_backend 'curl'
  else
    local python_vendor_probe_url='' python_current_probe_url=''
    # Prefer a distro-owned HTTPS endpoint for backend selection so recovery
    # from a broken current mirror does not depend on that mirror being healthy.
    python_vendor_probe_url=$(__python_https_probe_url "$dist_name" "$dist_arch" 2>/dev/null || true)
    python_current_probe_url=$(__python_https_current_mirror_probe_url "$dist_name" "$dist_version_name" "$dist_arch" "$current_mirror" 2>/dev/null || true)
    if __has_python_https_support "$python_vendor_probe_url" ||
       { [[ -n $python_current_probe_url && $python_current_probe_url != "$python_vendor_probe_url" ]] &&
         __has_python_https_support "$python_current_probe_url"; }; then
      # Reuse the validated backend in worker subprocesses instead of repeating
      # the external HTTPS capability check for every mirror probe.
      __set_http_backend 'python'
      >&2 echo "INFO: Command 'curl' not found, using the Python fallback."
    else
      __set_http_backend 'none'
      __install_curl_if_missing || return $RC_MISC_ERROR
      __set_http_backend 'curl'
    fi
  fi

  if [[ $dist_name =~ ^(ubuntu|pop)$ && -z ${country:-} ]]; then
    country=$(detect_country_code || true)
    if [[ -n $country ]]; then
      >&2 echo "Auto-detected country code: $country"
    fi
  fi

  #
  # download mirror lists
  #
  >&2 echo -n "Randomly selecting $max_healthchecks mirrors..."
  local preferred_mirrors=()
  case $dist_name in
    debian)
      # see https://deb.debian.org/
      local reference_mirror=$(__http_effective_url http://deb.debian.org/debian || echo http://deb.debian.org/debian/)
      # Keep Debian mirror discovery on HTTPS. Falling back to the reference
      # mirror is preferable to downgrading discovery to clear-text HTTP only.
      local debian_mirror_pattern='(https?|ftp)://[^"]+/debian/'
      # Python's stdlib fallback cannot probe ftp:// mirrors with the HTTP-like
      # metadata this script needs, so keep them out of the curl-less path.
      if [[ ${!HTTP_BACKEND_ENVVAR:-} == 'python' ]]; then
        debian_mirror_pattern='https?://[^"]+/debian/'
      fi
      local mirrors=$(__http_get https://www.debian.org/mirror/list "$HTTP_METADATA_TIMEOUT_SECS" 2>/dev/null | grep -Eo "$debian_mirror_pattern" || true)
      if [[ -z $mirrors ]]; then
        mirrors=$reference_mirror
      fi
      local last_modified_path="/dists/${dist_version_name}-updates/main/Contents-${dist_arch}.gz"
      ;;
    kali)
      local reference_mirror=https://http.kali.org/
      # Keep Kali candidates HTTPS-only so find --apply never downgrades an
      # existing secure mirror configuration during normal discovery.
      local mirrors=$(__http_get https://http.kali.org/README?mirrorlist "$HTTP_METADATA_TIMEOUT_SECS" 2>/dev/null | grep -oP '(?<=README">)(https.*)(?=</a)' || true)
      local last_modified_path="/dists/${dist_version_name}/main/Contents-${dist_arch}.gz"
      ;;
    ubuntu|pop)
      local mirrors
      # Avoid `local mirrors=$(...)` here: that form masks curl failures and makes
      # a broken mirror-list download look like a legitimate one-entry fallback.
      mirrors=$(__http_get "http://mirrors.ubuntu.com/${country:-mirrors}.txt" "$HTTP_METADATA_TIMEOUT_SECS") || {
        >&2 echo "WARNING: Failed to download Ubuntu mirror list from http://mirrors.ubuntu.com/${country:-mirrors}.txt."
        mirrors=''
      }
      # Python's stdlib fallback cannot probe ftp:// mirrors with the HTTP-like
      # metadata this script needs, so keep them out of the curl-less path.
      if [[ ${!HTTP_BACKEND_ENVVAR:-} == 'python' ]]; then
        mirrors=$(echo "$mirrors" | grep -Ev '^ftp://' || true)
      fi
      if [[ $dist_arch == "arm64" || $dist_arch == "armhf" ]]; then
        local reference_mirror=http://ports.ubuntu.com/ubuntu-ports/
        # On Ubuntu ARM, the default sources use the "ubuntu-ports" tree.
        # Transform the "ubuntu" mirror list to "ubuntu-ports" candidates.
        mirrors=$(
          echo "$mirrors" | awk '{
            url=$0
            if (url ~ /\/ubuntu-ports(\/|$)/) { print url; next }
            if (url ~ /\/ubuntu\//) { sub(/\/ubuntu\//, "/ubuntu-ports/", url); print url; next }
            if (url ~ /\/ubuntu\/?$/) { sub(/\/ubuntu\/?$/, "/ubuntu-ports/", url); print url; next }
          }' | awk 'NF'
        )
        mirrors+=$'\n'"$reference_mirror"
        # Some mirrors may not expose per-arch Contents files for all pockets, but InRelease should exist.
        local last_modified_path="/dists/${dist_version_name}-security/InRelease"
      else
        local reference_mirror=http://archive.ubuntu.com/ubuntu/
        local last_modified_path="/dists/${dist_version_name}-security/Contents-${dist_arch}.gz"
      fi
      ;;
  esac
  preferred_mirrors+=("$reference_mirror")
  mirrors=$(echo "$mirrors" | sort -u)

  #
  # ignore or enforce inclusion of current_mirror
  # honor --exclude-current by not prioritizing the current mirror
  #
  if [[ -n $current_mirror && ${exclude_current:-} != "true" ]]; then
    preferred_mirrors+=("$current_mirror")
  fi

  #
  # select preferred plus random mirros
  #
  if [[ ${#preferred_mirrors[@]} -gt 0 ]]; then
    mirrors=$(
      printf "%s\n" "${preferred_mirrors[@]}"
      echo "$mirrors" | shuf
    )
  else
    mirrors=$(echo "$mirrors" | shuf)
  fi

  # Deduplicate mirrors that only differ by trailing slashes, while preserving
  # the first occurrence as-is.
  mirrors=$(echo "$mirrors" | awk '{
    key=$0
    sub(/\/+$/, "", key)
    if (!seen[key]++) print
  }')

  if [[ -n $current_mirror && ${exclude_current:-} == "true" ]]; then
    mirrors=$(echo "$mirrors" | awk -v m="$current_mirror" 'NF && $0 != m')
  fi
  mirrors=$(echo "$mirrors" | awk 'NF' | unique | max_lines "$max_healthchecks" | sort)
  if [[ -z $mirrors ]]; then
    >&2 echo "WARNING: No mirrors left for health checks, falling back to reference mirror."
    mirrors=$reference_mirror
  fi

  >&2 echo "done"

  if [[ $verbosity -gt 1 ]]; then
    for mirror in $mirrors; do >&2 echo " -> $mirror"; done
  fi

  #
  # checking reachability and sync status of mirrors
  #
  >&2 echo -n "Checking health status of $(echo "$mirrors" | awk 'NF' | wc -l) mirrors using '$last_modified_path'"
  # returns a list with content like:
  # 1675322068 ok       http://archive.ubuntu.com/ubuntu/
  # 0          missing  http://ftp.example.com/ubuntu/
  #
  local script_path
  script_path=${BASH_SOURCE[0]}
  if [[ $script_path != */* ]]; then
    script_path=$(command -v "$script_path" 2>/dev/null || echo "$script_path")
  fi
  script_path=$(realpath "$script_path" 2>/dev/null || echo "$script_path")
  local healthcheck_results=$(echo "$mirrors" | awk 'NF' | \
    __xargs -i -P "$(echo "$mirrors" | awk 'NF' | wc -l)" bash "$script_path" __probe_mirror "{}" "$last_modified_path"
  )
  >&2 echo "done"

  #
  # filter out broken and outdated mirrors
  #
  local healthcheck_results_sorted_by_date=$(echo "$healthcheck_results" | sort -t' ' -k1,1rn -k3) # sort by last modified date and URL

  # determine the update time of a healthy mirror by first checking the reference mirror's modification date
  # only consider it if it produced a usable (non-zero) Last-Modified timestamp
  local healthy_mirrors_date
  healthy_mirrors_date=$(echo "$healthcheck_results_sorted_by_date" | awk -v ref="$reference_mirror" '$3 == ref && $2 != "missing" && $2 != "error" && $1 != 0 { print $1; exit }' || true)
  if [[ -z $healthy_mirrors_date ]]; then
    # fall back to last modified date of newest healthy mirror found
    healthy_mirrors_date=$(echo "$healthcheck_results_sorted_by_date" | awk '$2 != "missing" && $2 != "error" && $1 != 0 { print $1; exit }' || true)
    healthy_mirrors_date=${healthy_mirrors_date:-0}
  fi
  if [[ $verbosity -gt 0 ]]; then
    while IFS= read -r mirror; do
      local last_modified=${mirror%% *}
      local rest=${mirror#* }
      local status=${rest%% *}
      local mirror_url=${rest#* }
      case $last_modified in
        "$healthy_mirrors_date")
          >&2 echo " -> UP-TO-DATE (last modified: $(date -d "@$last_modified" +'%Y-%m-%d %H:%M:%S %Z')) $mirror_url"
          ;;
        0)
          case $status in
            missing)   >&2 echo " -> missing     (404 for $last_modified_path)           $mirror_url" ;;
            nolastmod) >&2 echo " -> no Last-Modified header for $last_modified_path     $mirror_url" ;;
            *)         >&2 echo " ->                         n/a                         $mirror_url" ;;
          esac
          ;;
        *)
          >&2 echo " -> outdated   (last modified: $(date -d "@$last_modified" +'%Y-%m-%d %H:%M:%S %Z')) $mirror_url"
          ;;
      esac
    done <<< "$healthcheck_results_sorted_by_date"
  fi
  if [[ ${ignore_sync_state:-} == "true" || $healthy_mirrors_date == 0 ]]; then
    # ignore sync state completely: take all mirrors with a valid probe result,
    # even if last_modified is 0, but drop mirrors where the probe failed or the
    # file is missing (status "error"/"missing").
    local healthy_mirrors=$(
      echo "$healthcheck_results_sorted_by_date" \
      | awk '$2 != "missing" && $2 != "error" { $1=""; $2=""; sub(/^  /, ""); if ($0 != "") print }'
    )
    >&2 echo " => $(echo "$healthy_mirrors" | awk 'NF' | wc -l) mirrors are reachable"
  else
    local healthy_mirrors=$(
      echo "$healthcheck_results_sorted_by_date" \
      | awk -v d="$healthy_mirrors_date" '$1 == d && $2 != "missing" && $2 != "error" { $1=""; $2=""; sub(/^  /, ""); if ($0 != "") print }'
    )
    if [[ -z $healthy_mirrors ]]; then
      # fall back to reachable mirrors if no mirror matches the expected sync timestamp
      healthy_mirrors=$(
        echo "$healthcheck_results_sorted_by_date" \
        | awk '$2 != "missing" && $2 != "error" { $1=""; $2=""; sub(/^  /, ""); if ($0 != "") print }'
      )
      >&2 echo " => $(echo "$healthy_mirrors" | awk 'NF' | wc -l) mirrors are reachable"
    else
      >&2 echo " => $(echo "$healthy_mirrors" | awk 'NF' | wc -l) mirrors are reachable and up-to-date"
    fi
  fi

  #
  # select mirrors for the speed test
  #
  local speedtest_mirrors=''
  if [[ ${#preferred_mirrors[@]} -gt 0 ]]; then
    for preferred_mirror in "${preferred_mirrors[@]}"; do
      local matched_preferred_mirror
      matched_preferred_mirror=$(echo "$healthy_mirrors" | awk -v p="$preferred_mirror" 'BEGIN{sub(/\/+$/, "", p)} {u=$0; key=u; sub(/\/+$/, "", key); if (key==p) {print u; exit}}')
      if [[ -n $matched_preferred_mirror ]]; then speedtest_mirrors+=$matched_preferred_mirror$'\n'; fi
    done
  fi
  speedtest_mirrors=$(echo "$speedtest_mirrors$healthy_mirrors" | awk 'NF' | unique | max_lines "$max_speedtests")

  #
  # test download speed and select fastest mirror
  #
  >&2 echo -n "Speed testing $(echo "$speedtest_mirrors" | awk 'NF' | wc -l) of the available $(echo "$healthy_mirrors" | awk 'NF' | wc -l) mirrors (sample download size: $((sample_size_kb))KB)"
  local mirrors_with_speed
  mirrors_with_speed=$(
    echo "$speedtest_mirrors" \
    | awk 'NF' \
    | __xargs -P $((download_parallel)) -I{} bash "$script_path" __speed_test_mirror "{}" "$((sample_size_kb*1024))" "$((sample_time_secs))" \
    | awk -F'\t' '$1 ~ /^[0-9.]+$/ && $2 ~ /^https?:\/\// { print }' \
    | sort -rg
  ) || return $RC_MISC_ERROR
  >&2 echo "done"
  if [[ -z $mirrors_with_speed ]]; then
    >&2 echo "ERROR: Could not determine any fast mirror matching required criterias."
    return $RC_MISC_ERROR
  fi
  local first_result="${mirrors_with_speed%%$'\n'*}"
  local fastest_mirror=$(echo "$first_result" | awk -F'\t' '{ print $2 }')
  fastest_mirror_speed=$(echo "$first_result" | awk -F'\t' '{ print $1 }' | numfmt --to=iec --suffix=B/s)

  # sanity check: ensure we detected a valid URL
  if [[ ! $fastest_mirror =~ ^https?:// ]]; then
    >&2 echo "ERROR: Fastest mirror detection returned invalid URL: $fastest_mirror"
    >&2 echo "Top candidates:"
    echo "$mirrors_with_speed" | sed -n '1,5p' >&2
    return $RC_MISC_ERROR
  fi
  local speed_test_duration=$(( $(date +%s) - start_at ))
  if [[ $verbosity -gt 0 ]]; then
    echo "$mirrors_with_speed" | tail -n +2 | tac | while IFS= read -r mirror; do
      mirror_speed=$(echo "${mirror%%$'\n'*}" | awk -F'\t' '{ print $1 }' | numfmt --to=iec --suffix=B/s)
      >&2 echo " -> $(echo "$mirror" | awk -F'\t' '{ print $2 }') ($mirror_speed)"
    done
  fi
  >&2 echo " => $fastest_mirror ($fastest_mirror_speed) determined as fastest mirror within $speed_test_duration seconds"

  if [[ ${apply:-} == "true" ]]; then
    set_mirror "$fastest_mirror" >&2 || return $?
  fi

  #
  # if function output is redirected/captured then write the selected mirror to STDOUT
  #
  if [[ ! -t 1 ]]; then
    echo "$fastest_mirror"
  fi
}


function set_mirror() {
  #
  # argument parsing
  #
  if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $(basename "$0") set MIRROR_URL";
    echo
    echo "$DESC_SET"
    echo
    echo "Parameters:"
    echo "  MIRROR_URL - the APT mirror URL to configure."
    return
  fi

  local new_mirror=${1:-}
  if [[ -z $new_mirror ]]; then
    echo "ERROR: Cannot set APT mirror: MIRROR_URL not specified!"
    echo
    set_mirror --help
    return $RC_INVALID_ARGS
  fi
  if ! matches "${new_mirror,,}" '^(https?|ftp)://'; then
    echo "ERROR: Cannot set APT mirror: malformed URL or unsupported protocol: $new_mirror"
    return $RC_INVALID_ARGS
  fi

  dist_name=$(get_dist_name)
  case $dist_name in
    debian|kali|ubuntu|pop) ;;
    *) echo "ERROR: Cannot set APT mirror: unsupported operating system: $dist_name"; return $RC_MISC_ERROR ;;
  esac

  #
  # determine the current mirror
  #
  local current_mirror
  readarray -t current_mirror < <(get_current_mirror || true)
  if [[ ${#current_mirror[@]} -lt 1 ]]; then
    echo "ERROR: Cannot set APT mirror: cannot determine current APT mirror."
    return $RC_MISC_ERROR
  fi

  #
  # reconfigure APT if necessary
  #
  if [[ "${current_mirror[0]}" == "$new_mirror" ]]; then
    echo "Nothing to do, already using: $new_mirror"
  else
    local backup="${current_mirror[1]}.$(date +'%Y%m%d_%H%M%S').save"
    echo "Creating backup $backup"
    __sudo cp "${current_mirror[1]}" "$backup"
    echo "Changing mirror from [${current_mirror[0]}] to [$new_mirror] in (${current_mirror[1]})..."
    __sudo sed -i \
      -e "s|${current_mirror[0]}\$|$new_mirror|g" \
      -e "s|${current_mirror[0]} |$new_mirror |g" \
      -e "s|${current_mirror[0]}\t|$new_mirror\t|g" \
      "${current_mirror[1]}"
    __sudo apt-get -o Acquire::http::Timeout=10 update
    echo "Successfully changed mirror from [${current_mirror[0]}] to [$new_mirror] in (${current_mirror[1]})"
  fi
}


#
# main entry point
#
case ${1:-} in
  __get_dist_suite_names) shift; get_dist_suite_names "$@" ;;
  __read_main_mirror_from_deb822_file) shift; read_main_mirror_from_deb822_file "$@" ;;
  __read_main_mirror_from_legacy_file) shift; read_main_mirror_from_legacy_file "$@" ;;
  __read_main_mirror_from_apt_files) shift; read_main_mirror_from_apt_files "$@" ;;
  __probe_mirror)      shift; __probe_mirror "$@" ;;
  __speed_test_mirror) shift; __speed_test_mirror "$@" ;;
  find)    shift; find_fast_mirror "$@" ;;
  set)     shift; set_mirror "$@" ;;
  current) shift; get_current_mirror "$@" | max_lines 1 ;;
  *) [[ "${1:-}" == "--help" ]] || ( echo "ERROR: Required command missing"; echo )
     echo "Usage: $(basename "$0") COMMAND";
     echo
     echo "Available commands:"
     echo " current - $DESC_CURRENT"
     echo " find    - $DESC_FIND"
     echo " set     - $DESC_SET"
     [[ "${1:-}" == "--help" ]] || exit $RC_INVALID_ARGS
     ;;
esac
