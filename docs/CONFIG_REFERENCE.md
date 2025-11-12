# Configuration File Reference

This document provides a comprehensive guide for creating and understanding XDP QoS Scheduler configuration files. Use this as a go-to reference when creating or modifying configuration files.

## Table of Contents
- [File Format](#file-format)
- [Configuration Structure](#configuration-structure)
- [Top-Level Fields](#top-level-fields)
- [Global Configuration](#global-configuration)
- [Traffic Classes](#traffic-classes)
- [Classification Rules](#classification-rules)
- [Example Configurations](#example-configurations)
- [Tips and Best Practices](#tips-and-best-practices)

---

## File Format

Configuration files are written in **JSON format** and typically stored in the `configs/` directory.

**File naming convention**: `<profile_name>.json`
- Examples: `default.json`, `gaming.json`, `server.json`

---

## Configuration Structure

A configuration file has three main sections:

```json
{
  "profile": "...",
  "description": "...",
  "global": { ... },
  "classes": [ ... ],
  "rules": [ ... ]
}
```

---

## Top-Level Fields

### `profile`
- **Type**: String
- **Required**: Yes
- **Description**: The name/identifier of this configuration profile
- **Example**: `"default"`, `"gaming"`, `"server"`

### `description`
- **Type**: String
- **Required**: No (but recommended)
- **Description**: Human-readable description of what this profile is optimized for
- **Example**: `"Optimized for low-latency gaming traffic"`

---

## Global Configuration

The `global` section defines system-wide scheduler behavior.

### Structure
```json
"global": {
  "scheduler": "...",
  "default_class": 7,
  "quantum": 1500,
  "starvation_threshold": 10
}
```

### Fields

#### `scheduler`
- **Type**: String
- **Required**: Yes
- **Description**: The packet scheduling algorithm to use
- **Valid Values**:
  - `"round_robin"` - Simple round-robin scheduling (fair, but no prioritization)
  - `"wfq"` - Weighted Fair Queuing (fair bandwidth sharing based on weights)
  - `"strict_priority"` - Always serve higher priority first (risk of starvation)
  - `"drr"` - Deficit Round Robin (fair with quantum-based scheduling)
  - `"pifo"` - Push-In First-Out (rank-based scheduling)
- **Example**: `"strict_priority"`
- **Usage Tips**:
  - Use `strict_priority` for gaming/real-time applications
  - Use `wfq` for server workloads with fair sharing
  - Use `drr` for balanced general-purpose use

#### `default_class`
- **Type**: Integer (0-7)
- **Required**: Yes
- **Description**: The class ID to assign to traffic that doesn't match any classification rules
- **Default**: Typically `7`
- **Example**: `7`

#### `quantum`
- **Type**: Integer (bytes)
- **Required**: Yes (for DRR scheduler)
- **Description**: The number of bytes each queue can transmit per round in DRR scheduling
- **Typical Value**: `1500` (one standard MTU)
- **Example**: `1500`
- **Usage Tips**: Keep this at MTU size (1500 bytes) for Ethernet networks

#### `starvation_threshold`
- **Type**: Integer (milliseconds)
- **Required**: No
- **Description**: Maximum time in milliseconds before lower-priority classes must be served (prevents starvation in strict priority mode)
- **Default**: Not set (no starvation prevention)
- **Example**: `10`
- **Usage Tips**: Set to 5-10ms when using strict_priority to prevent complete starvation of low-priority traffic

---

## Traffic Classes

The `classes` array defines different traffic classes with their QoS parameters.

### Structure
```json
"classes": [
  {
    "id": 0,
    "name": "control",
    "rate_limit": 10485760,
    "burst_size": 131072,
    "priority": 0,
    "weight": 100,
    "min_bandwidth": 1048576,
    "max_bandwidth": 10485760
  }
]
```

### Fields

#### `id`
- **Type**: Integer (0-7)
- **Required**: Yes
- **Description**: Unique identifier for this traffic class
- **Range**: 0-7 (8 classes maximum)
- **Example**: `0`, `1`, `2`, etc.
- **Usage Tips**: Lower IDs typically represent higher priority (convention, not enforced)

#### `name`
- **Type**: String
- **Required**: No (but strongly recommended)
- **Description**: Human-readable name for this class
- **Example**: `"gaming"`, `"voip"`, `"bulk"`, `"background"`
- **Usage Tips**: Use descriptive names that indicate the traffic type

#### `rate_limit`
- **Type**: Integer (bytes per second)
- **Required**: Yes
- **Description**: Maximum sustained bandwidth for this class (token bucket rate)
- **Special Value**: `0` means no rate limit (unlimited)
- **Example**: 
  - `10485760` = 10 MB/s = 80 Mbps
  - `104857600` = 100 MB/s = 800 Mbps
- **Conversion**: Mbps × 125,000 = bytes/second
- **Usage Tips**: 
  - Set to 0 for best-effort traffic
  - Set conservatively for guaranteed-bandwidth classes

#### `burst_size`
- **Type**: Integer (bytes)
- **Required**: Yes
- **Description**: Maximum burst size allowed (token bucket capacity)
- **Example**:
  - `131072` = 128 KB
  - `1048576` = 1 MB
- **Usage Tips**:
  - For low-latency: Keep small (64-256 KB)
  - For bulk transfer: Use larger (1-4 MB)
  - Should be at least 2× the expected packet burst

#### `priority`
- **Type**: Integer (0-7)
- **Required**: Yes
- **Description**: Scheduling priority for this class
- **Range**: 0-7 (lower number = higher priority)
- **Example**: `0` (highest), `7` (lowest)
- **Usage Tips**:
  - 0-2: Critical traffic (control, gaming, VoIP)
  - 3-5: Normal traffic (web, video, default)
  - 6-7: Background traffic (bulk, downloads)

#### `weight`
- **Type**: Integer (1-1000)
- **Required**: Yes (for WFQ/weighted schedulers)
- **Description**: Relative weight for bandwidth sharing in weighted fair queuing
- **Example**:
  - `200` = 2× the bandwidth of a class with weight 100
  - `50` = half the bandwidth of a class with weight 100
- **Usage Tips**:
  - Higher weight = more bandwidth share
  - Total weights don't need to sum to any specific value
  - Typical range: 10-200

#### `min_bandwidth`
- **Type**: Integer (bytes per second)
- **Required**: No
- **Description**: Guaranteed minimum bandwidth for this class
- **Special Value**: `0` means no guarantee
- **Example**: `1048576` = 1 MB/s = 8 Mbps
- **Usage Tips**: Use for traffic that needs guaranteed bandwidth (SLA requirements)

#### `max_bandwidth`
- **Type**: Integer (bytes per second)
- **Required**: No
- **Description**: Hard maximum bandwidth cap for this class
- **Special Value**: `0` means no maximum
- **Example**: `10485760` = 10 MB/s = 80 Mbps
- **Usage Tips**: Typically set equal to `rate_limit` or left at 0

---

## Classification Rules

The `rules` array defines how to classify incoming packets into traffic classes.

### Structure
```json
"rules": [
  {
    "comment": "SSH",
    "protocol": "tcp",
    "src_ip": "0.0.0.0",
    "src_ip_mask": "0.0.0.0",
    "dst_ip": "0.0.0.0",
    "dst_ip_mask": "0.0.0.0",
    "src_port_min": 0,
    "src_port_max": 0,
    "dst_port_min": 22,
    "dst_port_max": 22,
    "class_id": 0,
    "priority": 100
  }
]
```

### Fields

#### `comment`
- **Type**: String
- **Required**: No (but strongly recommended)
- **Description**: Human-readable description of what this rule matches
- **Example**: `"SSH and control protocols"`, `"Gaming - CS:GO"`
- **Usage Tips**: Always document your rules for maintainability

#### `protocol`
- **Type**: String
- **Required**: Yes
- **Description**: IP protocol to match
- **Valid Values**:
  - `"tcp"` - TCP protocol (6)
  - `"udp"` - UDP protocol (17)
  - `"icmp"` - ICMP protocol (1)
- **Example**: `"tcp"`, `"udp"`
- **Usage Tips**: 
  - Gaming traffic is typically UDP
  - Web traffic is typically TCP

#### `src_ip`
- **Type**: String (IPv4 address)
- **Required**: No
- **Description**: Source IP address to match
- **Default**: `"0.0.0.0"` (match any)
- **Example**: `"192.168.1.100"`
- **Usage Tips**: Usually left as 0.0.0.0 unless filtering by specific source

#### `src_ip_mask`
- **Type**: String (IPv4 address)
- **Required**: No
- **Description**: Network mask for source IP matching
- **Default**: `"0.0.0.0"` (match any)
- **Example**: `"255.255.255.0"` (match /24 subnet)
- **Usage Tips**: Use to match entire subnets

#### `dst_ip`
- **Type**: String (IPv4 address)
- **Required**: No
- **Description**: Destination IP address to match
- **Default**: `"0.0.0.0"` (match any)
- **Example**: `"8.8.8.8"`

#### `dst_ip_mask`
- **Type**: String (IPv4 address)
- **Required**: No
- **Description**: Network mask for destination IP matching
- **Default**: `"0.0.0.0"` (match any)
- **Example**: `"255.255.255.0"`

#### `src_port_min`
- **Type**: Integer (0-65535)
- **Required**: No
- **Description**: Minimum source port number to match
- **Default**: `0` (any port)
- **Example**: `1024`
- **Usage Tips**: Rarely used; most rules match by destination port

#### `src_port_max`
- **Type**: Integer (0-65535)
- **Required**: No
- **Description**: Maximum source port number to match (defines port range)
- **Default**: `0` (any port, or same as min if min is set)
- **Example**: `65535`

#### `dst_port_min`
- **Type**: Integer (0-65535)
- **Required**: Yes (for port-based classification)
- **Description**: Minimum destination port number to match
- **Example**: `80` (HTTP), `443` (HTTPS), `22` (SSH)
- **Usage Tips**: This is the primary field for most classification rules

#### `dst_port_max`
- **Type**: Integer (0-65535)
- **Required**: No
- **Description**: Maximum destination port number to match (defines port range)
- **Default**: Same as `dst_port_min` if not specified
- **Example**: `27030` (for range 27015-27030)
- **Usage Tips**: Use ranges for applications that use multiple ports

#### `class_id`
- **Type**: Integer (0-7)
- **Required**: Yes
- **Description**: The traffic class ID to assign when this rule matches
- **Example**: `1` (assign to class 1)
- **Usage Tips**: Must reference a valid class ID defined in the `classes` array

#### `priority`
- **Type**: Integer (0-255)
- **Required**: Yes
- **Description**: Rule evaluation priority (higher number = checked first)
- **Range**: 0-255
- **Example**: `100` (high priority), `50` (low priority)
- **Usage Tips**:
  - Higher priority rules are evaluated first
  - Use 90-100 for specific rules (e.g., gaming ports)
  - Use 50-70 for generic rules (e.g., HTTPS traffic)
  - First matching rule wins

---

## Example Configurations

### Gaming Profile (Low Latency)
```json
{
  "profile": "gaming",
  "description": "Optimized for low-latency gaming",
  "global": {
    "scheduler": "strict_priority",
    "default_class": 7,
    "quantum": 1500,
    "starvation_threshold": 10
  },
  "classes": [
    {
      "id": 1,
      "name": "gaming",
      "rate_limit": 104857600,
      "burst_size": 524288,
      "priority": 1,
      "weight": 200,
      "min_bandwidth": 52428800,
      "max_bandwidth": 104857600
    }
  ],
  "rules": [
    {
      "comment": "Gaming - CS:GO",
      "protocol": "udp",
      "dst_port_min": 27015,
      "dst_port_max": 27030,
      "class_id": 1,
      "priority": 90
    }
  ]
}
```

### Server Profile (Fair Sharing)
```json
{
  "profile": "server",
  "description": "Fair bandwidth allocation for servers",
  "global": {
    "scheduler": "wfq",
    "default_class": 7,
    "quantum": 1500
  },
  "classes": [
    {
      "id": 2,
      "name": "database",
      "rate_limit": 104857600,
      "burst_size": 1048576,
      "priority": 2,
      "weight": 200,
      "min_bandwidth": 52428800,
      "max_bandwidth": 104857600
    }
  ],
  "rules": [
    {
      "comment": "PostgreSQL",
      "protocol": "tcp",
      "dst_port_min": 5432,
      "dst_port_max": 5432,
      "class_id": 2,
      "priority": 80
    }
  ]
}
```

---

## Tips and Best Practices

### General Guidelines

1. **Start with a template**: Copy `configs/default.json` and modify as needed
2. **Test incrementally**: Change one thing at a time and test
3. **Document everything**: Use comments in rules and descriptive class names
4. **Monitor performance**: Use `xdp_qos_cli stats` to verify behavior

### Bandwidth Calculations

```
Mbps to bytes/second: Mbps × 125,000
Example: 100 Mbps = 100 × 125,000 = 12,500,000 bytes/second

Common values:
- 1 Mbps   = 125,000 bytes/s
- 10 Mbps  = 1,250,000 bytes/s
- 100 Mbps = 12,500,000 bytes/s
- 1 Gbps   = 125,000,000 bytes/s
```

### Burst Size Guidelines

- **Real-time traffic** (gaming, VoIP): 64-256 KB
- **Interactive traffic** (web, SSH): 256-512 KB
- **Streaming traffic** (video): 512 KB - 1 MB
- **Bulk traffic** (downloads): 1-4 MB

### Priority Assignment

```
Priority 0-2: Critical (control, gaming, VoIP)
Priority 3-5: Normal (web, video, default)
Priority 6-7: Background (bulk, best-effort)
```

### Common Port Ranges

| Application | Protocol | Port(s) |
|-------------|----------|---------|
| SSH | TCP | 22 |
| HTTP | TCP | 80 |
| HTTPS | TCP | 443 |
| DNS | UDP | 53 |
| CS:GO | UDP | 27015-27030 |
| Fortnite | UDP | 3478-3479 |
| Discord Voice | UDP | 50000-65535 |
| Zoom | UDP | 8801-8810 |

### Scheduler Selection Guide

| Scheduler | Best For | Pros | Cons |
|-----------|----------|------|------|
| `strict_priority` | Gaming, real-time | Lowest latency for high priority | Can starve low priority |
| `wfq` | Servers, multi-tenant | Fair sharing | More complex |
| `drr` | General purpose | Balanced, simple | Moderate latency |
| `round_robin` | Testing, simple setups | Very simple | No prioritization |
| `pifo` | Research, custom ranking | Flexible | Most complex |

### Token Bucket Rate Limiting

**How it works:**
- Tokens represent "permission to send bytes"
- Tokens refill at `rate_limit` (bytes/second)
- Bucket holds maximum `burst_size` tokens
- Each packet consumes tokens equal to its size
- If not enough tokens: packet is dropped

**Configuration:**
- Set `rate_limit` to sustained bandwidth limit
- Set `burst_size` to allow short bursts (2-5× expected burst)
- Set both to 0 to disable rate limiting for a class

### Troubleshooting

**Packets not matching rules:**
- Check rule priority (higher = evaluated first)
- Verify protocol (TCP vs UDP)
- Ensure port ranges are correct
- Check `xdp_qos_cli stats` for classification counts

**Performance issues:**
- Monitor CPU usage with `xdp_qos_cli stats`
- Check for queue drops in per-class statistics
- Adjust rate limits if seeing excessive drops
- Consider changing scheduler algorithm

**Starvation issues:**
- Set `starvation_threshold` in global config
- Switch from `strict_priority` to `wfq` or `drr`
- Reduce priority differences between classes

---

## Configuration File Locations

- **Default configs**: `/home/phoenix/Project/dissertation_new/xdp_qos_scheduler/configs/`
- **Active config**: Specified with `-c` flag when running `xdp_qos_cli`

## Loading Configuration

```bash
# Load a configuration file
sudo ./bin/xdp_qos_cli -i eth0 -c configs/gaming.json

# Reload configuration without restarting
sudo ./bin/xdp_qos_cli -i eth0 -c configs/new_config.json
```

---

## Further Reading

- See `QUICKSTART.md` for basic usage
- See `README.md` for system architecture
- See source code in `src/` for implementation details
