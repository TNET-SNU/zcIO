#include <linux/zcopy_mem.h>
#include <net/page_pool/helpers.h>
#include <linux/rmap.h>

DEFINE_HASHTABLE(zcopy_ctx_hash, 8);
DEFINE_SPINLOCK(zcopy_ctx_lock);

extern bool enable_zerocopy;

static bool is_pp_page(struct page *page){
  return (page->pp_magic & ~0x3UL) == PP_SIGNATURE;
}


static void zcopy_free_inv_range(struct zcopy_inv_range *ir){
  struct zcopy_inv_batch *b, *bn;
  int return_nr = 0;
  list_for_each_entry_safe(b, bn, &ir->batches, node) {
    //trace_printk("[zcopy_free_inv_range] ZeroCopy: batch: %px, nr: %d\n", b, b->nr);
    for (int i = 0; i < b->nr; i++) {
      struct page *page = b->pages[i];
      if (!page) {
        continue;
      }
      if (unlikely(!is_pp_page(page))) {
        trace_printk("ZeroCopy: Page is not page pool page: %px\n", page);
        continue;
      }
      //if (ir->cookie->event == 1){
      //  trace_printk("[zcopy_free_inv_range] ZeroCopy: Page: %px, ref count: %d, pp_ref count: %ld\n", page, page_ref_count(page), atomic_long_read(&page->pp_ref_count));
      //}
      /*if (page_ref_count(page) == 1) {
        trace_printk("[zcopy_free_inv_range] ZeroCopy: Page: %px, ref count: %d, pp_ref count: %ld\n", page, page_ref_count(page), atomic_long_read(&page->pp_ref_count));
      }*/
      if (page_ref_count(page) > 1) {
        put_page(page);
      }
      /*if (page_ref_count(page) != 1) {
        trace_printk("ZeroCopy: Page pool  ref count is not 1: %px, ref count: %d, pp_ref count: %ld\n", page, page_ref_count(page), atomic_long_read(&page->pp_ref_count));
      }*/
//      if (atomic_long_read(&page->pp_ref_count) == 1) {
      //if (page_ref_count(page) == 1) {
        page_pool_put_full_page(page->pp, page, false);
     // }
      return_nr++;
    }
    list_del(&b->node);
    kfree(b);
  }
  //trace_printk("[zcopy_free_inv_range] ZeroCopy: free inv range: %px, return_nr: %d\n", ir, return_nr);
  kfree(ir);
}


static int zcopy_pmd_entry(pmd_t *pmd, unsigned long addr, unsigned long next, struct mm_walk *walk)
{
    pte_t *pte;
    spinlock_t *ptl;
    struct page *page;
    struct mm_struct *mm = walk->mm;

    if (pmd_none(*pmd)){
//        trace_printk("ZeroCopy: SKIP EMPTY PMD at %lx\n", addr);
        return 0;
    }    
    if (pmd_trans_huge(*pmd)) {
  //      trace_printk("  -> SKIP HUGE PMD at %lx (Target might be hidden here!)\n", addr);
        return 0;
    }

    pte = pte_offset_map_lock(mm, pmd, addr, &ptl);
    if (!pte) return 0;
  

    for (; addr != next; addr += PAGE_SIZE, pte++) {
        if (!pte_present(*pte)){
          //  trace_printk("ZeroCopy: SKIP NON-PRESENT PTE at %lx\n", addr);
            continue;
        }

        page = vm_normal_page(walk->vma, addr, *pte);
        if (!page)
            continue;
        //trace_printk("ZeroCopy: Found page %px at %lx, refcount %d, pp_refcount %ld \n", page, (unsigned long)addr, page_ref_count(page), atomic_long_read(&page->pp_ref_count));

        if ((page->pp_magic & ~0x3UL) == PP_SIGNATURE) {
            
             if (page_ref_count(page) > 1) {
               put_page(page);
             }
            // trace_printk("[zcopy_mn_release] ZeroCopy: Cleaning up leaked page %px at %lx, refcount %d,  pp_refcount: %ld\n", page, (unsigned long)addr, page_ref_count(page),  atomic_long_read(&page->pp_ref_count));
             //if (page_ref_count(page) == 1) {
               page_pool_put_full_page(page->pp, page, false);
             //}
        }
    }
    pte_unmap_unlock(pte - 1, ptl);
    return 0;
}

static const struct mm_walk_ops zcopy_walk_ops = {
    .pmd_entry = zcopy_pmd_entry,
};

