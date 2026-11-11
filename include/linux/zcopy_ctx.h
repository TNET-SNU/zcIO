/* SPDX-License-Identifier: GPL-2.0 */
/*
 * zcIO host RX zero-copy: per-bio state shared by the block layer (which
 * records the reader's user addresses) and nvme-tcp (which remaps received
 * page-pool pages there).
 */
#ifndef __LINUX_ZCOPY_CTX_H
#define __LINUX_ZCOPY_CTX_H

#include <linux/types.h>
#include <linux/mm_types.h>
#include <linux/blk_types.h>

#define MY_CTX_MAGIC 0x12345678
struct my_ctx {
	u32 magic;

	int nr_pages;			/* capacity of user_addr[] and old_pages[] */
	int index;			/* pages recorded so far */
	int old_nr_pages;
	unsigned long *user_addr;	/* user address of each page of the bio */
	struct page **old_pages;	/* replaced page-pool pages, returned at completion */

	struct mm_struct *mm;		/* reader's mm, mmgrab()ed */

	bool head_aligned;
	bool tail_aligned;
	size_t total_bytes;

	/* remaps not yet made visible: TLB range and RSS change */
	bool zc_staged;
	unsigned long zc_flush_min;
	unsigned long zc_flush_max;
	long zc_rss_delta[NR_MM_COUNTERS];

	int error;			/* non-zero: do not use for zero-copy */
};

/* Replaces bi_private / bi_end_io of a read bio prepared for zero-copy. */
#define MY_BIO_PRIVATE_MAGIC 0x5a5a5a5a
struct my_bio_private {
	int magic;
	struct my_ctx *ctx;
	void *orig_private;
	bio_end_io_t *orig_end_io;
};

/* Host RX zero-copy switch, a module param of nvme-tcp (built-in). */
extern bool nvme_host_rx_zc;

static inline struct my_ctx *zc_bio_ctx(struct bio *bio)
{
	struct my_bio_private *priv = bio->bi_private;

	if (!priv || priv->magic != MY_BIO_PRIVATE_MAGIC)
		return NULL;
	if (!priv->ctx || priv->ctx->magic != MY_CTX_MAGIC)
		return NULL;
	return priv->ctx;
}

void zc_bio_prepare(struct bio *bio, int nr_pages);
void zc_bio_abort(struct bio *bio);
void zc_bio_pages_added(struct bio *bio);

#endif /* __LINUX_ZCOPY_CTX_H */
