#ifndef __LINUX_ZCOPY_CTX_H
#define __LINUX_ZCOPY_CTX_H

#include <linux/types.h>
#include <linux/mm_types.h>
#include <linux/pagevec.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>
#include <linux/blk_types.h>

#define MY_CTX_MAGIC 0x12345678
struct my_ctx {
  u32 magic;
  int submit_cpu;
  unsigned long *user_addr;
  struct page **pages;
  struct page **old_pages;
  bool head_aligned;
  bool tail_aligned;
  size_t total_bytes;
  size_t committed_bytes;
  int index;
  int pending_cnt;
  int next_flush_index;
  struct mm_struct *mm;
  bool can_use_zerocopy;
  size_t remaining_bytes;
  int nr_pages;
  int old_nr_pages;
  int start_frag_page_index;
  int error; 

  struct delayed_work pend_flush_dwork;
  unsigned long last_activity_jiffies;
};

#define MY_BIO_PRIVATE_MAGIC 0x5a5a5a5a
struct my_bio_private{
    int magic;
	struct my_ctx *ctx;
    void *orig_private;
    bio_end_io_t *orig_end_io;
};


struct my_ctx *init_my_ctx(int nr_pages, struct mm_struct *mm);
void free_my_ctx(struct my_ctx *ctx);
#endif /* __LINUX_ZCOPY_CTX_H */