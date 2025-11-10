#!/bin/bash
#
# Performance Evaluation Script for XDP QoS Scheduler
# Tests performance between phoenix (192.168.5.196) and toby (192.168.5.195)
#

set -e

# Configuration
PHOENIX_IP="192.168.5.196"
TOBY_IP="192.168.5.195"
INTERFACE="eth0"
RESULTS_DIR="./results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create results directory
mkdir -p "$RESULTS_DIR"

echo "=================================="
echo "XDP QoS Scheduler - Performance Evaluation"
echo "=================================="
echo "Phoenix: $PHOENIX_IP"
echo "Toby:    $TOBY_IP"
echo "Interface: $INTERFACE"
echo "Results: $RESULTS_DIR"
echo "=================================="
echo ""

# Function to run iperf3 test
run_iperf3_test() {
    local test_name=$1
    local duration=$2
    local parallel=$3
    local protocol=$4
    local port=$5
    local bandwidth=$6
    
    echo -e "${GREEN}Running iperf3 test: $test_name${NC}"
    echo "  Duration: ${duration}s, Parallel: $parallel, Protocol: $protocol"
    
    local output_file="$RESULTS_DIR/${test_name}_${TIMESTAMP}.json"
    
    if [ "$protocol" == "udp" ]; then
        iperf3 -c $TOBY_IP -p $port -u -b $bandwidth -t $duration -P $parallel -J > "$output_file" 2>&1
    else
        iperf3 -c $TOBY_IP -p $port -t $duration -P $parallel -J > "$output_file" 2>&1
    fi
    
    echo -e "${GREEN}  ✓ Results saved to: $output_file${NC}"
    echo ""
}

# Function to run latency test with ping
run_ping_test() {
    local test_name=$1
    local count=$2
    local packet_size=$3
    
    echo -e "${GREEN}Running ping test: $test_name${NC}"
    echo "  Count: $count, Packet size: $packet_size bytes"
    
    local output_file="$RESULTS_DIR/${test_name}_${TIMESTAMP}.txt"
    
    ping -c $count -s $packet_size $TOBY_IP > "$output_file" 2>&1
    
    # Extract statistics
    local avg_rtt=$(grep "avg" "$output_file" | awk -F'/' '{print $5}')
    echo -e "${GREEN}  ✓ Average RTT: $avg_rtt ms${NC}"
    echo -e "${GREEN}  ✓ Results saved to: $output_file${NC}"
    echo ""
}

# Function to monitor CPU usage
monitor_cpu() {
    local test_name=$1
    local duration=$2
    
    echo -e "${YELLOW}Monitoring CPU usage for $duration seconds...${NC}"
    
    local output_file="$RESULTS_DIR/cpu_${test_name}_${TIMESTAMP}.txt"
    
    mpstat 1 $duration > "$output_file" 2>&1 &
    local mpstat_pid=$!
    
    echo $mpstat_pid
}

# Function to capture packet statistics
capture_packet_stats() {
    local test_name=$1
    local output_file="$RESULTS_DIR/packets_${test_name}_${TIMESTAMP}.txt"
    
    echo -e "${YELLOW}Capturing packet statistics...${NC}"
    
    # Capture interface statistics
    ip -s link show $INTERFACE > "$output_file"
    
    # Capture XDP statistics if available
    if [ -d "/sys/fs/bpf/xdp_qos" ]; then
        bpftool map dump name cpu_stats >> "$output_file" 2>&1 || true
        bpftool map dump name queue_stats >> "$output_file" 2>&1 || true
    fi
    
    echo -e "${GREEN}  ✓ Packet stats saved to: $output_file${NC}"
}

