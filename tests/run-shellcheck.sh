#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
# SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
# SPDX-License-Identifier: Apache-2.0
#

# execute script with bash if loaded with other shell interpreter
if [ -z "${BASH_VERSINFO:-}" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

set -euo pipefail

#
# install latest release of shellcheck
#
pushd "$HOME"
case "$(uname -s)" in
  Linux*)
    if [[ ! -f shellcheck/shellcheck ]]; then
      rm -rf shellcheck
      mkdir shellcheck
      curl -sSfL "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz" | tar -xJ --strip-components=1 -C shellcheck
    fi
    ;;
  Darwin*)
    if [[ ! -f shellcheck/shellcheck ]]; then
      rm -rf shellcheck
      mkdir shellcheck
      curl -sSfL "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.darwin.x86_64.tar.xz" | tar -xJ --strip-components=1 -C shellcheck
    fi
    ;;
  CYGWIN*|MINGW*)
    if [[ ! -f shellcheck/shellcheck.exe ]]; then
      rm -rf shellcheck
      mkdir shellcheck
      curl -sSfL "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.zip" > shellcheck.zip
      echo 'set shell=CreateObject("Shell.Application")' > shellcheck-unzip.vbs
      echo "set FilesInZip=shell.NameSpace(\"$(cygpath -was shellcheck.zip)\").items" >> shellcheck-unzip.vbs
      echo "shell.NameSpace(\"$(cygpath -was shellcheck)\").CopyHere(FilesInZip)" >> shellcheck-unzip.vbs
      cscript //nologo shellcheck-unzip.vbs
      rm shellcheck.zip shellcheck-unzip.vbs
    fi
    ;;
  esac
popd
export PATH="$HOME/shellcheck:$PATH"

shellcheck -V

cd "${0%/*}/.."
find . -name '*.sh' -type f -print0 | while IFS= read -r -d '' file; do
  echo "Checking $file..."
  shellcheck -s bash "$file"
done