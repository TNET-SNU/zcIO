#include <linux/zcopy_mem.h>
#include <net/page_pool/helpers.h>
#include <linux/rmap.h>

DEFINE_HASHTABLE(zcopy_ctx_hash, 8);
DEFINE_SPINLOCK(zcopy_ctx_lock);

extern bool enable_zerocopy;

// add page pool page to list when invalidate_range_start is called, and remove it when release is called
static LIST_HEAD(zcopy_page_pool_list);
static spinlock_t zcopy_page_pool_list_lock;

/* [Callback] PMD 단위마다 호출되어 PTE를 검색 */
static int zcopy_pmd_entry(pmd_t *pmd, unsigned long addr, unsigned long next, struct mm_walk *walk)
{
    pte_t *pte;
    spinlock_t *ptl;
    struct page *page;
    struct mm_struct *mm = walk->mm;

    /* HugePage나 빈 PMD는 패스 */
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
  

    /* PTE 루프: 실제 페이지 확인 */
    for (; addr != next; addr += PAGE_SIZE, pte++) {
        if (!pte_present(*pte)){
          //  trace_printk("ZeroCopy: SKIP NON-PRESENT PTE at %lx\n", addr);
            continue;
        }

        page = vm_normal_page(walk->vma, addr, *pte);
        if (!page)
            continue;
        //trace_printk("ZeroCopy: Found page %px at %lx, refcount %d, pp_refcount %ld \n", page, (unsigned long)addr, page_ref_count(page), atomic_long_read(&page->pp_ref_count));

        /* ★ 핵심: 내 Page Pool 페이지인지 확인 (Magic Number) ★ */
        if ((page->pp_magic & ~0x3UL) == PP_SIGNATURE) {
            
            /* Refcount가 2(Pool+User) 상태일 테니 1을 내려줌.
             * 이후 커널이 표준 해제 과정에서 1->0으로 만들어 완전 해제됨. 
             */
         //    trace_printk("ZeroCopy: Cleaning up leaked page %px at %lx, refcount %d,  pp_refcount: %ld\n", page, (unsigned long)addr, page_ref_count(page),  atomic_long_read(&page->pp_ref_count));
             //page_pool_unref_page(page, 1);
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
   // trace_printk("zcopy_mn_release called with mm %p\n", mm);
    struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
    struct vm_area_struct *vma;
    VMA_ITERATOR(vmi, mm, 0);

    /* 1. 메모리 스캔 및 페이지 회수 */
    mmap_read_lock(mm);
    for_each_vma(vmi, vma) {
        // 쓰기 권한이 있는 익명 매핑(fio 버퍼)만 검사
        if (vma->vm_flags & VM_WRITE) {
            walk_page_range(mm, vma->vm_start, vma->vm_end, &zcopy_walk_ops, NULL);
        }
    }
    mmap_read_unlock(mm);

    /* 2. 해시 테이블에서 제거 */
    spin_lock(&zcopy_ctx_lock);
    if (!hlist_unhashed(&ctx->node))
      hlist_del_rcu(&ctx->node);
    spin_unlock(&zcopy_ctx_lock);

    /* 3. 구 조체 해제 (RCU 안전 해제) */
    kfree_rcu(ctx, rcu);
}
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

    /* Magic 확인 */
    if (page && (page->pp_magic & ~0x3UL) == PP_SIGNATURE) {
     // trace_printk("ZeroCopy: Found page %px at %lx, refcount %d, pp_refcount: %ld\n", page, (unsigned long)addr, page_ref_count(page),  atomic_long_read(&page->pp_ref_count));
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
static int
zcopy_mn_invalidate_range_start(struct mmu_notifier *mn,
                                const struct mmu_notifier_range *range) {
  struct zcopy_ctx *ctx = container_of(mn, struct zcopy_ctx, mn);
  struct mm_struct *mm = ctx->mm;
  struct vm_area_struct *vma = NULL;

  unsigned long addr;
  struct page *pages_to_recycle[256];
  int nr_recycled = 0;
  bool mmap_locked = false;

  if (mmap_read_trylock(mm)) {
      mmap_locked = true;
  } else if (!rwsem_is_locked(&mm->mmap_lock)) {
      // 락도 못 잡았는데, 현재 락이 걸려있지도 않다면?
      // (do_wp_page 처럼 VMA Lock만 걸린 상황) -> 위험하므로 스킵
     // trace_printk("ZeroCopy: Skip invalidation (No mmap_lock held)\n");
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

    /* 배치 꽉 참: Flush & Recycle */
    if (nr_recycled == 256 || nr_recycled == count) {
      flush_tlb_mm_range(mm, batch_start, addr + PAGE_SIZE, PAGE_SHIFT, false);

      for (int i = 0; i < nr_recycled; i++) {
     //  trace_printk("ZeroCopy: Recycle page %px at %lx\n", pages_to_recycle[i], (unsigned long)addr);
        struct page *pg = pages_to_recycle[i];
        put_page(pg);                               // PTE 몫
        page_pool_put_full_page(pg->pp, pg, false); // Pool 복귀
      }
      nr_recycled = 0;
    }
  }

  /* 남은 짜투리 처리 */
  if (nr_recycled > 0) {
    // ★ 수정됨: 마지막 남은 구간만 Flush ★
    flush_tlb_mm_range(mm, batch_start, range->end, PAGE_SHIFT, false);

    for (int i = 0; i < nr_recycled; i++) {
     // trace_printk("ZeroCopy: Last Recycle page %px at %lx, pp_refcount: %ld, refcount: %d\n", pages_to_recycle[i], (unsigned long)addr, atomic_long_read(&pages_to_recycle[i]->pp_ref_count), page_ref_count(pages_to_recycle[i]));
      struct page *pg = pages_to_recycle[i];
      put_page(pg);
      page_pool_put_full_page(pg->pp, pg, false);
    }
  }

  if (mmap_locked)
    mmap_read_unlock(mm);

  return 0;
}

static const struct mmu_notifier_ops zcopy_mn_ops = {
    .release = zcopy_mn_release,
    .invalidate_range_start = zcopy_mn_invalidate_range_start,
};


void zcopy_try_register(void) {
    struct zcopy_ctx *ctx;
    struct zcopy_ctx *new_ctx;
    struct mm_struct *mm = current->mm;
    int ret;

    if (!READ_ONCE(enable_zerocopy))
        return;

    /* 1. Fast Path: Lock 없이 빠르게 확인 */
    rcu_read_lock();
    hash_for_each_possible_rcu(zcopy_ctx_hash, ctx, node, (unsigned long)mm) {
      if (ctx->mm == mm) {
        rcu_read_unlock();
        return; /* 이미 등록됨 */
      }
    }
    rcu_read_unlock();

    /* 2. Slow Path: 등록 준비 (메모리 할당) */
    /* 주의: queue_rq 컨텍스트가 atomic일 수 있으므로 GFP_ATOMIC 권장 */
    new_ctx = kzalloc(sizeof(*new_ctx), GFP_ATOMIC);
    if (!new_ctx)
      return;
    INIT_HLIST_NODE(&new_ctx->node);
    new_ctx->mm = mm;
    new_ctx->mn.ops = &zcopy_mn_ops;

    /* 3. Notifier 등록 시도 */
    ret = mmu_notifier_register(&new_ctx->mn, mm);
    if (ret) {
      kfree(new_ctx);
      return;
    }
    //trace_printk("ZeroCopy: Register context for mm %p\n", mm);
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
      //kfree(new_ctx);
      return;
    }

    /* 진짜 없을 때만 추가 */
    hash_add_rcu(zcopy_ctx_hash, &new_ctx->node, (unsigned long)mm);
    spin_unlock(&zcopy_ctx_lock);
}