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

for image in "${@:-debian:stable-slim}"; do
  echo "##############################"
  echo "# Testing [$image]..."
  echo "##############################"
  docker run --rm \
    -v "$project_dir/.bats:/mnt/bats:ro" \
    -v "$project_dir:/mnt/workspace:ro" \
    "$image" \
    bash -c "
    cp -r /mnt/workspace ~/workspace &&
    cd ~/workspace &&
    bash tests/run-tests.sh
    "
done
