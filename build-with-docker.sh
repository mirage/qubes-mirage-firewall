#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 73488b0c54d6c43d662ddf58916b6d472430894f6394c6bdb8a879723abcc06f"
echo "(hashes should match for released versions)"
