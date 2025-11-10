#!/bin/bash
#
# Run Benchmarks with Background Stress
# Wrapper script to run comprehensive benchmarks under realistic load

set -e

REMOTE_PI="192.168.5.195"

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║          COMPREHENSIVE BENCHMARK WITH BACKGROUND STRESS                 ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "This will:"
echo "  1. Start background stress test (CPU + network load)"
echo "  2. Run comprehensive benchmarks"
echo "  3. Generate graphs"
echo ""
echo "Total time: ~45 minutes"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Must run as root (sudo)"
    exit 1
fi

# Check if stress script exists
if [ ! -f "./scripts/stress_background.sh" ]; then
    echo "❌ Stress script not found: ./scripts/stress_background.sh"
    exit 1
fi

# Check if benchmark script exists
if [ ! -f "./scripts/comprehensive_benchmark.sh" ]; then
    echo "❌ Benchmark script not found: ./scripts/comprehensive_benchmark.sh"
    exit 1
fi

echo "✅ Prerequisites OK"
echo ""
read -p "Press Enter to start (or Ctrl+C to cancel)..."
echo ""

# Start stress test in background
echo "▶  Starting background stress test..."
./scripts/stress_background.sh "$REMOTE_PI" > stress_test.log 2>&1 &
STRESS_PID=$!

# Save PID for cleanup
echo $STRESS_PID > /tmp/stress_test.pid

echo "   Stress test started (PID: $STRESS_PID)"
echo "   Log: stress_test.log"
echo ""

# Wait for stress to stabilize
echo "⏳ Waiting 30 seconds for stress to stabilize..."
for i in {30..1}; do
    printf "\r   %2d seconds remaining..." $i
    sleep 1
done
echo ""
echo ""

# Check CPU load
CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
echo "✅ CPU load: ${CPU_LOAD}%"
echo ""

# Run comprehensive benchmark
echo "▶  Starting comprehensive benchmark..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

bash ./scripts/comprehensive_benchmark.sh

BENCHMARK_EXIT=$?

# Cleanup stress test
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⏹  Stopping background stress test..."
kill $STRESS_PID 2>/dev/null || true
rm -f /tmp/stress_test.pid
echo "✅ Stress test stopped"
echo ""

if [ $BENCHMARK_EXIT -eq 0 ]; then
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                      BENCHMARK COMPLETED SUCCESSFULLY                    ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Results location:"
    LATEST_RESULTS=$(ls -td benchmark_results_* 2>/dev/null | head -1)
    if [ -n "$LATEST_RESULTS" ]; then
        echo "  📂 $LATEST_RESULTS/"
        echo ""
        if [ -d "$LATEST_RESULTS/graphs" ]; then
            echo "Graphs generated:"
            ls "$LATEST_RESULTS/graphs/"*.png 2>/dev/null | while read graph; do
                echo "  📊 $(basename $graph)"
            done
        fi
        echo ""
        echo "Report:"
        echo "  📄 $LATEST_RESULTS/benchmark_report.txt"
    fi
    echo ""
else
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                        BENCHMARK FAILED                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Check the logs for errors"
    exit 1
fi
