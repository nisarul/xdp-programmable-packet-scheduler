#!/usr/bin/env python3
"""
Generate comparison graphs from XDP QoS benchmark results
Creates presentation-ready charts for dissertation/slides
"""

import os
import sys
import glob
import matplotlib.pyplot as plt
import matplotlib
import numpy as np
from pathlib import Path

# Use non-interactive backend for headless systems
matplotlib.use('Agg')

# Set style for professional-looking graphs
plt.style.use('seaborn-v0_8-darkgrid')
plt.rcParams['figure.figsize'] = (12, 8)
plt.rcParams['font.size'] = 11
plt.rcParams['axes.titlesize'] = 14
plt.rcParams['axes.labelsize'] = 12

def parse_result_file(filepath):
    """Parse a result file and return key-value pairs"""
    results = {}
    try:
        with open(filepath, 'r') as f:
            for line in f:
                if ':' in line:
                    key, value = line.strip().split(':', 1)
                    value = value.strip()
                    # Try to convert to float, keep as string if fails
                    try:
                        if value and value != 'N/A':
                            results[key.strip()] = float(value)
                        else:
                            results[key.strip()] = None
                    except ValueError:
                        results[key.strip()] = value
    except FileNotFoundError:
        pass
    return results

def load_benchmark_results(results_dir):
    """Load all benchmark results from directory"""
    methods = ['baseline', 'tc_prio', 'tc_htb', 'xdp_gaming', 'xdp_server', 'xdp_default']
    method_labels = {
        'baseline': 'Baseline\n(No QoS)',
        'tc_prio': 'TC PRIO\n(Traditional)',
        'tc_htb': 'TC HTB\n(Traditional)',
        'xdp_gaming': 'XDP Gaming\n(Strict Priority)',
        'xdp_server': 'XDP Server\n(WFQ)',
        'xdp_default': 'XDP Default\n(DRR)'
    }
    
    data = {}
    for method in methods:
        data[method] = {
            'latency': parse_result_file(f"{results_dir}/{method}.latency"),
            'throughput': parse_result_file(f"{results_dir}/{method}.throughput"),
            'latency_load': parse_result_file(f"{results_dir}/{method}.latency_load"),
            'concurrent': parse_result_file(f"{results_dir}/{method}.concurrent"),
            'cpu': parse_result_file(f"{results_dir}/{method}.cpu"),
        }
    
    return data, method_labels

def create_latency_comparison(data, method_labels, output_dir):
    """Create latency comparison chart"""
    methods = list(data.keys())
    labels = [method_labels[m] for m in methods]
    
    # Extract data
    idle_latencies = [data[m]['latency'].get('avg_latency_ms', 0) or 0 for m in methods]
    loaded_latencies = [data[m]['latency_load'].get('loaded_avg_latency_ms', 0) or 0 for m in methods]
    
    x = np.arange(len(labels))
    width = 0.35
    
    fig, ax = plt.subplots(figsize=(14, 8))
    bars1 = ax.bar(x - width/2, idle_latencies, width, label='Idle (No Load)', color='#2ecc71')
    bars2 = ax.bar(x + width/2, loaded_latencies, width, label='Under Load', color='#e74c3c')
    
    ax.set_ylabel('Latency (ms)', fontweight='bold')
    ax.set_xlabel('QoS Method', fontweight='bold')
    ax.set_title('Latency Comparison: Idle vs Under Load\n(Lower is Better)', fontweight='bold', fontsize=16)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.legend(loc='upper left', fontsize=12)
    ax.grid(axis='y', alpha=0.3)
    
    # Add value labels on bars
    def autolabel(bars):
        for bar in bars:
            height = bar.get_height()
            if height > 0:
                ax.annotate(f'{height:.1f}',
                    xy=(bar.get_x() + bar.get_width() / 2, height),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha='center', va='bottom', fontsize=9)
    
    autolabel(bars1)
    autolabel(bars2)
    
    plt.tight_layout()
    plt.savefig(f"{output_dir}/latency_comparison.png", dpi=300, bbox_inches='tight')
    print(f"✓ Generated: latency_comparison.png")
    plt.close()

def create_bufferbloat_chart(data, method_labels, output_dir):
    """Create bufferbloat mitigation chart"""
    methods = list(data.keys())
    labels = [method_labels[m] for m in methods]
    
    # Calculate latency increase percentage
    increases = []
    for m in methods:
        idle = data[m]['latency'].get('avg_latency_ms', 0) or 0.001
        loaded = data[m]['latency_load'].get('loaded_avg_latency_ms', 0) or 0
        increase_pct = ((loaded - idle) / idle * 100) if idle > 0 else 0
        increases.append(increase_pct)
    
    fig, ax = plt.subplots(figsize=(14, 8))
    
    # Color bars: red for bad, orange for medium, green for good
    colors = []
    for inc in increases:
        if inc > 5000:
            colors.append('#e74c3c')
        elif inc > 1000:
            colors.append('#f39c12')
        else:
            colors.append('#2ecc71')
    
    bars = ax.bar(labels, increases, color=colors, alpha=0.8, edgecolor='black', linewidth=1.5)
    
    ax.set_ylabel('Latency Increase (%)', fontweight='bold')
    ax.set_xlabel('QoS Method', fontweight='bold')
    ax.set_title('Bufferbloat Test: Latency Increase Under Load\n(Lower is Better)', 
                 fontweight='bold', fontsize=16)
    ax.grid(axis='y', alpha=0.3)
    
    # Add value labels
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax.annotate(f'{height:.0f}%',
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, 3),
                textcoords="offset points",
                ha='center', va='bottom', fontsize=10, fontweight='bold')
    
    # Add horizontal line at 1000% as reference
    ax.axhline(y=1000, color='red', linestyle='--', alpha=0.5, label='1000% threshold')
    ax.legend(fontsize=10)
    
    plt.tight_layout()
    plt.savefig(f"{output_dir}/bufferbloat_mitigation.png", dpi=300, bbox_inches='tight')
    print(f"✓ Generated: bufferbloat_mitigation.png")
    plt.close()

