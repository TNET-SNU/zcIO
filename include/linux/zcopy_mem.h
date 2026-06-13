#ifndef __LINUX_ZCOPY_MEM_H
#define __LINUX_ZCOPY_MEM_H
#include <linux/mmu_notifier.h>
#include <linux/pagewalk.h>
#include <linux/hashtable.h>
#include <linux/sched/mm.h>

#define ZC_INV_BATCH 256

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

struct zcopy_ctx {
	struct mmu_notifier mn;
	struct mm_struct *mm;

	struct hlist_node node;
	struct rcu_head rcu;
	bool is_registered;

	spinlock_t lock;
	struct list_head inv_ranges;
};



extern DECLARE_HASHTABLE(zcopy_ctx_hash, 8);
extern spinlock_t zcopy_ctx_lock;


int zcopy_try_register(struct mm_struct *mm);
#endif