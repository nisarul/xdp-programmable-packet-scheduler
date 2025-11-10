#!/bin/bash
#
# Quick Setup Verification Script
# Checks if both Pis are ready for benchmarking
#

# Add system paths for tc, ethtool, etc.
export PATH=$PATH:/sbin:/usr/sbin

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REMOTE_PI="192.168.5.195"
INTERFACE="eth0"

echo ""
echo "================================================================"
echo "         XDP QoS Demo - Setup Verification"
echo "================================================================"
echo ""

# Check 1: Network connectivity
echo -n "Checking network connectivity to Pi2... "
if ping -c 2 -W 2 $REMOTE_PI &>/dev/null; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "  Cannot reach $REMOTE_PI - check Ethernet cable and IP configuration"
    exit 1
fi

# Check 2: Interface status
echo -n "Checking eth0 interface... "
if ip link show $INTERFACE &>/dev/null; then
    link_status=$(ip link show $INTERFACE | grep "state UP")
    if [ -n "$link_status" ]; then
        echo -e "${GREEN}✓ OK (UP)${NC}"
    else
        echo -e "${YELLOW}⚠ WARNING (DOWN)${NC}"
        echo "  Interface is down, bringing it up..."
        sudo ip link set $INTERFACE up
    fi
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "  Interface $INTERFACE not found"
    exit 1
fi

# Check 3: XDP programs built
echo -n "Checking XDP programs... "
if [ -f "./build/xdp_scheduler.o" ] && [ -f "./build/tc_scheduler.o" ]; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "  XDP programs not built. Run: make"
    exit 1
fi

# Check 4: Control plane built
echo -n "Checking control plane... "
if [ -f "./bin/control_plane" ] && [ -x "./bin/control_plane" ]; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "  Control plane not built. Run: make"
    exit 1
fi

# Check 5: Required tools
echo -n "Checking required tools... "
missing_tools=()
missing_packages=()

# Map tools to their package names
declare -A tool_packages
tool_packages[iperf3]="iperf3"
tool_packages[ping]="iputils-ping"
tool_packages[tc]="iproute2"
tool_packages[ethtool]="ethtool"

for tool in iperf3 ping tc ethtool; do
    if ! command -v $tool &>/dev/null; then
        missing_tools+=($tool)
        missing_packages+=(${tool_packages[$tool]})
    fi
done

if [ ${#missing_tools[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${YELLOW}⚠ WARNING${NC}"
    echo "  Missing tools: ${missing_tools[*]}"
    # Remove duplicates and show correct package names
    unique_packages=($(echo "${missing_packages[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    echo "  Install with: sudo apt install ${unique_packages[*]}"
fi

# Check 6: iperf3 server on remote Pi
echo -n "Checking iperf3 server on Pi2... "
# Try a quick iperf3 connection test (more reliable than nc)
if timeout 3 iperf3 -c $REMOTE_PI -t 1 &>/dev/null; then
    echo -e "${GREEN}✓ OK${NC}"
elif command -v nc &>/dev/null && nc -z -w 2 $REMOTE_PI 5201 &>/dev/null; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${YELLOW}⚠ WARNING${NC}"
    echo "  Cannot connect to iperf3 server on $REMOTE_PI:5201"
    echo "  On Pi2, run: iperf3 -s -D"
    echo "  Or install as systemd service (see docs/demo-setup-guide.md)"
fi

# Check 7: BPF filesystem
echo -n "Checking BPF filesystem... "
if mount | grep -q bpf; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${YELLOW}⚠ WARNING${NC}"
    echo "  BPF filesystem not mounted"
    echo "  Mounting now..."
    sudo mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
fi

# Check 8: No existing XDP program
echo -n "Checking for existing XDP programs... "
if ip link show $INTERFACE | grep -q "xdp"; then
    echo -e "${YELLOW}⚠ WARNING${NC}"
    echo "  XDP program already attached"
    echo "  Remove with: sudo ip link set dev $INTERFACE xdp off"
else
    echo -e "${GREEN}✓ OK (None)${NC}"
fi

# Check 9: No existing TC qdiscs
echo -n "Checking for existing TC qdiscs... "
if tc qdisc show dev $INTERFACE | grep -q -v "noqueue\|pfifo_fast"; then
    echo -e "${YELLOW}⚠ WARNING${NC}"
    echo "  TC qdisc already configured"
    echo "  Remove with: sudo tc qdisc del dev $INTERFACE root"
else
    echo -e "${GREEN}✓ OK (None)${NC}"
fi

# Quick latency test
echo -n "Testing baseline latency... "
latency=$(ping -c 5 -q $REMOTE_PI 2>/dev/null | grep "rtt min/avg/max" | awk -F'/' '{print $5}')
if [ -n "$latency" ]; then
    echo -e "${GREEN}✓ ${latency}ms${NC}"
else
    echo -e "${YELLOW}⚠ Could not measure${NC}"
fi

# Quick throughput test
echo -n "Testing baseline throughput... "
if command -v iperf3 &>/dev/null; then
    throughput=$(timeout 5 iperf3 -c $REMOTE_PI -t 3 -J 2>/dev/null | grep "bits_per_second" | tail -1 | awk -F: '{print $2}' | tr -d ' ,' | awk '{printf "%.0f\n", $1/1000000}')
    if [ -n "$throughput" ]; then
        echo -e "${GREEN}✓ ${throughput} Mbps${NC}"
    else
        echo -e "${YELLOW}⚠ Could not measure${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Skipped (iperf3 not available)${NC}"
fi

echo ""
echo "================================================================"
echo "                    Verification Summary"
echo "================================================================"
echo ""
echo "Phoenix IP:    $LOCAL_IP (this Pi)"
echo "Pi2 IP:        $REMOTE_PI"
echo "Interface:     $INTERFACE"
echo "Baseline RTT:  ${latency:-N/A} ms"
echo "Throughput:    ${throughput:-N/A} Mbps"
echo ""

# Final status
all_critical_ok=true
if ! ping -c 1 -W 1 $REMOTE_PI &>/dev/null; then
    all_critical_ok=false
fi
if [ ! -f "./bin/control_plane" ]; then
    all_critical_ok=false
fi

if [ "$all_critical_ok" = true ]; then
    echo -e "${GREEN}✓ System is ready for benchmarking!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Quick test:  sudo ./bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/gaming.json"
    echo "  2. Full benchmark: sudo bash scripts/comprehensive_benchmark.sh"
    echo ""
else
    echo -e "${RED}✗ System not ready - please fix errors above${NC}"
    echo ""
    exit 1
fi
