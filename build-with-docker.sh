#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 88fdd86993dfbd2e2c4a4d502c350bef091d7831405cf983aebe85f936799f2d"
echo "(hashes should match for released versions)"
