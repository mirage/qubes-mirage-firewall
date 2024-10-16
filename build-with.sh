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
echo "SHA2 of build:   $(sha256sum ./dist/qubes-firewall.xen)"
echo "SHA2 last known: 2392386d9056b17a648f26b0c5d1c72b93f8a197964c670b2b45e71707727317"
echo "(hashes should match for released versions)"
