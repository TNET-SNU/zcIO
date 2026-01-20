#include <linux/zcopy_ctx.h>
#include <linux/slab.h>

extern bool enable_zerocopy;



struct my_ctx *init_my_ctx_heap(int nr_pages, struct mm_struct *mm)
{
    size_t u_sz, p_sz, total;
    void *mem, *p;
    struct my_ctx *ctx;
    gfp_t gfp = GFP_KERNEL;

    if (!READ_ONCE(enable_zerocopy))
        return NULL;

#ifdef __GFP_SKIP_ZERO
    gfp |= __GFP_SKIP_ZERO;   /* init_on_alloc 등의 자동 memset을 스킵 */
#endif

    u_sz = array_size(nr_pages, sizeof(unsigned long));
    p_sz = array_size(nr_pages, sizeof(struct page *));
    if (u_sz == SIZE_MAX || p_sz == SIZE_MAX)
        return NULL;

    //total = sizeof(*ctx) + u_sz + 2 * p_sz; /* user_addr + pages + old_pages */
    total = sizeof(*ctx) + u_sz + p_sz; /* user_addr + old_pages */

    mem = kvmalloc(total, gfp);  /* 0-init 아님 */
    if (!mem)
        return NULL;

    /* ctx만 0으로 초기화 (배열은 0-init 안 함) */
    memset(mem, 0, sizeof(*ctx));
    ctx = mem;

    p = (void *)(ctx + 1);
    ctx->user_addr = p; p += u_sz;
   // ctx->pages     = p; p += p_sz;
    ctx->old_pages = p;

    ctx->magic = MY_CTX_MAGIC;
    ctx->nr_pages = nr_pages;
    ctx->tail_aligned = true;
    ctx->can_use_zerocopy = true;
    ctx->zc_flush_min = ULONG_MAX;
    ctx->inline_ctx = false;

    //mmgrab(mm);
    ctx->mm = mm;

    return ctx;
}

static struct my_ctx *init_my_ctx_inline(struct my_bio_private *priv, int nr_pages, struct mm_struct *mm)
{
    if (!READ_ONCE(enable_zerocopy))
        return NULL;

    struct my_ctx *ctx = &priv->inline_ctx;

    memset(ctx, 0, sizeof(*ctx));
    ctx->inline_ctx = true;
    ctx->user_addr = ctx->inline_user_addr;
    ctx->old_pages = ctx->inline_old_pages;

    ctx->magic = MY_CTX_MAGIC;
    ctx->nr_pages = nr_pages;

    ctx->mm = mm;

    return ctx;
}

struct my_ctx *init_my_ctx(struct my_bio_private *priv, int nr_pages, struct mm_struct *mm)
{
    if (!READ_ONCE(enable_zerocopy))
        return NULL;

    /* 작은 I/O는 inline으로: 4K/8K/16K(1/2/4 pages)에서 kvmalloc 제거 */
    if ((unsigned)nr_pages <= MYCTX_INLINE_PAGES) {
        return init_my_ctx_inline(priv, nr_pages, mm);
    }

    return init_my_ctx_heap(nr_pages, mm);
}


void free_my_ctx(struct my_ctx *ctx)
{
    if (!ctx || ctx->magic != MY_CTX_MAGIC)
        return;

    //if (ctx->mm)
    //    mmdrop(ctx->mm);

    ctx->magic = 0;
    if (!ctx->inline_ctx) {
        kvfree(ctx); 
    }
}


/*
struct my_ctx *init_my_ctx(int nr_pages, struct mm_struct *mm)
{
    struct my_ctx *ctx;
	if (!READ_ONCE(enable_zerocopy))
		return NULL;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx){
		return NULL;
	}

    ctx->magic = MY_CTX_MAGIC;
    ctx->nr_pages = nr_pages;
    ctx->tail_aligned = true;
    ctx->can_use_zerocopy = true;
    ctx->zc_flush_min = ULONG_MAX;

    ctx->user_addr = kmalloc_array(nr_pages, sizeof(*ctx->user_addr), GFP_KERNEL);
	if (!ctx->user_addr)
		goto free_ctx;

	ctx->pages = kmalloc_array(nr_pages, sizeof(*ctx->pages), GFP_KERNEL);
	if (!ctx->pages)
		goto free_user_addr;

	ctx->old_pages = kmalloc_array(nr_pages, sizeof(*ctx->old_pages), GFP_KERNEL);
	if (!ctx->old_pages)
		goto free_pages;
    
    mmgrab(mm);
    ctx->mm = mm;
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
    if (!ctx)
        return;

    if (ctx->magic != MY_CTX_MAGIC){
        return;
    }

    ctx->magic = 0;
    if (ctx->mm)
        mmdrop(ctx->mm);
    kfree(ctx->old_pages);
    kfree(ctx->user_addr);
    kfree(ctx->pages);
	kfree(ctx);
}

*/