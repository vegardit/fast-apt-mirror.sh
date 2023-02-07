#!/usr/bin/env bats
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
# BATS Tests (https://github.com/bats-core/bats-core) of await-http.sh script
#

function setup() {
  load ~/bats/support/load
  load ~/bats/assert/load

  readonly RC_OK=0
  readonly RC_INVALID_ARGS=3
  readonly RC_MISC_ERROR=222

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
    debian|ubuntu)
      assert_exitcode $RC_OK current
      assert_regex "$output" '(https?|ftp)://'
      >&3 echo " -> ${lines[-1]}"
      refute_regex "$output" 'ERROR:'
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
}

@test "find: Find mirror if executed without arguments" {
  assert_exitcode $RC_OK find
  assert_regex "$output" '-> (https?|ftp)://.* determined as fastest mirror'
  refute_regex "$output" 'ERROR:'
}

@test "find: Find mirror if executed with arguments" {
  assert_exitcode $RC_OK find --sample-size 10 --random-mirrors 8 --speed-tests 2
  assert_regex "$output" 'Randomly selecting 8 mirrors...done'
  assert_regex "$output" 'Speed testing 2 of the available'
  assert_regex "$output" '(sample download size: 10KB)'
  assert_regex "$output" '-> (https?|ftp)://.* determined as fastest mirror'
  refute_regex "$output" 'ERROR:'
}

@test "find: Find and apply mirror" {
  case $(get_dist_name) in
    debian|ubuntu) ;;
    *) skip ;;
  esac
  assert_exitcode $RC_OK find --apply --exclude-current
  assert_regex "$output" 'Creating backup /etc/apt/sources.list.bak'
  assert_regex "$output" "Changing mirror from \[.*\] to \[.*\]"
  assert_regex "$output" "Reading package lists..."
  refute_regex "$output" 'ERROR:'
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
  assert_regex '^ERROR: Cannot set APT mirror: MIRROR_URL not specified!'
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
    ubuntu) mirror_url1=http://archive.ubuntu.com/ubuntu
            mirror_url2=http://artfiles.org/ubuntu
            ;;
    *) skip ;;
  esac

  $CANDIDATE set $mirror_url1

  assert_exitcode $RC_OK set $mirror_url2
  assert_regex "$output" 'Creating backup /etc/apt/sources.list.bak'
  assert_regex "$output" "Changing mirror from \[.*\] to \[$mirror_url2\]"
  assert_regex "$output" "Get:[1-9]+ $mirror_url2"
  assert_regex "$output" "Reading package lists..."
  refute_regex "$output" 'ERROR:'
}
