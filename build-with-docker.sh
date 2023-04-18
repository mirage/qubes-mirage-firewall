#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/tmp/orb-build qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 4a3cd3f555f39c47b9675fd08425eee968a6484cb38aa19fb94f4c96844c2ae6"
echo "(hashes should match for released versions)"
