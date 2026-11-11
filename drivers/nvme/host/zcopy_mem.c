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
 * its PTE.  It must be dropped only once, though: if the driver still holds
 * fragment references, the page stays a page-pool page after we let go and
 * is seen again when its new mapping goes away.  zc_rx_test_clear_held()
 * tells whether we still hold it.
 */
#include <linux/hashtable.h>
#include <linux/mmu_notifier.h>
#include <linux/pagewalk.h>
#include <linux/sched/mm.h>
#include <linux/slab.h>
#include <linux/zcopy_ctx.h>
#include <linux/zcopy_mem.h>
#include <net/page_pool/helpers.h>
#include <net/zc_rx.h>

#define ZC_INV_BATCH 256

/* pages collected at invalidate_range_start, released at _end */
struct zcopy_inv_batch {
	struct list_head node;
	u16 nr;
	struct page *pages[ZC_INV_BATCH];
};

struct zcopy_inv_range {
	struct list_head node;
	const struct mmu_notifier_range *cookie;
	struct list_head batches;
};

/* one per registered mm */
struct zcopy_ctx {
	struct mmu_notifier mn;
	struct mm_struct *mm;
	struct hlist_node node;		/* in zcopy_ctx_hash */
	struct rcu_head rcu;
	spinlock_t lock;		/* protects inv_ranges */
	struct list_head inv_ranges;
};

/* mm -> zcopy_ctx, for a lock-free "already registered?" check per I/O */
static DEFINE_HASHTABLE(zcopy_ctx_hash, 8);
static DEFINE_SPINLOCK(zcopy_ctx_lock);

/* Drop the temporary refs taken at invalidate_range_start and the pp refs. */
static void zcopy_free_inv_range_pages(struct zcopy_inv_range *ir)
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
}

static void zcopy_free_inv_range(struct zcopy_inv_range *ir)
{
	zcopy_free_inv_range_pages(ir);
	kfree(ir);
}

/*
 * Add the page-pool pages mapped in [@addr, @end) of one PMD to @ir, each
 * with a temporary reference.  Called from invalidate_range_start, which
 * may run without mmap_lock (e.g. a COW fault under the per-VMA lock), so
 * this walks the page table directly instead of looking up VMAs.
 */
static void zcopy_collect_pmd(struct mm_struct *mm, pmd_t *pmd,
			      unsigned long addr, unsigned long end,
			      struct zcopy_inv_range *ir,
			      struct zcopy_inv_batch **bp)
{
	pte_t *start_pte, *pte;
	spinlock_t *ptl;

	start_pte = pte_offset_map_lock(mm, pmd, addr, &ptl);
	if (!start_pte)
		return;		/* none, or a huge PMD (never ours) */
	for (pte = start_pte; addr < end; addr += PAGE_SIZE, pte++) {
		pte_t pteval = ptep_get(pte);
		struct page *page;

		if (!pte_present(pteval) || pte_special(pteval) ||
		    !pfn_valid(pte_pfn(pteval)))
			continue;
		page = pte_page(pteval);
		if (!zc_rx_page_is_pp(page) || !zc_rx_test_clear_held(page))
			continue;	/* not ours, or already given back */
		if (WARN_ON_ONCE(!get_page_unless_zero(page))) {
			page_pool_put_full_page(page->pp, page, false);
			continue;
		}

		if (!*bp) {
			/* under the PTE lock: no sleeping allocation */
			*bp = kmalloc(sizeof(**bp), GFP_ATOMIC);
			if (!*bp) {
				put_page(page);	/* this page stays out of its pool */
				continue;
			}
			(*bp)->nr = 0;
			list_add_tail(&(*bp)->node, &ir->batches);
		}
		(*bp)->pages[(*bp)->nr++] = page;
		if ((*bp)->nr == ZC_INV_BATCH)
			*bp = NULL;
	}
	pte_unmap_unlock(start_pte, ptl);
}

static pmd_t *zcopy_find_pmd(struct mm_struct *mm, unsigned long addr)
{
	pgd_t *pgd = pgd_offset(mm, addr);
	p4d_t *p4d;
	pud_t *pud;

	if (pgd_none(*pgd) || pgd_bad(*pgd))
		return NULL;
	p4d = p4d_offset(pgd, addr);
	if (p4d_none(*p4d) || p4d_bad(*p4d))
		return NULL;
	pud = pud_offset(p4d, addr);
	if (pud_none(*pud) || pud_bad(*pud))
		return NULL;
	return pmd_offset(pud, addr);
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
	struct zcopy_inv_range local, *ir;
	struct zcopy_inv_batch *b = NULL;
	unsigned long addr, next;

	/* munmap (UNMAP); zap_page_range_single() e.g. madvise, and COW (CLEAR) */
	if (range->event != MMU_NOTIFY_UNMAP && range->event != MMU_NOTIFY_CLEAR)
		return 0;
	if (!mmu_notifier_range_blockable(range))
		return 0;

	/* this runs on every COW fault: allocate only if a pool page is found */
	INIT_LIST_HEAD(&local.batches);
	for (addr = range->start & PAGE_MASK; addr < range->end; addr = next) {
		pmd_t *pmd;

		next = pmd_addr_end(addr, range->end);
		pmd = zcopy_find_pmd(range->mm, addr);
		if (pmd && !pmd_none(*pmd))
			zcopy_collect_pmd(range->mm, pmd, addr, next, &local, &b);
	}
	if (list_empty(&local.batches))
		return 0;

	ir = kmalloc(sizeof(*ir), GFP_KERNEL);
	if (!ir) {
		zcopy_free_inv_range_pages(&local);	/* give them back right away */
		return 0;
	}
	INIT_LIST_HEAD(&ir->batches);
	list_splice(&local.batches, &ir->batches);
	ir->cookie = range;
	spin_lock(&ctx->lock);
	list_add_tail(&ir->node, &ctx->inv_ranges);
	spin_unlock(&ctx->lock);
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
		if (page && zc_rx_page_is_pp(page) && zc_rx_test_clear_held(page))
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
