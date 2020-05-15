#!/bin/bash
function explain_commands {
    echo "1) Set up test qubes:"
echo "First, set up the test-mirage script from https://github.com/talex5/qubes-test-mirage.git"

echo "Then, use `qubes-manager` to create two new AppVMs called `mirage-fw-test` and `fetchmotron`.
You can make it standalone or not and use any template (it doesn't matter
because unikernels already contain all their code and don't need to use a disk
to boot)."

echo "Next, still in dom0, create a new `mirage-fw-test` and `fetchmotron` kernels, with an empty `modules.img` and `vmlinuz` and a compressed empty file for the initramfs, and then set that as the kernel for the new VMs:

    mkdir /var/lib/qubes/vm-kernels/mirage-fw-test
    cd /var/lib/qubes/vm-kernels/mirage-fw-test
    touch modules.img vmlinuz test-mirage-ok
    cat /dev/null | gzip > initramfs
    qvm-prefs -s mirage-fw-test kernel mirage-fw-test

    mkdir /var/lib/qubes/vm-kernels/fetchmotron
    cd /var/lib/qubes/vm-kernels/fetchmotron
    touch modules.img vmlinuz test-mirage-ok
    cat /dev/null | gzip > initramfs
    qvm-prefs -s fetchmotron kernel fetchmotron
"
}

function explain_service {
echo "2) Set up rule update service:"
echo "In dom0, make a new service:

sudo bash
echo /usr/local/bin/update-firewall > /etc/qubes-rpc/yomimono.updateFirewall

Make a policy file for this service, YOUR_DEV_VM being the qube from which you build (e.g. ocamldev):

cd /etc/qubes-rpc/policy
cat << EOF >> yomimono.updateFirewall
YOUR_DEV_VM dom0 allow

copy the update-firewall script:

cd /usr/local/bin
qvm-run -p YOUR_DEV_VM 'cat /path/to/qubes-mirage-firewall/test/update-firewall.sh' > update-firewall
chmod +x update-firewall

Now, back to YOUR_DEV_VM. Let's test to change fetchmotron's firewall rules:

qrexec-client-vm dom0 yomimono.updateFirewall"
}

function explain_upstream {
echo "Also, start the test services on the upstream NetVM (which is available at 10.137.0.5 from the test unikernel).
For the UDP and TCP reply services:
Install nmap-ncat (to persist this package, install it in your sys-net template VM):

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
  if [ "$reply" != "hi" ]; then
    echo "echo hi | nc $udp_arg $echo_host -w 1 $port"
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
#mirage configure -t xen -l "application:error,net-xen xenstore:error,firewall:debug,frameQ:debug,uplink:debug,rules:debug,udp:debug,ipv4:debug,fw-resolver:debug" && \
mirage configure -t xen -l "net-xen xenstore:error,application:warning,qubes.db:warning" && \
#mirage configure -t xen -l "*:debug" && \
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
#mirage configure -t qubes -l "*:error" && \
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
