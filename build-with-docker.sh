#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/tmp/orb-build qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 3f71a1b672a15d145c7d40405dd75f06a2b148d2cfa106dc136e3da38552de41"
echo "(hashes should match for released versions)"
