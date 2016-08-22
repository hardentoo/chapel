
#include "chpl-hsa.h"
#include "chplrt.h"
#include "chplexit.h"
#include "chpl-mem.h"

/*enum ReduceOp {
    MAX,
    MIN,
    SUM,
    PROD,
    BITAND,
    BITOR,
    BITXOR,
    LOGAND,
    LOGOR
  };
*/

/*
 * Enqueue a reduction kernel
 */
static inline
void hsa_enqueue_reducekernel(void *inbuf, void *outbuf, size_t count,
                              uint32_t grid_size_x,
                              hsa_signal_t completion_signal,
                              hsa_symbol_info_t *symbol_info,
                              hsail_reduce_kernarg_t *args)
{
  hsa_kernel_dispatch_packet_t * dispatch_packet;
  hsa_queue_t *command_queue = hsa_device.command_queue;

  uint64_t index = hsa_queue_add_write_index_acq_rel(command_queue, 1);
  while (index - hsa_queue_load_read_index_acquire(command_queue) >=
      command_queue->size);
  dispatch_packet =
    (hsa_kernel_dispatch_packet_t*)(command_queue->base_address) +
    (index % command_queue->size);
  memset(dispatch_packet, 0, sizeof(hsa_kernel_dispatch_packet_t));
  dispatch_packet->setup |= 3 <<
    HSA_KERNEL_DISPATCH_PACKET_SETUP_DIMENSIONS;
  dispatch_packet->header |= HSA_FENCE_SCOPE_SYSTEM <<
    HSA_PACKET_HEADER_ACQUIRE_FENCE_SCOPE;
  dispatch_packet->header |= HSA_FENCE_SCOPE_SYSTEM <<
    HSA_PACKET_HEADER_RELEASE_FENCE_SCOPE;
  dispatch_packet->header |= 1 << HSA_PACKET_HEADER_BARRIER;
  dispatch_packet->grid_size_x = grid_size_x;
  dispatch_packet->grid_size_y = 1;
  dispatch_packet->grid_size_z = 1;
  dispatch_packet->workgroup_size_x = WKGRP_SIZE;
  dispatch_packet->workgroup_size_y = 1;
  dispatch_packet->workgroup_size_z = 1;
  dispatch_packet->private_segment_size = symbol_info->private_segment_size;
  dispatch_packet->group_segment_size = symbol_info->group_segment_size;
  dispatch_packet->kernel_object = symbol_info->kernel_object;

  args->gb0 = 0;
  args->gb1 = 0;
  args->gb2 = 0;
  args->prnt_buff = 0;
  args->vqueue_pntr = 0;
  args->aqlwrap_pntr = 0;

  args->in = (uint64_t)inbuf;
  args->out = (uint64_t)outbuf;
  args->count = (uint32_t)count;

  dispatch_packet->kernarg_address = (void*)args;
  dispatch_packet->completion_signal = completion_signal;

  __atomic_store_n((uint8_t*)(&dispatch_packet->header),
      (uint8_t)HSA_PACKET_TYPE_KERNEL_DISPATCH,
      __ATOMIC_RELEASE);

  hsa_signal_store_release(command_queue->doorbell_signal, index);
}

int32_t hsa_reduce_int32(const char *op, int32_t *src, size_t count) {
  int32_t res;
  int incount, outcount, iter, i, in, out;
  int32_t * darray[2];
//  struct timeval start, end, int1, int2, int3, int15;
//  double elapsed_time = 0.0;
  uint32_t max_num_wkgrps, num_wkgroups, grid_size_x;
  hsa_signal_t completion_signal;
  hsail_reduce_kernarg_t **args;
  hsa_symbol_info_t * symbol_info;
  //printf ("count is %lu\n", count);
  symbol_info = &kernel.symbol_info[0];
  darray[0] = src;
  if (0 != chpl_posix_memalign((void **) &darray[1], 64,
                               count * sizeof(int32_t))) {
    chpl_exit_any(1);
  }
  /*FIXME: This is an overestimation. Allocation count should be equal to the
   * number of iters.
   */
  args = chpl_malloc(count * sizeof (hsail_reduce_kernarg_t*));
 // gettimeofday(&start, NULL);
  hsa_signal_create(count, 0, NULL, &completion_signal);

  /*for (i = 0; i < count; ++i ) {
    printf("value for %d is %d\n", i, *(darray[0] + i));
    darray[1][i] = 0;
  }*/

  incount = count;
  max_num_wkgrps = incount / WKGRP_SIZE;
  num_wkgroups = (max_num_wkgrps + SEQ_CHUNK_SIZE  - 1) / SEQ_CHUNK_SIZE;
  grid_size_x = num_wkgroups * WKGRP_SIZE;
  outcount = num_wkgroups;
  iter = 0;
  while (incount > WKGRP_SIZE) {
    in = (iter & 1);
    out = (iter & 1) ^ 1;
  //  gettimeofday(&int1, NULL);
    hsa_memory_allocate(hsa_device.kernarg_region,
                        symbol_info->kernarg_segment_size,
                        (void**)&args[iter]);
   // gettimeofday(&int15, NULL);
    hsa_enqueue_reducekernel((void*)darray[in], (void*)darray[out], incount,
                              grid_size_x, completion_signal, symbol_info,
                              args[iter]);
    //gettimeofday(&int2, NULL);
    iter += 1;
    incount = outcount;
    max_num_wkgrps = incount / WKGRP_SIZE;
    num_wkgroups = (max_num_wkgrps + SEQ_CHUNK_SIZE  - 1) / SEQ_CHUNK_SIZE;
    grid_size_x = num_wkgroups * WKGRP_SIZE;
    outcount = num_wkgroups;
  }

  iter -= 1;
  while (hsa_signal_wait_acquire(completion_signal, HSA_SIGNAL_CONDITION_LT,
         count - iter, UINT64_MAX, HSA_WAIT_STATE_ACTIVE) > count - iter - 1);
  //gettimeofday(&int3, NULL);
  res = 0;
  for (i = 0; i < incount; ++i) res += darray[(iter & 1) ^ 1][i];

  for (i = 0; i <= iter; ++i) {
    hsa_memory_free((void*)args[i]);
  }
  chpl_free (args);
  hsa_signal_destroy(completion_signal);
  chpl_free (darray[1]);
/*  gettimeofday(&end, NULL);
  elapsed_time = ((int1.tv_sec * 1000000 + int1.tv_usec) -
      (start.tv_sec * 1000000 + start.tv_usec));
  printf("time taken, first: %lf msec\n", elapsed_time / 1000.00);
  elapsed_time = ((int15.tv_sec * 1000000 + int15.tv_usec) -
      (int1.tv_sec * 1000000 + int1.tv_usec));
  printf("time taken, 1.5: %lf msec\n", elapsed_time / 1000.00);
  elapsed_time = ((int2.tv_sec * 1000000 + int2.tv_usec) -
      (int15.tv_sec * 1000000 + int15.tv_usec));
  printf("time taken, second: %lf msec\n", elapsed_time / 1000.00);
  elapsed_time = ((int3.tv_sec * 1000000 + int3.tv_usec) -
      (int2.tv_sec * 1000000 + int2.tv_usec));
  printf("time taken, third: %lf msec\n", elapsed_time / 1000.00);

  elapsed_time = ((end.tv_sec * 1000000 + end.tv_usec) -
      (start.tv_sec * 1000000 + start.tv_usec));
  printf("time taken: %lf msec\n", elapsed_time / 1000.00);*/
  return res;
}

