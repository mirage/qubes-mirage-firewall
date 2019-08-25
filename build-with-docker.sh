#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 3cf9358df911c7bc5a28846087c5359e5b550e5d0c6cf342a6e1c90545518ac6"
echo "(hashes should match for released versions)"
