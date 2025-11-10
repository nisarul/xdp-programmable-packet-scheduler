/*
 * XDP QoS Scheduler - User-Space Control Plane
 * 
 * This program manages the XDP and TC eBPF programs:
 * - Loads/unloads XDP and TC programs
 * - Configures QoS policies from JSON files
 * - Updates runtime configuration
 * - Monitors statistics
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <getopt.h>
#include <net/if.h>
#include <netinet/in.h>
#include <linux/if_link.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <json-c/json.h>

/* We need the struct definitions but not xdp_md from common.h */
#define MAX_FLOWS 65536
#define MAX_CLASSES 8
#define MAX_RULES 256

/* Copy necessary structures without conflicts */
struct flow_tuple {
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u8 protocol;
    __u8 padding[3];
};

struct flow_state {
    __u64 packet_count;
    __u64 byte_count;
    __u64 last_seen;
    __u32 class_id;
    __u32 queue_id;
    __u32 tokens;
    __u32 last_token_update;
    __u16 priority;
    __u16 weight;
    __u32 deficit;
};

struct class_config {
    __u32 id;
    __u32 rate_limit;
    __u32 burst_size;
    __u16 priority;
    __u16 weight;
    __u32 min_bandwidth;
    __u32 max_bandwidth;
    __u32 flags;
};

struct queue_stats {
    __u64 enqueued_packets;
    __u64 enqueued_bytes;
    __u64 dequeued_packets;
    __u64 dequeued_bytes;
    __u64 dropped_packets;
    __u64 dropped_bytes;
    __u32 current_qlen;
    __u32 max_qlen;
    __u64 total_latency_ns;
};

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

struct global_config {
    __u32 sched_algorithm;
    __u32 default_class;
    __u32 num_classes;
    __u32 total_rate_limit;
    __u32 flags;
    __u32 quantum;
};

struct token_bucket {
    __u32 tokens;
    __u32 rate;
    __u32 capacity;
    __u64 last_update;
};

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
    __u8 priority;
    __u16 class_id;
};

enum sched_algorithm {
    SCHED_ROUND_ROBIN = 0,
    SCHED_WEIGHTED_FAIR_QUEUING = 1,
    SCHED_STRICT_PRIORITY = 2,
    SCHED_DEFICIT_ROUND_ROBIN = 3,
    SCHED_PIFO = 4,
};

#define DEFAULT_IFACE "eth0"
#define DEFAULT_CONFIG_PATH "configs/default.json"
#define BPF_PIN_DIR "/sys/fs/bpf/xdp_qos"

struct prog_context {
    struct bpf_object *xdp_obj;
    struct bpf_object *tc_obj;
    struct bpf_program *xdp_prog;
    struct bpf_program *tc_prog;
    int xdp_fd;
    int tc_fd;
    int ifindex;
    char ifname[IF_NAMESIZE];
    
    /* Map file descriptors */
    int flow_table_fd;
    int class_config_fd;
    int class_rules_fd;
    int cpu_stats_fd;
    int global_config_fd;
    int queue_stats_fd;
    int token_buckets_fd;
};

static struct prog_context ctx = {0};
static volatile sig_atomic_t keep_running = 1;

/* Signal handler for cleanup */
void sig_handler(int signo)
{
    printf("\nReceived signal %d, shutting down...\n", signo);
    keep_running = 0;
}

/* Create BPF pin directory */
int create_pin_dir(void)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "mkdir -p %s", BPF_PIN_DIR);
    return system(cmd);
}

/* Load XDP program */
int load_xdp_program(const char *filename)
{
    int err;
    
    printf("Loading XDP program from %s...\n", filename);
    
    ctx.xdp_obj = bpf_object__open_file(filename, NULL);
    if (libbpf_get_error(ctx.xdp_obj)) {
        fprintf(stderr, "Error opening XDP object file: %s\n", 
                strerror(errno));
        return -1;
    }
    
    err = bpf_object__load(ctx.xdp_obj);
    if (err) {
        fprintf(stderr, "Error loading XDP object: %s\n", strerror(-err));
        bpf_object__close(ctx.xdp_obj);
        return -1;
    }
    
    ctx.xdp_prog = bpf_object__find_program_by_name(ctx.xdp_obj, 
                                                     "xdp_packet_classifier");
    if (!ctx.xdp_prog) {
        fprintf(stderr, "Error finding XDP program\n");
        bpf_object__close(ctx.xdp_obj);
        return -1;
    }
    
    ctx.xdp_fd = bpf_program__fd(ctx.xdp_prog);
    
    printf("XDP program loaded successfully (fd=%d)\n", ctx.xdp_fd);
    return 0;
}

