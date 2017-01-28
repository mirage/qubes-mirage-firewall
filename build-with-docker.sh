#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum mir-qubes-firewall.xen)"
echo "SHA2 last known: f0c1a06fc4b02b494c81972dc89419af6cffa73b75839c0e8ee3798d77bf69b3"
