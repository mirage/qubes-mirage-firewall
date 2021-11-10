#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 14cc59ec7c3754f83f7422d48176bc0eb8e47d3c3ef116ae09619409b590d3cb"
echo "(hashes should match for released versions)"
