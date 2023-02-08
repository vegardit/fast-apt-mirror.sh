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

#docker run -it --rm \
#  -v "$project_dir:/mnt/workspace:ro" \
#  ruby:latest \
#  bash -c "
#    echo '::group::Install pre-reqs' &&
#    apt-get update &&
#    apt-get install bash curl apt-transport-https ca-certificates git -y &&
#    gem install bashcov simplecov-console &&
#    echo '::endgroup::' &&
#    cp -r /mnt/workspace ~/workspace &&
#    cd ~/workspace &&
#    bashcov tests/run-tests.sh
#  "

# running with non-root user as workaround for https://github.com/infertux/bashcov/issues/43
docker run -it --rm \
  -v "$project_dir:/mnt/workspace:ro" \
  ruby:latest \
  bash -c "
    echo '::group::Install pre-reqs' &&
    apt-get update &&
    apt-get install bash curl apt-transport-https ca-certificates git sudo -y &&
    gem install bashcov simplecov-console &&
    echo '::endgroup::' &&
    useradd -m bashcov &&
    echo 'bashcov ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/nopasswd
    cp -r /mnt/workspace /workspace &&
    chown -R bashcov:root /workspace &&
    cd /workspace &&
    runuser -u bashcov bashcov tests/run-tests.sh
  "