def create_concurrent_flows_chart(data, method_labels, output_dir):
    """Create concurrent flows performance chart"""
    methods = list(data.keys())
    labels = [method_labels[m] for m in methods]
    
    # Extract gaming jitter
    jitters = [data[m]['concurrent'].get('gaming_jitter_ms', 0) or 0 for m in methods]
    
    fig, ax = plt.subplots(figsize=(14, 8))
    
    # Color based on jitter quality
    colors = []
    for jitter in jitters:
        if jitter < 5:
            colors.append('#2ecc71')
        elif jitter < 20:
            colors.append('#f39c12')
        else:
            colors.append('#e74c3c')
    
    bars = ax.bar(labels, jitters, color=colors, alpha=0.8, edgecolor='black', linewidth=1.5)
    
    ax.set_ylabel('Gaming Jitter (ms)', fontweight='bold')
    ax.set_xlabel('QoS Method', fontweight='bold')
    ax.set_title('Concurrent Flows: Gaming Performance During Bulk Transfer\n(Lower is Better)', 
                 fontweight='bold', fontsize=16)
    ax.grid(axis='y', alpha=0.3)
    
    # Add value labels
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax.annotate(f'{height:.1f}ms',
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, 3),
                textcoords="offset points",
                ha='center', va='bottom', fontsize=10, fontweight='bold')
    
    # Add quality zones
    max_jitter = max(jitters) if jitters else 100
    ax.axhspan(0, 5, alpha=0.1, color='green', label='Excellent (<5ms)')
    ax.axhspan(5, 20, alpha=0.1, color='orange', label='Acceptable (5-20ms)')
    ax.axhspan(20, max_jitter * 1.1, alpha=0.1, color='red', label='Poor (>20ms)')
    ax.legend(loc='upper right', fontsize=10)
    
    plt.tight_layout()
    plt.savefig(f"{output_dir}/concurrent_flows_performance.png", dpi=300, bbox_inches='tight')
    print(f"✓ Generated: concurrent_flows_performance.png")
    plt.close()

def create_cpu_overhead_chart(data, method_labels, output_dir):
    """Create CPU overhead comparison chart"""
    methods = list(data.keys())
    labels = [method_labels[m] for m in methods]
    
    cpu_overheads = [abs(data[m]['cpu'].get('cpu_overhead_percent', 0) or 0) for m in methods]
    
    fig, ax = plt.subplots(figsize=(14, 8))
    
    # Color based on overhead
    colors = []
    for cpu in cpu_overheads:
        if cpu < 10:
            colors.append('#2ecc71')
        elif cpu < 20:
            colors.append('#f39c12')
        else:
            colors.append('#e74c3c')
    
    bars = ax.bar(labels, cpu_overheads, color=colors, alpha=0.8, edgecolor='black', linewidth=1.5)
    
    ax.set_ylabel('CPU Overhead (%)', fontweight='bold')
    ax.set_xlabel('QoS Method', fontweight='bold')
    ax.set_title('CPU Overhead During Traffic Processing\n(Lower is Better)', 
                 fontweight='bold', fontsize=16)
    ax.grid(axis='y', alpha=0.3)
    
    # Add value labels
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax.annotate(f'{height:.1f}%',
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, 3),
                textcoords="offset points",
                ha='center', va='bottom', fontsize=10, fontweight='bold')
    
    plt.tight_layout()
    plt.savefig(f"{output_dir}/cpu_overhead_comparison.png", dpi=300, bbox_inches='tight')
    print(f"✓ Generated: cpu_overhead_comparison.png")
    plt.close()

