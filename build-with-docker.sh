#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 1b4f66d43d091717347d0e1f68d0c8bd16304310fbb03fccd4ecf2de09dc5f14"
echo "(hashes should match for released versions)"
