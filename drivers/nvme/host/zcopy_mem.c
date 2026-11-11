// SPDX-License-Identifier: GPL-2.0
/*
 * zcIO host RX zero-copy: give page-pool pages back when their user
 * mapping goes away.
 *
 * A page that nvme-tcp remapped into a reader's buffer holds one page-pool
 * reference (pp_ref_count) besides its PTE's page reference.  When the PTE
 * is zapped (munmap, madvise(MADV_DONTNEED), exit) that page-pool
 * reference must be dropped, or the page never returns to its pool.
 *
 * Dropping it while the page is still mapped (e.g. mremap() moves the PTE)
 * is safe: page_pool does not recycle a page whose refcount is above one,
 * it releases it, and the page then lives on as an ordinary page owned by
 * its PTE.
 */
#include <linux/zcopy_mem.h>
#include <linux/zcopy_ctx.h>
#include <net/page_pool/helpers.h>
#include <net/zc_rx.h>

/* mm -> zcopy_ctx, for a lock-free "already registered?" check per I/O */
DEFINE_HASHTABLE(zcopy_ctx_hash, 8);
DEFINE_SPINLOCK(zcopy_ctx_lock);

/* Drop the temporary refs taken at invalidate_range_start and the pp refs. */
static void zcopy_free_inv_range(struct zcopy_inv_range *ir)
{
	struct zcopy_inv_batch *b, *bn;
	int i;

	list_for_each_entry_safe(b, bn, &ir->batches, node) {
		for (i = 0; i < b->nr; i++) {
			struct page *page = b->pages[i];

			put_page(page);
			page_pool_put_full_page(page->pp, page, false);
		}
		list_del(&b->node);
		kfree(b);
	}
	kfree(ir);
}

/* Page-pool page mapped at @addr, with a reference taken, or NULL. */
static struct page *zcopy_peek_pp_page_get(struct vm_area_struct *vma,
					   unsigned long addr)
{
	struct mm_struct *mm = vma->vm_mm;
	struct page *page, *ret = NULL;
	spinlock_t *ptl;
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	pgd = pgd_offset(mm, addr);
	if (pgd_none(*pgd) || pgd_bad(*pgd))
		return NULL;
	p4d = p4d_offset(pgd, addr);
	if (p4d_none(*p4d) || p4d_bad(*p4d))
		return NULL;
	pud = pud_offset(p4d, addr);
	if (pud_none(*pud) || pud_bad(*pud))
		return NULL;
	pmd = pmd_offset(pud, addr);

	pte = pte_offset_map_lock(mm, pmd, addr, &ptl);
	if (!pte)
		return NULL;
	if (pte_present(ptep_get(pte))) {
		page = vm_normal_page(vma, addr, ptep_get(pte));
		if (page && zc_rx_page_is_pp(page) && get_page_unless_zero(page))
			ret = page;
	}
	pte_unmap_unlock(pte, ptl);
	return ret;
}

/*
 * Before PTEs are removed, collect the page-pool pages in the range (with
 * a temporary reference so they stay valid); they are given back to their
 * pool at invalidate_range_end, after the zap dropped the PTE references.
 */
static int zcopy_mn_invalidate_range_start(struct mmu_notifier *mn,
					   const struct mmu_notifier_range *range)
{
	struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
	struct zcopy_inv_range *ir = NULL;
	struct zcopy_inv_batch *b = NULL;
	struct vm_area_struct *vma = NULL;
	unsigned long addr;

	/* munmap (UNMAP) and zap_page_range_single(), e.g. madvise (CLEAR) */
	if (range->event != MMU_NOTIFY_UNMAP && range->event != MMU_NOTIFY_CLEAR)
		return 0;
	if (!mmu_notifier_range_blockable(range))
		return 0;

	for (addr = range->start & PAGE_MASK; addr < range->end; addr += PAGE_SIZE) {
		struct page *page;

		if (!vma || addr >= vma->vm_end) {
			vma = find_vma(range->mm, addr);
			if (!vma || vma->vm_start >= range->end)
				break;
			if (addr < vma->vm_start)
				addr = vma->vm_start;
		}

		page = zcopy_peek_pp_page_get(vma, addr);
		if (!page)
			continue;

		if (!ir) {
			ir = kmalloc(sizeof(*ir), GFP_KERNEL);
			if (!ir)
				goto drop;
			INIT_LIST_HEAD(&ir->batches);
			ir->cookie = range;
		}
		if (!b) {
			b = kmalloc(sizeof(*b), GFP_KERNEL);
			if (!b)
				goto drop;
			b->nr = 0;
			list_add_tail(&b->node, &ir->batches);
		}
		b->pages[b->nr++] = page;
		if (b->nr == ZC_INV_BATCH)
			b = NULL;
		continue;
drop:
		put_page(page);	/* out of memory: this page stays out of its pool */
	}

	if (ir) {
		spin_lock(&ctx->lock);
		list_add_tail(&ir->node, &ctx->inv_ranges);
		spin_unlock(&ctx->lock);
	}
	return 0;
}

