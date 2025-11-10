#!/bin/bash
# Run comprehensive benchmark in background
# Logs output to benchmark.log

cd /home/phoenix/Project/dissertation_new/xdp_qos_scheduler

# Run with nohup to survive terminal disconnect
nohup sudo bash scripts/comprehensive_benchmark.sh > benchmark_$(date +%Y%m%d_%H%M%S).log 2>&1 &

# Get the process ID
BENCHMARK_PID=$!

echo "================================================================"
echo "  Benchmark started in background!"
echo "================================================================"
echo ""
echo "Process ID: $BENCHMARK_PID"
echo "Log file:   benchmark_$(date +%Y%m%d_%H%M%S).log"
echo ""
echo "To check progress:"
echo "  tail -f benchmark_*.log"
echo ""
echo "To check if still running:"
echo "  ps aux | grep comprehensive_benchmark"
echo ""
echo "Estimated completion: ~45 minutes from now"
echo ""
