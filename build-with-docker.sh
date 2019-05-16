#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 5ee982b12fb3964e7d9e32ca74ce377ec068b3bbef2b6c86c131f8bb422a3134"
echo "(hashes should match for released versions)"
