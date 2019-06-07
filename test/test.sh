#!/bin/bash
function explain_commands {
echo "1) Set up test qubes:"
echo "Follow the instructions in http://github.com/talex5/qubes-test-mirage to set up the boot-mirage and test-mirage scripts. Make two new qubes in dom0, called mirage-fw-test and fetchmotron, following the instructions for template and qube settings."
}

function explain_service {
echo "2) Set up rule update service:"
echo "In dom0, make a new service:

touch /etc/qubes-rpc/yomimono.updateFirewall

sudo bash
cd /etc/qubes-rpc
cat << EOF >> yomimono.updateFirewall
/usr/local/bin/update-firewall
EOF

Make a policy file for this service, YOUR_DEV_VM being the qube from which you build (e.g. ocamldev):

sudo bash
cd /etc/qubes-rpc/policy
cat << EOF >> yomimono.updateFirewall
YOUR_DEV_VM dom0 allow

make the update-firewall script:

sudo bash
cd /usr/local/bin

Copy the file update-rules.sh to /usr/local/bin.
In YOUR_DEV_VM, you can now change fetchmotron's firewall rules:

$ qrexec-client-vm dom0 yomimono.updateFirewall"
}

function explain_upstream {
echo "Also, start a test service on the upstream NetVM (which is available at 10.137.0.5 from the test unikernel)."
echo "For the UDP reply service:"
echo "Install nmap-ncat:"
echo "sudo dnf install nmap-ncat"
echo "Allow incoming traffic on the appropriate port:"
echo "sudo iptables -I INPUT -i vif+ -p udp --dport $udp_echo_port -j ACCEPT"
echo "Then run the service:"
echo "ncat -e /bin/cat -k -u -l 1235"
}

if ! [ -x "$(command -v boot-mirage)" ]; then
  echo 'Error: boot-mirage is not installed.' >&2
  explain_commands >&2
  exit 1
fi
if ! [ -x "$(command -v test-mirage)" ]; then
  echo 'Error: test-mirage is not installed.' >&2
  explain_commands >&2
  exit 1
fi
qrexec-client-vm dom0 yomimono.updateFirewall
if [ $? -ne 0 ]; then
  echo "Error: can't update firewall rules." >&2
  explain_service >&2
  exit 1
fi
udp_echo_host=10.137.0.5
udp_echo_port=1235
reply=$(echo hi | nc -u $udp_echo_host -q 1 $udp_echo_port)
if [ "$reply" != "hi" ]; then
  # TODO: if the development environment and the test unikernel have different
  # NetVMs serving their respective firewalls, this can be a false negative.
  # provide some nice way for the user to handle this -
  # the non-nice way is commenting out this test ;)
  echo "UDP echo service not reachable at $udp_echo_host:$udp_echo_port" >&2
  explain_upstream >&2
  # exit 1
fi

echo "We're gonna set up a unikernel for the mirage-fw-test qube"
cd ..
mirage configure -t xen -l "*:debug" && \
make depend && \
make
if [ $? -ne 0 ]; then
  echo "Could not build unikernel for mirage-fw-test qube" >&2
  exit 1
fi
cd test

echo "We're gonna set up a unikernel for fetchmotron qube"
mirage configure -t qubes -l "*:debug" && \
make depend && \
make
if [ $? -ne 0 ]; then
  echo "Could not build unikernel for fetchmotron qube" >&2
  exit 1
fi

cd ..
test-mirage qubes_firewall.xen mirage-fw-test &
cd test
test-mirage http_fetch.xen fetchmotron
