#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
set -eu

if [[ -d /mnt/bats/core && -d /mnt/bats/support && -d /mnt/bats/assert ]]; then
  bats_dir=/mnt/bats
  # The test files load helper libraries from ~/bats, so keep that path available
  # when the shared checkout is mounted into the container at /mnt/bats.
  ln -sfn "$bats_dir" ~/bats
else
  bats_dir=~/bats
  # Keep a clone-based fallback for local runs that do not mount a shared Bats checkout.
  if [[ ! -d "$bats_dir/core" ]]; then
    mkdir -p "$bats_dir"
    git clone --depth=1 --single-branch https://github.com/bats-core/bats-core.git "$bats_dir/core"
  fi
  if [[ ! -d "$bats_dir/support" ]]; then
    git clone --depth=1 --single-branch https://github.com/bats-core/bats-support.git "$bats_dir/support"
  fi
  if [[ ! -d "$bats_dir/assert" ]]; then
    git clone --depth=1 --single-branch https://github.com/bats-core/bats-assert.git "$bats_dir/assert"
  fi
fi

for test_file in "${0%/*}"/*.bats; do
  echo "#####################################"
  echo "# Testing [$test_file]..."
  echo "#####################################"
  echo "-----------------------------------"
  bash "$bats_dir/core/bin/bats" "$test_file"
done
