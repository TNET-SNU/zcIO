#ifndef __LINUX_ZCOPY_MEM_H
#define __LINUX_ZCOPY_MEM_H
#include <linux/mmu_notifier.h>
#include <linux/pagewalk.h>
#include <linux/hashtable.h>
#include <linux/sched/mm.h>

struct zcopy_ctx {
	struct mmu_notifier mn;
	struct mm_struct *mm;
	struct hlist_node node;
	struct rcu_head rcu;
	bool is_registered;
};

extern DECLARE_HASHTABLE(zcopy_ctx_hash, 8);
extern spinlock_t zcopy_ctx_lock;


void zcopy_try_register(void);
#endif