/* Attach XDP program to interface */
int attach_xdp_program(const char *ifname, __u32 flags)
{
    int err;
    
    ctx.ifindex = if_nametoindex(ifname);
    if (!ctx.ifindex) {
        fprintf(stderr, "Error getting ifindex for %s: %s\n",
                ifname, strerror(errno));
        return -1;
    }
    
    strncpy(ctx.ifname, ifname, IF_NAMESIZE - 1);
    
    /* First, try to detach any existing XDP program */
    printf("Checking for existing XDP program on %s...\n", ifname);
    err = bpf_xdp_detach(ctx.ifindex, flags, NULL);
    if (err && err != -ENOENT) {
        /* ENOENT means no program was attached, which is fine */
        fprintf(stderr, "Warning: Failed to detach existing XDP program: %s\n", 
                strerror(-err));
        /* Continue anyway - the attach might still work with XDP_FLAGS_REPLACE */
    } else if (!err) {
        printf("Detached existing XDP program\n");
    }
    
    printf("Attaching XDP program to interface %s (ifindex=%d)...\n",
           ifname, ctx.ifindex);
    
    err = bpf_xdp_attach(ctx.ifindex, ctx.xdp_fd, flags, NULL);
    if (err) {
        fprintf(stderr, "Error attaching XDP program: %s\n", strerror(-err));
        return -1;
    }
    
    printf("XDP program attached successfully\n");
    return 0;
}

/* Detach XDP program */
int detach_xdp_program(void)
{
    int err;
    
    if (!ctx.ifindex)
        return 0;
    
    printf("Detaching XDP program from interface %s...\n", ctx.ifname);
    
    err = bpf_xdp_detach(ctx.ifindex, 0, NULL);
    if (err) {
        fprintf(stderr, "Error detaching XDP program: %s\n", strerror(-err));
        return -1;
    }
    
    printf("XDP program detached successfully\n");
    return 0;
}

/* Load TC program using tc command (workaround for BTF issues) */
int load_tc_program(const char *filename)
{
    char cmd[512];
    int ret;
    
    printf("Loading TC program from %s...\n", filename);
    
    /* Save filename for later operations */
    static char tc_obj_path[256];
    snprintf(tc_obj_path, sizeof(tc_obj_path), "%s", filename);
    
    /* Add clsact qdisc (idempotent) */
    snprintf(cmd, sizeof(cmd), "tc qdisc add dev %s clsact 2>/dev/null || true", 
             ctx.ifname);
    ret = system(cmd);
    
    /* Attach TC BPF program to egress */
    snprintf(cmd, sizeof(cmd), 
             "tc filter add dev %s egress bpf da obj %s sec classifier direct-action 2>/dev/null",
             ctx.ifname, filename);
    ret = system(cmd);
    
    if (ret != 0) {
        fprintf(stderr, "Error attaching TC program via tc command\n");
        return -1;
    }
    
    printf("TC program loaded and attached successfully\n");
    
    /* Set dummy values so cleanup knows TC was set up */
    ctx.tc_obj = (struct bpf_object *)1;  /* Non-NULL marker */
    ctx.tc_fd = 1;
    
    return 0;
}

/* Attach TC program (now handled in load_tc_program) */
int attach_tc_program(void)
{
    /* TC attachment is now handled by load_tc_program() using tc command */
    printf("TC program already attached during load\n");
    return 0;
}

/* Detach TC program */
int detach_tc_program(void)
{
    char cmd[256];
    
    if (!ctx.ifindex || !ctx.tc_obj)
        return 0;
    
    printf("Detaching TC program from interface %s...\n", ctx.ifname);
    
    /* Remove TC filters and clsact qdisc using tc command */
    snprintf(cmd, sizeof(cmd), "tc filter del dev %s egress 2>/dev/null || true",
             ctx.ifname);
    system(cmd);
    
    snprintf(cmd, sizeof(cmd), "tc qdisc del dev %s clsact 2>/dev/null || true",
             ctx.ifname);
    system(cmd);
    
    printf("TC program detached successfully\n");
    
    return 0;
}

