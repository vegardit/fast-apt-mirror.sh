#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#
set -eu

# install bats
if [[ ! -d ~/bats/core ]]; then
  mkdir -p ~/bats
  git clone --depth=1 --single-branch https://github.com/bats-core/bats-core.git ~/bats/core
fi
if [[ ! -d ~/bats/support ]]; then
  git clone --depth=1 --single-branch https://github.com/bats-core/bats-support.git ~/bats/support
fi
if [[ ! -d ~/bats/assert ]]; then
  git clone --depth=1 --single-branch https://github.com/bats-core/bats-assert.git ~/bats/assert
fi

for test_file in "${0%/*}"/*.bats; do
  echo "#####################################"
  echo "# Testing [$test_file]..."
  echo "#####################################"
  echo "-----------------------------------"
  bash ~/bats/core/bin/bats "$test_file"
done
