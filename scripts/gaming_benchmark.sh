#!/bin/bash

# Gaming Priority Benchmark - Test gaming traffic prioritization
# Compares gaming latency/jitter under load across different QoS methods

set -e

# Configuration
INTERFACE="eth0"
REMOTE_HOST="192.168.5.195"
TEST_DURATION=30  # Shorter tests for focused analysis
GAMING_PORT=3074
BULK_PORTS="5201 5202 5203"
RESULTS_DIR="gaming_results_$(date +%Y%m%d_%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup_qos() {
    log_info "Cleaning up QoS configuration..."
    tc qdisc del dev $INTERFACE root 2>/dev/null || true
    pkill -f "control_plane" || true
    ip link set dev $INTERFACE xdp off 2>/dev/null || true
    sleep 2
}

setup_baseline() {
    log_info "Setting up baseline (no QoS)..."
    cleanup_qos
}

setup_tc_prio() {
    log_info "Setting up TC PRIO qdisc..."
    cleanup_qos
    
    # Create PRIO qdisc
    tc qdisc add dev $INTERFACE root handle 1: prio bands 8
    
    # Gaming traffic -> Band 0 (highest priority)
    tc filter add dev $INTERFACE parent 1:0 protocol ip prio 1 u32 \
        match ip protocol 17 0xff \
        match ip dport 3074 0xffff \
        flowid 1:1
    
    # Bulk traffic -> Band 7 (lowest priority)  
    tc filter add dev $INTERFACE parent 1:0 protocol ip prio 7 u32 \
        match ip protocol 6 0xff \
        match ip dport 5201 0xffff \
        flowid 1:8
}

setup_tc_htb() {
    log_info "Setting up TC HTB..."
    cleanup_qos
    
    # Create HTB root
    tc qdisc add dev $INTERFACE root handle 1: htb default 30
    tc class add dev $INTERFACE parent 1: classid 1:1 htb rate 100mbit
    
    # Gaming class - 50% guaranteed, 80% max
    tc class add dev $INTERFACE parent 1:1 classid 1:10 htb rate 50mbit ceil 80mbit prio 0
    
    # Bulk class - 20% guaranteed, 50% max  
    tc class add dev $INTERFACE parent 1:1 classid 1:30 htb rate 20mbit ceil 50mbit prio 2
    
    # Filters
    tc filter add dev $INTERFACE parent 1:0 protocol ip prio 1 u32 \
        match ip protocol 17 0xff \
        match ip dport 3074 0xffff \
        flowid 1:10
        
    tc filter add dev $INTERFACE parent 1:0 protocol ip prio 3 u32 \
        match ip protocol 6 0xff \
        match ip dport 5201 0xffff \
        flowid 1:30
}

setup_xdp_gaming() {
    log_info "Setting up XDP Gaming QoS..."
    cleanup_qos
    
    # Load XDP QoS with gaming config in background
    ./bin/control_plane -i $INTERFACE -c configs/gaming.json -x build/xdp_scheduler.o -t build/tc_scheduler.o > /dev/null 2>&1 &
    local xdp_pid=$!
    
    # Wait for initialization
    sleep 3
    
    # Check if it's running
    if ! kill -0 $xdp_pid 2>/dev/null; then
        log_error "XDP control plane failed to start"
        return 1
    fi
    
    log_info "XDP Gaming QoS configured (PID: $xdp_pid)"
    echo $xdp_pid > /tmp/xdp_ctrl.pid
    return 0
}

test_gaming_latency() {
    local method=$1
    local output_dir=$2
    
    log_info "Testing gaming latency under load for $method..."
    
    # Start bulk traffic to create contention
    for port in $BULK_PORTS; do
        iperf3 -c $REMOTE_HOST -p $port -t $TEST_DURATION -i 10 > $output_dir/${method}.bulk_${port}.log 2>&1 &
    done
    
    # Wait a moment for bulk traffic to ramp up
    sleep 2
    
    # Test gaming latency (simulated with ping to gaming port)
    timeout $TEST_DURATION ping -c 100 -i 0.1 $REMOTE_HOST > $output_dir/${method}.gaming_latency.raw 2>&1 &
    PING_PID=$!
    
    # Test gaming jitter (UDP to gaming port)
    timeout $TEST_DURATION iperf3 -c $REMOTE_HOST -p $GAMING_PORT -u -b 10M -t $TEST_DURATION -i 5 > $output_dir/${method}.gaming_jitter.log 2>&1 &
    
    # Wait for tests to complete
    wait $PING_PID
    wait
    
    log_pass "Gaming latency test completed for $method"
}

