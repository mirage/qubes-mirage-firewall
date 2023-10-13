#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/tmp/orb-build:Z qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 8ae5314edf5b863b788c4b873e27bc4b206a2ff7ef1051c4c62ae41584ed3e14"
echo "(hashes should match for released versions)"
