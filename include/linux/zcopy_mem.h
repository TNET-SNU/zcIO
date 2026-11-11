/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __LINUX_ZCOPY_MEM_H
#define __LINUX_ZCOPY_MEM_H

struct mm_struct;

/* zcIO host RX zero-copy: watch @mm so remapped pages go back to their pool */
int zcopy_try_register(struct mm_struct *mm);

#endif
