#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/tmp/orb-build:Z qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 2c3f68f49afdeaeedd2c03f8ef6d30d6bb4d6306bda0a1ff40f95f440a90034c"
echo "(hashes should match for released versions)"
