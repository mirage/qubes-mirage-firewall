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
echo "SHA2 last known: 78a1ee52574b9a4fc5eda265922bcbcface90f7c43ed7a68dc8e201a2ac0a7dc"
echo "(hashes should match for released versions)"
