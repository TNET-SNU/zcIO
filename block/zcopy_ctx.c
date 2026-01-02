#include <linux/zcopy_ctx.h>
#include <linux/slab.h>


struct my_ctx *init_my_ctx(int nr_pages, struct mm_struct *mm)
{
	struct my_ctx *ctx = kzalloc(sizeof(struct my_ctx), GFP_KERNEL);
	if (!ctx){
		return NULL;
	}
    ctx->magic = MY_CTX_MAGIC;
    ctx->user_addr = kzalloc(nr_pages * sizeof(unsigned long), GFP_KERNEL);
    if (!ctx->user_addr){
        goto free_ctx;
    }
    ctx->pages = kzalloc(nr_pages * sizeof(struct page *), GFP_KERNEL);
    if (!ctx->pages){
        goto free_user_addr;
    }
    ctx->old_pages = kzalloc(nr_pages * sizeof(struct page *), GFP_KERNEL);
    if (!ctx->old_pages){
        goto free_pages;
    }
    
    mmgrab(mm);

    ctx->head_aligned = true;
    ctx->tail_aligned = true;
    ctx->total_bytes = 0;
    ctx->committed_bytes = 0;
    ctx->index = 0;
    ctx->pending_cnt = 0;
    ctx->next_flush_index = 0;
    ctx->mm = mm;
    ctx->can_use_zerocopy = true;
    ctx->remaining_bytes = 0;
    ctx->start_frag_page_index = 0;
    ctx->nr_pages = nr_pages;
    ctx->old_nr_pages = 0;
    ctx->error = 0;
    ctx->submit_cpu = raw_smp_processor_id();
	return ctx;

free_pages:
    kfree(ctx->pages);
free_user_addr:
    kfree(ctx->user_addr);
free_ctx:
    kfree(ctx);
    return NULL;
}

void free_my_ctx(struct my_ctx *ctx)
{
    if (ctx->magic != MY_CTX_MAGIC){
        return;
    }
    mmdrop(ctx->mm);
    kfree(ctx->old_pages);
    kfree(ctx->user_addr);
    kfree(ctx->pages);
	kfree(ctx);
}

