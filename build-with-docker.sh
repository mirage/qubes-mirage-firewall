#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 83b96bd453c3c3cfb282076be81055026eca437b621b3ef3f2642af04ad782e2"
echo "(hashes should match for released versions)"