/* Get map file descriptors */
int get_map_fds(void)
{
    ctx.flow_table_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj, 
                                                         "flow_table");
    ctx.class_config_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj,
                                                           "class_config");
    ctx.class_rules_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj,
                                                          "class_rules");
    ctx.cpu_stats_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj,
                                                        "cpu_stats");
    ctx.global_config_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj,
                                                            "global_config");
    ctx.queue_stats_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj,
                                                          "queue_stats");
    ctx.token_buckets_fd = bpf_object__find_map_fd_by_name(ctx.xdp_obj,
                                                            "token_buckets");
    
    if (ctx.flow_table_fd < 0 || ctx.class_config_fd < 0 ||
        ctx.class_rules_fd < 0 || ctx.cpu_stats_fd < 0 ||
        ctx.global_config_fd < 0 || ctx.queue_stats_fd < 0 ||
        ctx.token_buckets_fd < 0) {
        fprintf(stderr, "Error getting map file descriptors\n");
        return -1;
    }
    
    printf("Map file descriptors obtained successfully\n");
    return 0;
}

/* Load configuration from JSON file */
int load_config_from_json(const char *config_file)
{
    struct json_object *root, *obj, *classes, *rules;
    struct global_config gcfg = {0};
    __u32 key = 0;
    int err;
    
    printf("Loading configuration from %s...\n", config_file);
    
    /* Parse JSON file */
    root = json_object_from_file(config_file);
    if (!root) {
        fprintf(stderr, "Error parsing JSON file: %s\n", config_file);
        return -1;
    }
    
    /* Parse global configuration */
    if (json_object_object_get_ex(root, "global", &obj)) {
        struct json_object *tmp;
        
        if (json_object_object_get_ex(obj, "scheduler", &tmp)) {
            const char *sched = json_object_get_string(tmp);
            if (strcmp(sched, "round_robin") == 0)
                gcfg.sched_algorithm = SCHED_ROUND_ROBIN;
            else if (strcmp(sched, "wfq") == 0)
                gcfg.sched_algorithm = SCHED_WEIGHTED_FAIR_QUEUING;
            else if (strcmp(sched, "strict_priority") == 0)
                gcfg.sched_algorithm = SCHED_STRICT_PRIORITY;
            else if (strcmp(sched, "drr") == 0)
                gcfg.sched_algorithm = SCHED_DEFICIT_ROUND_ROBIN;
            else if (strcmp(sched, "pifo") == 0)
                gcfg.sched_algorithm = SCHED_PIFO;
        }
        
        if (json_object_object_get_ex(obj, "default_class", &tmp))
            gcfg.default_class = json_object_get_int(tmp);
        
        if (json_object_object_get_ex(obj, "quantum", &tmp))
            gcfg.quantum = json_object_get_int(tmp);
    }
    
    /* Update global config map */
    err = bpf_map_update_elem(ctx.global_config_fd, &key, &gcfg, BPF_ANY);
    if (err) {
        fprintf(stderr, "Error updating global config: %s\n", strerror(errno));
        json_object_put(root);
        return -1;
    }
    
    /* Parse traffic classes */
    if (json_object_object_get_ex(root, "classes", &classes)) {
        int n_classes = json_object_array_length(classes);
        
        for (int i = 0; i < n_classes; i++) {
            struct json_object *cls = json_object_array_get_idx(classes, i);
            struct class_config cfg = {0};
            struct json_object *tmp;
            
            if (json_object_object_get_ex(cls, "id", &tmp))
                cfg.id = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(cls, "rate_limit", &tmp))
                cfg.rate_limit = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(cls, "burst_size", &tmp))
                cfg.burst_size = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(cls, "priority", &tmp))
                cfg.priority = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(cls, "weight", &tmp))
                cfg.weight = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(cls, "min_bandwidth", &tmp))
                cfg.min_bandwidth = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(cls, "max_bandwidth", &tmp))
                cfg.max_bandwidth = json_object_get_int(tmp);
            
            /* Update class config map */
            err = bpf_map_update_elem(ctx.class_config_fd, &cfg.id, &cfg, BPF_ANY);
            if (err) {
                fprintf(stderr, "Error updating class %u config: %s\n",
                        cfg.id, strerror(errno));
            }
            
            /* Initialize token bucket for this class */
            if (cfg.rate_limit > 0) {
                struct token_bucket tb = {
                    .tokens = cfg.burst_size,
                    .rate = cfg.rate_limit,
                    .capacity = cfg.burst_size,
                    .last_update = 0,
                };
                
                err = bpf_map_update_elem(ctx.token_buckets_fd, &cfg.id, &tb, BPF_ANY);
                if (err) {
                    fprintf(stderr, "Error initializing token bucket for class %u: %s\n",
                            cfg.id, strerror(errno));
                }
            }
        }
        
        printf("Configured %d traffic classes\n", n_classes);
    }
    
    /* Parse classification rules */
    if (json_object_object_get_ex(root, "rules", &rules)) {
        int n_rules = json_object_array_length(rules);
        
        for (int i = 0; i < n_rules && i < MAX_RULES; i++) {
            struct json_object *rule_obj = json_object_array_get_idx(rules, i);
            struct class_rule rule = {0};
            struct json_object *tmp;
            
            if (json_object_object_get_ex(rule_obj, "protocol", &tmp)) {
                const char *proto = json_object_get_string(tmp);
                if (strcmp(proto, "tcp") == 0)
                    rule.protocol = IPPROTO_TCP;
                else if (strcmp(proto, "udp") == 0)
                    rule.protocol = IPPROTO_UDP;
                else if (strcmp(proto, "icmp") == 0)
                    rule.protocol = IPPROTO_ICMP;
            }
            
            if (json_object_object_get_ex(rule_obj, "dst_port_min", &tmp))
                rule.dst_port_min = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(rule_obj, "dst_port_max", &tmp))
                rule.dst_port_max = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(rule_obj, "class_id", &tmp))
                rule.class_id = json_object_get_int(tmp);
            
            if (json_object_object_get_ex(rule_obj, "priority", &tmp))
                rule.priority = json_object_get_int(tmp);
            
            /* Default port range if not specified */
            if (rule.dst_port_max == 0 && rule.dst_port_min > 0)
                rule.dst_port_max = rule.dst_port_min;
            
            /* Update rules map */
            __u32 rule_key = i;
            err = bpf_map_update_elem(ctx.class_rules_fd, &rule_key, &rule, BPF_ANY);
            if (err) {
                fprintf(stderr, "Error updating rule %d: %s\n", i, strerror(errno));
            }
        }
        
        printf("Configured %d classification rules\n", n_rules);
    }
    
    json_object_put(root);
    printf("Configuration loaded successfully\n");
    return 0;
}

