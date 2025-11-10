/*
 * XDP Packet Scheduler - Packet Classification Module
 * 
 * This XDP program classifies incoming packets based on 5-tuple flow information
 * and traffic class rules. It can either handle scheduling directly (if hardware
 * supports it) or pass metadata to TC layer for scheduling.
 */

/* Include common types FIRST before BPF headers */
#include "../common/common.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* Linux kernel network headers - simplified for BPF */
#define ETH_P_IP 0x0800
#define IPPROTO_ICMP 1
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

/* XDP actions */
#define XDP_ABORTED 0
#define XDP_DROP 1
#define XDP_PASS 2
#define XDP_TX 3
#define XDP_REDIRECT 4

/* Ethernet header */
struct ethhdr {
    unsigned char h_dest[6];
    unsigned char h_source[6];
    __be16 h_proto;
} __attribute__((packed));

/* IPv4 header */
struct iphdr {
    __u8 ihl:4,
         version:4;
    __u8 tos;
    __be16 tot_len;
    __be16 id;
    __be16 frag_off;
    __u8 ttl;
    __u8 protocol;
    __sum16 check;
    __be32 saddr;
    __be32 daddr;
} __attribute__((packed));

/* TCP header */
struct tcphdr {
    __be16 source;
    __be16 dest;
    __be32 seq;
    __be32 ack_seq;
    __u16 res1:4,
          doff:4,
          fin:1,
          syn:1,
          rst:1,
          psh:1,
          ack:1,
          urg:1,
          ece:1,
          cwr:1;
    __be16 window;
    __sum16 check;
    __be16 urg_ptr;
} __attribute__((packed));

/* UDP header */
struct udphdr {
    __be16 source;
    __be16 dest;
    __be16 len;
    __sum16 check;
} __attribute__((packed));

/* BPF Maps */

/* Flow table: tracks per-flow state */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_FLOWS);
    __type(key, struct flow_tuple);
    __type(value, struct flow_state);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} flow_table SEC(".maps");

/* Classification rules */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_RULES);
    __type(key, __u32);
    __type(value, struct class_rule);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} class_rules SEC(".maps");

/* Traffic class configuration */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, struct class_config);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} class_config SEC(".maps");

/* Per-CPU statistics */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct cpu_stats);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} cpu_stats SEC(".maps");

/* Global configuration */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct global_config);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} global_config SEC(".maps");

/* Queue statistics per class */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, struct queue_stats);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} queue_stats SEC(".maps");

/* Token buckets per class */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, struct token_bucket);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} token_buckets SEC(".maps");

/* Helper function: Calculate flow hash */
static __always_inline __u32 __attribute__((unused)) calc_flow_hash(struct flow_tuple *flow)
{
    __u32 hash = 0;
    hash = flow->src_ip ^ flow->dst_ip;
    hash ^= ((__u32)flow->src_port << 16) | flow->dst_port;
    hash ^= flow->protocol;
    return hash;
}

/* Helper function: Parse Ethernet header */
static __always_inline int parse_ethhdr(void *data, void *data_end,
                                        struct ethhdr **ethhdr)
{
    struct ethhdr *eth = data;
    
    if ((void *)(eth + 1) > data_end)
        return -1;
    
    *ethhdr = eth;
    return bpf_ntohs(eth->h_proto);
}

/* Helper function: Parse IPv4 header and extract flow tuple */
static __always_inline int parse_ipv4(void *data, void *data_end,
                                      struct iphdr **iphdr,
                                      struct flow_tuple *flow)
{
    struct iphdr *iph = data;
    
    if ((void *)(iph + 1) > data_end)
        return -1;
    
    /* Check for IP fragmentation */
    if (iph->frag_off & bpf_htons(0x1FFF))
        return -1;
    
    flow->src_ip = iph->saddr;
    flow->dst_ip = iph->daddr;
    flow->protocol = iph->protocol;
    
    *iphdr = iph;
    return iph->protocol;
}

/* Helper function: Parse TCP header */
static __always_inline int parse_tcp(void *data, void *data_end,
                                     struct flow_tuple *flow)
{
    struct tcphdr *tcph = data;
    
    if ((void *)(tcph + 1) > data_end)
        return -1;
    
    flow->src_port = bpf_ntohs(tcph->source);
    flow->dst_port = bpf_ntohs(tcph->dest);
    
    return 0;
}

/* Helper function: Parse UDP header */
static __always_inline int parse_udp(void *data, void *data_end,
                                     struct flow_tuple *flow)
{
    struct udphdr *udph = data;
    
    if ((void *)(udph + 1) > data_end)
        return -1;
    
    flow->src_port = bpf_ntohs(udph->source);
    flow->dst_port = bpf_ntohs(udph->dest);
    
    return 0;
}

/* Helper function: Classify packet based on rules */
static __always_inline __u32 classify_packet(struct flow_tuple *flow)
{
    /* Iterate through classification rules (in priority order) */
    /* Note: Limited to first 16 rules for BPF verifier */
    /* Using bounded loop to satisfy BPF verifier */
    #pragma unroll
    for (int i = 0; i < 16; i++) {
        __u32 rule_idx = i;
        struct class_rule *rule = bpf_map_lookup_elem(&class_rules, &rule_idx);
        if (!rule)
            continue;
        
        /* Check protocol */
        if (rule->protocol && rule->protocol != flow->protocol)
            continue;
        
        /* Check source IP */
        if (rule->src_ip_mask &&
            (flow->src_ip & rule->src_ip_mask) != (rule->src_ip & rule->src_ip_mask))
            continue;
        
        /* Check destination IP */
        if (rule->dst_ip_mask &&
            (flow->dst_ip & rule->dst_ip_mask) != (rule->dst_ip & rule->dst_ip_mask))
            continue;
        
        /* Check source port range */
        if (rule->src_port_min || rule->src_port_max) {
            if (flow->src_port < rule->src_port_min ||
                flow->src_port > rule->src_port_max)
                continue;
        }
        
        /* Check destination port range */
        if (rule->dst_port_min || rule->dst_port_max) {
            if (flow->dst_port < rule->dst_port_min ||
                flow->dst_port > rule->dst_port_max)
                continue;
        }
        
        /* Rule matched */
        return rule->class_id;
    }
    
    /* No rule matched - use default class */
    return TC_DEFAULT;
}

