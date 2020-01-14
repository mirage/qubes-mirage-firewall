#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 91c5bf44a85339aaf14e4763a29c2b64537f5bc41cd7dc2571af954ec9dd3cad"
echo "(hashes should match for released versions)"
