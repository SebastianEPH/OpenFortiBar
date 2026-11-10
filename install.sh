#!/bin/zsh
# Compila e instala OpenForti Bar en /Applications y la abre.
set -e
cd ${0:A:h}
./build.sh "$@"
pkill -x OpenFortiBar || true
rm -rf /Applications/OpenFortiBar.app
cp -R build/OpenFortiBar.app /Applications/
open /Applications/OpenFortiBar.app