def create_throughput_chart(data, method_labels, output_dir):
    """Create throughput comparison chart"""
    methods = list(data.keys())
    labels = [method_labels[m] for m in methods]
    
    throughputs = [data[m]['throughput'].get('throughput_mbps', 0) or 0 for m in methods]
    
    fig, ax = plt.subplots(figsize=(14, 8))
    
    bars = ax.bar(labels, throughputs, color='#3498db', alpha=0.8, edgecolor='black', linewidth=1.5)
    
    ax.set_ylabel('Throughput (Mbps)', fontweight='bold')
    ax.set_xlabel('QoS Method', fontweight='bold')
    ax.set_title('Maximum Throughput Comparison\n(Higher is Better)', 
                 fontweight='bold', fontsize=16)
    ax.grid(axis='y', alpha=0.3)
    
    # Add value labels
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax.annotate(f'{height:.0f}',
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, 3),
                textcoords="offset points",
                ha='center', va='bottom', fontsize=10, fontweight='bold')
    
    # Add reference line at 900 Mbps
    ax.axhline(y=900, color='green', linestyle='--', alpha=0.5, label='900 Mbps (Good)')
    ax.legend(fontsize=10)
    
    plt.tight_layout()
    plt.savefig(f"{output_dir}/throughput_comparison.png", dpi=300, bbox_inches='tight')
    print(f"✓ Generated: throughput_comparison.png")
    plt.close()

def create_summary_comparison(data, method_labels, output_dir):
    """Create a comprehensive summary comparison chart"""
    methods = list(data.keys())
    labels = [method_labels[m] for m in methods]
    
    # Normalize metrics to 0-100 scale
    loaded_latencies = [data[m]['latency_load'].get('loaded_avg_latency_ms', 0) or 0 for m in methods]
    gaming_jitters = [data[m]['concurrent'].get('gaming_jitter_ms', 0) or 0 for m in methods]
    cpu_overheads = [abs(data[m]['cpu'].get('cpu_overhead_percent', 0) or 0) for m in methods]
    
    # Invert and normalize
    def normalize_inverse(values):
        max_val = max(values) if max(values) > 0 else 1
        return [100 - (v / max_val * 100) for v in values]
    
    norm_latency = normalize_inverse(loaded_latencies)
    norm_jitter = normalize_inverse(gaming_jitters)
    norm_cpu = normalize_inverse(cpu_overheads)
    
    # Create grouped bar chart
    x = np.arange(len(labels))
    width = 0.25
    
    fig, ax = plt.subplots(figsize=(16, 9))
    
    bars1 = ax.bar(x - width, norm_latency, width, label='Latency Score', color='#3498db')
    bars2 = ax.bar(x, norm_jitter, width, label='Gaming Performance', color='#2ecc71')
    bars3 = ax.bar(x + width, norm_cpu, width, label='CPU Efficiency', color='#9b59b6')
    
    ax.set_ylabel('Performance Score (Higher is Better)', fontweight='bold')
    ax.set_xlabel('QoS Method', fontweight='bold')
    ax.set_title('Overall Performance Summary (Normalized Scores)\nHigher Score = Better Performance', 
                 fontweight='bold', fontsize=16)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.legend(fontsize=12, loc='upper left')
    ax.grid(axis='y', alpha=0.3)
    ax.set_ylim(0, 110)
    
    # Add reference line
    ax.axhline(y=80, color='green', linestyle='--', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(f"{output_dir}/summary_comparison.png", dpi=300, bbox_inches='tight')
    print(f"✓ Generated: summary_comparison.png")
    plt.close()

def main():
    if len(sys.argv) < 2:
        # Find the most recent benchmark results directory
        results_dirs = glob.glob("benchmark_results_*")
        if not results_dirs:
            print("Error: No benchmark results found!")
            print("Run: sudo bash scripts/comprehensive_benchmark.sh")
            sys.exit(1)
        results_dir = max(results_dirs, key=os.path.getctime)
        print(f"Using most recent results: {results_dir}")
    else:
        results_dir = sys.argv[1]
    
    if not os.path.exists(results_dir):
        print(f"Error: Results directory not found: {results_dir}")
        sys.exit(1)
    
    # Create graphs subdirectory
    graphs_dir = f"{results_dir}/graphs"
    os.makedirs(graphs_dir, exist_ok=True)
    
    print(f"\n{'='*70}")
    print(f"  Generating Comparison Graphs from Benchmark Results")
    print(f"{'='*70}\n")
    print(f"Results directory: {results_dir}")
    print(f"Graphs directory:  {graphs_dir}\n")
    
    # Load data
    print("Loading benchmark data...")
    data, method_labels = load_benchmark_results(results_dir)
    
    # Generate graphs
    print("\nGenerating graphs...")
    create_latency_comparison(data, method_labels, graphs_dir)
    create_bufferbloat_chart(data, method_labels, graphs_dir)
    create_concurrent_flows_chart(data, method_labels, graphs_dir)
    create_cpu_overhead_chart(data, method_labels, graphs_dir)
    create_throughput_chart(data, method_labels, graphs_dir)
    create_summary_comparison(data, method_labels, graphs_dir)
    
    print(f"\n{'='*70}")
    print(f"✓ All graphs generated successfully!")
    print(f"{'='*70}\n")
    print(f"Graphs saved to: {graphs_dir}/\n")
    print("Generated files:")
    print("  1. latency_comparison.png")
    print("  2. bufferbloat_mitigation.png")
    print("  3. concurrent_flows_performance.png")
    print("  4. cpu_overhead_comparison.png")
    print("  5. throughput_comparison.png")
    print("  6. summary_comparison.png")
    print("\nReady for dissertation/slides (300 DPI)!\n")

if __name__ == "__main__":
    main()
