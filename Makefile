# Makefile for XDP QoS Scheduler

# Compiler and flags
CLANG ?= clang
LLC ?= llc
CC ?= gcc

# Architecture
ARCH := $(shell uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/x86/')

# Directories
SRC_DIR := src
XDP_DIR := $(SRC_DIR)/xdp
TC_DIR := $(SRC_DIR)/tc
CONTROL_DIR := $(SRC_DIR)/control
COMMON_DIR := $(SRC_DIR)/common
BUILD_DIR := build
BIN_DIR := bin

# Kernel headers
KERNEL_VERSION := $(shell uname -r)
KERNEL_HEADERS := /usr/src/linux-headers-$(KERNEL_VERSION)
LIBBPF_DIR := /usr/include

# BPF flags
BPF_CFLAGS := -O2 -g -Wall -Werror \
	-target bpf \
	-D__BPF__ \
	-D__BPF_TRACING__ \
	-I$(COMMON_DIR) \
	-I$(KERNEL_HEADERS)/include \
	-I$(KERNEL_HEADERS)/arch/$(ARCH)/include \
	-I$(KERNEL_HEADERS)/arch/$(ARCH)/include/generated \
	-I$(KERNEL_HEADERS)/include/uapi \
	-I$(KERNEL_HEADERS)/arch/$(ARCH)/include/uapi \
	-I$(KERNEL_HEADERS)/arch/$(ARCH)/include/generated/uapi \
	-I$(LIBBPF_DIR) \
	-Wno-unused-value \
	-Wno-pointer-sign \
	-Wno-compare-distinct-pointer-types

# User-space flags
CFLAGS := -O2 -g -Wall -Werror \
	-I$(LIBBPF_DIR) \
	-I$(COMMON_DIR)

LDFLAGS := -lbpf -lelf -lz -ljson-c

# Targets
XDP_OBJ := $(BUILD_DIR)/xdp_scheduler.o
TC_OBJ := $(BUILD_DIR)/tc_scheduler.o
CONTROL_BIN := $(BIN_DIR)/control_plane

# Source files
XDP_SRC := $(XDP_DIR)/xdp_scheduler.c
TC_SRC := $(TC_DIR)/tc_scheduler.c
CONTROL_SRC := $(CONTROL_DIR)/control_plane.c

# Default target
.PHONY: all
all: directories $(XDP_OBJ) $(TC_OBJ) $(CONTROL_BIN)

# Create directories
.PHONY: directories
directories:
	@mkdir -p $(BUILD_DIR) $(BIN_DIR)

# Build XDP program
$(XDP_OBJ): $(XDP_SRC) $(COMMON_DIR)/common.h
	@echo "Building XDP program..."
	$(CLANG) $(BPF_CFLAGS) -c $(XDP_SRC) -o $(XDP_OBJ)
	@echo "✓ XDP program built: $(XDP_OBJ)"

# Build TC program
$(TC_OBJ): $(TC_SRC) $(COMMON_DIR)/common.h
	@echo "Building TC program..."
	$(CLANG) $(BPF_CFLAGS) -c $(TC_SRC) -o $(TC_OBJ)
	@echo "✓ TC program built: $(TC_OBJ)"

# Build control plane
$(CONTROL_BIN): $(CONTROL_SRC) $(COMMON_DIR)/common.h
	@echo "Building control plane..."
	$(CC) $(CFLAGS) $(CONTROL_SRC) -o $(CONTROL_BIN) $(LDFLAGS)
	@echo "✓ Control plane built: $(CONTROL_BIN)"

# Install
.PHONY: install
install: all
	@echo "Installing XDP QoS Scheduler..."
	sudo mkdir -p /opt/xdp_qos_scheduler
	sudo cp $(XDP_OBJ) /opt/xdp_qos_scheduler/
	sudo cp $(TC_OBJ) /opt/xdp_qos_scheduler/
	sudo cp $(CONTROL_BIN) /usr/local/bin/xdp-qos-control
	sudo mkdir -p /etc/xdp_qos_scheduler
	sudo cp -r configs/* /etc/xdp_qos_scheduler/
	sudo chmod +x /usr/local/bin/xdp-qos-control
	sudo chmod +x scripts/*.sh scripts/*.py
	@echo "✓ Installation complete"

# Uninstall
.PHONY: uninstall
uninstall:
	@echo "Uninstalling XDP QoS Scheduler..."
	sudo rm -rf /opt/xdp_qos_scheduler
	sudo rm -f /usr/local/bin/xdp-qos-control
	sudo rm -rf /etc/xdp_qos_scheduler
	@echo "✓ Uninstallation complete"

# Load XDP program
.PHONY: load
load: all
	@echo "Loading XDP QoS Scheduler..."
	sudo $(CONTROL_BIN) -i eth0 -x $(XDP_OBJ) -c configs/default.json

# Unload XDP program
.PHONY: unload
unload:
	@echo "Unloading XDP program..."
	sudo $(CONTROL_BIN) -i eth0 -d

# Run tests
.PHONY: test
test: all
	@echo "Running tests..."
	sudo bash scripts/performance_eval.sh

# Monitor statistics
.PHONY: monitor
monitor:
	@echo "Starting statistics monitor..."
	sudo python3 monitoring/stats_monitor.py

# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(BUILD_DIR) $(BIN_DIR)
	@echo "✓ Clean complete"

# Deep clean (including results)
.PHONY: distclean
distclean: clean
	@echo "Cleaning all generated files..."
	rm -rf results
	sudo rm -rf /sys/fs/bpf/xdp_qos
	@echo "✓ Deep clean complete"

# Check dependencies
.PHONY: check-deps
check-deps:
	@echo "Checking dependencies..."
	@which $(CLANG) > /dev/null || (echo "❌ clang not found" && exit 1)
	@which $(CC) > /dev/null || (echo "❌ gcc not found" && exit 1)
	@which bpftool > /dev/null || (echo "❌ bpftool not found" && exit 1)
	@which iperf3 > /dev/null || (echo "❌ iperf3 not found" && exit 1)
	@pkg-config --exists libbpf || (echo "❌ libbpf not found" && exit 1)
	@pkg-config --exists json-c || (echo "❌ json-c not found" && exit 1)
	@python3 -c "import bcc" 2>/dev/null || (echo "⚠️  bcc-tools not found (optional, for monitoring)" && exit 0)
	@echo "✓ All required dependencies found"

# Show kernel config
.PHONY: kernel-config
kernel-config:
	@echo "Checking kernel configuration..."
	@echo "Kernel version: $(KERNEL_VERSION)"
	@echo "Architecture: $(ARCH)"
	@echo ""
	@echo "Required kernel features:"
	@grep -q "CONFIG_BPF=y" /boot/config-$(KERNEL_VERSION) && echo "✓ BPF support" || echo "❌ BPF support missing"
	@grep -q "CONFIG_XDP_SOCKETS=y" /boot/config-$(KERNEL_VERSION) && echo "✓ XDP sockets" || echo "⚠️  XDP sockets not enabled"
	@grep -q "CONFIG_NET_CLS_BPF=y" /boot/config-$(KERNEL_VERSION) 2>/dev/null && echo "✓ TC BPF classifier" || echo "⚠️  TC BPF classifier not enabled"

# Show help
.PHONY: help
help:
	@echo "XDP QoS Scheduler - Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all           - Build all components (default)"
	@echo "  install       - Install to system"
	@echo "  uninstall     - Remove from system"
	@echo "  load          - Load XDP program with default config"
	@echo "  unload        - Unload XDP program"
	@echo "  test          - Run performance tests"
	@echo "  monitor       - Monitor live statistics"
	@echo "  clean         - Remove build artifacts"
	@echo "  distclean     - Remove all generated files"
	@echo "  check-deps    - Check for required dependencies"
	@echo "  kernel-config - Show kernel configuration"
	@echo "  help          - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make              # Build everything"
	@echo "  make load         # Load with default config"
	@echo "  make monitor      # Monitor statistics"
	@echo "  make test         # Run performance tests"

.DEFAULT_GOAL := all
