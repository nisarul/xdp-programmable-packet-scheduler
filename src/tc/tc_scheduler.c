/*
 * TC eBPF Scheduler - Programmable Packet Scheduling
 * 
 * This TC classifier implements multiple scheduling algorithms:
 * - Round Robin (RR)
 * - Weighted Fair Queuing (WFQ)
 * - Strict Priority (SP)
 * - Deficit Round Robin (DRR)
 * - PIFO (Push-In First-Out)
 */

/* Include common types FIRST before BPF headers */
#include "../common/common.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* TC actions */
#define TC_ACT_UNSPEC (-1)
#define TC_ACT_OK 0
#define TC_ACT_RECLASSIFY 1
#define TC_ACT_SHOT 2
#define TC_ACT_PIPE 3
#define TC_ACT_STOLEN 4
#define TC_ACT_QUEUED 5
#define TC_ACT_REPEAT 6
#define TC_ACT_REDIRECT 7

/* Network protocol constants */
#define ETH_P_IP 0x0800
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

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

/* __sk_buff structure for TC programs */
struct __sk_buff {
    __u32 len;
    __u32 pkt_type;
    __u32 mark;
    __u32 queue_mapping;
    __u32 protocol;
    __u32 vlan_present;
    __u32 vlan_tci;
    __u32 vlan_proto;
    __u32 priority;
    __u32 ingress_ifindex;
    __u32 ifindex;
    __u32 tc_index;
    __u32 cb[5];
    __u32 hash;
    __u32 tc_classid;
    __u32 data;
    __u32 data_end;
    __u32 napi_id;
} __attribute__((preserve_access_index));

/* External maps from XDP program */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_FLOWS);
    __type(key, struct flow_tuple);
    __type(value, struct flow_state);
} flow_table SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, struct class_config);
} class_config SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct global_config);
} global_config SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, struct queue_stats);
} queue_stats SEC(".maps");

/* TC-specific maps */

/* Round-robin state per class */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, __u32);  /* Current queue index */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} rr_state SEC(".maps");

/* DRR deficit counter per flow */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_FLOWS);
    __type(key, struct flow_tuple);
    __type(value, __u32);  /* Deficit counter */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} drr_deficit SEC(".maps");

/* PIFO queue entries */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_QUEUE_DEPTH);
    __type(key, __u32);
    __type(value, struct pifo_entry);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} pifo_queue SEC(".maps");

/* PIFO queue metadata */
struct pifo_meta {
    __u32 head;
    __u32 tail;
    __u32 size;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, struct pifo_meta);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} pifo_metadata SEC(".maps");

/* WFQ virtual time tracking */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_CLASSES);
    __type(key, __u32);
    __type(value, __u64);  /* Virtual time */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} wfq_vtime SEC(".maps");

/* Helper: Parse packet headers to extract flow tuple */
static __always_inline int extract_flow_tuple(struct __sk_buff *skb,
                                              struct flow_tuple *flow)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth;
    struct iphdr *iph;
    
    /* Parse Ethernet */
    eth = data;
    if ((void *)(eth + 1) > data_end)
        return -1;
    
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return -1;
    
    /* Parse IPv4 */
    iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return -1;
    
    flow->src_ip = iph->saddr;
    flow->dst_ip = iph->daddr;
    flow->protocol = iph->protocol;
    
    /* Parse L4 headers */
    void *l4 = (void *)iph + (iph->ihl * 4);
    
    if (iph->protocol == IPPROTO_TCP) {
        struct tcphdr *tcph = l4;
        if ((void *)(tcph + 1) > data_end)
            return -1;
        flow->src_port = bpf_ntohs(tcph->source);
        flow->dst_port = bpf_ntohs(tcph->dest);
    } else if (iph->protocol == IPPROTO_UDP) {
        struct udphdr *udph = l4;
        if ((void *)(udph + 1) > data_end)
            return -1;
        flow->src_port = bpf_ntohs(udph->source);
        flow->dst_port = bpf_ntohs(udph->dest);
    } else {
        flow->src_port = 0;
        flow->dst_port = 0;
    }
    
    return 0;
}

