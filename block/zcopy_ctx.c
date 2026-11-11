// SPDX-License-Identifier: GPL-2.0
/*
 * zcIO host RX zero-copy: prepare user-memory read bios so nvme-tcp can
 * remap received page-pool pages into the reader's buffer, and give the
 * replaced page-pool pages back when the bio completes.
 */
#include <linux/bio.h>
#include <linux/slab.h>
#include <linux/sched/mm.h>
#include <linux/zcopy_ctx.h>
#include <linux/zcopy_mem.h>
#include <net/page_pool/helpers.h>
#include <net/zc_rx.h>

static struct my_ctx *zc_ctx_alloc(int nr_pages, struct mm_struct *mm)
{
	size_t u_sz = array_size(nr_pages, sizeof(unsigned long));
	size_t p_sz = array_size(nr_pages, sizeof(struct page *));
	struct my_ctx *ctx;

	if (u_sz == SIZE_MAX || p_sz == SIZE_MAX)
		return NULL;
	/* the arrays are written before they are read: only clear the ctx */
	ctx = kvmalloc(sizeof(*ctx) + u_sz + p_sz, GFP_KERNEL);
	if (!ctx)
		return NULL;
	memset(ctx, 0, sizeof(*ctx));

	ctx->magic = MY_CTX_MAGIC;
	ctx->nr_pages = nr_pages;
	ctx->user_addr = (void *)(ctx + 1);
	ctx->old_pages = (void *)ctx->user_addr + u_sz;
	ctx->head_aligned = true;
	ctx->tail_aligned = true;
	ctx->zc_flush_min = ULONG_MAX;
	/* the remap and TLB flush may run after the reader has exited */
	mmgrab(mm);
	ctx->mm = mm;
	return ctx;
}

static void zc_ctx_free(struct my_ctx *ctx)
{
	mmdrop(ctx->mm);
	kvfree(ctx);
}

static void zc_bio_end_io(struct bio *bio)
{
	struct my_bio_private *priv = bio->bi_private;
	struct my_ctx *ctx = priv->ctx;
	int i;

	bio->bi_private = priv->orig_private;
	bio->bi_end_io = priv->orig_end_io;
	/* first: this unpins the bio's pages */
	priv->orig_end_io(bio);

	/* page-pool pages replaced by a re-read: their PTE and pp references */
	for (i = 0; i < ctx->old_nr_pages; i++) {
		struct page *page = ctx->old_pages[i];

		put_page(page);
		page_pool_put_full_page(page->pp, page, false);
	}
	zc_ctx_free(ctx);
	kfree(priv);
}

/*
 * Prepare @bio, a read into the current task's memory spanning at most
 * @nr_pages pages, for host RX zero-copy.  Call before
 * bio_iov_iter_get_pages(); a no-op when zero-copy is off.
 */
void zc_bio_prepare(struct bio *bio, int nr_pages)
{
	struct my_bio_private *priv;

	if (!READ_ONCE(nvme_host_rx_zc) || !current->mm)
		return;

	priv = kmalloc(sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return;
	priv->ctx = zc_ctx_alloc(nr_pages, current->mm);
	if (!priv->ctx) {
		kfree(priv);
		return;
	}
	priv->magic = MY_BIO_PRIVATE_MAGIC;
	priv->orig_private = bio->bi_private;
	priv->orig_end_io = bio->bi_end_io;
	bio->bi_private = priv;
	bio->bi_end_io = zc_bio_end_io;

	zcopy_try_register(current->mm);
}

/* bio_iov_iter_get_pages() failed: undo zc_bio_prepare(). */
void zc_bio_abort(struct bio *bio)
{
	struct my_bio_private *priv = bio->bi_private;

	if (!zc_bio_ctx(bio))
		return;
	bio->bi_private = priv->orig_private;
	bio->bi_end_io = priv->orig_end_io;
	zc_ctx_free(priv->ctx);
	kfree(priv);
}

/* After bio_iov_iter_get_pages(): record how much the bio covers. */
void zc_bio_pages_added(struct bio *bio)
{
	struct my_ctx *ctx = zc_bio_ctx(bio);

	if (!ctx)
		return;
	ctx->total_bytes = bio->bi_iter.bi_size;
	ctx->nr_pages = ctx->index;
}
