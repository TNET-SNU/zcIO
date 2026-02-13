#ifndef __LINUX_ZCOPY_CTX_H
#define __LINUX_ZCOPY_CTX_H

#include <linux/types.h>
#include <linux/mm_types.h>
#include <linux/pagevec.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>
#include <linux/blk_types.h>


// small i/o does not need to alloc pages (4pages = 16KB)
#define MYCTX_INLINE_PAGES 4


#define MY_CTX_MAGIC 0x12345678
struct my_ctx {
  u32 magic;
  bool inline_ctx;

  int nr_pages;
  int old_nr_pages;
  unsigned long *user_addr;
  struct page **old_pages;
  unsigned long inline_user_addr[MYCTX_INLINE_PAGES];
  struct page *inline_old_pages[MYCTX_INLINE_PAGES];
  
  struct mm_struct *mm;

  bool tail_aligned;
  bool head_aligned;
  size_t total_bytes;
  int index;
  bool can_use_zerocopy;
  size_t remaining_bytes;

  /* remap result */
  bool zc_staged;
  unsigned long zc_flush_min;
  unsigned long zc_flush_max;
  long zc_rss_delta[NR_MM_COUNTERS];
  int zc_staged_pages;

  int error; 
};

#define MY_BIO_PRIVATE_MAGIC 0x5a5a5a5a
struct my_bio_private{
    int magic;
	  struct my_ctx *ctx;
    struct my_ctx inline_ctx;
    void *orig_private;
    bio_end_io_t *orig_end_io;
};


struct my_ctx *init_my_ctx(struct my_bio_private *priv, int nr_pages, struct mm_struct *mm);
struct my_ctx *init_my_ctx_heap(int nr_pages, struct mm_struct *mm);
void free_my_ctx(struct my_ctx *ctx);
#endif /* __LINUX_ZCOPY_CTX_H */