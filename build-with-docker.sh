#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/tmp/orb-build qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: d9f7827e2f2c8150ac97a4d348a29f5ee0810a455dbab9233490fff97470f7b8"
echo "(hashes should match for released versions)"