int64_t hsa_reduce_int64(const char *op, int64_t *src, size_t count) {
  int64_t res;
  int incount, outcount, iter, i, in, out;
  int64_t * darray[2];
  uint32_t max_num_wkgrps, num_wkgroups, grid_size_x;
  hsa_signal_t completion_signal;
  hsail_reduce_kernarg_t **args;
  hsa_symbol_info_t * symbol_info;
  //FIXME: use the op argument
  /*if (!strcasecmp(op, "Max"))
    opType = MAX;
    else if (!strcasecmp(op, "Min"))
    opType = MIN;
    else if (!strcasecmp(op, "Sum"))
    opType = SUM;
    else if (!strcasecmp(op, "Product"))
    opType = PROD;
    else if (!strcasecmp(op, "LogicalAnd"))
    opType = LOGAND;
    else if (!strcasecmp(op, "LogicalOr"))
    opType = LOGOR;
    else if (!strcasecmp(op, "BitwiseAnd"))
    opType = BITAND;
    else if (!strcasecmp(op, "BitwiseOr"))
    opType = BITOR;
    else if (!strcasecmp(op, "BitwiseXor"))
    opType = BITXOR; */
  symbol_info = &kernel.symbol_info[0];
  darray[0] = src;
  if (0 != chpl_posix_memalign((void **) &darray[1], 64,
                               count * sizeof(int64_t))) {
    chpl_exit_any(1);
  }
  args = chpl_malloc(count * sizeof (hsail_reduce_kernarg_t*));
  hsa_signal_create(count, 0, NULL, &completion_signal);

  incount = count;
  max_num_wkgrps = incount / WKGRP_SIZE;
  num_wkgroups = (max_num_wkgrps + SEQ_CHUNK_SIZE  - 1) / SEQ_CHUNK_SIZE;
  grid_size_x = num_wkgroups * WKGRP_SIZE;
  outcount = num_wkgroups;
  iter = 0;
  while (incount > WKGRP_SIZE) {
    in = (iter & 1);
    out = (iter & 1) ^ 1;
    hsa_memory_allocate(hsa_device.kernarg_region,
                        symbol_info->kernarg_segment_size,
                        (void**)&args[iter]);
    hsa_enqueue_reducekernel((void*)darray[in], (void*)darray[out], incount,
                             grid_size_x, completion_signal, symbol_info,
                             args[iter]);
    iter += 1;
    incount = outcount;
    max_num_wkgrps = incount / WKGRP_SIZE;
    num_wkgroups = (max_num_wkgrps + SEQ_CHUNK_SIZE  - 1) / SEQ_CHUNK_SIZE;
    grid_size_x = num_wkgroups * WKGRP_SIZE;
    outcount = num_wkgroups;
  }

  iter -= 1;
  while (hsa_signal_wait_acquire(completion_signal, HSA_SIGNAL_CONDITION_LT,
         count - iter, UINT64_MAX, HSA_WAIT_STATE_ACTIVE) > count - iter - 1);
  res = 0;
  for (i = 0; i < incount; ++i) res += darray[(iter & 1) ^ 1][i];

  for (i = 0; i <= iter; ++i) {
    hsa_memory_free((void*)args[i]);
  }
  chpl_free (args);
  hsa_signal_destroy(completion_signal);
  chpl_free (darray[1]);
  return res;
}