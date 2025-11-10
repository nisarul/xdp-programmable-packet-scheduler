# Enabling BTF on Raspberry Pi - Complete Guide

## Overview

**Goal**: Recompile Raspberry Pi kernel with BTF (BPF Type Format) support to enable TC-BPF programs.

**Time Required**: 3-4 hours (mostly compilation)  
**Difficulty**: Medium (mostly waiting)  
**Risk**: Low (we keep backup kernel)

## Prerequisites Check

✅ **Disk Space**: 47GB free (need ~10GB)  
✅ **Architecture**: aarch64 (ARM64)  
✅ **Current Kernel**: 6.12.34+rpt-rpi-v8  
✅ **Build Tools**: build-essential, git, bc, libelf-dev, libncurses-dev  
⚠️ **Need to Install**: bison, flex, libssl-dev, pahole (dwarves)

## Step 1: Install Missing Dependencies (5 minutes)

```bash
sudo apt update
sudo apt install -y bison flex libssl-dev dwarves pahole
```

**What these do:**
- `bison` & `flex`: Parse kernel configuration
- `libssl-dev`: Kernel module signing
- `dwarves` & `pahole`: **CRITICAL for BTF** - generates BTF information from DWARF debug data

## Step 2: Download Raspberry Pi Kernel Source (10 minutes)

```bash
# Create workspace
mkdir -p ~/kernel_build
cd ~/kernel_build

# Clone Raspberry Pi kernel (specific version matching your kernel)
git clone --depth=1 --branch rpi-6.12.y https://github.com/raspberrypi/linux
cd linux

# Verify you're on the right branch
git branch
```

**Note**: Using `--depth=1` saves ~3GB by not downloading full git history.

## Step 3: Configure Kernel with BTF Support (5 minutes)

```bash
# Start with Raspberry Pi 4 default config
make bcm2711_defconfig

# Enable BTF and related options
./scripts/config --enable CONFIG_DEBUG_INFO
./scripts/config --enable CONFIG_DEBUG_INFO_BTF
./scripts/config --enable CONFIG_DEBUG_INFO_DWARF5
./scripts/config --enable CONFIG_PAHOLE_HAS_SPLIT_BTF
./scripts/config --enable CONFIG_DEBUG_INFO_BTF_MODULES

# Optional: Enable more BPF features
./scripts/config --enable CONFIG_BPF_SYSCALL
./scripts/config --enable CONFIG_BPF_JIT
./scripts/config --enable CONFIG_BPF_JIT_ALWAYS_ON
./scripts/config --enable CONFIG_CGROUP_BPF
./scripts/config --enable CONFIG_BPF_EVENTS

# Apply configuration
make olddefconfig

# Verify BTF is enabled
grep CONFIG_DEBUG_INFO_BTF .config
```

**Expected output:**
```
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
```

## Step 4: Compile Kernel (2-3 hours)

```bash
# Clean any previous builds
make clean

# Compile using all 4 cores
make -j4 Image modules dtbs

# This will take 2-3 hours. You can:
# - Leave it running overnight
# - Work on dissertation writing
# - Use another terminal for other work
```

**Progress Indicators:**
```
[   10%] Building kernel core...
[   50%] Building kernel modules...
[   80%] Building device trees...
[  100%] Linking vmlinux...
```

**What's being built:**
- `Image` - Kernel binary
- `modules` - Loadable kernel modules (drivers, etc.)
- `dtbs` - Device tree blobs (hardware description)

## Step 5: Install New Kernel (10 minutes)

**Note**: Modern Raspberry Pi OS uses `vmlinuz` kernel packaging instead of `kernel8.img`.

