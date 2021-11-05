#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 2615ab9a9cbe5b29cf0d2a82aff7e281d06666da9cad5e767dbbc08acb77e295"
echo "(hashes should match for released versions)"
