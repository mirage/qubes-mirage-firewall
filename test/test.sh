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
echo "Also, start the test services on the upstream NetVM (which is available at 10.137.0.5 from the test unikernel).
For the UDP and TCP reply services:
Install nmap-ncat:

sudo dnf install nmap-ncat

Allow incoming traffic from local virtual interfaces on the appropriate ports,
then run the services:

sudo iptables -I INPUT -i vif+ -p udp --dport $udp_echo_port -j ACCEPT
sudo iptables -I INPUT -i vif+ -p tcp --dport $tcp_echo_port_lower -j ACCEPT
sudo iptables -I INPUT -i vif+ -p tcp --dport $tcp_echo_port_upper -j ACCEPT
ncat -e /bin/cat -k -u -l $udp_echo_port &
ncat -e /bin/cat -k -l $tcp_echo_port_lower &
ncat -e /bin/cat -k -l $tcp_echo_port_upper &
"
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
echo_host=10.137.0.5
udp_echo_port=1235
tcp_echo_port_lower=6668
tcp_echo_port_upper=6670

# Pretest that checks if our echo servers work.
# NOTE: we assume the dev qube has the same netvm as fetchmotron.
# If yours is different, this test will fail (comment it out)
function pretest {
  protocol=$1
  port=$2
  if [ "$protocol" = "udp" ]; then
    udp_arg="-u"
  else
    udp_arg=""
  fi
  reply=$(echo hi | nc $udp_arg $echo_host -w 1 $port)
  echo "echo hi | nc $udp_arg $echo_host -w 1 $port"
  if [ "$reply" != "hi" ]; then
    echo "echo services not reachable at $protocol $echo_host:$port" >&2
    explain_upstream >&2
    exit 1
  fi
}

pretest "udp" "$udp_echo_port"
pretest "tcp" "$tcp_echo_port_lower"
pretest "tcp" "$tcp_echo_port_upper"

echo "We're gonna set up a unikernel for the mirage-fw-test qube"
cd ..
make clean && \
mirage configure -t xen -l "net-xen xenstore:error,rules:debug" && \
make depend && \
make
if [ $? -ne 0 ]; then
  echo "Could not build unikernel for mirage-fw-test qube" >&2
  exit 1
fi
cd test

echo "We're gonna set up a unikernel for fetchmotron qube"
make clean && \
mirage configure -t qubes -l "net-xen frontend:error,firewall test:debug" && \
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
