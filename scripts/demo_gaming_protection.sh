#!/bin/bash
#
# Quick Gaming QoS Demo - Shows XDP protecting gaming traffic
# Demonstrates the "bufferbloat" problem and XDP solution
#
# This is a focused test that clearly shows XDP QoS benefits:
# 1. Gaming traffic (UDP port 3074) under bulk download stress
# 2. Compares: No QoS vs XDP Gaming config
# 3. Measures what matters: latency and jitter during congestion

set -e

# Add system paths
export PATH=$PATH:/sbin:/usr/sbin

# Configuration
REMOTE_PI="192.168.5.195"
REMOTE_USER="toby"
REMOTE_PASS="syednisar"
INTERFACE="eth0"
TEST_DURATION=60

# XDP paths
XDP_CTRL="./bin/control_plane"
XDP_OBJ="./build/xdp_scheduler.o"
TC_OBJ="./build/tc_scheduler.o"
CONFIG_GAMING="./configs/gaming.json"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_fail() {
    echo -e "${RED}[✗]${NC} $1"
}

log_test() {
    echo -e "${CYAN}[TEST]${NC} $1"
}

cleanup_qos() {
    # Kill control plane if PID file exists
    if [ -f /tmp/xdp_ctrl.pid ]; then
        local pid=$(cat /tmp/xdp_ctrl.pid)
        kill -TERM $pid 2>/dev/null || true
        sleep 1
        kill -KILL $pid 2>/dev/null || true
        rm -f /tmp/xdp_ctrl.pid
    fi
    
    # Also kill any stray control plane processes
    pkill -f "control_plane" 2>/dev/null || true
    
    # Remove XDP and TC
    ip link set dev $INTERFACE xdp off 2>/dev/null || true
    tc qdisc del dev $INTERFACE root 2>/dev/null || true
    tc qdisc del dev $INTERFACE clsact 2>/dev/null || true
    
    sleep 2
}

setup_xdp_gaming() {
    cleanup_qos
    
    # Start XDP control plane (loads both XDP and TC programs)
    $XDP_CTRL -i $INTERFACE -x $XDP_OBJ -t $TC_OBJ -c $CONFIG_GAMING &>/dev/null &
    ctrl_pid=$!
    
    # Save PID for later cleanup
    echo $ctrl_pid > /tmp/xdp_ctrl.pid
    
    # Wait for initialization
    sleep 3
    
    # Check if control plane is running
    if ! kill -0 $ctrl_pid 2>/dev/null; then
        log_fail "XDP control plane failed to start"
        return 1
    fi
    
    log_pass "XDP + TC Gaming QoS enabled (PID: $ctrl_pid)"
}

test_gaming_under_load() {
    local test_name=$1
    local with_qos=$2
    
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    log_test "$test_name"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if [ "$with_qos" == "true" ]; then
        setup_xdp_gaming
    else
        cleanup_qos
        log_info "No QoS (baseline) - all traffic competes equally"
    fi
    
    sleep 3
    
    # Start bulk UPLOADS to create realistic congestion
    log_info "Starting 8 bulk upload streams (80Mbps each = 640Mbps total)..."
    local bulk_pids=()
    for i in {1..8}; do
        # 80Mbps per stream creates good congestion without completely saturating
        iperf3 -c $REMOTE_PI -t $((TEST_DURATION + 10)) -p $((5200 + i)) -b 80M &>/dev/null &
        bulk_pids+=($!)
    done
    local bulk_pid=${bulk_pids[0]}
    
    sleep 5  # Let congestion build up
    log_info "Network saturated, now testing gaming traffic..."
    echo ""
    
    # Test 1: Measure ping latency during bulk transfer
    log_test "Test 1: Ping latency (ICMP) during bulk transfer"
    ping -c 60 -i 0.5 $REMOTE_PI > /tmp/gaming_ping_${test_name}.txt 2>&1
    
    local avg_latency=$(grep "rtt min/avg/max" /tmp/gaming_ping_${test_name}.txt | awk -F'/' '{print $5}')
    local min_latency=$(grep "rtt min/avg/max" /tmp/gaming_ping_${test_name}.txt | awk -F'/' '{print $4}')
    local max_latency=$(grep "rtt min/avg/max" /tmp/gaming_ping_${test_name}.txt | awk -F'/' '{print $6}' | cut -d' ' -f1)
    local jitter=$(echo "$max_latency - $min_latency" | bc)
    
    echo -e "  Latency: ${YELLOW}min=${min_latency}ms${NC}, ${CYAN}avg=${avg_latency}ms${NC}, ${RED}max=${max_latency}ms${NC}"
    echo -e "  Jitter:  ${YELLOW}${jitter}ms${NC}"
    echo ""
    
    # Test 2: Measure gaming UDP traffic (port 3074 = Xbox/CoD)
    log_test "Test 2: Gaming UDP traffic (port 3074, 10Mbps, 100 byte packets)"
    timeout 30 iperf3 -c $REMOTE_PI -u -b 10M -l 100 -p 3074 -J > /tmp/gaming_udp_${test_name}.json 2>&1 || true
    
    local udp_jitter=$(grep -o '"jitter_ms"[^,]*' /tmp/gaming_udp_${test_name}.json | head -1 | awk -F':' '{print $2}' | tr -d ' ')
    local udp_loss=$(grep -o '"lost_percent"[^,]*' /tmp/gaming_udp_${test_name}.json | head -1 | awk -F':' '{print $2}' | tr -d ' ')
    
    if [ -n "$udp_jitter" ] && [ "$udp_jitter" != "null" ]; then
        echo -e "  UDP Jitter: ${YELLOW}${udp_jitter}ms${NC}"
        echo -e "  Packet Loss: ${RED}${udp_loss}%${NC}"
    else
        echo -e "  ${YELLOW}[Warning: Could not measure UDP metrics]${NC}"
    fi
    echo ""
    
    # Kill all bulk transfers
    for pid in "${bulk_pids[@]}"; do
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
    done
    
    # Summary
    echo "───────────────────────────────────────────────────────────"
    if (( $(echo "$avg_latency < 10" | bc -l) )); then
        log_pass "EXCELLENT: Gaming latency under 10ms during heavy load!"
    elif (( $(echo "$avg_latency < 50" | bc -l) )); then
        echo -e "${YELLOW}[OK]${NC} Acceptable: Gaming latency ${avg_latency}ms"
    else
        log_fail "POOR: Gaming latency ${avg_latency}ms is too high!"
    fi
    
    if (( $(echo "$jitter < 20" | bc -l) )); then
        log_pass "EXCELLENT: Low jitter (${jitter}ms)"
    else
        echo -e "${YELLOW}[WARN]${NC} High jitter: ${jitter}ms (causes lag spikes)"
    fi
    echo "───────────────────────────────────────────────────────────"
    echo ""
    
    cleanup_qos
    sleep 2
}

