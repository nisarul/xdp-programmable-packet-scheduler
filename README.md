# XDP QoS Scheduler - Programmable Packet Scheduling using XDP/eBPF

A high-performance, programmable packet scheduling framework implemented in the Linux kernel using XDP (eXpress Data Path) and eBPF (extended Berkeley Packet Filter). This system enables Quality of Service (QoS) enforcement through traffic classification, scheduling, and shaping entirely in kernel space for minimal latency and maximum throughput.

## 🎯 Project Overview

This dissertation project implements a complete QoS framework that:

- **Classifies packets** based on 5-tuple flow information (src/dst IP, src/dst port, protocol)
- **Schedules traffic** using multiple algorithms (RR, WFQ, SP, DRR, PIFO)
- **Enforces rate limits** using token bucket algorithms
- **Operates in kernel space** for minimal overhead
- **Provides runtime configuration** via JSON profiles
- **Monitors performance** with detailed statistics

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Network Interface (eth0)                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  XDP Packet Classifier                       │
│  - Parse headers (Ethernet, IPv4, TCP/UDP, ICMP)           │
│  - Extract 5-tuple flow information                         │
│  - Classify into traffic classes                            │
│  - Token bucket rate limiting                               │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                   TC eBPF Scheduler                          │
│  - Round Robin (RR)                                          │
│  - Weighted Fair Queuing (WFQ)                              │
│  - Strict Priority (SP)                                      │
│  - Deficit Round Robin (DRR)                                │
│  - Push-In First-Out (PIFO)                                 │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    Network Stack                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              User-Space Control Plane                        │
│  - Load/unload programs                                      │
│  - Configure policies from JSON                              │
│  - Runtime updates                                           │
│  - Statistics monitoring                                     │
└─────────────────────────────────────────────────────────────┘
```

## 📋 Features

### Traffic Classification
- **Protocol-based**: TCP, UDP, ICMP
- **Port-based**: Source and destination port ranges
- **IP-based**: Source and destination IP addresses with masks
- **Priority-based**: Configurable rule priorities

### Scheduling Algorithms
1. **Round Robin (RR)**: Equal distribution across queues
2. **Weighted Fair Queuing (WFQ)**: Bandwidth allocation based on weights
3. **Strict Priority (SP)**: High-priority traffic first
4. **Deficit Round Robin (DRR)**: Fair queuing with quantum-based scheduling
5. **PIFO**: Programmable scheduling with custom ranks

### QoS Enforcement
- **Token Bucket Rate Limiting**: Per-class bandwidth caps
- **Burst Control**: Configurable burst sizes
- **Bandwidth Guarantees**: Minimum and maximum bandwidth per class
- **Traffic Shaping**: Smooth traffic flow

### Monitoring & Statistics
- **Per-CPU Statistics**: Total packets, bytes, classifications, drops
- **Queue Statistics**: Enqueue/dequeue/drop counts per class
- **Flow Tracking**: Per-flow packet and byte counters
- **Latency Metrics**: Average latency per traffic class
- **Real-time Monitoring**: Live statistics dashboard

## 🚀 Getting Started

### Prerequisites

#### System Requirements
- **Hardware**: Raspberry Pi 4 or compatible ARM64/x86_64 system
- **OS**: Linux kernel 5.4+ with BPF/XDP support
- **Network**: Two systems for testing (phoenix: 192.168.5.196, toby: 192.168.5.195)

#### Required Packages

On **Raspberry Pi OS** or **Ubuntu**:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install build tools
sudo apt install -y \
    build-essential \
    clang \
    llvm \
    gcc \
    make \
    pkg-config

# Install BPF/XDP libraries
sudo apt install -y \
    libbpf-dev \
    linux-headers-$(uname -r) \
    bpftool

# Install dependencies
sudo apt install -y \
    libelf-dev \
    zlib1g-dev \
    libjson-c-dev

# Install testing tools
sudo apt install -y \
    iperf3 \
    tcpreplay \
    python3-pip \
    python3-bcc

# Optional: ePPing for latency measurement
git clone https://github.com/xdp-project/bpf-examples.git
cd bpf-examples/pping
make && sudo make install
```

### Installation

1. **Clone or navigate to the project directory**:
```bash
cd /home/phoenix/Project/dissertation_new/xdp_qos_scheduler
```

