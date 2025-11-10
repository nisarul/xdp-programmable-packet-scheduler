#ifndef __COMMON_H__
#define __COMMON_H__

/* Basic type definitions for BPF */
typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

typedef signed char __s8;
typedef signed short __s16;
typedef signed int __s32;
typedef signed long long __s64;

typedef __u16 __be16;
typedef __u32 __be32;
typedef __u64 __be64;
typedef __u16 __sum16;
typedef __u32 __wsum;

/* BPF map types */
#define BPF_MAP_TYPE_HASH 1
#define BPF_MAP_TYPE_ARRAY 2
#define BPF_MAP_TYPE_PERCPU_ARRAY 6

/* BPF map flags */
#define BPF_ANY 0

/* XDP metadata structure */
struct xdp_md {
    __u32 data;
    __u32 data_end;
    __u32 data_meta;
    __u32 ingress_ifindex;
    __u32 rx_queue_index;
    __u32 egress_ifindex;
};

/* Maximum number of flows to track */
#define MAX_FLOWS 65536

/* Maximum number of traffic classes */
#define MAX_CLASSES 8

/* Maximum number of queues per class */
#define MAX_QUEUES_PER_CLASS 16

/* Maximum queue depth (packets) */
#define MAX_QUEUE_DEPTH 1024

/* Traffic class definitions */
enum traffic_class {
    TC_CONTROL = 0,      /* Network control, routing protocols */
    TC_GAMING = 1,       /* Low-latency gaming traffic */
    TC_VOIP = 2,         /* Voice over IP */
    TC_VIDEO = 3,        /* Video streaming */
    TC_WEB = 4,          /* HTTP/HTTPS traffic */
    TC_BULK = 5,         /* Bulk data transfer */
    TC_BACKGROUND = 6,   /* Background tasks */
    TC_DEFAULT = 7,      /* Default/unclassified */
};

/* Scheduling algorithms */
enum sched_algorithm {
    SCHED_ROUND_ROBIN = 0,
    SCHED_WEIGHTED_FAIR_QUEUING = 1,
    SCHED_STRICT_PRIORITY = 2,
    SCHED_DEFICIT_ROUND_ROBIN = 3,
    SCHED_PIFO = 4,
};

/* Flow tuple for identification */
struct flow_tuple {
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u8 protocol;
    __u8 padding[3];
};

/* Flow state information */
struct flow_state {
    __u64 packet_count;
    __u64 byte_count;
    __u64 last_seen;
    __u32 class_id;
    __u32 queue_id;
    __u32 tokens;           /* For token bucket rate limiting */
    __u32 last_token_update;
    __u16 priority;
    __u16 weight;           /* For WFQ */
    __u32 deficit;          /* For DRR */
};

/* Traffic class configuration */
struct class_config {
    __u32 id;
    __u32 rate_limit;       /* bytes per second */
    __u32 burst_size;       /* bytes */
    __u16 priority;
    __u16 weight;
    __u32 min_bandwidth;    /* guaranteed bandwidth in bps */
    __u32 max_bandwidth;    /* maximum bandwidth in bps */
    __u32 flags;
};

/* Queue statistics */
struct queue_stats {
    __u64 enqueued_packets;
    __u64 enqueued_bytes;
    __u64 dequeued_packets;
    __u64 dequeued_bytes;
    __u64 dropped_packets;
    __u64 dropped_bytes;
    __u32 current_qlen;
    __u32 max_qlen;
    __u64 total_latency_ns;  /* For average latency calculation */
};

/* Per-CPU statistics */
struct cpu_stats {
    __u64 total_packets;
    __u64 total_bytes;
    __u64 classified_packets;
    __u64 dropped_packets;
    __u64 xdp_pass;
    __u64 xdp_drop;
    __u64 xdp_tx;
    __u64 xdp_redirect;
};

/* Global configuration */
struct global_config {
    __u32 sched_algorithm;
    __u32 default_class;
    __u32 num_classes;
    __u32 total_rate_limit;
    __u32 flags;
    __u32 quantum;          /* For DRR */
};

/* PIFO queue entry */
struct pifo_entry {
    __u64 rank;             /* Scheduling rank (lower = higher priority) */
    __u64 enqueue_time;
    __u32 packet_len;
    __u32 flow_hash;
    struct flow_tuple flow;
};

/* Token bucket state */
struct token_bucket {
    __u32 tokens;
    __u32 rate;             /* tokens per second */
    __u32 capacity;         /* maximum tokens */
    __u64 last_update;      /* timestamp in nanoseconds */
};

/* Classification rule */
struct class_rule {
    __u32 src_ip;
    __u32 src_ip_mask;
    __u32 dst_ip;
    __u32 dst_ip_mask;
    __u16 src_port_min;
    __u16 src_port_max;
    __u16 dst_port_min;
    __u16 dst_port_max;
    __u8 protocol;
    __u8 priority;          /* Rule priority (higher = checked first) */
    __u16 class_id;
};

/* Packet metadata passed between XDP and TC */
struct pkt_metadata {
    __u32 class_id;
    __u32 flow_hash;
    __u64 timestamp;
    __u32 original_len;
};

/* Helper macros */
#define MAX_RULES 256
#define NSEC_PER_SEC 1000000000ULL

/* BPF map pin paths */
#define FLOW_TABLE_PATH "/sys/fs/bpf/xdp_qos/flow_table"
#define CLASS_CONFIG_PATH "/sys/fs/bpf/xdp_qos/class_config"
#define QUEUE_STATS_PATH "/sys/fs/bpf/xdp_qos/queue_stats"
#define CPU_STATS_PATH "/sys/fs/bpf/xdp_qos/cpu_stats"
#define GLOBAL_CONFIG_PATH "/sys/fs/bpf/xdp_qos/global_config"
#define RULES_PATH "/sys/fs/bpf/xdp_qos/rules"

#endif /* __COMMON_H__ */