/* Helper function: Update token bucket */
static __always_inline int update_token_bucket(struct token_bucket *tb,
                                               __u32 packet_len,
                                               __u64 now)
{
    __u64 time_delta_ns = now - tb->last_update;
    __u64 new_tokens;
    
    if (time_delta_ns == 0)
        return 0;
    
    /* Calculate new tokens: rate is in bytes/sec */
    new_tokens = (tb->rate * time_delta_ns) / NSEC_PER_SEC;
    
    /* Add tokens, but don't exceed capacity */
    tb->tokens += new_tokens;
    if (tb->tokens > tb->capacity)
        tb->tokens = tb->capacity;
    
    tb->last_update = now;
    
    /* Check if we have enough tokens */
    if (tb->tokens >= packet_len) {
        tb->tokens -= packet_len;
        return 1;  /* Packet allowed */
    }
    
    return 0;  /* Packet dropped */
}

/* Main XDP program */
SEC("xdp")
int xdp_packet_classifier(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth;
    struct iphdr *iph;
    struct flow_tuple flow = {};
    struct flow_state *flow_st;
    struct cpu_stats *stats;
    struct class_config *class_cfg;
    struct token_bucket *tb;
    __u32 key = 0;
    __u32 class_id;
    __u32 pkt_len;
    __u64 now;
    int eth_type, ip_proto;
    
    /* Get current timestamp */
    now = bpf_ktime_get_ns();
    
    /* Get per-CPU statistics */
    stats = bpf_map_lookup_elem(&cpu_stats, &key);
    if (stats) {
        __sync_fetch_and_add(&stats->total_packets, 1);
    }
    
    /* Parse Ethernet header */
    eth_type = parse_ethhdr(data, data_end, &eth);
    if (eth_type < 0)
        goto pass;
    
    /* Only handle IPv4 for now */
    if (eth_type != ETH_P_IP)
        goto pass;
    
    /* Parse IPv4 header */
    ip_proto = parse_ipv4(data + sizeof(*eth), data_end, &iph, &flow);
    if (ip_proto < 0)
        goto pass;
    
    /* Parse transport layer */
    void *l4_hdr = data + sizeof(*eth) + (iph->ihl * 4);
    
    if (ip_proto == IPPROTO_TCP) {
        if (parse_tcp(l4_hdr, data_end, &flow) < 0)
            goto pass;
    } else if (ip_proto == IPPROTO_UDP) {
        if (parse_udp(l4_hdr, data_end, &flow) < 0)
            goto pass;
    } else if (ip_proto == IPPROTO_ICMP) {
        /* ICMP doesn't have ports */
        flow.src_port = 0;
        flow.dst_port = 0;
    } else {
        /* Other protocols - classify based on IP only */
        flow.src_port = 0;
        flow.dst_port = 0;
    }
    
    /* Classify packet */
    class_id = classify_packet(&flow);
    
    /* Update statistics */
    if (stats) {
        __sync_fetch_and_add(&stats->classified_packets, 1);
        __sync_fetch_and_add(&stats->total_bytes, (data_end - data));
    }
    
    /* Lookup or create flow state */
    flow_st = bpf_map_lookup_elem(&flow_table, &flow);
    if (!flow_st) {
        /* New flow - create state */
        struct flow_state new_flow = {
            .packet_count = 1,
            .byte_count = data_end - data,
            .last_seen = now,
            .class_id = class_id,
            .queue_id = 0,
            .tokens = 0,
            .last_token_update = now,
            .priority = 0,
            .weight = 1,
            .deficit = 0,
        };
        
        bpf_map_update_elem(&flow_table, &flow, &new_flow, BPF_ANY);
    } else {
        /* Update existing flow */
        __sync_fetch_and_add(&flow_st->packet_count, 1);
        __sync_fetch_and_add(&flow_st->byte_count, (data_end - data));
        flow_st->last_seen = now;
        flow_st->class_id = class_id;
    }
    
    /* Get class configuration */
    class_cfg = bpf_map_lookup_elem(&class_config, &class_id);
    if (!class_cfg)
        goto pass;
    
    /* Token bucket rate limiting */
    tb = bpf_map_lookup_elem(&token_buckets, &class_id);
    if (tb && tb->rate > 0) {
        pkt_len = data_end - data;
        if (!update_token_bucket(tb, pkt_len, now)) {
            /* Rate limit exceeded - drop packet */
            if (stats)
                __sync_fetch_and_add(&stats->dropped_packets, 1);
            
            if (stats)
                __sync_fetch_and_add(&stats->xdp_drop, 1);
            
            return XDP_DROP;
        }
    }
    
    /* Update queue statistics */
    struct queue_stats *qstats = bpf_map_lookup_elem(&queue_stats, &class_id);
    if (qstats) {
        __sync_fetch_and_add(&qstats->enqueued_packets, 1);
        __sync_fetch_and_add(&qstats->enqueued_bytes, (data_end - data));
    }
    
    if (stats)
        __sync_fetch_and_add(&stats->xdp_pass, 1);
    
    /* Pass to network stack / TC layer for scheduling */
    return XDP_PASS;

pass:
    if (stats)
        __sync_fetch_and_add(&stats->xdp_pass, 1);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
