#ifndef _chpl_hsa_h_
#define _chpl_hsa_h_

#include <hsa.h>
#include <hsa_ext_finalize.h>
#include "chpltypes.h"

#define HSA_ARGUMENT_ALIGN_BYTES 16

struct hsa_device_t {
    hsa_agent_t agent;
    hsa_isa_t isa;
    hsa_queue_t *command_queue;
    hsa_region_t kernarg_region;
    uint16_t max_items_per_group_dim;
};
typedef struct hsa_device_t hsa_device_t;
hsa_device_t hsa_device;

struct hsa_symbol_info_t {
    uint64_t kernel_object;
    uint32_t kernarg_segment_size;
    uint32_t group_segment_size;
    uint32_t private_segment_size;
};
typedef struct hsa_symbol_info_t hsa_symbol_info_t;

struct hsa_kernel_t {
    hsa_code_object_t code_object;
    hsa_executable_t executable;
    hsa_symbol_info_t * symbol_info;
};
typedef struct hsa_kernel_t hsa_kernel_t;
hsa_kernel_t kernel;

typedef struct __attribute__ ((aligned(HSA_ARGUMENT_ALIGN_BYTES))) {
    uint64_t gb0;
    uint64_t gb1;
    uint64_t gb2;
    uint64_t prnt_buff;
    uint64_t vqueue_pntr;
    uint64_t aqlwrap_pntr;
    uint64_t in;
    uint64_t out;
    uint32_t count;
} hsail_kernarg_t;

hsa_status_t get_gpu_agent(hsa_agent_t agent, void *data);
hsa_status_t get_kernarg_memory_region(hsa_region_t region, void* data);
int load_module_from_file(const char* file_name, char ** buf);
int chpl_hsa_initialize(void);
int hsa_shutdown(void);
int hsa_create_executable(const char * fn_name, const char * file_name);
void hsa_enqueue_kernel(void *inbuf, void *outbuf, size_t count,
                        hsa_signal_t completion_signal,
                        hsa_symbol_info_t * symbol_info,
                        hsail_kernarg_t * args);

int32_t hsa_reduce_int32(const char *op, int32_t *src, size_t count);
int64_t hsa_reduce_int64(const char *op, int64_t *src, size_t count);

#endif //_chpl_hsa_h_
