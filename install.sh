#!/bin/zsh
# Compila e instala TunnelBar en /Applications y la abre.
set -e
cd ${0:A:h}
./build.sh "$@"
pkill -x TunnelBar || true
rm -rf /Applications/TunnelBar.app
cp -R build/TunnelBar.app /Applications/
open /Applications/TunnelBar.app
