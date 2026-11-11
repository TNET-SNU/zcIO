// SPDX-License-Identifier: GPL-2.0
/*
 * zcIO RX zero-copy helpers shared by the NVMe/TCP host and target.
 */
#include <linux/export.h>
#include <net/zc_rx.h>

static void zc_rx_cursor_reset(struct zc_rx_cursor *c,
			       const struct sk_buff *root)
{
	c->root = root;
	c->skb = root;
	c->base = 0;
	c->pos = skb_headlen(root);
	c->frag = 0;
}

/* Move to the next skb of root's frag_list; nested frag_lists are not walked. */
static bool zc_rx_cursor_next_skb(struct zc_rx_cursor *c)
{
	const struct sk_buff *next;

	if (c->skb == c->root) {
		next = skb_shinfo(c->root)->frag_list;
		c->base = c->pos;	/* frag_list data follows root's frags */
	} else {
		next = c->skb->next;
		c->base += c->skb->len;
	}
	if (!next || skb_has_frag_list(next))
		return false;

	c->skb = next;
	c->pos = c->base + skb_headlen(next);
	c->frag = 0;
	return true;
}

/**
 * zc_rx_skb_page_at - find a whole page-pool page at a stream offset
 * @c: cursor, zc_rx_cursor_init()ed for this read_sock() actor call
 * @root: the skb handed to the actor
 * @off: offset within @root
 *
 * Returns the page-pool page holding bytes [@off, @off + PAGE_SIZE) of
 * @root if that range is exactly one frag covering a whole order-0 page,
 * or NULL (the caller then copies).  No reference is taken.
 *
 * Calls with increasing @off for the same @root resume where the previous
 * one stopped, so walking a whole skb is O(nr_frags) in total.
 */
struct page *zc_rx_skb_page_at(struct zc_rx_cursor *c,
			       const struct sk_buff *root, unsigned int off)
{
	if (c->root != root || off < c->pos)
		zc_rx_cursor_reset(c, root);

	for (;;) {
		const struct skb_shared_info *si = skb_shinfo(c->skb);

		while (c->frag < si->nr_frags) {
			const skb_frag_t *f = &si->frags[c->frag];
			unsigned int start = c->pos;
			unsigned int end = start + skb_frag_size(f);
			struct page *page;

			if (off < start)	/* in a linear area */
				return NULL;
			if (off < end) {
				if (off != start || skb_frag_size(f) != PAGE_SIZE ||
				    skb_frag_off(f) != 0)
					return NULL;
				page = skb_frag_page(f);
				/* an order-0 page; not 4K of a larger pool page */
				if (PageCompound(page) || !zc_rx_page_is_pp(page))
					return NULL;
				return page;
			}
			c->pos = end;
			c->frag++;
		}
		if (!zc_rx_cursor_next_skb(c))
			return NULL;
	}
}
EXPORT_SYMBOL_GPL(zc_rx_skb_page_at);