/* Print statistics */
void print_statistics(void)
{
    struct cpu_stats stats = {0};
    struct queue_stats qstats;
    __u32 key = 0;
    int err;
    
    /* Get CPU statistics */
    err = bpf_map_lookup_elem(ctx.cpu_stats_fd, &key, &stats);
    if (err) {
        fprintf(stderr, "Error reading CPU stats: %s\n", strerror(errno));
        return;
    }
    
    printf("\n===== Statistics =====\n");
    printf("Total packets:      %llu\n", stats.total_packets);
    printf("Total bytes:        %llu\n", stats.total_bytes);
    printf("Classified packets: %llu\n", stats.classified_packets);
    printf("Dropped packets:    %llu\n", stats.dropped_packets);
    printf("XDP_PASS:           %llu\n", stats.xdp_pass);
    printf("XDP_DROP:           %llu\n", stats.xdp_drop);
    printf("XDP_TX:             %llu\n", stats.xdp_tx);
    printf("XDP_REDIRECT:       %llu\n", stats.xdp_redirect);
    
    /* Print queue statistics per class */
    printf("\n===== Queue Statistics =====\n");
    for (int i = 0; i < MAX_CLASSES; i++) {
        key = i;
        err = bpf_map_lookup_elem(ctx.queue_stats_fd, &key, &qstats);
        if (err)
            continue;
        
        if (qstats.enqueued_packets > 0) {
            printf("\nClass %d:\n", i);
            printf("  Enqueued: %llu packets, %llu bytes\n",
                   qstats.enqueued_packets, qstats.enqueued_bytes);
            printf("  Dequeued: %llu packets, %llu bytes\n",
                   qstats.dequeued_packets, qstats.dequeued_bytes);
            printf("  Dropped:  %llu packets, %llu bytes\n",
                   qstats.dropped_packets, qstats.dropped_bytes);
            printf("  Queue length: %u (max: %u)\n",
                   qstats.current_qlen, qstats.max_qlen);
            
            if (qstats.dequeued_packets > 0) {
                __u64 avg_latency = qstats.total_latency_ns / qstats.dequeued_packets;
                printf("  Avg latency: %llu ns\n", avg_latency);
            }
        }
    }
    printf("\n");
}

