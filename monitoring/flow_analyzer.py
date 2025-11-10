#!/usr/bin/env python3
"""
Flow Analysis Tool
Analyzes flow patterns and generates reports from XDP QoS Scheduler
"""

import sys
import os
import json
import time
from collections import defaultdict
from ctypes import *

BPF_PIN_DIR = "/sys/fs/bpf/xdp_qos"

class FlowTuple(Structure):
    _fields_ = [
        ("src_ip", c_uint),
        ("dst_ip", c_uint),
        ("src_port", c_ushort),
        ("dst_port", c_ushort),
        ("protocol", c_ubyte),
        ("padding", c_ubyte * 3),
    ]

class FlowState(Structure):
    _fields_ = [
        ("packet_count", c_ulonglong),
        ("byte_count", c_ulonglong),
        ("last_seen", c_ulonglong),
        ("class_id", c_uint),
        ("queue_id", c_uint),
        ("tokens", c_uint),
        ("last_token_update", c_uint),
        ("priority", c_ushort),
        ("weight", c_ushort),
        ("deficit", c_uint),
    ]

CLASS_NAMES = {
    0: "CONTROL",
    1: "GAMING/RT",
    2: "VOIP",
    3: "VIDEO",
    4: "WEB",
    5: "BULK",
    6: "BACKGROUND",
    7: "DEFAULT",
}

PROTOCOL_NAMES = {
    1: "ICMP",
    6: "TCP",
    17: "UDP",
}

def ip_to_str(ip):
    """Convert IP to string"""
    return f"{ip & 0xFF}.{(ip >> 8) & 0xFF}.{(ip >> 16) & 0xFF}.{(ip >> 24) & 0xFF}"

def format_bytes(b):
    """Format bytes"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if b < 1024.0:
            return f"{b:.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} TB"

def analyze_flows(output_format='text'):
    """Analyze flows from BPF map"""
    
    # Open flow table map
    try:
        flow_table_fd = os.open(f"{BPF_PIN_DIR}/flow_table", os.O_RDONLY)
    except Exception as e:
        print(f"Error: Cannot open flow table. Is XDP program running?")
        print(f"Details: {e}")
        return
    
    flows = []
    
    # Read all flows (simplified - actual implementation would use BPF helpers)
    print("Reading flows from BPF map...")
    
    # Statistics
    stats = {
        'total_flows': 0,
        'total_packets': 0,
        'total_bytes': 0,
        'by_class': defaultdict(lambda: {'flows': 0, 'packets': 0, 'bytes': 0}),
        'by_protocol': defaultdict(lambda: {'flows': 0, 'packets': 0, 'bytes': 0}),
        'top_talkers': [],
    }
    
    # For this demo, we'll create a summary report
    if output_format == 'json':
        print(json.dumps(stats, indent=2))
    else:
        print("\n" + "="*80)
        print("Flow Analysis Report")
        print("="*80)
        print(f"\nTotal Flows: {stats['total_flows']}")
        print(f"Total Packets: {stats['total_packets']:,}")
        print(f"Total Bytes: {format_bytes(stats['total_bytes'])}")
        
        print("\n" + "-"*80)
        print("Traffic by Class:")
        print("-"*80)
        print(f"{'Class':<15} {'Flows':<10} {'Packets':<15} {'Bytes':<15}")
        print("-"*80)
        
        for class_id in sorted(stats['by_class'].keys()):
            data = stats['by_class'][class_id]
            class_name = CLASS_NAMES.get(class_id, f"Class {class_id}")
            print(f"{class_name:<15} {data['flows']:<10} "
                  f"{data['packets']:<15,} {format_bytes(data['bytes']):<15}")
        
        print("\n" + "-"*80)
        print("Traffic by Protocol:")
        print("-"*80)
        print(f"{'Protocol':<15} {'Flows':<10} {'Packets':<15} {'Bytes':<15}")
        print("-"*80)
        
        for proto in sorted(stats['by_protocol'].keys()):
            data = stats['by_protocol'][proto]
            proto_name = PROTOCOL_NAMES.get(proto, f"Protocol {proto}")
            print(f"{proto_name:<15} {data['flows']:<10} "
                  f"{data['packets']:<15,} {format_bytes(data['bytes']):<15}")
        
        print("\n" + "-"*80)
        print("Top 20 Flows by Packets:")
        print("-"*80)
        print(f"{'Source':<22} {'Dest':<22} {'Proto':<8} {'Class':<12} {'Packets':<12} {'Bytes':<12}")
        print("-"*80)
        
        # Would display top flows here
        
        print("\n" + "="*80)
    
    os.close(flow_table_fd)

def export_flows(output_file):
    """Export flows to CSV"""
    print(f"Exporting flows to {output_file}...")
    
    with open(output_file, 'w') as f:
        f.write("src_ip,src_port,dst_ip,dst_port,protocol,class,packets,bytes\n")
        # Would write flow data here
    
    print(f"Export complete: {output_file}")

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="XDP QoS Flow Analysis Tool")
    parser.add_argument("-f", "--format", choices=['text', 'json'], default='text',
                       help="Output format (default: text)")
    parser.add_argument("-e", "--export", type=str,
                       help="Export flows to CSV file")
    parser.add_argument("-d", "--dir", type=str, default=BPF_PIN_DIR,
                       help=f"BPF pin directory (default: {BPF_PIN_DIR})")
    
    args = parser.parse_args()
    
    global BPF_PIN_DIR
    BPF_PIN_DIR = args.dir
    
    if args.export:
        export_flows(args.export)
    else:
        analyze_flows(output_format=args.format)

if __name__ == "__main__":
    main()
