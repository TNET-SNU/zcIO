/* include/linux/nvmet_tcp_zc.h */
#ifndef _LINUX_NVMET_TCP_ZC_H
#define _LINUX_NVMET_TCP_ZC_H

#include <linux/bvec.h>
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
};

struct nvmet_tcp_zc_bvec {
    struct bio_vec bv;              // iov_iter가 보는 부분
    struct scatterlist *sg;         // 이 bv가 대응하는 sg
//    struct page_pool *pp;           // (선택) 반환에 필요한 pool
};

#endif