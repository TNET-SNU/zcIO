/* SPDX-License-Identifier: GPL-2.0 */
/*
 * folio_pp_release.h - Generic hook for returning a page-pool page to its
 * pool when a page-cache folio is evicted.
 *
 * Drivers that place page-pool pages directly into the page cache (e.g.
 * NVMe/TCP cached zerocopy) attach one of these structs as folio->private.
 * The iomap release path (ifs_free) detects the magic and calls
 * page_pool_unref_page() instead of treating the private data as an
 * iomap_folio_state.
 */
#ifndef _LINUX_FOLIO_PP_RELEASE_H
#define _LINUX_FOLIO_PP_RELEASE_H

#include <net/page_pool/helpers.h>

#define FOLIO_PP_RELEASE_MAGIC  0x70706670u   /* "ppfp" */

struct folio_pp_release {
	u32          magic;	/* FOLIO_PP_RELEASE_MAGIC */
	struct page *frag_page;
};

/**
 * folio_pp_release_init - fill in a folio_pp_release descriptor.
 */
static inline void folio_pp_release_init(struct folio_pp_release *fpr,
					 struct page *frag_page)
{
	fpr->magic     = FOLIO_PP_RELEASE_MAGIC;
	fpr->frag_page = frag_page;
}

/**
 * folio_pp_release_run - called by ifs_free() when it detects our magic.
 * Returns the frag page to the pool and frees the descriptor.
 */
static inline void folio_pp_release_run(struct folio_pp_release *fpr)
{
	/*
	 * Drop our get_page ref first so that _refcount reaches 1
	 * (only the page-cache ref remains).  page_pool_unref_page()
	 * then sees _refcount == 1 and can safely recycle the page back
	 * into the pool.  Calling unref first would leave _refcount == 2,
	 * causing the pool to detach the page rather than recycle it.
	 */
	put_page(fpr->frag_page);
	page_pool_unref_page(fpr->frag_page, 1);
	kfree(fpr);
}

#endif /* _LINUX_FOLIO_PP_RELEASE_H */
