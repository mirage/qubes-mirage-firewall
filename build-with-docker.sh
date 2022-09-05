#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: f77d17444edf299c64f12a62b6a9e2f598d166caf1bb7582dae4cab46f1dcb6d"
echo "(hashes should match for released versions)"
