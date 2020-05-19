#!/bin/sh
set -eu
echo Building Docker image with dependencies..
docker build -t qubes-mirage-firewall .
echo Building Firewall...
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
echo "SHA2 of build:   $(sha256sum qubes_firewall.xen)"
echo "SHA2 last known: 4f4456b5fe7c8ae1ba2f6934cf89749cf6aae9a90cce899cf744c89d311467a3"
echo "(hashes should match for released versions)"
