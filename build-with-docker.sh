#!/bin/sh
set -eux
docker build -t qubes-mirage-firewall .
docker run --rm -i -v `pwd`:/home/opam/qubes-mirage-firewall qubes-mirage-firewall
