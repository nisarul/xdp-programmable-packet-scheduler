# Remote Pi Server Requirements for XDP QoS Testing

## Quick Setup (Already Done)

The remote Pi (Toby @ 192.168.5.195) needs:

### ✅ 1. Multiple iperf3 Servers Running

**Already configured!** The following command was run:

```bash
# On remote Pi (Toby)
sudo pkill iperf3
for port in {5201..5210}; do
    iperf3 -s -p $port -D
done
```

**Verify it's working:**
```bash
ssh toby@192.168.5.195 "ss -tlnp | grep iperf3"
```

You should see 10 servers listening on ports 5201-5210.

---

## What This Does

### Without Multiple Servers:
- ❌ Only 1 iperf3 stream possible
- ❌ Can't saturate the link
- ❌ No congestion = no bufferbloat
- ❌ QoS has nothing to demonstrate

### With Multiple Servers:
- ✅ 5+ parallel iperf3 streams possible
- ✅ Can saturate 50Mbps rate limit
- ✅ Creates congestion and bufferbloat
- ✅ QoS benefits become visible!

**Test result:**
```
Without QoS + 5 parallel streams: ~94ms avg latency (bufferbloat!)
With XDP QoS: Should be <10ms (protected!)
```

---

## Making it Permanent

### Option 1: Systemd Service (Recommended)

Create `/etc/systemd/system/iperf3-multi.service` on remote Pi:

```ini
[Unit]
Description=iperf3 Multi-Port Server
After=network.target

[Service]
Type=forking
ExecStartPre=/usr/bin/pkill -9 iperf3
ExecStart=/bin/bash -c 'for port in {5201..5210}; do /usr/bin/iperf3 -s -p $port -D; done'
ExecStop=/usr/bin/pkill -9 iperf3
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable iperf3-multi.service
sudo systemctl start iperf3-multi.service
sudo systemctl status iperf3-multi.service
```

### Option 2: Add to /etc/rc.local

```bash
# Add before "exit 0"
for port in {5201..5210}; do
    /usr/bin/iperf3 -s -p $port -D
done
```

---

## Summary of Remote Pi Setup

| Requirement | Status | Purpose |
|-------------|--------|---------|
| iperf3 installed | ✅ Done | Network throughput testing |
| iperf3 servers on ports 5201-5210 | ✅ Done | Parallel streams for congestion |
| SSH access | ✅ Done | Remote control from Phoenix |
| Network connectivity | ✅ Done | Direct eth0 connection |

---

## Testing the Setup

### From Phoenix Pi:

**Test 1: Single stream (no congestion):**
```bash
iperf3 -c 192.168.5.195 -t 10
ping -c 10 192.168.5.195
# Expected: Low latency (~0.2ms)
```

**Test 2: Multiple streams (congestion!):**
```bash
for i in {1..5}; do 
    iperf3 -c 192.168.5.195 -t 20 -p $((5200+i)) -b 15M &
done
sleep 2
ping -c 20 192.168.5.195
# Expected: High latency (~90ms) - BUFFERBLOAT!
pkill iperf3
```

**Test 3: With XDP QoS (protection):**
```bash
sudo ./scripts/demo_gaming_protection.sh
# Expected: XDP keeps latency low (<10ms) even during congestion
```

---

## Troubleshooting

### Check if servers are running:
```bash
ssh toby@192.168.5.195 "pgrep -a iperf3"
```

### Restart servers:
```bash
ssh toby@192.168.5.195 "sudo pkill iperf3; for port in {5201..5210}; do iperf3 -s -p \$port -D; done"
```

### Check network connectivity:
```bash
ping -c 5 192.168.5.195
iperf3 -c 192.168.5.195 -t 3
```

---

## Current Status

✅ **Remote Pi is fully configured and ready for testing!**

- 10 iperf3 servers running (ports 5201-5210)
- Tested: 5 parallel streams create 94ms bufferbloat
- Ready for XDP QoS demonstration

You can now run the gaming protection demo:
```bash
sudo ./scripts/demo_gaming_protection.sh
```

It should now show clear XDP benefits! 🚀