2. **Check dependencies**:
```bash
make check-deps
```

3. **Build the project**:
```bash
make
```

4. **Install system-wide** (optional):
```bash
sudo make install
```

## 📖 Usage

### Basic Usage

#### 1. Load XDP Program with Default Configuration

```bash
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/default.json
```

**Options**:
- `-i, --interface`: Network interface (default: eth0)
- `-x, --xdp`: XDP object file
- `-c, --config`: Configuration JSON file
- `-s, --stats`: Statistics interval in seconds

#### 2. Monitor Live Statistics

In another terminal:

```bash
sudo python3 monitoring/stats_monitor.py
```

Or use the Makefile:

```bash
sudo make monitor
```

#### 3. Unload XDP Program

```bash
sudo bin/control_plane -i eth0 -d
```

Or use the Makefile:

```bash
sudo make unload
```

### Configuration Profiles

Three pre-configured profiles are included:

#### 1. **Gaming Profile** (`configs/gaming.json`)
- **Scheduler**: Strict Priority
- **Optimized for**: Low-latency gaming, VoIP
- **Classes**: Gaming (highest), VoIP, Video, Web, Bulk

```bash
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/gaming.json
```

#### 2. **Server Profile** (`configs/server.json`)
- **Scheduler**: Weighted Fair Queuing
- **Optimized for**: Server workloads, databases, web services
- **Classes**: Database, Web Services, Interactive, File Transfer

```bash
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/server.json
```

#### 3. **Default Profile** (`configs/default.json`)
- **Scheduler**: Deficit Round Robin
- **Optimized for**: General-purpose balanced traffic
- **Classes**: Real-time, VoIP, Video, Web, Bulk

### Creating Custom Configurations

Create a JSON configuration file with the following structure:

```json
{
  "profile": "custom",
  "description": "Custom QoS configuration",
  
  "global": {
    "scheduler": "wfq",
    "default_class": 7,
    "quantum": 1500
  },
  
  "classes": [
    {
      "id": 0,
      "name": "high_priority",
      "rate_limit": 104857600,
      "burst_size": 1048576,
      "priority": 0,
      "weight": 200,
      "min_bandwidth": 52428800,
      "max_bandwidth": 104857600
    }
  ],
  
  "rules": [
    {
      "comment": "SSH traffic",
      "protocol": "tcp",
      "dst_port_min": 22,
      "dst_port_max": 22,
      "class_id": 0,
      "priority": 100
    }
  ]
}
```

**Scheduler Options**:
- `round_robin`: Equal distribution
- `wfq`: Weighted Fair Queuing
- `strict_priority`: Priority-based
- `drr`: Deficit Round Robin
- `pifo`: Programmable scheduling

## 🧪 Performance Evaluation

### Running Tests

The project includes a comprehensive performance evaluation script:

```bash
sudo bash scripts/performance_eval.sh
```

This script runs:

1. **Baseline Tests** (Traditional Linux stack)
2. **XDP-Only Tests** (XDP processing)
3. **XDP + TC Hybrid Tests** (Full scheduling)
4. **Fairness Tests** (Multiple flows)
5. **Rate Limiting Tests** (QoS enforcement)

Results are saved to `./results/` directory.

### Manual Testing

#### Test Throughput with iperf3

On **toby** (192.168.5.195):
```bash
iperf3 -s -p 5201
```

On **phoenix** (192.168.5.196):
```bash
# TCP test
iperf3 -c 192.168.5.195 -p 5201 -t 10

# UDP test with 100 Mbps
iperf3 -c 192.168.5.195 -p 5201 -u -b 100M -t 10
```

#### Test Latency with ping

```bash
# Small packets
ping -c 100 -s 64 192.168.5.195

# Large packets
ping -c 100 -s 1400 192.168.5.195
```

#### Test with Multiple Traffic Classes

```bash
# Gaming traffic (UDP, port 27015)
iperf3 -c 192.168.5.195 -p 27015 -u -b 50M -t 30 &

# Web traffic (TCP, port 443)
iperf3 -c 192.168.5.195 -p 443 -t 30 &

# Bulk traffic (TCP, port 8080)
iperf3 -c 192.168.5.195 -p 8080 -t 30 &
```

## 📊 Monitoring

### Real-time Statistics Dashboard

```bash
sudo python3 monitoring/stats_monitor.py -i 1
```

