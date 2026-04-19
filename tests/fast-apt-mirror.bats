#!/usr/bin/env bats
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
# BATS Tests (https://github.com/bats-core/bats-core) of fast-apt-mirror.sh script
#

function setup() {
  load ~/bats/support/load
  load ~/bats/assert/load

  readonly RC_OK=0
  readonly RC_INVALID_ARGS=3
  readonly RC_MISC_ERROR=222
  readonly BASH_BIN=$(command -v bash)

  readonly CANDIDATE=$(realpath $BATS_TEST_DIRNAME/../fast-apt-mirror.sh)
  chmod u+x $CANDIDATE
}

function assert_exitcode() {
  expected_rc=$1 && shift
  run $CANDIDATE "$@"
  if [ $status -ne $expected_rc ]; then
    echo "# COMMAND: $CANDIDATE $@" >&3
    echo "# ERROR: $output" >&3
    return 1
  fi
}

function create_fake_bin() {
  local fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$fake_bin"
  for cmd in "$@"; do
    local target
    target=$(command -v "$cmd") || return 1
    cat > "$fake_bin/$cmd" <<EOF
#!$BASH_BIN
exec "$target" "\$@"
EOF
    chmod u+x "$fake_bin/$cmd"
  done
  echo "$fake_bin"
}

