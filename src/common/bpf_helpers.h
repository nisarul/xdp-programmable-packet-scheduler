#ifndef __BPF_HELPERS_H__
#define __BPF_HELPERS_H__

#include <linux/bpf.h>

/* BPF helper function definitions */
static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *) 1;
static int (*bpf_map_update_elem)(void *map, const void *key, const void *value, __u64 flags) = (void *) 2;
static int (*bpf_map_delete_elem)(void *map, const void *key) = (void *) 3;
static __u64 (*bpf_ktime_get_ns)(void) = (void *) 5;
static int (*bpf_trace_printk)(const char *fmt, int fmt_size, ...) = (void *) 6;
static __u32 (*bpf_get_smp_processor_id)(void) = (void *) 8;
static int (*bpf_redirect)(int ifindex, __u64 flags) = (void *) 23;
static int (*bpf_redirect_map)(void *map, __u32 key, __u64 flags) = (void *) 51;
static __u64 (*bpf_get_prandom_u32)(void) = (void *) 7;
static int (*bpf_xdp_adjust_head)(void *ctx, int delta) = (void *) 44;
static int (*bpf_xdp_adjust_meta)(void *ctx, int delta) = (void *) 54;
static __u64 (*bpf_csum_diff)(__u32 *from, __u32 from_size, __u32 *to, __u32 to_size, __u32 seed) = (void *) 28;

/* Debugging macro */
#define DEBUG 1

#if DEBUG
#define bpf_debug(fmt, ...)                                     \
    ({                                                          \
        char ____fmt[] = fmt;                                   \
        bpf_trace_printk(____fmt, sizeof(____fmt),              \
                         ##__VA_ARGS__);                        \
    })
#else
#define bpf_debug(fmt, ...) do { } while (0)
#endif

/* License */
char _license[] __attribute__((section("license"), used)) = "GPL";

#endif /* __BPF_HELPERS_H__ */
