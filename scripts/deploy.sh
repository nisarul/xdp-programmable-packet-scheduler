#!/bin/bash
#
# Quick deployment script for XDP QoS Scheduler
# Handles installation and basic setup on Raspberry Pi
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}XDP QoS Scheduler - Deployment Script${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Detect system
echo -e "${YELLOW}Detecting system...${NC}"
ARCH=$(uname -m)
KERNEL=$(uname -r)
echo "  Architecture: $ARCH"
echo "  Kernel: $KERNEL"
echo ""

# Check kernel version
KERNEL_MAJOR=$(echo $KERNEL | cut -d. -f1)
KERNEL_MINOR=$(echo $KERNEL | cut -d. -f2)

if [ "$KERNEL_MAJOR" -lt 5 ] || ([ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -lt 4 ]); then
    echo -e "${RED}Warning: Kernel version $KERNEL may not support all XDP features${NC}"
    echo "Recommended: Linux 5.4 or newer"
    echo ""
fi

# Install dependencies
echo -e "${YELLOW}Checking and installing dependencies...${NC}"

PACKAGES=(
    "build-essential"
    "clang"
    "llvm"
    "gcc"
    "make"
    "pkg-config"
    "libbpf-dev"
    "linux-headers-$(uname -r)"
    "bpftool"
    "libelf-dev"
    "zlib1g-dev"
    "libjson-c-dev"
    "iperf3"
    "python3-pip"
)

for pkg in "${PACKAGES[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        echo -e "  ${GREEN}✓${NC} $pkg already installed"
    else
        echo -e "  ${YELLOW}Installing $pkg...${NC}"
        apt-get install -y $pkg > /dev/null 2>&1
        echo -e "  ${GREEN}✓${NC} $pkg installed"
    fi
done

# Install optional packages
echo ""
echo -e "${YELLOW}Installing optional packages...${NC}"
pip3 install --quiet bcc 2>/dev/null && echo -e "  ${GREEN}✓${NC} bcc-tools" || echo -e "  ${YELLOW}⚠${NC}  bcc-tools (optional, skipped)"

# Check BPF filesystem
echo ""
echo -e "${YELLOW}Checking BPF filesystem...${NC}"
if mount | grep -q "bpf on /sys/fs/bpf"; then
    echo -e "  ${GREEN}✓${NC} BPF filesystem mounted"
else
    echo -e "  ${YELLOW}Mounting BPF filesystem...${NC}"
    mount -t bpf bpf /sys/fs/bpf
    echo -e "  ${GREEN}✓${NC} BPF filesystem mounted"
fi

# Create directories
echo ""
echo -e "${YELLOW}Creating directories...${NC}"
mkdir -p /sys/fs/bpf/xdp_qos
echo -e "  ${GREEN}✓${NC} /sys/fs/bpf/xdp_qos"

# Build the project
echo ""
echo -e "${YELLOW}Building XDP QoS Scheduler...${NC}"
make clean > /dev/null 2>&1 || true
if make; then
    echo -e "  ${GREEN}✓${NC} Build successful"
else
    echo -e "  ${RED}✗${NC} Build failed"
    exit 1
fi

# Check kernel configuration
echo ""
echo -e "${YELLOW}Checking kernel configuration...${NC}"

check_kernel_config() {
    local config=$1
    local name=$2
    
    if grep -q "$config=y" /boot/config-$(uname -r) 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $name"
        return 0
    else
        echo -e "  ${RED}✗${NC} $name (missing)"
        return 1
    fi
}

check_kernel_config "CONFIG_BPF" "BPF support" || true
check_kernel_config "CONFIG_BPF_SYSCALL" "BPF syscall" || true
check_kernel_config "CONFIG_XDP_SOCKETS" "XDP sockets" || true
check_kernel_config "CONFIG_NET_CLS_BPF" "TC BPF classifier" || true

# Test compilation
echo ""
echo -e "${YELLOW}Verifying build artifacts...${NC}"

if [ -f "build/xdp_scheduler.o" ]; then
    echo -e "  ${GREEN}✓${NC} XDP program compiled"
else
    echo -e "  ${RED}✗${NC} XDP program missing"
    exit 1
fi

if [ -f "build/tc_scheduler.o" ]; then
    echo -e "  ${GREEN}✓${NC} TC program compiled"
else
    echo -e "  ${RED}✗${NC} TC program missing"
    exit 1
fi

if [ -f "bin/control_plane" ]; then
    echo -e "  ${GREEN}✓${NC} Control plane compiled"
else
    echo -e "  ${RED}✗${NC} Control plane missing"
    exit 1
fi

# Set up scripts
echo ""
echo -e "${YELLOW}Setting up scripts...${NC}"
chmod +x scripts/*.sh scripts/*.py 2>/dev/null || true
chmod +x monitoring/*.py 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Scripts are executable"

# Detect network interface
echo ""
echo -e "${YELLOW}Detecting network interface...${NC}"
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
echo "  Default interface: $DEFAULT_IFACE"

# Create systemd service (optional)
echo ""
read -p "Do you want to create a systemd service? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cat > /etc/systemd/system/xdp-qos.service <<EOF
[Unit]
Description=XDP QoS Scheduler
After=network.target

[Service]
Type=simple
ExecStart=$(pwd)/bin/control_plane -i $DEFAULT_IFACE -x $(pwd)/build/xdp_scheduler.o -c $(pwd)/configs/default.json -s 0
ExecStop=$(pwd)/bin/control_plane -i $DEFAULT_IFACE -d
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    echo -e "  ${GREEN}✓${NC} Systemd service created"
    echo "  To enable: systemctl enable xdp-qos"
    echo "  To start:  systemctl start xdp-qos"
fi

# Summary
echo ""
echo -e "${BLUE}=====================================${NC}"
echo -e "${GREEN}Deployment complete!${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo "Quick start commands:"
echo ""
echo "  1. Load XDP program:"
echo -e "     ${YELLOW}sudo bin/control_plane -i $DEFAULT_IFACE -x build/xdp_scheduler.o -c configs/default.json${NC}"
echo ""
echo "  2. Monitor statistics:"
echo -e "     ${YELLOW}sudo python3 monitoring/stats_monitor.py${NC}"
echo ""
echo "  3. Run performance tests:"
echo -e "     ${YELLOW}sudo bash scripts/performance_eval.sh${NC}"
echo ""
echo "  4. Unload XDP program:"
echo -e "     ${YELLOW}sudo bin/control_plane -i $DEFAULT_IFACE -d${NC}"
echo ""
echo "For more information, see README.md"
echo ""