static void zcopy_mn_invalidate_range_end(struct mmu_notifier *mn,
					  const struct mmu_notifier_range *range)
{
	struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
	struct zcopy_inv_range *pos, *found = NULL;

	spin_lock(&ctx->lock);
	list_for_each_entry(pos, &ctx->inv_ranges, node) {
		if (pos->cookie == range) {
			list_del(&pos->node);
			found = pos;
			break;
		}
	}
	spin_unlock(&ctx->lock);

	if (found)
		zcopy_free_inv_range(found);
}

/*
 * exit_mmap() calls ->release before it zaps the address space, and no
 * invalidate callbacks follow, so give back the pp references of the
 * pages that are still mapped now.  Their PTE references are dropped by
 * the zap that follows.
 */
static int zcopy_release_pmd_entry(pmd_t *pmd, unsigned long addr,
				   unsigned long next, struct mm_walk *walk)
{
	pte_t *start_pte, *pte;
	spinlock_t *ptl;

	start_pte = pte_offset_map_lock(walk->mm, pmd, addr, &ptl);
	if (!start_pte)
		return 0;
	for (pte = start_pte; addr != next; addr += PAGE_SIZE, pte++) {
		pte_t pteval = ptep_get(pte);
		struct page *page;

		if (!pte_present(pteval))
			continue;
		page = vm_normal_page(walk->vma, addr, pteval);
		if (page && zc_rx_page_is_pp(page))
			page_pool_put_full_page(page->pp, page, false);
	}
	pte_unmap_unlock(start_pte, ptl);
	return 0;
}

static const struct mm_walk_ops zcopy_release_walk_ops = {
	.pmd_entry	= zcopy_release_pmd_entry,
	.walk_lock	= PGWALK_RDLOCK,
};

static void zcopy_mn_release(struct mmu_notifier *mn, struct mm_struct *mm)
{
	struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
	struct zcopy_inv_range *ir, *n;
	LIST_HEAD(pending);

	spin_lock(&zcopy_ctx_lock);
	hash_del_rcu(&ctx->node);
	spin_unlock(&zcopy_ctx_lock);

	/* ranges whose invalidate_range_end will not come any more */
	spin_lock(&ctx->lock);
	list_splice_init(&ctx->inv_ranges, &pending);
	spin_unlock(&ctx->lock);
	list_for_each_entry_safe(ir, n, &pending, node) {
		list_del(&ir->node);
		zcopy_free_inv_range(ir);
	}

	mmap_read_lock(mm);
	walk_page_range(mm, 0, TASK_SIZE, &zcopy_release_walk_ops, NULL);
	mmap_read_unlock(mm);

	/* frees ctx via ->free_notifier once no notifier callback can run */
	mmu_notifier_put(mn);
}

static struct mmu_notifier *zcopy_alloc_notifier(struct mm_struct *mm)
{
	struct zcopy_ctx *ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);

	if (!ctx)
		return ERR_PTR(-ENOMEM);
	spin_lock_init(&ctx->lock);
	INIT_HLIST_NODE(&ctx->node);
	INIT_LIST_HEAD(&ctx->inv_ranges);
	ctx->mm = mm;
	return &ctx->mn;
}

static void zcopy_free_notifier(struct mmu_notifier *mn)
{
	/* hash readers are plain RCU */
	kfree_rcu(container_of(mn, struct zcopy_ctx, mn), rcu);
}

static const struct mmu_notifier_ops zcopy_mn_ops = {
	.release		= zcopy_mn_release,
	.invalidate_range_start	= zcopy_mn_invalidate_range_start,
	.invalidate_range_end	= zcopy_mn_invalidate_range_end,
	.alloc_notifier		= zcopy_alloc_notifier,
	.free_notifier		= zcopy_free_notifier,
};

static bool zcopy_mm_registered(struct mm_struct *mm)
{
	struct zcopy_ctx *ctx;
	bool found = false;

	rcu_read_lock();
	hash_for_each_possible_rcu(zcopy_ctx_hash, ctx, node, (unsigned long)mm) {
		if (ctx->mm == mm) {
			found = true;
			break;
		}
	}
	rcu_read_unlock();
	return found;
}

/* Register the notifier for @mm once, before its first zero-copy read. */
int zcopy_try_register(struct mm_struct *mm)
{
	struct mmu_notifier *mn;
	struct zcopy_ctx *ctx;

	if (!READ_ONCE(nvme_host_rx_zc))
		return 0;
	if (zcopy_mm_registered(mm))
		return 0;

	/* returns the existing subscription, with a reference, if any */
	mn = mmu_notifier_get(&zcopy_mn_ops, mm);
	if (IS_ERR(mn))
		return PTR_ERR(mn);
	ctx = container_of(mn, struct zcopy_ctx, mn);

	spin_lock(&zcopy_ctx_lock);
	if (hlist_unhashed(&ctx->node)) {
		hash_add_rcu(zcopy_ctx_hash, &ctx->node, (unsigned long)mm);
		spin_unlock(&zcopy_ctx_lock);
		return 0;	/* this reference is dropped in ->release */
	}
	spin_unlock(&zcopy_ctx_lock);

	mmu_notifier_put(mn);	/* lost a race: drop the extra reference */
	return 0;
}
