#!/bin/zsh
set -eu
cd "${0:A:h}"
./build.sh
open "$PWD/build/Window Focus Prototype.app"
