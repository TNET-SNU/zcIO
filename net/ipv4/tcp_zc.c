#include "tcp_zc.h"
#include <net/page_pool/helpers.h>
#include <net/sock.h>
#include <linux/nvmet_tcp_zc.h>


/* rx zcopy */
bool enable_zerocopy;
EXPORT_SYMBOL(enable_zerocopy);
module_param(enable_zerocopy, bool, 0644);
MODULE_PARM_DESC(enable_zerocopy, "enable zcopy");


bool can_zerocopy(struct sock *sk, struct msghdr *msg){
    if (!enable_zerocopy)
        return false;

    if (!iov_iter_is_bvec(&msg->msg_iter)){
	//	pr_info("[can_zerocopy] not bvec\n");
        return false;
	}

    if (!sk->sk_user_data || *(u32 *)sk->sk_user_data != 
	NVMET_TCP_MAGIC){
		pr_info("[can_zerocopy] not nvmet_tcp_magic\n");
        return false;
	}

    return true;
}

/*
static __always_inline void zc_cursor_reset(struct nvmet_tcp_queue *q,
					    struct sk_buff *root)
{
	struct zc_skb_cursor *c = &q->zc_cur;

	c->root = root;
	c->skb  = root;
	c->fskb = NULL;

	c->base = 0;
	c->pos  = skb_headlen(root);
	c->frag = 0;

    return;
}

static __always_inline bool zc_cursor_next_skb(struct zc_skb_cursor *c)
{
	struct sk_buff *next;

	if (!c->fskb) {
		next = skb_shinfo(c->root)->frag_list;
		if (!next)
			return false;

		// nested frag_list면 여기선 fastpath 포기(원하면 slowpath로) 
		if (unlikely(skb_shinfo(next)->frag_list))
			return false;

		// root의 frags 끝(pos)이 frag_list의 시작 base 
		c->base = c->pos;
		c->skb  = next;
		c->fskb = next;
	} else {
		next = c->fskb->next;
		if (!next)
			return false;

		if (unlikely(skb_shinfo(next)->frag_list))
			return false;

		// 재귀 코드의 pos += fskb->len 과 동일한 의미 
		c->base += c->fskb->len;
		c->skb  = next;
		c->fskb = next;
	}

	c->pos  = c->base + skb_headlen(c->skb);
	c->frag = 0;
	return true;
}


static __always_inline void zc_cursor_invalidate(struct nvme_tcp_queue *q)
{
	q->zc_cur.root = NULL;
}

static int zc_find_next_4k_stateful(struct nvmet_tcp_queue *q,
				   struct sk_buff *root,
				   unsigned int cur_off,
				   struct sk_buff **owner,
				   int *frag_idx,
				   unsigned int *page_off)
{
	struct zc_skb_cursor *c = &q->zc_cur;

	// 새 skb면 커서 reset 
	if (unlikely(c->root != root))
		zc_cursor_reset(q, root);

	if (unlikely(cur_off < c->base || cur_off < c->pos))
		zc_cursor_reset(q, root);

	for (;;) {
		struct skb_shared_info *si = skb_shinfo(c->skb);
		unsigned int head_end = c->base + skb_headlen(c->skb);

		// linear 안이면 linear 끝으로 
		if (cur_off < head_end)
			cur_off = head_end;

		// frags[] 스캔: 커서 위치부터 앞으로만 
		while (c->frag < si->nr_frags) {
			skb_frag_t *f = &si->frags[c->frag];
			unsigned int start = c->pos;
			unsigned int end   = start + skb_frag_size(f);

			if (cur_off < end) {
				// 경계 정확히 일치 + full 4K page frag면 성공
				if (cur_off == start && likely(zc_is_full_4k_page_frag(f))) {
					*owner   = c->skb;
					*frag_idx = c->frag;
					*page_off = start;

					// 다음 호출을 위해 커서 advance
					c->pos = end;
					c->frag++;
					return 0;
				}

				// 아니면 이 frag는 통째로 skip 
				cur_off = end;
			}

			c->pos = end;
			c->frag++;
		}

		// 이 skb에서 못 찾았으면 frag_list의 다음 skb로 
		if (!zc_cursor_next_skb(c))
			return -ENOENT;
	}
}
*/

static bool tcp_iter_bvec_can_swap_4k(struct iov_iter *iter)
{
    /*
     * - iter->bvec : current bvec pointer
     * - iter->iov_offset : current bvec offset
     */
    if (!iter->bvec && !iov_iter_is_bvec(iter)){
		pr_info("[tcp_iter_bvec_can_swap_4k] not bvec\n");
        return false;
	}

   // if (iter->iov_offset != 0)
   //     return false;

    if (iter->bvec->bv_offset != 0){
		pr_info("[tcp_iter_bvec_can_swap_4k] bv_offset != 0\n");
        return false;
	}

    if (iter->bvec->bv_len != ZC_PG_SZ)
	{
		pr_info("[tcp_iter_bvec_can_swap_4k] bv_len != 4K\n");
        return false;
	}

    if (!iter->bvec->bv_page)
	{
		pr_info("[tcp_iter_bvec_can_swap_4k] bv_page is NULL\n");
        return false;
	}
    return true;
}

static void tcp_zc_store_4k_frag_page(struct msghdr *msg, struct page *newp)
{
	struct iov_iter *iter = &msg->msg_iter;
	struct bio_vec *bvec_curr = (struct bio_vec *)iter->bvec;
	struct zc_data *zc_data = (struct zc_data *)msg->msg_control;

	if (!get_page_unless_zero(newp)){
		pr_info("failed to get newp\n");
		return ;
	}
	page_pool_ref_page(newp);


	//sg_set_page(sg, newp, sg->length, sg->offset);
    // do i have to free old page of bvec?
	bvec_curr->bv_page = newp;
	if (zc_data && zc_data->page_count < ZC_DATA_MAX_PAGES){
		//pr_info("[tcp_zc_store_4k_frag_page] store page to zc_data, page_count: %zu, new page: %px, page ref count: %d, page_pool ref count: %zu\n", zc_data->page_count, newp, page_ref_count(newp), atomic_long_read(&newp->pp_ref_count));
		
		zc_data->page[zc_data->page_count] = newp;
		zc_data->page_count++;
	}
	return;
}

