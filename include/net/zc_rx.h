/* SPDX-License-Identifier: GPL-2.0 */
/*
 * zcIO RX zero-copy helpers shared by the NVMe/TCP host and target.
 *
 * With the mlx5 rx_zc_stride pflag the NIC receives payload into whole
 * PAGE_SIZE page-pool pages, so a page-aligned 4K range of the TCP stream
 * is often exactly one skb frag.  These helpers find such a frag so the
 * caller can hand the page over (remap it into user space, or place it in
 * an I/O scatterlist) instead of copying it.
 */
#ifndef _NET_ZC_RX_H
#define _NET_ZC_RX_H

#include <linux/mm_types.h>
#include <linux/skbuff.h>
#include <net/page_pool/types.h>

/*
 * Forward-only cursor over the frags of one skb (and its frag_list).
 *
 * The cursor caches skb pointers, so it is only valid while the caller
 * holds that skb: zc_rx_cursor_init() it at the start of every
 * read_sock() actor call, never carry it across calls.
 */
struct zc_rx_cursor {
	const struct sk_buff *root;	/* skb the cursor walks */
	const struct sk_buff *skb;	/* root or the current frag_list skb */
	unsigned int base;		/* offset of @skb's data within @root */
	unsigned int pos;		/* offset of frags[@frag] within @root */
	int frag;			/* next frag of @skb to look at */
};

static inline void zc_rx_cursor_init(struct zc_rx_cursor *c)
{
	c->root = NULL;
}

static inline bool zc_rx_page_is_pp(const struct page *page)
{
	return (page->pp_magic & ~0x3UL) == PP_SIGNATURE;
}

struct page *zc_rx_skb_page_at(struct zc_rx_cursor *c,
			       const struct sk_buff *root, unsigned int off);

#endif /* _NET_ZC_RX_H */
