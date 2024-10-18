#!/bin/sh
set -eu

if [[ $# -ne 1 ]] ; then
	echo "Usage: build-with.sh { docker | podman }"
	exit 1
fi

builder=$1
case $builder in
	docker|podman)
	;;
	*)
	echo "You should use either docker or podman for building"
	exit 2
esac

echo Building $builder image with dependencies..
$builder build -t qubes-mirage-firewall .
echo Building Firewall...
$builder run --rm -i -v `pwd`:/tmp/orb-build:Z qubes-mirage-firewall
echo "SHA2 of build:     $(sha256sum ./dist/qubes-firewall.xen | cut -d' ' -f1)"
echo "SHA2 current head: $(cat qubes-firewall.sha256 | cut -d' ' -f1)"
echo "SHA2 last release: $(cat qubes-firewall-release.sha256 | cut -d' ' -f1)"
echo "(hashes should match for head versions)"