# Test 1: Baseline (No XDP)
test_baseline() {
    echo ""
    echo "========================================="
    echo "Test 1: Baseline (Traditional Linux Stack)"
    echo "========================================="
    echo ""
    
    # Ensure XDP is detached
    echo "Ensuring XDP is detached..."
    sudo ip link set dev $INTERFACE xdp off 2>/dev/null || true
    
    # TCP throughput test
    run_iperf3_test "baseline_tcp_single" 10 1 "tcp" 5201 "0"
    run_iperf3_test "baseline_tcp_parallel" 10 4 "tcp" 5201 "0"
    
    # UDP throughput test
    run_iperf3_test "baseline_udp_100M" 10 1 "udp" 5201 "100M"
    run_iperf3_test "baseline_udp_1G" 10 1 "udp" 5201 "1G"
    
    # Latency test
    run_ping_test "baseline_ping_small" 100 64
    run_ping_test "baseline_ping_large" 100 1400
    
    capture_packet_stats "baseline"
}

# Test 2: XDP-only processing
test_xdp_only() {
    echo ""
    echo "========================================="
    echo "Test 2: XDP-Only Processing"
    echo "========================================="
    echo ""
    
    # Load XDP program with default config
    echo "Loading XDP program..."
    sudo ./control_plane -i $INTERFACE -x xdp_scheduler.o -c configs/default.json &
    local control_pid=$!
    
    sleep 3  # Wait for program to load
    
    # TCP throughput test
    run_iperf3_test "xdp_tcp_single" 10 1 "tcp" 5201 "0"
    run_iperf3_test "xdp_tcp_parallel" 10 4 "tcp" 5201 "0"
    
    # UDP throughput test
    run_iperf3_test "xdp_udp_100M" 10 1 "udp" 5201 "100M"
    run_iperf3_test "xdp_udp_1G" 10 1 "udp" 5201 "1G"
    
    # Latency test
    run_ping_test "xdp_ping_small" 100 64
    run_ping_test "xdp_ping_large" 100 1400
    
    capture_packet_stats "xdp_only"
    
    # Stop control plane
    echo "Stopping XDP program..."
    sudo kill $control_pid 2>/dev/null || true
    sleep 2
}

# Test 3: XDP + TC hybrid scheduling
test_xdp_tc_hybrid() {
    echo ""
    echo "========================================="
    echo "Test 3: XDP + TC Hybrid Scheduling"
    echo "========================================="
    echo ""
    
    # Load XDP and TC programs
    echo "Loading XDP and TC programs..."
    sudo ./control_plane -i $INTERFACE -x xdp_scheduler.o -t tc_scheduler.o -c configs/gaming.json &
    local control_pid=$!
    
    sleep 3  # Wait for programs to load
    
    # Multiple traffic classes test
    echo "Testing with multiple traffic classes..."
    
    # Gaming traffic (UDP, high priority)
    run_iperf3_test "hybrid_gaming_udp" 10 2 "udp" 27015 "50M"
    
    # Web traffic (TCP, medium priority)
    run_iperf3_test "hybrid_web_tcp" 10 2 "tcp" 443 "0"
    
    # Bulk traffic (TCP, low priority)
    run_iperf3_test "hybrid_bulk_tcp" 10 2 "tcp" 8080 "0"
    
    # Mixed traffic test
    echo "Running mixed traffic test..."
    iperf3 -c $TOBY_IP -p 27015 -u -b 30M -t 10 -J > "$RESULTS_DIR/hybrid_mixed_gaming_${TIMESTAMP}.json" 2>&1 &
    iperf3 -c $TOBY_IP -p 443 -t 10 -J > "$RESULTS_DIR/hybrid_mixed_web_${TIMESTAMP}.json" 2>&1 &
    iperf3 -c $TOBY_IP -p 8080 -t 10 -J > "$RESULTS_DIR/hybrid_mixed_bulk_${TIMESTAMP}.json" 2>&1 &
    wait
    
    # Latency under load
    run_ping_test "hybrid_ping_under_load" 100 64
    
    capture_packet_stats "hybrid"
    
    # Stop control plane
    echo "Stopping programs..."
    sudo kill $control_pid 2>/dev/null || true
    sleep 2
}

