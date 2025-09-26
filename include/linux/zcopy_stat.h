#ifndef __LINUX_ZCOPY_STAT_H
#define __LINUX_ZCOPY_STAT_H

#include <linux/atomic.h>

static atomic_long_t stat_pp_ref_in, stat_pp_ref_out;
static atomic_long_t stat_page_get_in, stat_page_put_out;
static atomic_long_t stat_map_ins, stat_map_outs;

static void stat_print(void)
{
	pr_info("pp_ref_in: %ld, pp_ref_out: %ld, page_get_in: %ld, page_put_out: %ld, map_ins: %ld, unpin_outs: %ld\n",
		atomic_long_read(&stat_pp_ref_in), atomic_long_read(&stat_pp_ref_out), atomic_long_read(&stat_page_get_in), atomic_long_read(&stat_page_put_out), atomic_long_read(&stat_map_ins), atomic_long_read(&stat_map_outs));
} 

#endif