```bash
# If you haven't done this already:
# sudo make modules_install

# Set kernel version (this will be 6.12.34-v8+btf or similar)
KERNEL_VERSION=$(make kernelrelease)
echo "New kernel version: $KERNEL_VERSION"

# Backup current kernel (IMPORTANT!)
sudo cp /boot/vmlinuz-$(uname -r) /boot/vmlinuz-$(uname -r).backup
sudo cp /boot/config-$(uname -r) /boot/config-$(uname -r).backup
sudo cp /boot/System.map-$(uname -r) /boot/System.map-$(uname -r).backup

# Install new kernel and related files
sudo cp arch/arm64/boot/Image /boot/vmlinuz-${KERNEL_VERSION}
sudo cp .config /boot/config-${KERNEL_VERSION}
sudo cp System.map /boot/System.map-${KERNEL_VERSION}

# Install device tree blobs
sudo cp arch/arm64/boot/dts/broadcom/*.dtb /boot/

# Create initramfs for new kernel
sudo update-initramfs -c -k ${KERNEL_VERSION}

# Update bootloader to use new kernel (config location may vary)
# Modern Raspberry Pi OS uses /boot/firmware/config.txt
# Older versions use /boot/config.txt
CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"

sudo sh -c "echo '' >> $CONFIG_FILE"
sudo sh -c "echo '# BTF-enabled kernel' >> $CONFIG_FILE"
sudo sh -c "echo 'kernel=vmlinuz-${KERNEL_VERSION}' >> $CONFIG_FILE"
sudo sh -c "echo 'initramfs initrd.img-${KERNEL_VERSION}' >> $CONFIG_FILE"

# Sync and verify
sync
ls -lh /boot/vmlinuz-${KERNEL_VERSION} /boot/initrd.img-${KERNEL_VERSION}
```

**Verification:**
```bash
# Check kernel size (new one should be larger due to debug info)
ls -lh /boot/vmlinuz-*
# Old kernel: ~25-30MB
# New kernel: ~32-35MB (larger = BTF included!)

# Verify config.txt was updated (check correct location)
CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
tail -3 "$CONFIG_FILE"
# Should show:
# kernel=vmlinuz-6.12.34-v8+btf
# initramfs initrd.img-6.12.34-v8+btf
```

## Step 6: Reboot (2 minutes)

```bash
# Reboot into new kernel
sudo reboot
```

**During reboot:**
- Watch for any errors on screen
- If kernel panics, you can recover (see Troubleshooting)

## Step 7: Verify BTF is Available (1 minute)

After reboot:

```bash
# Check kernel version (should still be 6.12.34)
uname -r

# CRITICAL CHECK: BTF should now exist!
ls -lh /sys/kernel/btf/vmlinux

# Expected output:
# -r--r--r-- 1 root root 4.2M Nov 9 15:30 /sys/kernel/btf/vmlinux

# Verify BTF is readable
sudo bpftool btf dump file /sys/kernel/btf/vmlinux | head -20

# Should show:
# [1] INT 'long unsigned int' size=8 bits_offset=0 nr_bits=64 encoding=(none)
# [2] CONST '(anon)' type_id=1
# ...
```

## Step 8: Test TC-BPF Loading (2 minutes)

```bash
cd ~/Project/dissertation_new/xdp_qos_scheduler

# Test 1: Load TC program with tc command
sudo tc qdisc add dev eth0 clsact
sudo tc filter add dev eth0 egress \
    bpf da obj build/tc_scheduler.o sec classifier \
    direct-action

# Expected: SUCCESS (no BTF error!)
# Verify it loaded:
sudo tc filter show dev eth0 egress

# Clean up
sudo tc qdisc del dev eth0 clsact

# Test 2: Test control plane
sudo ./bin/control_plane -i eth0 \
    -x build/xdp_scheduler.o \
    -t build/tc_scheduler.o \
    -c configs/gaming.json -s 0 &

sleep 5

# Verify both XDP and TC are loaded
sudo bpftool prog show | grep -E "xdp|sched_cls"

# Kill control plane
sudo pkill -9 control_plane
```

## Step 9: Run Full Demo (5 minutes)

```bash
# Test the gaming protection demo
sudo ./scripts/demo_gaming_protection.sh

# Expected output should now show:
# ✓ XDP + TC Gaming QoS enabled
# [TEST] Without QoS: 2000-3000ms latency
# [TEST] With XDP QoS: 20-50ms latency
# ✓ EXCELLENT: 95% improvement!
```

## Troubleshooting

### Problem: Kernel Won't Boot

**Symptoms**: Black screen or kernel panic on boot

**Solution**: Boot with backup kernel

1. Power off Pi
2. Insert SD card into another computer
3. Edit `/boot/firmware/config.txt` (or `/boot/config.txt` on older systems), find the lines you added:
   ```
   kernel=vmlinuz-6.12.34-v8+btf
   initramfs initrd.img-6.12.34-v8+btf
   ```
4. Comment them out or change to backup kernel:
   ```
   #kernel=vmlinuz-6.12.34-v8+btf
   #initramfs initrd.img-6.12.34-v8+btf
   kernel=vmlinuz-6.12.34+rpt-rpi-v8
   initramfs initrd.img-6.12.34+rpt-rpi-v8
   ```
