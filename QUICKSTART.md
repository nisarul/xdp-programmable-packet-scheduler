# Quick Start Guide - XDP QoS Scheduler

This guide will help you get the XDP QoS Scheduler running on your Raspberry Pi (phoenix) in under 10 minutes.

## Prerequisites

- Raspberry Pi 4 or compatible system
- Linux kernel 5.4+
- Root/sudo access
- Network connectivity

## Step-by-Step Setup

### 1. Initial Deployment (One-Time Setup)

```bash
cd /home/phoenix/Project/dissertation_new/xdp_qos_scheduler
sudo bash scripts/deploy.sh
```

This script will:
- ✓ Check and install all dependencies
- ✓ Verify kernel support for XDP/eBPF
- ✓ Build all components
- ✓ Set up directories and permissions
- ✓ (Optional) Create systemd service

### 2. Load XDP Program

Choose a configuration profile based on your use case:

#### Option A: Default (Balanced)
```bash
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/default.json
```

#### Option B: Gaming (Low Latency)
```bash
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/gaming.json
```

#### Option C: Server (Fairness)
```bash
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/server.json
```

The program will display statistics every 5 seconds. Leave it running.

### 3. Monitor in Real-Time (New Terminal)

```bash
sudo python3 monitoring/stats_monitor.py
```

You'll see:
- 📊 Overall packet/byte statistics
- 📦 Queue statistics per traffic class
- 🔝 Top 10 active flows
- Real-time data rates

### 4. Test Your Setup

#### On phoenix (192.168.5.196):

```bash
# Simple throughput test
iperf3 -c 192.168.5.195 -t 10

# Test with gaming port (should get high priority)
iperf3 -c 192.168.5.195 -p 27015 -u -b 50M -t 10
```

#### On toby (192.168.5.195):
First, start the iperf3 server:

```bash
iperf3 -s
```

### 5. Run Full Performance Tests

```bash
sudo bash scripts/performance_eval.sh
```

Results will be saved to `./results/` directory.

### 6. Unload When Done

```bash
sudo bin/control_plane -i eth0 -d
```

## Common Commands

### Makefile Shortcuts

```bash
# Build everything
make

# Load with default config
sudo make load

# Monitor statistics
sudo make monitor

# Run tests
sudo make test

# Unload XDP
sudo make unload

# Clean build
make clean
```

### Manual Operations

```bash
# Check if XDP is loaded
ip link show eth0

# View BPF maps
sudo bpftool map show

# View loaded programs
sudo bpftool prog show type xdp

# Dump statistics
sudo bpftool map dump name cpu_stats
sudo bpftool map dump name queue_stats
```

## Traffic Classification Examples

The configurations classify traffic based on:

| Port(s) | Protocol | Class | Priority |
|---------|----------|-------|----------|
| 22 | TCP | Control | Highest |
| 53 | UDP | Control | Highest |
| 27015-27030 | UDP | Gaming | Very High |
| 3478-3479 | UDP | Gaming | Very High |
| 80, 443 | TCP | Web | Medium |
| Others | Any | Default | Low |

## Testing Different Scenarios

### Scenario 1: Gaming Performance
```bash
# Load gaming profile
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/gaming.json

# Generate gaming traffic
iperf3 -c 192.168.5.195 -p 27015 -u -b 30M -t 60
```

### Scenario 2: Multiple Concurrent Flows
```bash
# Load server profile (WFQ)
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/server.json

# Start multiple flows
for i in {1..5}; do
    iperf3 -c 192.168.5.195 -p $((5200+i)) -t 30 &
done
```

### Scenario 3: Rate Limiting Test
```bash
# Gaming profile has rate limits
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/gaming.json

# Try to exceed rate limit (100 Mbps on gaming class)
iperf3 -c 192.168.5.195 -p 27015 -u -b 200M -t 30
```

## Troubleshooting Quick Fixes

### Problem: "Operation not permitted"
```bash
# Run with sudo
sudo <command>
```

### Problem: "Cannot find interface"
```bash
# Check available interfaces
ip link show

# Use correct interface name
sudo bin/control_plane -i <your_interface> ...
```

### Problem: "Maps not found"
```bash
# Ensure BPF filesystem is mounted
sudo mount -t bpf bpf /sys/fs/bpf

# Create directory
sudo mkdir -p /sys/fs/bpf/xdp_qos
```

### Problem: Build errors
```bash
# Install dependencies
sudo apt update
sudo apt install -y build-essential clang libbpf-dev linux-headers-$(uname -r)

# Rebuild
make clean && make
```

### Problem: XDP already attached
```bash
# Force remove existing XDP
sudo ip link set dev eth0 xdp off

# Try loading again
sudo bin/control_plane -i eth0 -x build/xdp_scheduler.o -c configs/default.json
```

## Next Steps

1. **Customize Configuration**: Edit JSON files in `configs/` to match your needs
2. **Analyze Results**: Review performance test results in `./results/`
3. **Monitor Long-term**: Set up systemd service for automatic loading
4. **Optimize**: Adjust weights, priorities, and rate limits based on your traffic

## Performance Tips

1. **Use the right scheduler**:
   - Gaming/Real-time: Strict Priority
   - Mixed workloads: WFQ or DRR
   - Fair sharing: Round Robin

2. **Tune rate limits**:
   - Set burst_size to 1-2 seconds of traffic at rate_limit
   - Use min_bandwidth for guarantees

3. **Monitor regularly**:
   - Check drop rates in each class
   - Verify fairness across flows
   - Measure latency under load

## Getting Help

- Check `README.md` for detailed documentation
- View kernel logs: `sudo dmesg | grep -i xdp`
- Enable debug: Uncomment debug prints in source and rebuild
- View trace: `sudo cat /sys/kernel/debug/tracing/trace_pipe`

---

**Happy scheduling! 🚀**