static __always_inline bool zc_is_full_4k_page_frag(const skb_frag_t *f)
{
	return skb_frag_size(f) == PAGE_SIZE && skb_frag_off(f) == 0;
}

static int zc_find_page_stateless(struct sk_buff *root_skb, 
                                  unsigned int offset,
                                  struct sk_buff **out_skb,
                                  int *out_frag_idx)
{
    /* [질문하신 변수 선언] curr는 현재 검사 중인 skb를 가리킴 */
    struct sk_buff *curr = root_skb;
    struct skb_shared_info *si;
    int i;

    /* * [루프 구조]
     * 1. 처음엔 root_skb를 검사 (curr == root_skb)
     * 2. 다 검사했는데 없으면? frag_list로 점프!
     * 3. 그 다음부터는 next를 타고 이동!
     */
    while (curr) {
        unsigned int headlen = skb_headlen(curr);
        si = skb_shinfo(curr);

        /* --- 1. Linear 영역 체크 (헤더 등) --- */
        if (offset < headlen) {
            // 오프셋이 헤더 쪽에 있으면 Zero-Copy 불가
            return -ENOENT;
        }
        offset -= headlen; // Linear 길이만큼 뺌

        /* --- 2. Frags 배열(페이지 조각들) 순회 --- */
        for (i = 0; i < si->nr_frags; i++) {
            skb_frag_t *frag = &si->frags[i];
            unsigned int len = skb_frag_size(frag);

            if (offset < len) {
                // Bingo! 위치 찾음. 
                // (단, offset이 0이고 4K 정렬된 경우만 성공)
                if (offset == 0 && likely(zc_is_full_4k_page_frag(frag))) {
                    *out_skb = curr;      // 현재 보고 있는 그 SKB
                    *out_frag_idx = i;    // 그 SKB 안의 i번째 조각
                    return 0; 
                }
				pr_info("[zc_find_page_stateless] not full 4K frag, offset: %u, frag_idx: %d\n", offset, i);
                return -ENOENT; // 조건 안 맞음
            }
            offset -= len; // 다음 frag 검사를 위해 뺌
        }

        /* --- 3. 다음 SKB로 이동 로직 (질문하신 부분) --- */
        if (curr == root_skb) {
            /* * 맨 처음(Head)이었다면, 이제 꼬리(frag_list)로 진입!
             * frag_list가 없으면(NULL) 루프 종료.
             */
            if (skb_has_frag_list(curr))
                curr = si->frag_list; 
            else
                break; 
        } else {
            /* * 이미 꼬리(frag_list) 안에 있다면?
             * 옆 친구(next)로 이동!
             */
            curr = curr->next;
        }
    }
	pr_info("[zc_find_page_stateless] not found 4K frag, offset: %u\n", offset);
    return -ENOENT; // 끝까지 뒤져도 없음
}

size_t do_zerocopy(struct sk_buff *skb, size_t offset, struct msghdr *msg, size_t used, struct sock *sk){
	struct iov_iter *iter = &msg->msg_iter;
	size_t done = 0;
    struct sk_buff *owner = NULL;
    int frag_index = -1;

	//pr_info("[do_zerocopy] iter: %px\n", iter);
	if (!iov_iter_is_bvec(iter)){
		pr_info("[do_zerocopy] not bvec\n");
		return 0;
	}

	//want 4K 배수만 처리
    size_t total_size = iov_iter_count(iter);
	size_t avail = min_t(size_t, total_size, used);
    size_t want = avail & ~((size_t)ZC_PG_MASK);
    if (!want){
		pr_info("want is 0, real data size: %zu\n", iov_iter_count(iter));
        return 0;
	}
  //  pr_info("[do_zerocopy] available: %zu / %zu -- real data size: %zu\n", avail, total_size, want);
	while (want >= ZC_PG_SZ) {
	//	pr_info("----> want: %zu\n", want);
		skb_frag_t *frag;
		struct page *newp;
		
		// check bv page 's alignment
        if (!tcp_iter_bvec_can_swap_4k(iter)){
			pr_info("--- unableto swap 4K frag, offset: %zu, done: %zu\n", offset + done, done);
            return done;
		}

        if (zc_find_page_stateless(skb, offset + done, &owner, &frag_index)){
			skb_dump(KERN_INFO, skb, true);
            pr_info("failed to find 4K frag, offset: %zu, done: %zu\n", offset + done, done);
            return done;
        }

		frag = &skb_shinfo(owner)->frags[frag_index];
		// check frag's alignment
	//	pr_info("[do_zerocopy] frag index : %d, size : %d, off : %d\n", frag_index, skb_frag_size(frag), skb_frag_off(frag));
		/* clean 4K frag만 */
        if (skb_frag_size(frag) != ZC_PG_SZ)
            break;
        if (skb_frag_off(frag) != 0)
            break;

        newp = skb_frag_page(frag);
        if (!newp)
            break;

		// swap 4K frag
        tcp_zc_store_4k_frag_page(msg, newp);

		iov_iter_advance(iter, ZC_PG_SZ);
        done += ZC_PG_SZ;
        want -= ZC_PG_SZ;
        //idx++;
    }
	//pr_info("[do_zerocopy] done : %zu\n", done);
	return done;
}

