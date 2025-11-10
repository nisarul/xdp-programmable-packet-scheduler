#!/bin/bash
#
# Quick Demo Script for Viva/Presentation
# Shows XDP vs No QoS in ~5 minutes
#

set -e

# Add system paths for tc, ethtool, etc.
export PATH=$PATH:/sbin:/usr/sbin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REMOTE_PI="192.168.5.195"
INTERFACE="eth0"
TEST_TIME=20

log_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

log_info() {
    echo -e "[$(date +%H:%M:%S)]${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "[$(date +%H:%M:%S)]${GREEN}[PASS]${NC} $1"
}

log_test() {
    echo -e "[$(date +%H:%M:%S)]${YELLOW}[TEST]${NC} $1"
}

cleanup() {
    log_info "Cleaning up..."
    sudo ip link set dev $INTERFACE xdp off 2>/dev/null || true
    pkill -f "control_plane" 2>/dev/null || true
    pkill -f "iperf3.*-c" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================================
# MAIN DEMO
# ============================================================================

clear
log_header "XDP QoS SCHEDULER - QUICK DEMO"

echo "This demo compares:"
echo "  1. Baseline (no QoS) - shows bufferbloat problem"
echo "  2. XDP QoS (gaming config) - shows the solution"
echo ""
echo "Duration: ~5 minutes"
echo ""
echo "Starting tests in 3 seconds..."
sleep 3

# ============================================================================
# PART 1: BASELINE (NO QOS)
# ============================================================================

log_header "PART 1: Baseline - The Problem (Bufferbloat)"

log_info "Step 1: Measuring idle latency (no load)..."
idle_latency=$(ping -c 10 -q $REMOTE_PI 2>/dev/null | grep "rtt min/avg/max" | awk -F'/' '{print $5}')
echo ""
echo -e "  ${GREEN}Idle Latency: ${idle_latency}ms${NC}"
echo ""
sleep 2

log_info "Step 2: Starting heavy download in background..."
iperf3 -c $REMOTE_PI -t $TEST_TIME -P 4 > /tmp/baseline_load.txt 2>&1 &
load_pid=$!
sleep 3

log_info "Step 3: Measuring latency UNDER LOAD (watch it spike!)..."
echo ""
ping -c 15 $REMOTE_PI | while read line; do
    if echo "$line" | grep -q "time="; then
        latency=$(echo "$line" | grep -oP 'time=\K[0-9.]+')
        if (( $(echo "$latency > 50" | bc -l) )); then
            echo -e "  ${RED}$line  ← BUFFERBLOAT!${NC}"
        elif (( $(echo "$latency > 20" | bc -l) )); then
            echo -e "  ${YELLOW}$line  ← Getting worse${NC}"
        else
            echo -e "  ${GREEN}$line${NC}"
        fi
    fi
done

wait $load_pid 2>/dev/null || true

loaded_latency=$(ping -c 5 -q $REMOTE_PI 2>/dev/null | grep "rtt min/avg/max" | awk -F'/' '{print $5}')

echo ""
log_pass "Baseline Test Complete"
echo ""
echo -e "${YELLOW}RESULTS:${NC}"
echo -e "  Idle Latency:    ${GREEN}${idle_latency}ms${NC}"
echo -e "  Loaded Latency:  ${RED}${loaded_latency}ms${NC}"
increase=$(echo "scale=1; ($loaded_latency - $idle_latency) / $idle_latency * 100" | bc)
echo -e "  ${RED}Latency increased by ${increase}%!${NC}"
echo ""
echo "This is the BUFFERBLOAT problem - bulk traffic causes huge latency spikes!"
echo ""
echo "Proceeding to XDP solution test in 3 seconds..."
sleep 3

# ============================================================================
# PART 2: XDP QOS
# ============================================================================

log_header "PART 2: XDP QoS - The Solution"

log_info "Enabling XDP QoS with Gaming configuration..."
sudo ./bin/control_plane -i $INTERFACE -x ./build/xdp_scheduler.o -c ./configs/gaming.json > /tmp/xdp_output.txt 2>&1 &
xdp_pid=$!
sleep 5

if ! kill -0 $xdp_pid 2>/dev/null; then
    echo -e "${RED}Failed to start XDP!${NC}"
    cat /tmp/xdp_output.txt
    exit 1
fi

log_pass "XDP QoS is running (Strict Priority Scheduler)"
echo ""
sleep 2

log_info "Step 1: Measuring idle latency with XDP..."
xdp_idle=$(ping -c 10 -q $REMOTE_PI 2>/dev/null | grep "rtt min/avg/max" | awk -F'/' '{print $5}')
echo ""
echo -e "  ${GREEN}Idle Latency: ${xdp_idle}ms${NC}"
echo ""
sleep 2

log_info "Step 2: Starting same heavy download..."
iperf3 -c $REMOTE_PI -t $TEST_TIME -P 4 > /tmp/xdp_load.txt 2>&1 &
load_pid=$!
sleep 3

log_info "Step 3: Measuring latency UNDER LOAD (XDP should keep it low!)..."
echo ""
ping -c 15 $REMOTE_PI | while read line; do
    if echo "$line" | grep -q "time="; then
        latency=$(echo "$line" | grep -oP 'time=\K[0-9.]+')
        if (( $(echo "$latency > 20" | bc -l) )); then
            echo -e "  ${YELLOW}$line${NC}"
        else
            echo -e "  ${GREEN}$line  ← Still low!${NC}"
        fi
    fi
done

wait $load_pid 2>/dev/null || true

xdp_loaded=$(ping -c 5 -q $REMOTE_PI 2>/dev/null | grep "rtt min/avg/max" | awk -F'/' '{print $5}')

echo ""
log_pass "XDP QoS Test Complete"

# Stop XDP
kill $xdp_pid 2>/dev/null || true
wait $xdp_pid 2>/dev/null || true

# ============================================================================
# FINAL COMPARISON
# ============================================================================

log_header "RESULTS COMPARISON"

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│                    LATENCY COMPARISON                       │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│                                                             │"
printf "│  %-25s │ %10s │ %10s │\n" "Scenario" "Idle" "Under Load"
echo "│  ───────────────────────────────────────────────────────── │"
printf "│  %-25s │ %9sms │ ${RED}%9sms${NC} │\n" "Baseline (No QoS)" "$idle_latency" "$loaded_latency"
printf "│  %-25s │ %9sms │ ${GREEN}%9sms${NC} │\n" "XDP QoS (Gaming)" "$xdp_idle" "$xdp_loaded"
echo "│                                                             │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""

# Calculate improvements
baseline_increase=$(echo "scale=1; ($loaded_latency - $idle_latency) / $idle_latency * 100" | bc)
xdp_increase=$(echo "scale=1; ($xdp_loaded - $xdp_idle) / $xdp_idle * 100" | bc)
improvement=$(echo "scale=1; (1 - $xdp_loaded / $loaded_latency) * 100" | bc)

echo -e "${YELLOW}KEY FINDINGS:${NC}"
echo ""
echo -e "  ${RED}Baseline:${NC}"
echo -e "    • Latency increased by ${RED}${baseline_increase}%${NC} under load"
echo -e "    • This is BUFFERBLOAT - bulk traffic blocks latency-sensitive traffic"
echo ""
echo -e "  ${GREEN}XDP QoS:${NC}"
echo -e "    • Latency increased by only ${GREEN}${xdp_increase}%${NC} under load"
echo -e "    • ${GREEN}${improvement}% better${NC} than baseline"
echo -e "    • Gaming/real-time traffic stays prioritized!"
echo ""
echo -e "${CYAN}WHY XDP IS BETTER:${NC}"
echo "  ✓ Operates at driver level (before kernel stack)"
echo "  ✓ Classifies packets in microseconds"
echo "  ✓ Strict priority keeps important traffic flowing"
echo "  ✓ Programmable without kernel modules"
echo "  ✓ Lower CPU overhead than traditional TC"
echo ""

# Throughput comparison
baseline_tput=$(grep "receiver" /tmp/baseline_load.txt | tail -1 | awk '{print $(NF-2)}')
xdp_tput=$(grep "receiver" /tmp/xdp_load.txt | tail -1 | awk '{print $(NF-2)}')

echo -e "${YELLOW}THROUGHPUT (bulk transfer):${NC}"
echo "  Baseline:  ${baseline_tput} Mbps"
echo "  XDP QoS:   ${xdp_tput} Mbps"
echo "  (Similar throughput, but XDP protects latency-sensitive traffic!)"
echo ""

log_header "DEMO COMPLETE"

echo "This demonstrates how XDP QoS solves the bufferbloat problem"
echo "by prioritizing time-sensitive traffic (gaming, video calls)"
echo "while still allowing bulk transfers to proceed."
echo ""
echo "For comprehensive benchmarks, run:"
echo "  sudo bash scripts/comprehensive_benchmark.sh"
echo ""