analyze_gaming_results() {
    local method=$1
    local output_dir=$2
    
    # Extract gaming latency stats
    if [[ -f "$output_dir/${method}.gaming_latency.raw" ]]; then
        local latency_stats=$(tail -1 "$output_dir/${method}.gaming_latency.raw" | grep "rtt" | awk -F'=' '{print $2}' | awk '{print $1}')
        echo "$method,$latency_stats" >> $output_dir/gaming_latency_summary.csv
    fi
    
    # Extract jitter stats from gaming traffic
    if [[ -f "$output_dir/${method}.gaming_jitter.log" ]]; then
        local jitter=$(grep "Jitter" "$output_dir/${method}.gaming_jitter.log" | tail -1 | awk '{print $(NF-1)}')
        local loss=$(grep "Lost" "$output_dir/${method}.gaming_jitter.log" | tail -1 | awk -F'(' '{print $2}' | awk -F'%' '{print $1}')
        echo "$method,$jitter,$loss" >> $output_dir/gaming_performance_summary.csv
    fi
}

run_gaming_benchmark() {
    log_info "🎮 Starting Gaming Priority Benchmark..."
    
    mkdir -p $RESULTS_DIR
    
    # Initialize summary files
    echo "Method,Min/Avg/Max/StdDev" > $RESULTS_DIR/gaming_latency_summary.csv
    echo "Method,Jitter_ms,Loss_percent" > $RESULTS_DIR/gaming_performance_summary.csv
    
    local methods=("baseline" "tc_prio" "tc_htb" "xdp_gaming")
    
    for method in "${methods[@]}"; do
        log_info "🔧 Setting up $method configuration..."
        
        case $method in
            baseline) setup_baseline ;;
            tc_prio) setup_tc_prio ;;
            tc_htb) setup_tc_htb ;;
            xdp_gaming) setup_xdp_gaming ;;
        esac
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to setup $method, skipping..."
            continue
        fi
        
        # Send notification
        if command -v telegram_send &> /dev/null; then
            telegram_send "🎮 Gaming benchmark: Testing $method configuration..."
        fi
        
        test_gaming_latency $method $RESULTS_DIR
        analyze_gaming_results $method $RESULTS_DIR
        
        # Cleanup between tests
        cleanup_qos
        sleep 5
    done
    
    generate_gaming_report
}

generate_gaming_report() {
    local report_file="$RESULTS_DIR/gaming_benchmark_report.txt"
    
    cat > $report_file << EOF
================================================================================
🎮 GAMING PRIORITY BENCHMARK REPORT
================================================================================

Test Date: $(date)
Test Duration: ${TEST_DURATION} seconds per test
Device Under Test: $(hostname) ($(hostname -I | awk '{print $1}'))
Traffic Generator: ${REMOTE_HOST}
Interface: ${INTERFACE}

================================================================================
🎯 GAMING LATENCY UNDER LOAD (Lower is Better)
================================================================================

EOF
    
    if [[ -f "$RESULTS_DIR/gaming_latency_summary.csv" ]]; then
        echo "Method                    Min/Avg/Max/StdDev (ms)" >> $report_file
        echo "--------------------------------------------------------------------------------" >> $report_file
        tail -n +2 "$RESULTS_DIR/gaming_latency_summary.csv" | while IFS=',' read -r method stats; do
            printf "%-25s %s\n" "$method" "$stats" >> $report_file
        done
    fi
    
    cat >> $report_file << EOF

================================================================================
🎮 GAMING TRAFFIC QUALITY (Lower Jitter/Loss is Better)  
================================================================================

EOF
    
    if [[ -f "$RESULTS_DIR/gaming_performance_summary.csv" ]]; then
        echo "Method                    Jitter (ms)    Loss (%)" >> $report_file
        echo "--------------------------------------------------------------------------------" >> $report_file
        tail -n +2 "$RESULTS_DIR/gaming_performance_summary.csv" | while IFS=',' read -r method jitter loss; do
            printf "%-25s %-14s %s\n" "$method" "$jitter" "$loss" >> $report_file
        done
    fi
    
    cat >> $report_file << EOF

================================================================================
💡 GAMING PRIORITIZATION ANALYSIS
================================================================================

This benchmark tests how well each QoS method prioritizes gaming traffic 
(UDP port 3074) when competing with bulk traffic (TCP ports 5201-5203).

Key Metrics:
• Lower latency = Better gaming experience
• Lower jitter = Smoother gameplay  
• Lower loss = No packet drops

Expected Results:
• Baseline: Poor gaming performance under load
• TC PRIO: Good gaming priority with traditional Linux QoS
• TC HTB: Rate-limited but protected gaming traffic
• XDP Gaming: Improved priority with starvation protection

================================================================================
EOF
    
    log_pass "Gaming benchmark report generated: $report_file"
    
    # Send completion notification
    if command -v telegram_send &> /dev/null; then
        telegram_send "🎮 Gaming benchmark completed! Results in $RESULTS_DIR"
    fi
    
    cat $report_file
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check dependencies
    for cmd in tc iperf3 ping; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    # Trap to cleanup on exit
    trap cleanup_qos EXIT
    
    run_gaming_benchmark
fi