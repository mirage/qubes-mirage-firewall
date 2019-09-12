#!/bin/sh

# this script sets a deny-all rule for a particular VM, set here as TEST_VM.
# it is intended to be used as part of a test suite which analyzes whether
# an upstream FirewallVM correctly applies rule changes when they occur.

# Copy this script into dom0 at /usr/local/bin/update-firewall.sh so it can be
# remotely triggered by your development VM as part of the firewall testing
# script.

TEST_VM=fetchmotron

echo "Current $TEST_VM firewall rules:"
qvm-firewall $TEST_VM list

echo "Removing $TEST_VM rules..."
rc=0
while [ "$rc" = "0" ]; do
    qvm-firewall $TEST_VM del --rule-no 0
    rc=$?
done

echo "$TEST_VM firewall rules are now:"
qvm-firewall $TEST_VM list

echo "Setting $TEST_VM specialtarget=dns rule:"
qvm-firewall $TEST_VM add accept specialtarget=dns

echo "Setting $TEST_VM allow rule for UDP port 1235 to 10.137.0.5:"
qvm-firewall $TEST_VM add accept 10.137.0.5 udp 1235

echo "Setting $TEST_VM allow rule for UDP port 1338 to 10.137.0.5:"
qvm-firewall $TEST_VM add accept 10.137.0.5 udp 1338

echo "Setting $TEST_VM allow rule for TCP port 6668-6670 to 10.137.0.5:"
qvm-firewall $TEST_VM add accept 10.137.0.5 tcp 6668-6670

echo "Setting $TEST_VM allow rule for ICMP type 8 (ping) to 10.137.0.5:"
qvm-firewall $TEST_VM add accept 10.137.0.5 icmp icmptype=8

echo "Setting $TEST_VM allow rule for bogus.linse.me:"
qvm-firewall $TEST_VM add accept dsthost=bogus.linse.me

echo "Setting deny rule to host google.com:"
qvm-firewall $TEST_VM add drop dsthost=google.com

echo "Setting allow-all on port 443 rule:"
qvm-firewall $TEST_VM add accept proto=tcp dstports=443-443

echo "Setting $TEST_VM deny-all rule:"
qvm-firewall $TEST_VM add drop

echo "$TEST_VM firewall rules are now:"
qvm-firewall $TEST_VM list