/* Round Robin Scheduler */
static __always_inline int schedule_round_robin(struct __sk_buff *skb,
                                                 struct flow_state *flow_st,
                                                 __u32 class_id)
{
    __u32 *rr_idx = bpf_map_lookup_elem(&rr_state, &class_id);
    if (!rr_idx)
        return TC_ACT_OK;
    
    /* Assign to next queue in round-robin fashion */
    flow_st->queue_id = *rr_idx;
    
    /* Update round-robin state */
    *rr_idx = (*rr_idx + 1) % MAX_QUEUES_PER_CLASS;
    
    return TC_ACT_OK;
}

/* Weighted Fair Queuing Scheduler */
static __always_inline int schedule_wfq(struct __sk_buff *skb,
                                        struct flow_state *flow_st,
                                        struct class_config *cfg,
                                        __u32 class_id)
{
    __u64 *vtime = bpf_map_lookup_elem(&wfq_vtime, &class_id);
    if (!vtime)
        return TC_ACT_OK;
    
    __u32 pkt_len = skb->len;
    
    /* Calculate virtual finish time: VFT = VT + (packet_len / weight) */
    __u64 vft = *vtime + (pkt_len / (flow_st->weight ? flow_st->weight : 1));
    
    /* Update virtual time to minimum finish time */
    *vtime = vft;
    
    /* Map VFT to queue (simplified) */
    flow_st->queue_id = (vft % MAX_QUEUES_PER_CLASS);
    
    return TC_ACT_OK;
}

/* Strict Priority Scheduler */
static __always_inline int schedule_strict_priority(struct __sk_buff *skb,
                                                     struct flow_state *flow_st,
                                                     struct class_config *cfg,
                                                     struct global_config *gcfg)
{
    /* Basic priority to queue mapping */
    flow_st->queue_id = (cfg->priority < MAX_QUEUES_PER_CLASS) ?
                         cfg->priority : 0;
    
    /* Optional starvation protection if threshold is configured */
    if (gcfg->starvation_threshold > 0) {
        static __u64 last_low_prio_service = 0;
        __u64 now = bpf_ktime_get_ns();
        __u64 threshold_ns = (__u64)gcfg->starvation_threshold * 1000000; /* Convert ms to ns */
        
        /* If this is lower priority traffic (priority > 2) and it's been too long */
        if (cfg->priority > 2 && (now - last_low_prio_service > threshold_ns)) {
            /* Force service for starvation prevention */
            last_low_prio_service = now;
            flow_st->queue_id = 0; /* Temporarily boost to highest queue */
        }
    }
    
    return TC_ACT_OK;
}

/* Deficit Round Robin Scheduler */
static __always_inline int schedule_drr(struct __sk_buff *skb,
                                       struct flow_tuple *flow,
                                       struct flow_state *flow_st,
                                       struct global_config *gcfg)
{
    __u32 *deficit = bpf_map_lookup_elem(&drr_deficit, flow);
    __u32 pkt_len = skb->len;
    __u32 quantum = gcfg->quantum ? gcfg->quantum : 1500;
    
    if (!deficit) {
        /* First packet from this flow */
        __u32 new_deficit = quantum;
        bpf_map_update_elem(&drr_deficit, flow, &new_deficit, BPF_ANY);
        deficit = &new_deficit;
    }
    
    /* Add quantum to deficit */
    *deficit += quantum;
    
    /* Check if deficit is sufficient */
    if (*deficit >= pkt_len) {
        *deficit -= pkt_len;
        flow_st->deficit = *deficit;
        return TC_ACT_OK;
    }
    
    /* Not enough deficit - defer packet */
    return TC_ACT_SHOT;  /* Drop for now (in real impl, would enqueue) */
}