static void zcopy_mn_release(struct mmu_notifier *mn, struct mm_struct *mm)
{
    //trace_printk("[zcopy_mn_release] ZeroCopy: zcopy_mn_release called with mm %p\n", mm);

    //pr_info("[zcopy_mn_release] ZeroCopy: zcopy_mn_release called with mm %p\n", mm);

    struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
    LIST_HEAD(tmp);

/*  struct vm_area_struct *vma;
  VMA_ITERATOR(vmi, mm, 0);

  mmap_read_lock(mm);

  for_each_vma(vmi, vma) {
      // 쓰기 권한이 있는 익명 매핑(fio 버퍼)만 검사
      if (vma->vm_flags & VM_WRITE) {
          walk_page_range(mm, vma->vm_start, vma->vm_end, &zcopy_walk_ops, NULL);
      }
  }
  mmap_read_unlock(mm);
*/
    
    /* 2. 해시 테이블에서 제거 */
    spin_lock(&zcopy_ctx_lock);
    if (!hlist_unhashed(&ctx->node))
      hlist_del_rcu(&ctx->node);
    spin_unlock(&zcopy_ctx_lock);

    spin_lock(&ctx->lock);
    list_replace_init(&ctx->inv_ranges, &tmp);
    spin_unlock(&ctx->lock);

    while (!list_empty(&tmp)) {
      struct zcopy_inv_range *ir = list_first_entry(&tmp, struct zcopy_inv_range, node);
      list_del(&ir->node);
      zcopy_free_inv_range(ir);
    }

    /* 3. 구 조체 해제 (RCU 안전 해제) */
    kfree_rcu(ctx, rcu);
}
/*
static struct page *zcopy_check_pte(struct mm_struct *mm, unsigned long addr,
                                    struct vm_area_struct *vma) {
  pgd_t *pgd;
  p4d_t *p4d;
  pud_t *pud;
  pmd_t *pmd;
  pte_t *pte;
  spinlock_t *ptl;
  struct page *page = NULL;
  struct page *ret_page = NULL; // 리턴할 변수 따로 선언

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
  if (pmd_none(*pmd) || pmd_bad(*pmd) || pmd_trans_huge(*pmd))
    return NULL;

  pte = pte_offset_map_lock(mm, pmd, addr, &ptl);
  if (!pte)
    return NULL;

  if (pte_present(*pte)) {
    unsigned long pfn = pte_pfn(*pte);
    if (!pfn_valid(pfn))
      goto out;

    page = pte_page(*pte);

    if (page && (page->pp_magic & ~0x3UL) == PP_SIGNATURE) {
  
      // 1. PTE Steal
      ptep_get_and_clear(mm, addr, pte);

      // 2. RMAP 제거 & RSS 갱신
      struct folio *folio = page_folio(page);
      if (vma){
          folio_remove_rmap_ptes(folio, page, 1, vma);
      }
          if (folio_test_anon(folio))
            dec_mm_counter(mm, MM_ANONPAGES);
          else
            dec_mm_counter(mm, mm_counter_file(folio));

      // ★ 중요: 훔친 경우에만 리턴값 설정 ★
      ret_page = page;
    }
  }
out:
  pte_unmap_unlock(pte, ptl);
  return ret_page; // 훔친 게 없으면 NULL 리턴
}

*/

static struct page *zcopy_peek_pp_page_get(struct mm_struct *mm, unsigned long addr){
  pgd_t *pgd;
  p4d_t *p4d;
  pud_t *pud;
  pmd_t *pmd;
  pte_t *pte;
  spinlock_t *ptl;
  struct page *page = NULL;
  struct page *ret_page = NULL; // 리턴할 변수 따로 선언

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
  if (pmd_none(*pmd) || pmd_bad(*pmd) || pmd_trans_huge(*pmd))
    return NULL;

  if (pmd_trans_huge(*pmd) || pmd_devmap(*pmd)) {
    pr_info("ZeroCopy: pmd is trans huge or devmap: %px\n", pmd);
    return NULL;
  }

  pte = pte_offset_map_lock(mm, pmd, addr, &ptl);
  if (!pte)
    return NULL;

  if (pte_present(*pte)) {
    page = pte_page(*pte);
    if (page && is_pp_page(page)) {
      //trace_printk("[zcopy_peek_pp_page_get] ZeroCopy: peek pp page: %px\n", page);
      ret_page = page;
    }
    else {
      ret_page = NULL;
    }
  }
  pte_unmap_unlock(pte, ptl);
  return ret_page;
}

