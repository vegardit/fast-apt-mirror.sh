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
readonly DESC_SET="Configures the given APT mirror in /etc/apt/(sources.list|sources.list.d/system.sources) and runs 'sudo apt-get update'."

# workaround to prevent: "xargs: environment is too large for exec" in some environments
function __xargs() {
  env -i HOME="$HOME" LC_CTYPE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" PATH="$PATH" TERM="${TERM:-}" USER="${USER:-}" xargs "$@"
}

function __sudo() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
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
    curl --max-time 10 -fsS 'http://ip-api.com/json/?fields=status,message,countryCode' \
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

function read_main_mirror_from_deb822_file() {
  # https://repolib.readthedocs.io/en/latest/deb822-format.html#deb822-style-format
  local file=$1
  [[ -f $file ]] || return 0
  local line mirror_uri='' mirror_main=''
  while IFS= read -r line; do
    if [[ -z $line ]]; then mirror_uri=; mirror_main=; continue; fi
    if matches "$line" 'URIs:\s+([^ ]+)'; then mirror_uri=${BASH_REMATCH[1]}; continue; fi
    if matches "$line" 'Components:\s+.*(main)(\s+|$)'; then mirror_main=true; continue; fi
    if [[ -n $mirror_uri && "$mirror_main" == "true" ]]; then
      echo "$mirror_uri"
      return
    fi
  done < "$file"
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

  local current_mirror_cfgfile
  case $dist_name in
    debian) current_mirror_cfgfile='/etc/apt/sources.list.d/debian.sources' ;;
    kali)   current_mirror_cfgfile='/etc/apt/sources.list' ;;
    ubuntu|pop)
        if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then # Ubuntu 24+
          current_mirror_cfgfile='/etc/apt/sources.list.d/ubuntu.sources'
        else
          current_mirror_cfgfile='/etc/apt/sources.list.d/system.sources'
        fi
      ;;
  esac
  local current_mirror_url=$(read_main_mirror_from_deb822_file "$current_mirror_cfgfile")

  if [[ -z $current_mirror_url ]]; then
    if [[ -f /etc/apt/sources.list ]]; then
       if grep -q -E "^deb\s+mirror\+file:/etc/apt/apt-mirrors.txt\s+.*\s+main" /etc/apt/sources.list; then
         current_mirror_cfgfile=/etc/apt/apt-mirrors.txt
         current_mirror_url=$(awk 'NR==1 { print $1 }' "$current_mirror_cfgfile")
       else
         current_mirror_cfgfile=/etc/apt/sources.list
         current_mirror_url=$(grep -E "^deb\s+(https?|ftp)://.*\s+main" "$current_mirror_cfgfile" | awk 'NR==1 { print $2 }')
       fi
    fi
  elif [[ $current_mirror_url == "mirror+file:"* ]]; then
    current_mirror_cfgfile=${current_mirror_url/mirror+file:/}
    current_mirror_url=$(awk 'NR==1 { print $1 }' "${current_mirror_url/mirror+file:/}")
  fi

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
  if ! hash curl &>/dev/null; then
    >&2 echo "INFO: Required command 'curl' not found, trying to install it..."
    __sudo apt-get -o Acquire::http::Timeout=10 update && \
    __sudo apt-get -o Acquire::http::Timeout=10 install -y --no-install-recommends curl ca-certificates || return $RC_MISC_ERROR
  fi

  local start_at=$(date +%s)
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
        echo "     --apply             - Replaces the currently configured APT mirror in /etc/apt/(sources.list|sources.list.d/system.sources) with a fast mirror and runs 'sudo apt-get update'"
        echo "     --country CODE      - The country code to use for selecting mirrors. NOTE: Only applies to Ubuntu based distros. Defaults to http://mirrors.ubuntu.com/mirrors.txt"
        echo "     --exclude-current   - If specified, don't include the currently configured APT mirror in the speed tests."
        echo "     --healthchecks N    - Number of mirrors from the mirrors list to check for availability and up-to-dateness - default is 20"
        echo "     --ignore-sync-state - Don't check up-to-dateness of mirrors as part of healthchecks"
        echo "     --speedtests N      - Maximum number of healthy mirrors to test for speed - default is 5"
        echo " -p, --parallel N        - Number of parallel speed tests. May result in incorrect results because of competing connections but finds a suitable mirror faster."
        echo "     --sample-size KB    - Number of kilobytes to download during the speed from each mirror - default is 200KB"
        echo "     --sample-time SECS  - Maximum number of seconds within the sample download from a mirror must finish - default is 3"
        echo " -v, --verbose           - More output. Specify multiple times to increase verbosity."
        return ;;
    esac
    shift
  done

  local download_parallel=${download_parallel:-1}
  local max_speedtests=${max_speedtests:-5}
  local sample_size_kb=${sample_size_kb:-200}
  local sample_time_secs=${sample_time_secs:-3}
  local max_healthchecks=${max_healthchecks:-20}
  local verbosity=${verbosity:-0}
  local country=${country:-}

  local dist_name=$(get_dist_name)
  case $dist_name in
    debian|kali|ubuntu|pop)
      local dist_version_name=$(get_dist_version_name)
      local dist_arch=$(dpkg --print-architecture)
      if [[ $dist_name =~ ^(ubuntu|pop)$ && -z ${country:-} ]]; then
        country=$(detect_country_code || true)
        if [[ -n $country ]]; then
          >&2 echo "Auto-detected country code: $country"
        fi
      fi
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

  #
  # download mirror lists
  #
  >&2 echo -n "Randomly selecting $max_healthchecks mirrors..."
  local preferred_mirrors=()
  case $dist_name in
    debian)
      # see https://deb.debian.org/
      local reference_mirror=$(curl --max-time 5 -sSL -o /dev/null http://deb.debian.org/debian -w "%{url_effective}" || echo http://deb.debian.org/debian/)
      local mirrors=$(curl --max-time 5 -sSL https://www.debian.org/mirror/list 2>/dev/null | grep -Eo '(https?|ftp)://[^"]+/debian/' || true)
      if [[ -z $mirrors ]]; then
        mirrors=$reference_mirror
      fi
      local last_modified_path="/dists/${dist_version_name}-updates/main/Contents-${dist_arch}.gz"
      ;;
    kali)
      local reference_mirror=https://http.kali.org/
      local mirrors=$(curl -sSfL https://http.kali.org/README?mirrorlist | grep -oP '(?<=README">)(https.*)(?=</a)')
      local last_modified_path="/dists/${dist_version_name}/main/Contents-${dist_arch}.gz"
      ;;
    ubuntu|pop)
      local mirrors
      # Avoid `local mirrors=$(...)` here: that form masks curl failures and makes
      # a broken mirror-list download look like a legitimate one-entry fallback.
      mirrors=$(curl --max-time 5 -sSfL "http://mirrors.ubuntu.com/${country:-mirrors}.txt") || {
        >&2 echo "WARNING: Failed to download Ubuntu mirror list from http://mirrors.ubuntu.com/${country:-mirrors}.txt."
        mirrors=''
      }
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
  # shellcheck disable=SC2016 # Expressions don't expand in single quotes, use double quotes for that
  local healthcheck_results=$(echo "$mirrors" | awk 'NF' | \
    __xargs -i -P "$(echo "$mirrors" | awk 'NF' | wc -l)" bash -c \
       'set -o pipefail
        headers=$(curl --max-time 3 -sSIL "{}'"${last_modified_path}"'" 2>/dev/null || echo "CURL_ERROR")
        http_status=$(printf "%s\n" "$headers" | awk '"'"'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }'"'"')
        last_modified=0
        status="error"
        if [[ "$headers" == "CURL_ERROR" || -z "$http_status" ]]; then
          status="error"
        elif [[ "$http_status" == "404" ]]; then
          status="missing"
        else
          last_mod_line=$(printf "%s\n" "$headers" | grep -i "last-modified" | cut -d" " -f2- | head -n1)
          if [[ -n "$last_mod_line" ]]; then
            last_modified=$(LANG=C date -f- -u +%s <<<"$last_mod_line" 2>/dev/null || echo 0)
            if [[ "$last_modified" != 0 ]]; then
              status="ok"
            else
              status="nolastmod"
            fi
          else
            status="nolastmod"
          fi
        fi
        echo "$last_modified $status {}"
        >&2 echo -n "."'
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
    | __xargs -P $((download_parallel)) -I{} bash -c \
          "printf '%s\t%s\n' \"\$(curl -fL -r 0-$((sample_size_kb*1024)) --max-time $((sample_time_secs)) -sS -w '%{speed_download}' -o /dev/null \"\${1}ls-lR.gz\" 2>/dev/null || echo 0)\" \"\$1\"; >&2 echo -n '.'" _ {} \
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