# Test 4: Fairness test
test_fairness() {
    echo ""
    echo "========================================="
    echo "Test 4: Fairness Evaluation"
    echo "========================================="
    echo ""
    
    # Load XDP with WFQ scheduler
    echo "Loading XDP with WFQ scheduler..."
    sudo ./control_plane -i $INTERFACE -x xdp_scheduler.o -c configs/server.json &
    local control_pid=$!
    
    sleep 3
    
    # Run multiple flows simultaneously
    echo "Running 8 parallel flows..."
    for i in {1..8}; do
        iperf3 -c $TOBY_IP -p $((5200 + i)) -t 30 -J > "$RESULTS_DIR/fairness_flow${i}_${TIMESTAMP}.json" 2>&1 &
    done
    
    wait
    
    capture_packet_stats "fairness"
    
    # Stop control plane
    sudo kill $control_pid 2>/dev/null || true
    sleep 2
}

# Test 5: Rate limiting test
test_rate_limiting() {
    echo ""
    echo "========================================="
    echo "Test 5: Rate Limiting"
    echo "========================================="
    echo ""
    
    # Load XDP with rate limiting
    echo "Loading XDP with rate limiting..."
    sudo ./control_plane -i $INTERFACE -x xdp_scheduler.o -c configs/gaming.json &
    local control_pid=$!
    
    sleep 3
    
    # Test different traffic classes with rate limits
    run_iperf3_test "ratelimit_control" 10 1 "tcp" 22 "0"
    run_iperf3_test "ratelimit_gaming" 10 1 "udp" 27015 "200M"
    run_iperf3_test "ratelimit_bulk" 10 1 "tcp" 8080 "0"
    
    capture_packet_stats "ratelimit"
    
    # Stop control plane
    sudo kill $control_pid 2>/dev/null || true
    sleep 2
}

# Generate summary report
generate_report() {
    echo ""
    echo "========================================="
    echo "Generating Summary Report"
    echo "========================================="
    echo ""
    
    local report_file="$RESULTS_DIR/summary_${TIMESTAMP}.txt"
    
    {
        echo "XDP QoS Scheduler - Performance Evaluation Summary"
        echo "=================================================="
        echo "Date: $(date)"
        echo "Phoenix: $PHOENIX_IP"
        echo "Toby: $TOBY_IP"
        echo ""
        echo "Test Results:"
        echo "-------------"
        
        # Process iperf3 results
        for file in "$RESULTS_DIR"/*.json; do
            if [ -f "$file" ]; then
                echo ""
                echo "File: $(basename $file)"
                
                # Extract key metrics using jq if available
                if command -v jq &> /dev/null; then
                    echo "  Throughput: $(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // "N/A"' "$file" 2>/dev/null || echo "N/A") bps"
                    echo "  Packets: $(jq -r '.end.sum.packets // "N/A"' "$file" 2>/dev/null || echo "N/A")"
                    echo "  Lost: $(jq -r '.end.sum.lost_packets // "N/A"' "$file" 2>/dev/null || echo "N/A")"
                    echo "  Jitter: $(jq -r '.end.sum.jitter_ms // "N/A"' "$file" 2>/dev/null || echo "N/A") ms"
                fi
            fi
        done
        
    } > "$report_file"
    
    echo -e "${GREEN}Summary report saved to: $report_file${NC}"
    echo ""
}

# Main execution
main() {
    echo "Starting performance evaluation..."
    echo ""
    
    # Check if we're root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
    
    # Check if toby is reachable
    if ! ping -c 1 -W 2 $TOBY_IP > /dev/null 2>&1; then
        echo -e "${RED}Error: Cannot reach toby ($TOBY_IP)${NC}"
        exit 1
    fi
    
    # Run tests
    test_baseline
    test_xdp_only
    test_xdp_tc_hybrid
    test_fairness
    test_rate_limiting
    
    # Generate report
    generate_report
    
    echo ""
    echo "========================================="
    echo "Performance evaluation complete!"
    echo "Results saved to: $RESULTS_DIR"
    echo "========================================="
}

# Run main function
main