Shows:
- Overall packet/byte counts
- Per-class queue statistics
- Top flows by packet count
- Data rates and latency

### BPF Tools

#### View BPF Maps

```bash
# List all maps
sudo bpftool map show

# Dump CPU statistics
sudo bpftool map dump name cpu_stats

# Dump queue statistics
sudo bpftool map dump name queue_stats

# Dump flow table
sudo bpftool map dump name flow_table
```

#### View Loaded Programs

```bash
# List XDP programs
sudo bpftool prog show type xdp

# List TC programs
sudo bpftool prog show type sched_cls
```

### System Statistics

```bash
# Interface statistics
ip -s link show eth0

# TC statistics (if TC program loaded)
sudo tc -s qdisc show dev eth0
```

## 🔧 Troubleshooting

### Common Issues

#### 1. XDP Program Won't Load

**Error**: `Error attaching XDP program`

**Solutions**:
```bash
# Check if XDP is already attached
sudo ip link show eth0

# Force detach existing XDP program
sudo ip link set dev eth0 xdp off

# Check interface supports XDP
ethtool -i eth0
```

#### 2. Permission Denied

**Error**: `Operation not permitted`

**Solution**: Run with sudo or as root
```bash
sudo bin/control_plane ...
```

#### 3. Maps Not Found

**Error**: `Error getting map file descriptors`

**Solutions**:
```bash
# Ensure BPF filesystem is mounted
sudo mount -t bpf bpf /sys/fs/bpf

# Create pin directory
sudo mkdir -p /sys/fs/bpf/xdp_qos
```

#### 4. Missing Dependencies

```bash
# Check what's missing
make check-deps

# Install missing packages
sudo apt install libbpf-dev linux-headers-$(uname -r)
```

### Debug Mode

Enable debug output in XDP program by uncommenting debug prints in `xdp_scheduler.c` and rebuilding:

```bash
make clean && make
```

View debug output:
```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe
```

## 📁 Project Structure

```
xdp_qos_scheduler/
├── src/
│   ├── xdp/
│   │   └── xdp_scheduler.c       # XDP packet classifier
│   ├── tc/
│   │   └── tc_scheduler.c        # TC scheduling algorithms
│   ├── control/
│   │   └── control_plane.c       # User-space control plane
│   └── common/
│       ├── common.h              # Shared data structures
│       └── bpf_helpers.h         # BPF helper functions
├── configs/
│   ├── default.json              # Default configuration
│   ├── gaming.json               # Gaming-optimized config
│   └── server.json               # Server-optimized config
├── scripts/
│   └── performance_eval.sh       # Performance testing script
├── monitoring/
│   └── stats_monitor.py          # Statistics monitor
├── Makefile                      # Build system
└── README.md                     # This file
```

## 🎓 Research & Development

### Key Metrics to Measure

1. **Throughput**: Bits per second
2. **Latency**: Round-trip time (RTT)
3. **Packet Loss**: Dropped packets percentage
4. **CPU Usage**: Processing overhead
5. **Fairness**: Bandwidth distribution across flows
6. **QoS Compliance**: Rate limit adherence

### Experimental Setup

- **Phoenix** (192.168.5.196): XDP scheduler enabled
- **Toby** (192.168.5.195): Traffic generator/receiver
- **Tools**: iperf3, tcpreplay, ePPing, bpftrace

### Comparison Points

1. Traditional Linux stack (no XDP)
2. XDP-only processing
3. XDP + TC hybrid scheduling
4. Different scheduling algorithms
5. Various traffic patterns

## 📚 References

- [XDP Tutorial](https://github.com/xdp-project/xdp-tutorial)
- [Linux BPF Documentation](https://www.kernel.org/doc/html/latest/bpf/)
- [libbpf Documentation](https://libbpf.readthedocs.io/)
- [TC Documentation](https://man7.org/linux/man-pages/man8/tc.8.html)

## 📝 License

This project is developed for academic purposes as part of a dissertation on programmable packet scheduling.

## 👤 Author

**Phoenix**
- System: Raspberry Pi (phoenix @ 192.168.5.196)
- Project: Dissertation - Programmable Packet Scheduling and QoS using XDP/eBPF

## 🤝 Contributing

This is a dissertation project. For questions or suggestions, please contact the author.

---

**Last Updated**: November 7, 2025
