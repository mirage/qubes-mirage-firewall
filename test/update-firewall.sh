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

echo "Setting $TEST_VM allow rule for UDP port 1235 to 10.137.0.5:"
qvm-firewall $TEST_VM add accept 10.137.0.5 udp 1235

echo "Setting $TEST_VM allow rule for UDP port 6668-6670 to 10.137.0.5:"
qvm-firewall $TEST_VM add accept 10.137.0.5 udp 6668-6670

echo "Setting $TEST_VM deny-all rule:"
qvm-firewall $TEST_VM add drop

echo "$TEST_VM firewall rules are now:"
qvm-firewall $TEST_VM list
