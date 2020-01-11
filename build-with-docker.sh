#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 8a337e61e7d093f7c1f0fa5fe277dace4d606bfa06cfde3f2d61d6bdee6eefbc"
echo "(hashes should match for released versions)"
