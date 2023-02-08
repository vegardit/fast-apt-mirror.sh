#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
# shellcheck disable=SC2155 # (warning): Declare and assign separately to avoid masking return values

###################
# script init
###################
# execute script with bash if loaded with other shell interpreter
if [ -z "${BASH_VERSINFO:-}" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

if (return 0 2>/dev/null); then
  >&2 echo "WARNING: This file should not be sourced!"
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
trap 'rc=$?; if [[ $rc -ne '$RC_MISC_ERROR' && $rc -ne '$RC_INVALID_ARGS' ]]; then echo >&2 "$(date +%H:%M:%S) Error - exited with status $rc in $BASH_SOURCE at line $LINENO:"; cat -n $BASH_SOURCE | tail -n+$((LINENO - 3)) | head -n7; exit $rc; fi' ERR

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
readonly DESC_SET="Configures the given APT mirror in /etc/apt/sources.list and runs 'sudo apt-get update'."

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

function get_dist_name() {
  if compgen -G "/etc/*-release" >/dev/null; then
    cat /etc/*-release | grep "^ID=" | cut -d= -f2
  else
    echo "$OSTYPE"
  fi
}

function get_dist_version_name() {
  if compgen -G "/etc/*-release" >/dev/null; then
    cat /etc/*-release | grep VERSION_CODENAME | cut -d= -f2
  else
    echo "unkown"
  fi
}

function get_current_mirror() {
  >&2 echo -n "Current mirror: "
  dist_name=$(get_dist_name)
  case $dist_name in
    debian|ubuntu)
       ;;
    *) >&2 echo "unknown (Unsupported operating system: $dist_name)"
       return $RC_MISC_ERROR
       ;;
  esac

  local current_mirror=
  if [[ -f /etc/apt/sources.list ]]; then
    current_mirror=$(grep -E "^deb\s+(https?|ftp)://.*\s+main" /etc/apt/sources.list | head -1 | awk '{ print $2 }')
  fi

  if [[ -z $current_mirror ]]; then
    >&2 echo "unknown"
    return
  fi

  >&2 echo "$current_mirror"

  # if function is piped or output is caputured write the selected APT mirror to STDOUT
  if [[ -p /dev/stdout ]]; then
    echo "$current_mirror"
  fi
}


shopt -s extglob

function find_fast_mirror() {
  if ! hash curl &>/dev/null; then
    >&2 echo "ERROR: Required command 'curl' not found! Try: apt install curl"
    return $RC_MISC_ERROR
  fi

  local start_at=$(date +%s)
  #
  # argument parsing
  #
  while [ $# -gt 0 ]; do
    case $1 in
      --apply)                    local apply=true ;;
      --exclude-current)          local exclude_current=true ;;
      -p|--parallel)       shift; local download_parallel=$1 ;;
      -m|--random-mirrors) shift; local max_random_mirrors=$1 ;;
      -t|--speed-tests)    shift; local max_speedtests=$1 ;;
      --sample-size)       shift; local sample_size_kb=$1 ;;
      --sample-time)       shift; local sample_time_secs=$1 ;;
      --verbose)                  local verbosity=$(( ${verbosity:-0} + 1 )) ;;
      -+(v))                      local verbosity=$(( ${verbosity:-0} + ${#1} - 1 )) ;;
      --help)
        echo "Usage: $(basename "$0") find [OPTION]...";
        echo
        echo "$DESC_FIND"
        echo
        echo "Options:"
        echo "     --apply                - Replaces the current APT mirror in /etc/apt/sources.list with a fast mirror and runs 'sudo apt-get update'"
        echo "     --exclude-current      - If specified, don't include the current APT mirror in the speed tests."
        echo " -p, --parallel COUNT       - Number of parallel speed tests. May result in incorrect results because of competing connections but finds a suitable mirror faster."
        echo " -m, --random-mirrors COUNT - Number of random mirrors to select from the Ubuntu/Debian mirror list site to test for availability and up-to-dateness - default is 20"
        echo " -t  --speed-tests COUNT    - Maximum number of mirrors to test for speed (out of the mirrors found to be available and up-to-date) - default is 5"
        echo "     --sample-size KB       - Number of kilobytes to download during the speed from each mirror - default is 200KB"
        echo "     --sample-time SECS     - Maximum number of seconds within the sample download from a mirror must finish - default is 3"
        echo " -v, --verbose              - More output. Specify multiple times to increase verbosity."
        return ;;
    esac
    shift
  done

  local download_parallel=${download_parallel:-1}
  local max_speedtests=${max_speedtests:-5}
  local sample_size_kb=${sample_size_kb:-200}
  local sample_time_secs=${sample_time_secs:-3}
  local max_random_mirrors=${max_random_mirrors:-20}
  local verbosity=${verbosity:-0}

  dist_name=$(get_dist_name)
  case $dist_name in
    debian|ubuntu)
       local dist_version_name=$(get_dist_version_name)
       local dist_arch=$(dpkg --print-architecture)
       ;;
    *) # use dummy values on unsupported Linux distributions so the speed test can still be executed
       local dist_name=ubuntu
       local dist_version_name=bionic
       #local dist_name=debian
       #local dist_version_name=bullseye
       local dist_arch=amd64
       ;;
  esac

  #
  # determine the current APT mirror
  #
  local current_mirror=$(get_current_mirror || true)

  #
  # select mirror candidates
  #
  >&2 echo -n "Randomly selecting $((max_random_mirrors)) mirrors..."
  case $dist_name in
    debian)
      local mirrors=$(curl -s https://www.debian.org/mirror/list | grep -Eo '(https?|ftp)://[^"]+/debian/' | sort -u)
      local last_modified_path="/dists/${dist_version_name}-updates/main/Contents-${dist_arch}.gz"
      ;;
    ubuntu)
      local mirrors=$(curl -s http://mirrors.ubuntu.com/mirrors.txt)
      local last_modified_path="/dists/${dist_version_name}-security/Contents-${dist_arch}.gz"
      ;;
  esac

  if [[ -n $current_mirror ]]; then
    if [[ ${exclude_current:-} == "true" ]]; then
      mirrors=$(echo "$mirrors" | grep -v "$current_mirror" | shuf -n $((max_random_mirrors)))
    elif [[ $mirrors != *"current_mirror"* ]]; then
      mirrors="$current_mirror"$'\n'"$(echo "$mirrors" | shuf -n $((max_random_mirrors)))"
    fi
  else
    mirrors=$(echo "$mirrors" | shuf -n $((max_random_mirrors)))
  fi

  >&2 echo "done"
  if [[ ${verbosity:-} -gt 1 ]]; then
    for mirror in $mirrors; do  >&2 echo " -> $mirror"; done
  fi

  #
  # filter out inaccessible or outdated mirrors
  #
  >&2 echo -n "Checking sync status of $(echo "$mirrors" | wc -l) mirrors"
  # returns a list with content like:
  # 1675322068 http://archive.ubuntu.com/ubuntu/
  # 1675322068 http://ftp.halifax.rwth-aachen.de/ubuntu/
  #
  # shellcheck disable=SC2016 # Expressions don't expand in single quotes, use double quotes for that
  local mirrors_with_updatetimes=$(echo "$mirrors" | \
    __xargs -i -P "$(echo "$mirrors" | wc -l)" bash -c \
       'last_modified=$(set -o pipefail; curl --max-time 3 -sSf --head "{}'"${last_modified_path}"'" &>/dev/null | grep "Last-Modified" | cut -d" " -f2- | LANG=C date -f- -u +%s || echo 0); echo "$last_modified {}"; >&2 echo -n "."'
  )
  >&2 echo "done"
  newest_mirrors=$(echo "$mirrors_with_updatetimes" | sort -rg | awk '{ if (NR==1) TS=$1; if ($1==TS) print $2; }')
  if [[ ${verbosity:-} -gt 1 ]]; then
    for mirror in $mirrors; do  >&2 echo " -> $mirror UP-TO-DATE"; done
  fi
  >&2 echo " -> $(echo "$newest_mirrors" | wc -l) mirrors are reachable and up-to-date"

  #
  # test download speed and select fastest mirror
  #
  >&2 echo -n "Speed testing $max_speedtests of the available $(echo "$newest_mirrors" | wc -l) mirrors (sample download size: $((sample_size_kb))KB)"
  mirrors_with_speed=$(
    echo "$newest_mirrors" \
    | head -n $((max_speedtests)) \
    | __xargs -P $((download_parallel)) -i bash -c \
             "curl -r 0-$((sample_size_kb*1024)) --max-time $((sample_time_secs)) -sSf -w '%{speed_download} {}\n' -o /dev/null {}ls-lR.gz 2>/dev/null || true; >&2 echo -n '.'" \
    | sort -rg
  )
  >&2 echo "done"
  if [[ -z $mirrors_with_speed ]]; then
    >&2 echo "ERROR: Could not determine any fast mirror matching required criterias."
    return $RC_MISC_ERROR
  fi
  fastest_mirror=$(echo "$mirrors_with_speed" | head -1 | cut -d" " -f2)
  fastest_mirror_speed=$(echo "$mirrors_with_speed" | head -1 | cut -d" " -f1 | numfmt --to=iec --suffix=B/s)
  >&2 echo " -> $fastest_mirror ($fastest_mirror_speed) determined as fastest mirror within $(( $(date +%s) - start_at )) seconds"
  if [[ ${verbosity:-} -gt 0 ]]; then
    echo "$mirrors_with_speed" | tail -n +2 | while IFS= read -r mirror; do
      mirror_speed=$(echo "$mirror" | head -1 | cut -d" " -f1 | numfmt --to=iec --suffix=B/s)
      >&2 echo " -> $(echo "$mirror" | cut -d" " -f2) ($mirror_speed)"
    done
  fi
  if [[ ${apply:-} == "true" ]]; then
    set_mirror "$fastest_mirror" >&2 || return $?
  fi

  #
  # if function output is redirected/captured then write the selected mirror to STDOUT
  #
  if [[ -p /dev/stdout ]]; then
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
  if [[ ! ${new_mirror,,} =~ ^(https?|ftp):// ]]; then
    echo "ERROR: Cannot set APT mirror: malformed URL or unsupported protocol: $new_mirror"
    return $RC_INVALID_ARGS
  fi

  dist_name=$(get_dist_name)
  case $dist_name in
    debian|ubuntu) ;;
    *) echo "ERROR: Cannot set APT mirror: unsupported operating system: $dist_name"; return $RC_MISC_ERROR ;;
  esac

  #
  # determine the current mirror
  #
  local current_mirror=$(get_current_mirror || true)
  if [[ -z $current_mirror ]]; then
    echo "ERROR: Cannot set APT mirror: cannot determine current APT mirror."
    return $RC_MISC_ERROR
  fi

  #
  # reconfigure APT if necessary
  #
  if [[ "$current_mirror" == "$new_mirror" ]]; then
    echo "Nothing to do, already using: $new_mirror"
  else
    local backup=/etc/apt/sources.list.bak.$(date +'%Y%m%d_%H%M%S')
    echo "Creating backup $backup"
    __sudo cp /etc/apt/sources.list "$backup"
    echo "Changing mirror from [$current_mirror] to [$new_mirror]..."
    __sudo sed -i "s|$current_mirror |$new_mirror |g" /etc/apt/sources.list
    __sudo apt-get update
  fi
}

#
# main enty point
#
case ${1:-} in
  find)    shift; find_fast_mirror "$@" ;;
  set)     shift; set_mirror "$@" ;;
  current) shift; get_current_mirror "$@" ;;
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