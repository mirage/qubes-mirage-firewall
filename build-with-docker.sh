#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 4b24bab81f9c1b14bafabd9725428456c4d6eaff0ef5cefd032a59b9f4021693"