/* PIFO Scheduler */
static __always_inline int schedule_pifo(struct __sk_buff *skb,
                                        struct flow_tuple *flow,
                                        struct flow_state *flow_st,
                                        __u32 class_id)
{
    struct pifo_meta *meta = bpf_map_lookup_elem(&pifo_metadata, &class_id);
    if (!meta || meta->size >= MAX_QUEUE_DEPTH)
        return TC_ACT_SHOT;  /* Queue full */
    
    __u64 now = bpf_ktime_get_ns();
    
    /* Calculate rank based on priority and arrival time */
    __u64 rank = ((__u64)flow_st->priority << 48) | (now & 0xFFFFFFFFFFFF);
    
    /* Create PIFO entry */
    struct pifo_entry entry = {
        .rank = rank,
        .enqueue_time = now,
        .packet_len = skb->len,
        .flow_hash = flow->src_ip ^ flow->dst_ip,
    };
    __builtin_memcpy(&entry.flow, flow, sizeof(*flow));
    
    /* Insert into PIFO queue (simplified - should maintain sorted order) */
    __u32 insert_idx = meta->tail;
    bpf_map_update_elem(&pifo_queue, &insert_idx, &entry, BPF_ANY);
    
    /* Update metadata */
    meta->tail = (meta->tail + 1) % MAX_QUEUE_DEPTH;
    meta->size++;
    
    return TC_ACT_OK;
}

/* Main TC classifier */
SEC("classifier")
int tc_packet_scheduler(struct __sk_buff *skb)
{
    struct flow_tuple flow = {};
    struct flow_state *flow_st;
    struct class_config *cfg;
    struct global_config *gcfg;
    struct queue_stats *qstats;
    __u32 key = 0;
    __u32 class_id;
    int ret;
    
    /* Extract flow tuple */
    if (extract_flow_tuple(skb, &flow) < 0)
        return TC_ACT_OK;
    
    /* Lookup flow state (should be created by XDP) */
    flow_st = bpf_map_lookup_elem(&flow_table, &flow);
    if (!flow_st)
        return TC_ACT_OK;  /* Unknown flow, pass through */
    
    class_id = flow_st->class_id;
    
    /* Get class configuration */
    cfg = bpf_map_lookup_elem(&class_config, &class_id);
    if (!cfg)
        return TC_ACT_OK;
    
    /* Get global configuration */
    gcfg = bpf_map_lookup_elem(&global_config, &key);
    if (!gcfg)
        return TC_ACT_OK;
    
    /* Apply scheduling algorithm based on configuration */
    switch (gcfg->sched_algorithm) {
    case SCHED_ROUND_ROBIN:
        ret = schedule_round_robin(skb, flow_st, class_id);
        break;
    
    case SCHED_WEIGHTED_FAIR_QUEUING:
        ret = schedule_wfq(skb, flow_st, cfg, class_id);
        break;
    
    case SCHED_STRICT_PRIORITY:
        ret = schedule_strict_priority(skb, flow_st, cfg, gcfg);
        break;
    
    case SCHED_DEFICIT_ROUND_ROBIN:
        ret = schedule_drr(skb, &flow, flow_st, gcfg);
        break;
    
    case SCHED_PIFO:
        ret = schedule_pifo(skb, &flow, flow_st, class_id);
        break;
    
    default:
        ret = TC_ACT_OK;
        break;
    }
    
    /* Update queue statistics */
    qstats = bpf_map_lookup_elem(&queue_stats, &class_id);
    if (qstats) {
        if (ret == TC_ACT_OK) {
            __sync_fetch_and_add(&qstats->dequeued_packets, 1);
            __sync_fetch_and_add(&qstats->dequeued_bytes, skb->len);
        } else if (ret == TC_ACT_SHOT) {
            __sync_fetch_and_add(&qstats->dropped_packets, 1);
            __sync_fetch_and_add(&qstats->dropped_bytes, skb->len);
        }
    }
    
    /* Set skb priority based on class */
    skb->priority = cfg->priority;
    
    return ret;
}

char _license[] SEC("license") = "GPL";