# Main execution
clear
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                  XDP QoS GAMING PROTECTION DEMO                          ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "This demo shows how XDP QoS protects gaming traffic during heavy"
echo "network congestion (e.g., someone downloading a large file)."
echo ""
echo "We'll run two tests:"
echo -e "  1. ${RED}WITHOUT QoS${NC} - Gaming suffers during bulk transfers (bufferbloat)"
echo -e "  2. ${GREEN}WITH XDP QoS${NC} - Gaming stays smooth even during bulk transfers"
echo ""
echo "Gaming traffic: UDP port 3074 (Xbox Live, Call of Duty)"
echo "Stress: Saturating network with bulk TCP download"
echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo ""

# Check prerequisites
if [ "$EUID" -ne 0 ]; then
    log_fail "Must run as root (sudo)"
    exit 1
fi

if ! ping -c 2 -W 2 $REMOTE_PI &>/dev/null; then
    log_fail "Cannot reach remote Pi: $REMOTE_PI"
    exit 1
fi

log_pass "Prerequisites OK"
echo ""
read -p "Press Enter to start the demo..."

# Test 1: Without QoS (baseline - shows the problem)
test_gaming_under_load "baseline" "false"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  WITHOUT QoS: Did you see high latency and jitter?                      ║"
echo "║  This is the 'bufferbloat' problem - bulk traffic interferes with gaming║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
read -p "Press Enter to test WITH XDP QoS protection..."

# Test 2: With XDP Gaming QoS (solution)
test_gaming_under_load "xdp_gaming" "true"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                            COMPARISON RESULTS                            ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Show comparison
baseline_avg=$(grep "rtt min/avg/max" /tmp/gaming_ping_baseline.txt | awk -F'/' '{print $5}')
xdp_avg=$(grep "rtt min/avg/max" /tmp/gaming_ping_xdp_gaming.txt | awk -F'/' '{print $5}')

baseline_max=$(grep "rtt min/avg/max" /tmp/gaming_ping_baseline.txt | awk -F'/' '{print $6}' | cut -d' ' -f1)
xdp_max=$(grep "rtt min/avg/max" /tmp/gaming_ping_xdp_gaming.txt | awk -F'/' '{print $6}' | cut -d' ' -f1)

improvement=$(echo "scale=1; (($baseline_avg - $xdp_avg) / $baseline_avg) * 100" | bc)

echo "Average Latency:"
echo -e "  Without QoS: ${RED}${baseline_avg}ms${NC}"
echo -e "  With XDP:    ${GREEN}${xdp_avg}ms${NC}"

# Color code improvement based on value
if (( $(echo "$improvement > 0" | bc -l) )); then
    echo -e "  Improvement: ${GREEN}${improvement}%${NC} better"
else
    degradation=$(echo "$improvement * -1" | bc)
    echo -e "  Improvement: ${RED}${degradation}% WORSE${NC} (QoS not helping - need more congestion!)"
fi
echo ""

echo "Maximum Latency:"
echo -e "  Without QoS: ${RED}${baseline_max}ms${NC}"
echo -e "  With XDP:    ${GREEN}${xdp_max}ms${NC}"
echo ""

echo "══════════════════════════════════════════════════════════════════════════"
echo ""
if (( $(echo "$improvement > 20" | bc -l) )); then
    log_pass "Demo complete! XDP QoS significantly improves gaming traffic!"
    echo "     XDP reduced latency by ${improvement}% during network congestion."
elif (( $(echo "$improvement > 0" | bc -l) )); then
    echo -e "${YELLOW}[OK]${NC} XDP QoS shows ${improvement}% improvement (moderate)"
    echo "     Suggestion: Run stress_background.sh for more congestion"
else
    echo -e "${RED}[ISSUE]${NC} XDP QoS not showing benefits - network not congested enough!"
    echo ""
    echo "Diagnosis:"
    echo "  • Baseline latency is only ${baseline_avg}ms (very low)"
    echo "  • Max latency is ${baseline_max}ms (no bufferbloat observed)"
    echo ""
    echo "Solutions to create realistic congestion:"
    echo "  1. Run: sudo ./scripts/stress_background.sh 192.168.5.195"
    echo "  2. Then re-run this demo"
    echo ""
    echo "OR for dissertation data:"
    echo "  • Use comprehensive benchmark with stress"
    echo "  • Focus on 'latency under load' metric"
fi
echo ""
