#ifndef _TCP_ZC_H
#define _TCP_ZC_H

#include <linux/skbuff.h>
#include <linux/socket.h>
//#include <drivers/nvme/target/nvmet.h>

#define ZC_PG_SZ 4096U
#define ZC_PG_MASK (ZC_PG_SZ - 1)

struct zc_skb_cursor {
	struct sk_buff *root;   /* 커서가 유효한 “root skb” */
	struct sk_buff *skb;    /* 현재 스캔 중인 skb: root 또는 frag_list 요소 */
	struct sk_buff *fskb;   /* frag_list 체인에서 현재 skb (root이면 NULL) */

	unsigned int base;      /* 현재 skb의 stream base (root 기준 offset) */
	unsigned int pos;       /* 현재 frag의 start offset (root 기준) */
	int frag;               /* 현재 skb에서 다음으로 볼 frag index */
};

void set_zc_data_frozen(struct msghdr *msg);
bool can_zerocopy(struct sock *sk, struct msghdr *msg);
__always_inline bool is_pp_page(struct page *page);
size_t do_zerocopy(struct sk_buff *skb, size_t offset, struct msghdr *msg, size_t used, struct sock *sk);
#endif /* _TCP_ZC_H */