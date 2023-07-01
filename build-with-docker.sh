#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/tmp/orb-build qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 1f621d3bde2cf2905b5ad333f7dbde9ef99479251118e1a1da9b4da15957a87d"
echo "(hashes should match for released versions)"
