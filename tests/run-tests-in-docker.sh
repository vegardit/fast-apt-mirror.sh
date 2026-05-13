#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
set -eu

cd "${0%/*}/.."

if [[ $OSTYPE == "cygwin" || $OSTYPE == "msys" ]]; then
  project_dir=$(pwd)
  project_dir=${project_dir/\cygdrive\//}
else
  project_dir=$(pwd)
fi

# Allows CI to run the same distro image with an alternate /etc/apt source shape.
apt_source_layout=${FAST_APT_MIRROR_TEST_APT_SOURCE_LAYOUT:-default}

for image in "${@:-debian:stable-slim}"; do
  echo "##############################"
  echo "# Testing [$image] with APT source layout [$apt_source_layout]..."
  echo "##############################"

  docker run --rm \
    -e "FAST_APT_MIRROR_TEST_APT_SOURCE_LAYOUT=$apt_source_layout" \
    -v "$project_dir/.bats:/mnt/bats:ro" \
    -v "$project_dir:/mnt/workspace:ro" \
    "$image" \
    bash -c '
      set -eu
      cp -r /mnt/workspace ~/workspace
      cd ~/workspace

      case "${FAST_APT_MIRROR_TEST_APT_SOURCE_LAYOUT:-default}" in
        default)
          ;;
        legacy-source-options)
          . /etc/os-release
          if [[ ${ID:-} != "ubuntu" ]]; then
            echo "ERROR: APT source layout [legacy-source-options] requires an Ubuntu image."
            exit 1
          fi

          arch=$(dpkg --print-architecture)
          codename=${VERSION_CODENAME:?}
          # Reproduce CI images that use legacy sources.list entries with
          # bracketed options before the URL instead of ubuntu.sources.
          rm -f /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/system.sources
          cat > /etc/apt/sources.list <<EOF
deb [arch=$arch signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu/ $codename main restricted universe multiverse
deb [arch=$arch signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu/ $codename-updates main restricted universe multiverse
deb [arch=$arch signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://security.ubuntu.com/ubuntu/ $codename-security main restricted universe multiverse
EOF
          ;;
        *)
          echo "ERROR: Unsupported APT source layout [$FAST_APT_MIRROR_TEST_APT_SOURCE_LAYOUT]."
          exit 1
          ;;
      esac

      bash tests/run-tests.sh
    '
done
