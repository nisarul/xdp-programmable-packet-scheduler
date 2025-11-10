#!/bin/bash
#
# Background Stress Script - Creates realistic network congestion
# Purpose: Make XDP QoS benefits visible by creating CPU and network load
#
# This script should run in background during benchmarks to:
# 1. Add CPU load (keeps CPU at ~70-80%)
# 2. Add background network traffic (creates packet processing pressure)
# 3. Add memory pressure (forces system to work harder)

set -e

# Configuration
REMOTE_PI="${1:-192.168.5.195}"
CPU_CORES=$(nproc)
TARGET_CPU_LOAD=90  # Target 90% average CPU usage

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "[$(date +%H:%M:%S)]${BLUE}[STRESS]${NC} $1"
}

log_warn() {
    echo -e "[$(date +%H:%M:%S)]${YELLOW}[STRESS]${NC} $1"
}

# Cleanup function
cleanup() {
    log_warn "Stopping stress test..."
    pkill -P $$ 2>/dev/null || true
    pkill -f "stress-ng" 2>/dev/null || true
    pkill -f "iperf3.*background" 2>/dev/null || true
    log_info "Stress test stopped"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

echo ""
echo "================================================================================"
echo "                    BACKGROUND STRESS TEST STARTING"
echo "================================================================================"
echo ""
log_info "Target CPU load: ${TARGET_CPU_LOAD}%"
log_info "Available cores: ${CPU_CORES}"
log_info "Remote Pi: ${REMOTE_PI}"
echo ""

# Check if stress-ng is available
if ! command -v stress-ng &>/dev/null; then
    log_warn "stress-ng not found, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y stress-ng
fi

# Calculate stress workers
# Use all cores for CPU stress at 90% load
CPU_WORKERS=$CPU_CORES

log_info "Starting CPU stress (${CPU_WORKERS} workers at ${TARGET_CPU_LOAD}% load)..."
stress-ng --cpu $CPU_WORKERS --cpu-load $TARGET_CPU_LOAD --vm 2 --vm-bytes 512M --metrics-brief &
STRESS_PID=$!

sleep 2

# Start background network traffic (high intensity)
log_info "Starting intensive background network traffic..."

# Traffic pattern 1: Multiple concurrent bulk TCP transfers (simulates heavy downloads)
for i in {1..4}; do
    while true; do
        iperf3 -c $REMOTE_PI -t 30 -p $((5210 + i)) &>/dev/null
        sleep 2
    done &
done

# Traffic pattern 2: Bursty traffic (simulates web browsing) - more frequent
while true; do
    iperf3 -c $REMOTE_PI -t 5 -p 5215 &>/dev/null
    sleep 5
done &
TRAFFIC2_PID=$!

# Traffic pattern 3: Small packet flood (simulates IoT devices) - higher rate
while true; do
    iperf3 -c $REMOTE_PI -u -b 10M -l 64 -t 20 -p 5216 &>/dev/null
    sleep 5
done &
TRAFFIC3_PID=$!

# Traffic pattern 4: Additional UDP flood for packet processing stress
while true; do
    iperf3 -c $REMOTE_PI -u -b 15M -l 128 -t 15 -p 5217 &>/dev/null
    sleep 3
done &
TRAFFIC4_PID=$!

echo ""
log_info "High-intensity stress test running with PID:"
log_info "  - CPU + Memory stress: $STRESS_PID (${CPU_WORKERS} workers at ${TARGET_CPU_LOAD}%)"
log_info "  - 4x Bulk TCP traffic (ports 5211-5214)"
log_info "  - Bursty web traffic: $TRAFFIC2_PID"
log_info "  - Small packet UDP: $TRAFFIC3_PID"
log_info "  - Additional UDP flood: $TRAFFIC4_PID"
echo ""
log_info "Press Ctrl+C to stop"
echo ""

# Monitor and report CPU usage every 20 seconds with more detail
while true; do
    sleep 20
    # Get overall CPU usage
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    # Get load average
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    # Get memory usage
    MEM_USAGE=$(free | awk 'NR==2{printf "%.1f%%", $3*100/$2}')
    
    log_info "System Status - CPU: ${CPU_USAGE}%, Load: ${LOAD_AVG}/${CPU_CORES}, Memory: ${MEM_USAGE}"
done
