#!/bin/sh
echo "Follow the instructions in http://github.com/talex5/qubes-test-mirage to set up the boot-mirage and test-mirage scripts. Make two new qubes in dom0, called mirage-fw-test and fetchmotron, following the instructions for template and qube settings."

if ! [ -x "$(command -v boot-mirage)" ]; then
  echo 'Error: boot-mirage is not installed.' >&2
  exit 1
fi
if ! [ -x "$(command -v test-mirage)" ]; then
  echo 'Error: test-mirage is not installed.' >&2
  exit 1
fi

echo "We're gonna set up a unikernel for the mirage-fw-test qube"
cd ..
mirage configure -t xen
make depend
make
test-mirage qubes_firewall.xen mirage-fw-test &
cd test

echo "We're gonna set up a unikernel for fetchmotron qube"
mirage configure -t qubes
make depend
make

test-mirage http_fetch.xen fetchmotron 