/* Usage information */
void print_usage(const char *prog)
{
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("\nOptions:\n");
    printf("  -i, --interface IFACE   Network interface (default: %s)\n", DEFAULT_IFACE);
    printf("  -c, --config FILE       Configuration file (default: %s)\n", DEFAULT_CONFIG_PATH);
    printf("  -x, --xdp FILE          XDP object file\n");
    printf("  -t, --tc FILE           TC object file\n");
    printf("  -s, --stats INTERVAL    Print stats every INTERVAL seconds (0 = disable)\n");
    printf("  -d, --detach            Detach XDP program and exit\n");
    printf("  -h, --help              Show this help\n");
}

int main(int argc, char **argv)
{
    char *ifname = DEFAULT_IFACE;
    char *config_file = DEFAULT_CONFIG_PATH;
    char *xdp_file = NULL;
    char *tc_file = NULL;
    int stats_interval = 5;
    int detach_only = 0;
    int opt, err;
    
    static struct option long_options[] = {
        {"interface", required_argument, 0, 'i'},
        {"config", required_argument, 0, 'c'},
        {"xdp", required_argument, 0, 'x'},
        {"tc", required_argument, 0, 't'},
        {"stats", required_argument, 0, 's'},
        {"detach", no_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    /* Parse command line arguments */
    while ((opt = getopt_long(argc, argv, "i:c:x:t:s:dh", long_options, NULL)) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 'c':
            config_file = optarg;
            break;
        case 'x':
            xdp_file = optarg;
            break;
        case 't':
            tc_file = optarg;
            break;
        case 's':
            stats_interval = atoi(optarg);
            break;
        case 'd':
            detach_only = 1;
            break;
        case 'h':
            print_usage(argv[0]);
            return 0;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }
    
    /* Setup signal handlers */
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    
    /* Detach only mode */
    if (detach_only) {
        ctx.ifindex = if_nametoindex(ifname);
        if (ctx.ifindex)
            detach_xdp_program();
        return 0;
    }
    
    /* Validate XDP file */
    if (!xdp_file) {
        fprintf(stderr, "Error: XDP object file required (-x option)\n");
        print_usage(argv[0]);
        return 1;
    }
    
    /* Create BPF pin directory */
    create_pin_dir();
    
    /* Load and attach XDP program */
    err = load_xdp_program(xdp_file);
    if (err)
        return 1;
    
    err = attach_xdp_program(ifname, XDP_FLAGS_UPDATE_IF_NOEXIST);
    if (err) {
        bpf_object__close(ctx.xdp_obj);
        return 1;
    }
    
    /* Load and attach TC program (if provided) */
    if (tc_file) {
        err = load_tc_program(tc_file);
        if (err) {
            fprintf(stderr, "Warning: Failed to load TC program\n");
            goto cleanup;
        }
        
        err = attach_tc_program();
        if (err) {
            fprintf(stderr, "Warning: Failed to attach TC program\n");
            goto cleanup;
        }
    } else {
        printf("Note: No TC program specified (-t option), XDP only mode\n");
    }
    
    /* Get map file descriptors */
    err = get_map_fds();
    if (err) {
        goto cleanup;
    }
    
    /* Load configuration */
    err = load_config_from_json(config_file);
    if (err) {
        fprintf(stderr, "Warning: Failed to load configuration\n");
    }
    
    printf("\nXDP QoS Scheduler running on interface %s\n", ifname);
    printf("Press Ctrl+C to stop\n\n");
    
    /* Main loop - print statistics periodically */
    while (keep_running) {
        if (stats_interval > 0) {
            print_statistics();
            sleep(stats_interval);
        } else {
            pause();
        }
    }
    
cleanup:
    /* Cleanup */
    printf("\nCleaning up...\n");
    
    if (tc_file) {
        detach_tc_program();
        /* tc_obj is a marker, not a real object - don't close it */
    }
    
    detach_xdp_program();
    
    if (ctx.xdp_obj) {
        bpf_object__close(ctx.xdp_obj);
        ctx.xdp_obj = NULL;
    }
    
    printf("Shutdown complete\n");
    return 0;
}