function get_dist_name() {
  if compgen -G "/etc/*-release" >/dev/null; then
    cat /etc/*-release | grep "^ID=" | cut -d= -f2
  else
    echo "$OSTYPE"
  fi
}


##############################
# test argument parsing
##############################
@test "Show usage help if executed without args" {
  assert_exitcode $RC_INVALID_ARGS
  assert_regex "$output" '^ERROR: Required command missing'
  assert_regex "$output" 'Usage:'
}

@test "Show usage help if executed with --help" {
  assert_exitcode $RC_OK --help
  assert_regex "$output" '^Usage:'
  refute_regex "$output" 'ERROR:'
}


##############################
# test current
##############################
@test "current: Show current URL" {
  case $(get_dist_name) in
    debian|kali|ubuntu)
      assert_exitcode $RC_OK current
      assert_regex "$output" '(https?|ftp)://'
      refute_regex "$output" 'ERROR:'
      >&3 echo "|-> ${lines[0]}"
      ;;
    *)
      assert_exitcode $RC_MISC_ERROR current
      assert_regex "$output" 'Current mirror: unknown \(Unsupported operating system'
      ;;
  esac
}


##############################
# test find
##############################
@test "find: Show usage help if executed with --help" {
  assert_exitcode $RC_OK find --help
  assert_regex "$output" '^Usage: fast-apt-mirror.sh find'
  refute_regex "$output" 'ERROR:'
  refute_regex "$output" "Required command 'curl' not found"
  refute_regex "$output" 'using the Python fallback'
}

@test "find: Show usage help without touching the backend when curl is absent from PATH" {
  fake_bin=$(create_fake_bin bash basename)
  backend_log="${BATS_TEST_TMPDIR}/backend.log"
  for cmd in curl python3 apt-get; do
    cat > "${fake_bin}/$cmd" <<EOF
#!$BASH_BIN
printf '%s\n' "$cmd \$*" >> "$backend_log"
exit 99
EOF
    chmod u+x "${fake_bin}/$cmd"
  done

  run env PATH="$fake_bin:$PATH" "$CANDIDATE" find --help

  assert_success
  assert_regex "$output" '^Usage: fast-apt-mirror.sh find'
  refute_regex "$output" "Required command 'curl' not found"
  refute_regex "$output" 'using the Python fallback'
  refute_regex "$output" 'trying to install it'
  [ ! -e "$backend_log" ]
}

@test "find: Reject missing option values" {
  assert_exitcode $RC_INVALID_ARGS find --country
  assert_regex "$output" "Option --country: missing value"

  assert_exitcode $RC_INVALID_ARGS find --speedtests
  assert_regex "$output" "Option --speedtests: missing value"
}

@test "find: Find mirror if executed without arguments" {
  assert_exitcode $RC_OK find
  assert_regex "$output" '=> (https?|ftp)://.* determined as fastest mirror'
  refute_regex "$output" 'ERROR:'
}

@test "find: Find mirror if executed with arguments" {
  assert_exitcode $RC_OK find --sample-size 10 --healthchecks 8 --ignore-sync-state --speedtests 2 --country DE
  assert_regex "$output" 'Randomly selecting 8 mirrors...done'
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  if [[ $arch == arm64 || $arch == armhf ]]; then
    # On Ubuntu ARM, depending on country, there currently may be fewer than 2 reachable ubuntu-ports mirrors.
    assert_regex "$output" 'Speed testing [12] of the available'
  else
    assert_regex "$output" 'Speed testing 2 of the available'
  fi
  assert_regex "$output" '(sample download size: 10KB)'
  assert_regex "$output" '=> (https?|ftp)://.* determined as fastest mirror'
  refute_regex "$output" 'ERROR:'
}

@test "find: Find mirror with --ignore-sync-state only" {
  assert_exitcode $RC_OK find --ignore-sync-state --speedtests 2 --healthchecks 8 --country DE
  assert_regex "$output" 'Randomly selecting 8 mirrors...done'
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  if [[ $arch == arm64 || $arch == armhf ]]; then
    # On Ubuntu ARM, depending on country, there currently may be fewer than 2 reachable ubuntu-ports mirrors.
    assert_regex "$output" 'Speed testing [12] of the available'
  else
    assert_regex "$output" 'Speed testing 2 of the available'
  fi
  assert_regex "$output" '=> (https?|ftp)://.* determined as fastest mirror'
  refute_regex "$output" 'Fastest mirror detection returned invalid URL'
}

@test "find: Find and apply mirror" {
  case $(get_dist_name) in
    debian|kali|ubuntu) ;;
    *) skip ;;
  esac
  assert_exitcode $RC_OK find -vvv --apply --exclude-current --country DE
  >&3 echo "|-> ${lines[-2]}"
  assert_regex "$output" 'Creating backup /etc/apt/(sources\.list|apt-mirrors\.txt).*.save'
  assert_regex "$output" "Changing mirror from \[.*\] to \[.*\]"
  assert_regex "$output" "Reading package lists..."
  assert_regex "$output" "Successfully changed mirror from \[.*\] to \[.*\]"
  refute_regex "$output" 'ERROR:'
}

@test "__probe_mirror: Reuses forced python backend without revalidating HTTPS support" {
  fake_bin=$(create_fake_bin bash basename date cat)
  python_log="${BATS_TEST_TMPDIR}/python.log"
  cat > "${fake_bin}/python3" <<EOF
#!$BASH_BIN
printf '%s\n' "\$*" >> "$python_log"
printf '200\tWed, 01 Jan 2025 00:00:00 GMT\n'
EOF
  chmod u+x "${fake_bin}/python3"

  run env PATH="$fake_bin:$PATH" FAST_APT_MIRROR_HTTP_BACKEND=python "$CANDIDATE" __probe_mirror https://mirror.example/ /dists/test/InRelease

  assert_success
  [ "${lines[0]}" = '1735689600 ok https://mirror.example/' ]
  assert_regex "$(cat "$python_log")" '^- probe https://mirror\.example//dists/test/InRelease 3 '
  refute_regex "$(cat "$python_log")" 'deb\.debian\.org'
}

@test "__speed_test_mirror: Uses forced python backend arguments as-is" {
  fake_bin=$(create_fake_bin bash basename cat)
  python_log="${BATS_TEST_TMPDIR}/python.log"
  cat > "${fake_bin}/python3" <<EOF
#!$BASH_BIN
printf '%s\n' "\$*" >> "$python_log"
printf '12345\n'
EOF
  chmod u+x "${fake_bin}/python3"

  run env PATH="$fake_bin:$PATH" FAST_APT_MIRROR_HTTP_BACKEND=python "$CANDIDATE" __speed_test_mirror https://mirror.example/ 2048 7

  assert_success
  [ "${lines[0]}" = $'12345\thttps://mirror.example/' ]
  assert_regex "$(cat "$python_log")" '^- speed https://mirror\.example/ls-lR\.gz 7 2048$'
}


##############################
# test set
##############################
@test "set: Show usage help if executed with --help" {
  assert_exitcode $RC_OK set --help
  assert_regex "$output" '^Usage: fast-apt-mirror.sh set'
  refute_regex "$output" 'ERROR:'
}

@test "set: Show error if executed with no URL" {
  assert_exitcode $RC_INVALID_ARGS set
  assert_regex "$output" '^ERROR: Cannot set APT mirror: MIRROR_URL not specified!'
}

@test "set: Show error if executed with malformed URL" {
  assert_exitcode $RC_INVALID_ARGS set foobar
  assert_output 'ERROR: Cannot set APT mirror: malformed URL or unsupported protocol: foobar'
}

@test "set: Set mirror URL" {
  case $(get_dist_name) in
    debian) mirror_url1=http://ftp.de.debian.org/debian
            mirror_url2=http://ftp.nl.debian.org/debian
            ;;
    kali)   mirror_url1=https://mirror.netcologne.de/kali
            mirror_url2=https://ftp.halifax.rwth-aachen.de/kali
            ;;
    ubuntu)
            arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
            if [[ $arch == arm64 || $arch == armhf ]]; then
              mirror_url1=http://ports.ubuntu.com/ubuntu-ports
              # Avoid flaky third-party mirrors on ARM (mirror sync in progress can break apt-get update).
              # Use ports.ubuntu.com with a trailing-slash variant to still test set changes.
              mirror_url2=http://ports.ubuntu.com/ubuntu-ports/
            else
              mirror_url1=http://archive.ubuntu.com/ubuntu
              mirror_url2=https://ftp.uni-stuttgart.de/ubuntu
            fi
            ;;
    *) skip ;;
  esac

  $CANDIDATE set $mirror_url1

  assert_exitcode $RC_OK set $mirror_url2
  >&3 echo "|-> ${lines[-1]}"
  assert_regex "$output" 'Creating backup /etc/apt/(sources\.list|apt-mirrors\.txt).*.save'
  assert_regex "$output" "Changing mirror from \[.*\] to \[$mirror_url2\]"
  mirror_url2_base=${mirror_url2%/}
  assert_regex "$output" "(Get|Hit):[1-9]+ $mirror_url2_base"
  assert_regex "$output" "Reading package lists..."
  refute_regex "$output" 'ERROR:'
}