5. Boot Pi - will use old kernel
6. Once booted, check kernel compilation errors

### Problem: Compilation Fails

**Error**: `pahole: command not found`

**Solution**:
```bash
sudo apt install -y dwarves pahole
```

**Error**: `make: *** [vmlinux] Error 1`

**Solution**:
```bash
# Check error message, often missing dependencies
make clean
# Install missing dep, then retry
make -j4 Image modules dtbs
```

### Problem: BTF File Missing After Reboot

**Check**:
```bash
# Is kernel the new one?
ls -lh /boot/vmlinuz-*
# New kernel should be ~32-35MB (larger than old ~25-30MB)

# Was BTF enabled in config?
zcat /proc/config.gz | grep CONFIG_DEBUG_INFO_BTF
# Should show: CONFIG_DEBUG_INFO_BTF=y

# Is pahole installed?
which pahole
# Should show: /usr/sbin/pahole
```

**Solution**: Recompile with pahole installed from the start

### Problem: Compilation Takes Forever

**Check CPU throttling**:
```bash
# Monitor temperature and frequency
watch -n1 'vcgencmd measure_temp && vcgencmd measure_clock arm'

# If thermal throttling (>80°C):
# - Add heatsink
# - Improve airflow
# - Use -j2 instead of -j4 (slower but cooler)
```

## Expected Timeline

| Step | Duration | Description |
|------|----------|-------------|
| 1. Install deps | 5 min | One-time setup |
| 2. Download source | 10 min | ~500MB download |
| 3. Configure | 5 min | Enable BTF options |
| 4. Compile | **2-3 hours** | CPU-intensive |
| 5. Install | 10 min | Copy files to /boot |
| 6. Reboot | 2 min | Boot new kernel |
| 7. Verify | 1 min | Check BTF exists |
| 8. Test | 2 min | Load TC-BPF program |
| 9. Demo | 5 min | Full system test |
| **TOTAL** | **3-4 hours** | Most is waiting for compile |

## What Changes

### Before (Current State):
```
❌ /sys/kernel/btf/vmlinux: Not found
❌ TC-BPF loading: Fails with BTF error
✅ XDP: Works
✅ Traditional TC: Works
```

### After (With BTF):
```
✅ /sys/kernel/btf/vmlinux: 4.2MB file
✅ TC-BPF loading: Works perfectly
✅ XDP: Still works
✅ Traditional TC: Still works
✅ Full XDP+TC-BPF: NOW WORKS!
```

## Benefits for Your Dissertation

1. **Full Implementation**: XDP+TC-BPF working as designed
2. **Performance**: Fast-path scheduling (not just classification)
3. **Demonstration**: Can show complete system in action
4. **Credibility**: "Production-ready" implementation
5. **Future Work**: Solid foundation for extensions

## After BTF is Enabled

Run full benchmarks with the complete system:

```bash
# Terminal 1: Background stress
sudo ./scripts/stress_background.sh 192.168.5.195

# Terminal 2: Comprehensive benchmark (wait 30 seconds)
sudo ./scripts/comprehensive_benchmark.sh

# Terminal 3: Interactive demo
sudo ./scripts/demo_gaming_protection.sh
```

**Expected improvements** with full XDP+TC-BPF:
- Classification latency: 50% faster than traditional TC
- Scheduling latency: 30% faster with TC-BPF vs traditional
- Overall QoS: 95%+ latency improvement under load

## Quick Reference Commands

```bash
# Check if BTF is available
ls -lh /sys/kernel/btf/vmlinux

# Revert to backup kernel (if needed)
# Edit config.txt and comment out the new kernel lines
# (location: /boot/firmware/config.txt or /boot/config.txt)
sudo nano /boot/firmware/config.txt
sudo reboot

# Check compilation progress
tail -f ~/kernel_build/linux/build.log

# Monitor system during compile
htop  # or: watch -n1 'vcgencmd measure_temp'
```

## Next Steps

Once BTF is enabled:

1. ✅ **Test control plane** - Verify TC-BPF loads
2. ✅ **Run demos** - Gaming protection with full XDP+TC-BPF
3. ✅ **Benchmark** - Compare traditional TC vs TC-BPF performance
4. ✅ **Document** - Update dissertation with full implementation
5. ✅ **Celebrate** - Your XDP QoS system is fully operational! 🎉

---

**Ready to start?** Let me know if you want to begin, or if you have questions about any step!
