#!/bin/bash
#
# Remote Pi Server Setup for XDP QoS Testing
# Run this script on the REMOTE Pi (Toby - 192.168.5.195)
#

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║              Remote Pi Server Setup for XDP QoS Testing                 ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Must run as root (sudo)"
    exit 1
fi

echo "Setting up iperf3 servers on multiple ports..."
echo ""

# Kill any existing iperf3 servers
pkill iperf3 2>/dev/null || true
sleep 1

# Start iperf3 servers on ports 5201-5210
for port in {5201..5210}; do
    iperf3 -s -p $port -D
    if [ $? -eq 0 ]; then
        echo "✅ iperf3 server started on port $port"
    else
        echo "❌ Failed to start iperf3 server on port $port"
    fi
done

echo ""
echo "Verifying servers..."
sleep 1
echo ""

# Check which ports are listening
netstat -tlnp 2>/dev/null | grep iperf3 || ss -tlnp | grep iperf3

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                            Setup Complete!                               ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Remote Pi is now ready for XDP QoS testing."
echo "iperf3 servers running on ports: 5201-5210"
echo ""
echo "To make this permanent, add to /etc/rc.local or create a systemd service."
echo ""
