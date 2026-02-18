/* include/linux/nvmet_tcp_zc.h */
#ifndef _LINUX_NVMET_TCP_ZC_H
#define _LINUX_NVMET_TCP_ZC_H

#include <linux/bvec.h>

#define NVMET_TCP_MAGIC 0x4E564D45  /* "NVME"의 헥사값 */
#define ZC_DATA_MAX_PAGES 256

enum zc_policy {
	ZC_DISABLED = 0,
	ZC_ENABLED = 1,
};

enum zc_reason {
	ZCR_OK = 0,
	ZCR_GLOB_OFF,
	ZCR_NOT_WRITE,
	ZCR_INLINE,
	ZCR_PDU_LEN_NOT_4K,
	ZCR_PDU_OFF_NOT_4K,
	ZCR_XFER_NOT_4K,
	ZCR_RBYTES_NOT_4K,
	ZCR_SG_BAD,
	ZCR_QUEUE_NOT_LIVE,
	ZCR_QUEUE_QID_0,
	ZCR_SK_BAD,
};

struct zc_data {
	struct page *page[ZC_DATA_MAX_PAGES];
	size_t page_count;
};

#endif