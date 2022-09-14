#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: d0ec19d5b392509955edccf100852bcc9c0e05bf31f1ec25c9cc9c9e74c3b7bf"
echo "(hashes should match for released versions)"
