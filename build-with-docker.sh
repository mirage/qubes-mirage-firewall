#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 5b9b16e8d5611e59d90d750ed5cee520743e937d3c9ddd6983c9ca110d11053d"
echo "(hashes should match for released versions)"
