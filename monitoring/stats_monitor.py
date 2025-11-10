#!/usr/bin/env python3
"""
XDP QoS Scheduler - Statistics Monitor
Monitors and displays real-time statistics from the XDP/TC scheduler
"""

import sys
import time
import os
import json
from bcc import BPF
from ctypes import *

# Map paths
BPF_PIN_DIR = "/sys/fs/bpf/xdp_qos"

class CPUStats(Structure):
    _fields_ = [
        ("total_packets", c_ulonglong),
        ("total_bytes", c_ulonglong),
        ("classified_packets", c_ulonglong),
        ("dropped_packets", c_ulonglong),
        ("xdp_pass", c_ulonglong),
        ("xdp_drop", c_ulonglong),
        ("xdp_tx", c_ulonglong),
        ("xdp_redirect", c_ulonglong),
    ]

class QueueStats(Structure):
    _fields_ = [
        ("enqueued_packets", c_ulonglong),
        ("enqueued_bytes", c_ulonglong),
        ("dequeued_packets", c_ulonglong),
        ("dequeued_bytes", c_ulonglong),
        ("dropped_packets", c_ulonglong),
        ("dropped_bytes", c_ulonglong),
        ("current_qlen", c_uint),
        ("max_qlen", c_uint),
        ("total_latency_ns", c_ulonglong),
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

class FlowTuple(Structure):
    _fields_ = [
        ("src_ip", c_uint),
        ("dst_ip", c_uint),
        ("src_port", c_ushort),
        ("dst_port", c_ushort),
        ("protocol", c_ubyte),
        ("padding", c_ubyte * 3),
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

def format_bytes(bytes):
    """Format bytes into human-readable string"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes < 1024.0:
            return f"{bytes:.2f} {unit}"
        bytes /= 1024.0
    return f"{bytes:.2f} PB"

def format_rate(bytes, interval):
    """Format data rate in bps"""
    bits = bytes * 8
    rate = bits / interval if interval > 0 else 0
    
    for unit in ['bps', 'Kbps', 'Mbps', 'Gbps']:
        if rate < 1000.0:
            return f"{rate:.2f} {unit}"
        rate /= 1000.0
    return f"{rate:.2f} Tbps"

def ip_to_str(ip):
    """Convert IP address to string"""
    return f"{ip & 0xFF}.{(ip >> 8) & 0xFF}.{(ip >> 16) & 0xFF}.{(ip >> 24) & 0xFF}"

def protocol_to_str(proto):
    """Convert protocol number to string"""
    protos = {1: "ICMP", 6: "TCP", 17: "UDP"}
    return protos.get(proto, str(proto))

class StatsMonitor:
    def __init__(self, pin_dir=BPF_PIN_DIR):
        self.pin_dir = pin_dir
        self.prev_stats = {}
        self.prev_time = time.time()
        
    def load_maps(self):
        """Load pinned BPF maps"""
        try:
            self.cpu_stats_fd = os.open(f"{self.pin_dir}/cpu_stats", os.O_RDONLY)
            self.queue_stats_fd = os.open(f"{self.pin_dir}/queue_stats", os.O_RDONLY)
            self.flow_table_fd = os.open(f"{self.pin_dir}/flow_table", os.O_RDONLY)
            return True
        except Exception as e:
            print(f"Error loading maps: {e}")
            return False
    
    def read_cpu_stats(self):
        """Read CPU statistics"""
        stats = CPUStats()
        key = c_uint(0)
        
        try:
            BPF.lookup_elem(self.cpu_stats_fd, byref(key), byref(stats))
            return stats
        except:
            return None
    
    def read_queue_stats(self):
        """Read queue statistics for all classes"""
        stats_map = {}
        
        for class_id in range(8):
            key = c_uint(class_id)
            stats = QueueStats()
            
            try:
                BPF.lookup_elem(self.queue_stats_fd, byref(key), byref(stats))
                stats_map[class_id] = stats
            except:
                continue
        
        return stats_map
    
    def read_flows(self, max_flows=100):
        """Read top flows from flow table"""
        flows = []
        
        try:
            # Iterate through flow table
            key = FlowTuple()
            next_key = FlowTuple()
            value = FlowState()
            
            # Get first key
            ret = BPF.get_first_key(self.flow_table_fd, byref(next_key))
            if ret < 0:
                return flows
            
            count = 0
            while count < max_flows:
                key = next_key
                
                # Lookup value
                try:
                    BPF.lookup_elem(self.flow_table_fd, byref(key), byref(value))
                    flows.append((key, value))
                except:
                    pass
                
                # Get next key
                ret = BPF.get_next_key(self.flow_table_fd, byref(key), byref(next_key))
                if ret < 0:
                    break
                
                count += 1
        except Exception as e:
            print(f"Error reading flows: {e}")
        
        # Sort by packet count
        flows.sort(key=lambda x: x[1].packet_count, reverse=True)
        return flows[:max_flows]
    
    def display_stats(self, interval=1):
        """Display statistics"""
        current_time = time.time()
        time_delta = current_time - self.prev_time
        
        # Clear screen
        os.system('clear')
        
        print("=" * 80)
        print("XDP QoS Scheduler - Live Statistics")
        print("=" * 80)
        print()
        
        # CPU Statistics
        cpu_stats = self.read_cpu_stats()
        if cpu_stats:
            print("📊 Overall Statistics:")
            print(f"  Total Packets:      {cpu_stats.total_packets:,}")
            print(f"  Total Bytes:        {format_bytes(cpu_stats.total_bytes)}")
            print(f"  Classified:         {cpu_stats.classified_packets:,}")
            print(f"  Dropped:            {cpu_stats.dropped_packets:,}")
            
            # Calculate rates
            prev = self.prev_stats.get('cpu', cpu_stats)
            pkt_rate = (cpu_stats.total_packets - prev.total_packets) / time_delta
            byte_rate = (cpu_stats.total_bytes - prev.total_bytes) / time_delta
            
            print(f"  Packet Rate:        {pkt_rate:.2f} pps")
            print(f"  Data Rate:          {format_rate(byte_rate, 1)}")
            
            print()
            print("  XDP Actions:")
            print(f"    PASS:     {cpu_stats.xdp_pass:,}")
            print(f"    DROP:     {cpu_stats.xdp_drop:,}")
            print(f"    TX:       {cpu_stats.xdp_tx:,}")
            print(f"    REDIRECT: {cpu_stats.xdp_redirect:,}")
            
            self.prev_stats['cpu'] = cpu_stats
        
        print()
        print("-" * 80)
        
        # Queue Statistics
        queue_stats = self.read_queue_stats()
        if queue_stats:
            print()
            print("📦 Queue Statistics by Traffic Class:")
            print()
            print(f"{'Class':<15} {'Enqueued':<15} {'Dequeued':<15} {'Dropped':<12} {'Rate':<12}")
            print("-" * 80)
            
            for class_id, stats in sorted(queue_stats.items()):
                if stats.enqueued_packets > 0:
                    class_name = CLASS_NAMES.get(class_id, f"Class {class_id}")
                    
                    # Calculate rate
                    prev = self.prev_stats.get(f'queue_{class_id}', stats)
                    byte_delta = stats.enqueued_bytes - prev.enqueued_bytes
                    rate = format_rate(byte_delta, time_delta)
                    
                    drop_pct = 0
                    if stats.enqueued_packets > 0:
                        drop_pct = (stats.dropped_packets / stats.enqueued_packets) * 100
                    
                    print(f"{class_name:<15} {stats.enqueued_packets:<15,} "
                          f"{stats.dequeued_packets:<15,} "
                          f"{stats.dropped_packets:<12,} {rate:<12}")
                    
                    if stats.dequeued_packets > 0:
                        avg_latency = stats.total_latency_ns / stats.dequeued_packets
                        print(f"  └─ Avg Latency: {avg_latency/1000:.2f} μs, "
                              f"Drop Rate: {drop_pct:.2f}%")
                    
                    self.prev_stats[f'queue_{class_id}'] = stats
        
        print()
        print("-" * 80)
        
        # Top Flows
        flows = self.read_flows(max_flows=10)
        if flows:
            print()
            print("🔝 Top 10 Flows:")
            print()
            print(f"{'Source':<22} {'Dest':<22} {'Proto':<8} {'Class':<12} {'Packets':<12}")
            print("-" * 80)
            
            for flow_tuple, flow_state in flows:
                src = f"{ip_to_str(flow_tuple.src_ip)}:{flow_tuple.src_port}"
                dst = f"{ip_to_str(flow_tuple.dst_ip)}:{flow_tuple.dst_port}"
                proto = protocol_to_str(flow_tuple.protocol)
                class_name = CLASS_NAMES.get(flow_state.class_id, str(flow_state.class_id))
                
                print(f"{src:<22} {dst:<22} {proto:<8} {class_name:<12} "
                      f"{flow_state.packet_count:<12,}")
        
        print()
        print("=" * 80)
        print(f"Updated: {time.strftime('%Y-%m-%d %H:%M:%S')} | "
              f"Press Ctrl+C to exit")
        
        self.prev_time = current_time
    
    def run(self, interval=1):
        """Main monitoring loop"""
        if not self.load_maps():
            print("Failed to load BPF maps. Is the XDP program running?")
            return
        
        print("Starting statistics monitor...")
        print(f"Refresh interval: {interval} second(s)")
        print()
        
        try:
            while True:
                self.display_stats(interval)
                time.sleep(interval)
        except KeyboardInterrupt:
            print("\n\nMonitoring stopped.")
        finally:
            os.close(self.cpu_stats_fd)
            os.close(self.queue_stats_fd)
            os.close(self.flow_table_fd)

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="XDP QoS Scheduler Statistics Monitor")
    parser.add_argument("-i", "--interval", type=int, default=1,
                       help="Refresh interval in seconds (default: 1)")
    parser.add_argument("-d", "--dir", type=str, default=BPF_PIN_DIR,
                       help=f"BPF pin directory (default: {BPF_PIN_DIR})")
    
    args = parser.parse_args()
    
    monitor = StatsMonitor(pin_dir=args.dir)
    monitor.run(interval=args.interval)

if __name__ == "__main__":
    main()