static int zcopy_mn_invalidate_range_start(struct mmu_notifier *mn, const struct mmu_notifier_range *range){
  struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
  struct mm_struct *mm = ctx->mm;
  int total_nr = 0;
  
/*  trace_printk("mn_start: event=%u blockable=%d start=%lx end=%lx pid=%d comm=%s\n",
        range->event, mmu_notifier_range_blockable(range),
        range->start, range->end, current->pid, current->comm);
*/
  if (!(range->event == 0) /*MMU_NOTIFY_UNMAP*/
  || !mmu_notifier_range_blockable(range))
    return 0;
  
  unsigned long start = range->start & PAGE_MASK;
  unsigned long end = PAGE_ALIGN(range->end);

  struct zcopy_inv_range *ir;
  struct zcopy_inv_batch * b = NULL;
  struct vm_area_struct *vma = NULL;
  unsigned long addr;
  

  for (addr = start; addr < end; addr += PAGE_SIZE) {
    struct page *page = zcopy_peek_pp_page_get(mm, addr);
    if (!page) 
      continue;
    if (!ir){
      ir = kmalloc(sizeof(*ir), GFP_KERNEL);
      if (!ir)
        return 0;

      INIT_LIST_HEAD(&ir->batches);
      ir->cookie = range;

      spin_lock(&ctx->lock);
      list_add_tail(&ir->node, &ctx->inv_ranges);
      spin_unlock(&ctx->lock);
    }

    if (!b){
      b = kmalloc(sizeof(*b), GFP_KERNEL);
      if (!b){
        continue;
      }
      b->nr = 0;
      INIT_LIST_HEAD(&b->node);
    }

    b->pages[b->nr++] = page;

    if (b->nr == ZC_INV_BATCH) {
//      pr_info("ZeroCopy: add batch: %px\n", b);
      list_add_tail(&b->node, &ir->batches);
      b = NULL;
    }
    total_nr++;
  }

  if (ir){
    if (b){
      //pr_info("ZeroCopy: add last batch: %px\n", b);
      list_add_tail(&b->node, &ir->batches);
    }
  }
  //trace_printk("[zcopy_mn_invalidate_range_start] ZeroCopy: total_nr: %d\n", total_nr);


  return 0;
}
/*
static int zcopy_mn_invalidate_range_start(struct mmu_notifier *mn,
                                          const struct mmu_notifier_range *range) {
  struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
  struct mm_struct *mm = ctx->mm;
  unsigned long addr;
  struct page *pages_to_recycle[256];
  int nr_recycled = 0;
  bool mmap_locked = false;

  if (mmap_read_trylock(mm)) {
      mmap_locked = true;
  } else if (!rwsem_is_locked(&mm->mmap_lock)) {
      return 0; 
  }
  // ★ Flush 시작 지점을 기억할 변수 추가 ★
  unsigned long batch_start = range->start;
  int count = range->end - range->start;

  if (!mmu_notifier_range_blockable(range))
    return 0;

   //trace_printk("======= Invalidate Range: %lx - %lx\n", range->start, range->end);

  for (addr = range->start; addr < range->end; addr += PAGE_SIZE) {

    if (!vma || addr >= vma ->vm_end){
      vma = find_vma(mm, addr);
    }

    if (!vma || addr < vma ->vm_start){
     // trace_printk("[2]Invalidate Range: %lx - %lx (Event: %d) - No VMA\n", range->start, range->end, range->event);
     // continue;
    }

    struct page *page = zcopy_check_pte(mm, addr, vma);

    if (page) {
      pages_to_recycle[nr_recycled++] = page;

      // 배치의 첫 페이지라면, Flush 시작점을 여기로 설정 (최적화)
      if (nr_recycled == 1)
        batch_start = addr;
    }

    if (nr_recycled == 256 || nr_recycled == count) {
      flush_tlb_mm_range(mm, batch_start, addr + PAGE_SIZE, PAGE_SHIFT, false);

      for (int i = 0; i < nr_recycled; i++) {
     //  trace_printk("ZeroCopy: Recycle page %px at %lx\n", pages_to_recycle[i], (unsigned long)addr);
        struct page *pg = pages_to_recycle[i];
        put_page(pg);                               // PTE 몫
       // page_pool_put_full_page(pg->pp, pg, false); // Pool 복귀
      }
      nr_recycled = 0;
    }
  }

  if (nr_recycled > 0) {
    // ★ 수정됨: 마지막 남은 구간만 Flush ★
    flush_tlb_mm_range(mm, batch_start, range->end, PAGE_SHIFT, false);

    for (int i = 0; i < nr_recycled; i++) {
     // trace_printk("ZeroCopy: Last Recycle page %px at %lx, pp_refcount: %ld, refcount: %d\n", pages_to_recycle[i], (unsigned long)addr, atomic_long_read(&pages_to_recycle[i]->pp_ref_count), page_ref_count(pages_to_recycle[i]));
      struct page *pg = pages_to_recycle[i];
      put_page(pg);
    //  page_pool_put_full_page(pg->pp, pg, false);
    }
  }

  if (mmap_locked)
    mmap_read_unlock(mm);

  return 0;
}
*/
static void zcopy_mn_invalidate_range_end(struct mmu_notifier *mn,
                                          const struct mmu_notifier_range *range) {
  struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
  struct zcopy_inv_range *pos, *n;
  struct zcopy_inv_range *found = NULL;

  // find the range in the list
  spin_lock(&ctx->lock);
  list_for_each_entry_safe(pos, n, &ctx->inv_ranges, node) {
    if (pos->cookie == range) {
      found = pos;
      list_del(&found->node);
      break;
    }
  }
  spin_unlock(&ctx->lock);

  if (found) {
    zcopy_free_inv_range(found);
  }
  else {
    //pr_info("[zcopy_mn_invalidate_range_end] ZeroCopy: not found: %px\n", range);
  }
}

static const struct mmu_notifier_ops zcopy_mn_ops = {
    .release = zcopy_mn_release,
    .invalidate_range_start = zcopy_mn_invalidate_range_start,
    .invalidate_range_end = zcopy_mn_invalidate_range_end,
};


int zcopy_try_register(struct mm_struct *mm) {
    struct zcopy_ctx *ctx;
    struct zcopy_ctx *new_ctx;
    int ret;

    if (!READ_ONCE(enable_zerocopy))
        return 0;

    /* 1. Fast Path: Lock 없이 빠르게 확인 */
    rcu_read_lock();
    hash_for_each_possible_rcu(zcopy_ctx_hash, ctx, node, (unsigned long)mm) {
      if (ctx->mm == mm) {
        rcu_read_unlock();
        return 0; /* 이미 등록됨 */
      }
    }
    rcu_read_unlock();

    /* 2. Slow Path: 등록 준비 (메모리 할당) */
    /* 주의: queue_rq 컨텍스트가 atomic일 수 있으므로 GFP_ATOMIC 권장 */
    new_ctx = kzalloc(sizeof(*new_ctx), GFP_KERNEL);
    if (!new_ctx)
      return -1;

    spin_lock_init(&new_ctx->lock);
    INIT_HLIST_NODE(&new_ctx->node);
    INIT_LIST_HEAD(&new_ctx->inv_ranges);

    new_ctx->mm = mm;
    new_ctx->mn.ops = &zcopy_mn_ops;

    /* 3. Notifier 등록 시도 */
    ret = mmu_notifier_register(&new_ctx->mn, mm);
    if (ret) {
      kfree(new_ctx);
      return -1;
    }
    
    /* 4. Critical Section 진입 */
    spin_lock(&zcopy_ctx_lock);

    /* ★ [수정 핵심] Double-Check 시에도 RCU Lock 필수! ★
    * spinlock이 있어도 RCU 리스트 순회(dereference)를 하려면
    * rcu_read_lock이 있어야 해제된 메모리 참조를 막을 수 있습니다.
    */
    rcu_read_lock(); // <--- 여기 추가!!

    ctx = NULL;
    hash_for_each_possible_rcu(zcopy_ctx_hash, ctx, node, (unsigned long)mm) {
      if (ctx->mm == mm) {
        break;
      }
    }
    rcu_read_unlock(); // <--- 검색 끝나면 해제

    if (ctx) {
      /* 이미 누가 등록함! 내껀 취소하고 나가야 함 */
      spin_unlock(&zcopy_ctx_lock);

      mmu_notifier_unregister(&new_ctx->mn, mm);
      if (new_ctx){
        kfree(new_ctx);
      }

      return 0;
    }


    /* 진짜 없을 때만 추가 */
    hash_add_rcu(zcopy_ctx_hash, &new_ctx->node, (unsigned long)mm);
    spin_unlock(&zcopy_ctx_lock);
    //trace_printk("[zcopy_try_register] ZeroCopy: try_register: %px\n", new_ctx);
    return 0;
}