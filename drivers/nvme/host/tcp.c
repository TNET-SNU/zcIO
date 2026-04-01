// SPDX-License-Identifier: GPL-2.0
/*
 * NVMe over Fabrics TCP host.
 * Copyright (c) 2018 Lightbits Labs. All rights reserved.
 */
#include <linux/limits.h>
#include <linux/sysctl.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/err.h>
#include <linux/key.h>
#include <linux/nvme-tcp.h>
#include <linux/nvme-keyring.h>
#include <net/sock.h>
#include <net/tcp.h>
#include <net/tls.h>
#include <net/tls_prot.h>
#include <net/handshake.h>
#include <linux/blk-mq.h>
#include <crypto/hash.h>
#include <net/busy_poll.h>
#include <trace/events/sock.h>

#include "nvme.h"
#include "fabrics.h"

/* rx-zcopy */
#include <linux/rmap.h>
#include <net/page_pool/helpers.h>
#include <linux/hugetlb.h>
#include <linux/zcopy_ctx.h>
#include <linux/mm.h>
#include <linux/mm_types.h> 


struct nvme_tcp_queue;

/* Define the socket priority to use for connections were it is desirable
 * that the NIC consider performing optimized packet processing or filtering.
 * A non-zero value being sufficient to indicate general consideration of any
 * possible optimization.  Making it a module param allows for alternative
 * values that may be unique for some NIC implementations.
 */
static int so_priority;
module_param(so_priority, int, 0644);
MODULE_PARM_DESC(so_priority, "nvme tcp socket optimize priority");

/*
 * Use the unbound workqueue for nvme_tcp_wq, then we can set the cpu affinity
 * from sysfs.
 */
static bool wq_unbound;
module_param(wq_unbound, bool, 0644);
MODULE_PARM_DESC(wq_unbound, "Use unbound workqueue for nvme-tcp IO context (default false)");

/*
 * TLS handshake timeout
 */
static int tls_handshake_timeout = 10;
#ifdef CONFIG_NVME_TCP_TLS
module_param(tls_handshake_timeout, int, 0644);
MODULE_PARM_DESC(tls_handshake_timeout,
		 "nvme TLS handshake timeout in seconds (default 10)");
#endif

/*
 * rx-zcopy: zerocopy 성능 최적화 설정
 */
#define ZC_MAX_STAGE_PAGES 64


int enable_zerocopy = 0;
module_param(enable_zerocopy, int, 0644);
MODULE_PARM_DESC(enable_zerocopy, "Enable RX zerocopy");
EXPORT_SYMBOL_GPL(enable_zerocopy); /* 여러 오브젝트에서 쓰면 export 필요 */


static bool nvme_tcp_rx_zc_batch_flush = false;
module_param_named(rx_zc_batch_flush, nvme_tcp_rx_zc_batch_flush, bool, 0644);

static int nvme_tcp_rx_zc_batch_pages = 64;
module_param_named(rx_zc_batch_pages, nvme_tcp_rx_zc_batch_pages, int, 0644);

static int nvme_tcp_rx_zc_idle_us = 50;
module_param_named(rx_zc_idle_us, nvme_tcp_rx_zc_idle_us, int, 0644);

static bool nvme_tcp_rx_zc_debug;
module_param_named(rx_zc_debug, nvme_tcp_rx_zc_debug, bool, 0644);

#define ZC_LOG(fmt, ...) \
	do { if (unlikely(nvme_tcp_rx_zc_debug)) pr_info("[rxzc] " fmt, ##__VA_ARGS__); } while (0)

#define ZC_LOG_RL(fmt, ...) \
	do { if (unlikely(nvme_tcp_rx_zc_debug)) pr_info_ratelimited("[rxzc] " fmt, ##__VA_ARGS__); } while (0)

#ifdef CONFIG_DEBUG_LOCK_ALLOC
/* lockdep can detect a circular dependency of the form
 *   sk_lock -> mmap_lock (page fault) -> fs locks -> sk_lock
 * because dependencies are tracked for both nvme-tcp and user contexts. Using
 * a separate class prevents lockdep from conflating nvme-tcp socket use with
 * user-space socket API use.
 */
static struct lock_class_key nvme_tcp_sk_key[2];
static struct lock_class_key nvme_tcp_slock_key[2];

static void nvme_tcp_reclassify_socket(struct socket *sock)
{
	struct sock *sk = sock->sk;

	if (WARN_ON_ONCE(!sock_allow_reclassification(sk)))
		return;

	switch (sk->sk_family) {
	case AF_INET:
		sock_lock_init_class_and_name(sk, "slock-AF_INET-NVME",
					      &nvme_tcp_slock_key[0],
					      "sk_lock-AF_INET-NVME",
					      &nvme_tcp_sk_key[0]);
		break;
	case AF_INET6:
		sock_lock_init_class_and_name(sk, "slock-AF_INET6-NVME",
					      &nvme_tcp_slock_key[1],
					      "sk_lock-AF_INET6-NVME",
					      &nvme_tcp_sk_key[1]);
		break;
	default:
		WARN_ON_ONCE(1);
	}
}
#else
static void nvme_tcp_reclassify_socket(struct socket *sock) { }
#endif

enum nvme_tcp_send_state {
	NVME_TCP_SEND_CMD_PDU = 0,
	NVME_TCP_SEND_H2C_PDU,
	NVME_TCP_SEND_DATA,
	NVME_TCP_SEND_DDGST,
};

enum nvme_tcp_zc_policy {
    ZC_UNDECIDED = 0,
    ZC_DISABLED,
    ZC_ENABLED,
};

struct nvme_tcp_request {
	struct nvme_request	req;
	void			*pdu;
	struct nvme_tcp_queue	*queue;
	u32			data_len;
	u32			pdu_len;
	u32			pdu_sent;
	u32			h2cdata_left;
	u32			h2cdata_offset;
	u16			ttag;
	__le16			status;
	struct list_head	entry;
	struct llist_node	lentry;
	__le32			ddgst;

	struct bio		*curr_bio;
	struct iov_iter		iter;

	/* send state */
	size_t			offset;
	size_t			data_sent;
	enum nvme_tcp_send_state state;

	/* rx-zcopy */
	enum nvme_tcp_zc_policy zc_policy;
	u32 zc_staged_pages;
};

enum nvme_tcp_queue_flags {
	NVME_TCP_Q_ALLOCATED	= 0,
	NVME_TCP_Q_LIVE		= 1,
	NVME_TCP_Q_POLLING	= 2,
};

enum nvme_tcp_recv_state {
	NVME_TCP_RECV_PDU = 0,
	NVME_TCP_RECV_DATA,
	NVME_TCP_RECV_DDGST,
};


struct zc_skb_cursor {
	struct sk_buff *root;   /* 커서가 유효한 “root skb” */
	struct sk_buff *skb;    /* 현재 스캔 중인 skb: root 또는 frag_list 요소 */
	struct sk_buff *fskb;   /* frag_list 체인에서 현재 skb (root이면 NULL) */

	unsigned int base;      /* 현재 skb의 stream base (root 기준 offset) */
	unsigned int pos;       /* 현재 frag의 start offset (root 기준) */
	int frag;               /* 현재 skb에서 다음으로 볼 frag index */
};

struct nvme_tcp_zc_pend_ent {
	struct request *rq;
	u32 pages;  /* staged pages 힌트 */
};

struct nvme_tcp_ctrl;
struct nvme_tcp_queue {
	struct socket		*sock;
	struct work_struct	io_work;
	int			io_cpu;

	struct mutex		queue_lock;
	struct mutex		send_mutex;
	struct llist_head	req_list;
	struct list_head	send_list;

	/* recv state */
	void			*pdu;
	int			pdu_remaining;
	int			pdu_offset;
	size_t			data_remaining;
	size_t			ddgst_remaining;
	unsigned int		nr_cqe;

	/* send state */
	struct nvme_tcp_request *request;

	u32			maxh2cdata;
	size_t			cmnd_capsule_len;
	struct nvme_tcp_ctrl	*ctrl;
	unsigned long		flags;
	bool			rd_enabled;

	bool			hdr_digest;
	bool			data_digest;
	struct ahash_request	*rcv_hash;
	struct ahash_request	*snd_hash;
	__le32			exp_ddgst;
	__le32			recv_ddgst;
	struct completion       tls_complete;
	int                     tls_err;
	struct page_frag_cache	pf_cache;

	/* rx-zcopy */
	spinlock_t zc_lock;
	struct workqueue_struct *zc_wq;
	bool zc_prepared;
    u32 zc_head, zc_tail, zc_cnt;
    u32 zc_pending_pages;
	u16 *zc_pend_cids;
	u32 zc_queue_depth;
    struct work_struct zc_flush_work;
	/* idle tail flush (µs) */
    struct hrtimer zc_idle_timer;
    u64 zc_last_defer_ns;   /* last enqueue timestamp */
	bool zc_shutting_down;
	atomic_t zc_idle_armed;
	struct zc_skb_cursor zc_cur;


	void (*state_change)(struct sock *);
	void (*data_ready)(struct sock *);
	void (*write_space)(struct sock *);
};

struct nvme_tcp_ctrl {
	/* read only in the hot path */
	struct nvme_tcp_queue	*queues;
	struct blk_mq_tag_set	tag_set;

	/* other member variables */
	struct list_head	list;
	struct blk_mq_tag_set	admin_tag_set;
	struct sockaddr_storage addr;
	struct sockaddr_storage src_addr;
	struct nvme_ctrl	ctrl;

	struct work_struct	err_work;
	struct delayed_work	connect_work;
	struct nvme_tcp_request async_req;
	u32			io_queues[HCTX_MAX_TYPES];
};

static LIST_HEAD(nvme_tcp_ctrl_list);
static DEFINE_MUTEX(nvme_tcp_ctrl_mutex);
static struct workqueue_struct *nvme_tcp_wq;
static const struct blk_mq_ops nvme_tcp_mq_ops;
static const struct blk_mq_ops nvme_tcp_admin_mq_ops;
static int nvme_tcp_try_send(struct nvme_tcp_queue *queue);

static inline struct nvme_tcp_ctrl *to_tcp_ctrl(struct nvme_ctrl *ctrl)
{
	return container_of(ctrl, struct nvme_tcp_ctrl, ctrl);
}

static inline int nvme_tcp_queue_id(struct nvme_tcp_queue *queue)
{
	return queue - queue->ctrl->queues;
}

static inline bool nvme_tcp_tls(struct nvme_ctrl *ctrl)
{
	if (!IS_ENABLED(CONFIG_NVME_TCP_TLS))
		return 0;

	return ctrl->opts->tls;
}

static inline struct blk_mq_tags *nvme_tcp_tagset(struct nvme_tcp_queue *queue)
{
	u32 queue_idx = nvme_tcp_queue_id(queue);

	if (queue_idx == 0)
		return queue->ctrl->admin_tag_set.tags[queue_idx];
	return queue->ctrl->tag_set.tags[queue_idx - 1];
}

static inline u8 nvme_tcp_hdgst_len(struct nvme_tcp_queue *queue)
{
	return queue->hdr_digest ? NVME_TCP_DIGEST_LENGTH : 0;
}

static inline u8 nvme_tcp_ddgst_len(struct nvme_tcp_queue *queue)
{
	return queue->data_digest ? NVME_TCP_DIGEST_LENGTH : 0;
}

static inline void *nvme_tcp_req_cmd_pdu(struct nvme_tcp_request *req)
{
	return req->pdu;
}

static inline void *nvme_tcp_req_data_pdu(struct nvme_tcp_request *req)
{
	/* use the pdu space in the back for the data pdu */
	return req->pdu + sizeof(struct nvme_tcp_cmd_pdu) -
		sizeof(struct nvme_tcp_data_pdu);
}

static inline size_t nvme_tcp_inline_data_size(struct nvme_tcp_request *req)
{
	if (nvme_is_fabrics(req->req.cmd))
		return NVME_TCP_ADMIN_CCSZ;
	return req->queue->cmnd_capsule_len - sizeof(struct nvme_command);
}

static inline bool nvme_tcp_async_req(struct nvme_tcp_request *req)
{
	return req == &req->queue->ctrl->async_req;
}

static inline bool nvme_tcp_has_inline_data(struct nvme_tcp_request *req)
{
	struct request *rq;

	if (unlikely(nvme_tcp_async_req(req)))
		return false; /* async events don't have a request */

	rq = blk_mq_rq_from_pdu(req);

	return rq_data_dir(rq) == WRITE && req->data_len &&
		req->data_len <= nvme_tcp_inline_data_size(req);
}

static inline struct page *nvme_tcp_req_cur_page(struct nvme_tcp_request *req)
{
	return req->iter.bvec->bv_page;
}

static inline size_t nvme_tcp_req_cur_offset(struct nvme_tcp_request *req)
{
	return req->iter.bvec->bv_offset + req->iter.iov_offset;
}

static inline size_t nvme_tcp_req_cur_length(struct nvme_tcp_request *req)
{
	return min_t(size_t, iov_iter_single_seg_count(&req->iter),
			req->pdu_len - req->pdu_sent);
}

static inline size_t nvme_tcp_pdu_data_left(struct nvme_tcp_request *req)
{
	return rq_data_dir(blk_mq_rq_from_pdu(req)) == WRITE ?
			req->pdu_len - req->pdu_sent : 0;
}

static inline size_t nvme_tcp_pdu_last_send(struct nvme_tcp_request *req,
		int len)
{
	return nvme_tcp_pdu_data_left(req) <= len;
}

static void nvme_tcp_init_iter(struct nvme_tcp_request *req,
		unsigned int dir)
{
	struct request *rq = blk_mq_rq_from_pdu(req);
	struct bio_vec *vec;
	unsigned int size;
	int nr_bvec;
	size_t offset;

	if (rq->rq_flags & RQF_SPECIAL_PAYLOAD) {
		vec = &rq->special_vec;
		nr_bvec = 1;
		size = blk_rq_payload_bytes(rq);
		offset = 0;
	} else {
		struct bio *bio = req->curr_bio;
		struct bvec_iter bi;
		struct bio_vec bv;

		vec = __bvec_iter_bvec(bio->bi_io_vec, bio->bi_iter);
		nr_bvec = 0;
		bio_for_each_bvec(bv, bio, bi) {
			nr_bvec++;
		}
		size = bio->bi_iter.bi_size;
		offset = bio->bi_iter.bi_bvec_done;
	}

	iov_iter_bvec(&req->iter, dir, vec, nr_bvec, size);
	req->iter.iov_offset = offset;

}

static inline void nvme_tcp_advance_req(struct nvme_tcp_request *req,
		int len)
{
	req->data_sent += len;
	req->pdu_sent += len;
	iov_iter_advance(&req->iter, len);
	if (!iov_iter_count(&req->iter) &&
	    req->data_sent < req->data_len) {
		req->curr_bio = req->curr_bio->bi_next;
		nvme_tcp_init_iter(req, ITER_SOURCE);
	}
}

static inline void nvme_tcp_send_all(struct nvme_tcp_queue *queue)
{
	int ret;

	/* drain the send queue as much as we can... */
	do {
		ret = nvme_tcp_try_send(queue);
	} while (ret > 0);
}

static inline bool nvme_tcp_queue_has_pending(struct nvme_tcp_queue *queue)
{
	return !list_empty(&queue->send_list) ||
		!llist_empty(&queue->req_list);
}

static inline bool nvme_tcp_queue_more(struct nvme_tcp_queue *queue)
{
	return !nvme_tcp_tls(&queue->ctrl->ctrl) &&
		nvme_tcp_queue_has_pending(queue);
}

static inline void nvme_tcp_queue_request(struct nvme_tcp_request *req,
		bool sync, bool last)
{
	struct nvme_tcp_queue *queue = req->queue;
	bool empty;

	empty = llist_add(&req->lentry, &queue->req_list) &&
		list_empty(&queue->send_list) && !queue->request;

	/*
	 * if we're the first on the send_list and we can try to send
	 * directly, otherwise queue io_work. Also, only do that if we
	 * are on the same cpu, so we don't introduce contention.
	 */
	if (queue->io_cpu == raw_smp_processor_id() &&
	    sync && empty && mutex_trylock(&queue->send_mutex)) {
		nvme_tcp_send_all(queue);
		mutex_unlock(&queue->send_mutex);
	}

	if (last && nvme_tcp_queue_has_pending(queue))
		queue_work_on(queue->io_cpu, nvme_tcp_wq, &queue->io_work);
}

static void nvme_tcp_process_req_list(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_request *req;
	struct llist_node *node;

	for (node = llist_del_all(&queue->req_list); node; node = node->next) {
		req = llist_entry(node, struct nvme_tcp_request, lentry);
		list_add(&req->entry, &queue->send_list);
	}
}

static inline struct nvme_tcp_request *
nvme_tcp_fetch_request(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_request *req;

	req = list_first_entry_or_null(&queue->send_list,
			struct nvme_tcp_request, entry);
	if (!req) {
		nvme_tcp_process_req_list(queue);
		req = list_first_entry_or_null(&queue->send_list,
				struct nvme_tcp_request, entry);
		if (unlikely(!req))
			return NULL;
	}

	list_del(&req->entry);
	return req;
}

static inline void nvme_tcp_ddgst_final(struct ahash_request *hash,
		__le32 *dgst)
{
	ahash_request_set_crypt(hash, NULL, (u8 *)dgst, 0);
	crypto_ahash_final(hash);
}

static inline void nvme_tcp_ddgst_update(struct ahash_request *hash,
		struct page *page, off_t off, size_t len)
{
	struct scatterlist sg;

	sg_init_table(&sg, 1);
	sg_set_page(&sg, page, len, off);
	ahash_request_set_crypt(hash, &sg, NULL, len);
	crypto_ahash_update(hash);
}

static inline void nvme_tcp_hdgst(struct ahash_request *hash,
		void *pdu, size_t len)
{
	struct scatterlist sg;

	sg_init_one(&sg, pdu, len);
	ahash_request_set_crypt(hash, &sg, pdu + len, len);
	crypto_ahash_digest(hash);
}

static int nvme_tcp_verify_hdgst(struct nvme_tcp_queue *queue,
		void *pdu, size_t pdu_len)
{
	struct nvme_tcp_hdr *hdr = pdu;
	__le32 recv_digest;
	__le32 exp_digest;

	if (unlikely(!(hdr->flags & NVME_TCP_F_HDGST))) {
		dev_err(queue->ctrl->ctrl.device,
			"queue %d: header digest flag is cleared\n",
			nvme_tcp_queue_id(queue));
		return -EPROTO;
	}

	recv_digest = *(__le32 *)(pdu + hdr->hlen);
	nvme_tcp_hdgst(queue->rcv_hash, pdu, pdu_len);
	exp_digest = *(__le32 *)(pdu + hdr->hlen);
	if (recv_digest != exp_digest) {
		dev_err(queue->ctrl->ctrl.device,
			"header digest error: recv %#x expected %#x\n",
			le32_to_cpu(recv_digest), le32_to_cpu(exp_digest));
		return -EIO;
	}

	return 0;
}

static int nvme_tcp_check_ddgst(struct nvme_tcp_queue *queue, void *pdu)
{
	struct nvme_tcp_hdr *hdr = pdu;
	u8 digest_len = nvme_tcp_hdgst_len(queue);
	u32 len;

	len = le32_to_cpu(hdr->plen) - hdr->hlen -
		((hdr->flags & NVME_TCP_F_HDGST) ? digest_len : 0);

	if (unlikely(len && !(hdr->flags & NVME_TCP_F_DDGST))) {
		dev_err(queue->ctrl->ctrl.device,
			"queue %d: data digest flag is cleared\n",
		nvme_tcp_queue_id(queue));
		return -EPROTO;
	}
	crypto_ahash_init(queue->rcv_hash);

	return 0;
}

static void nvme_tcp_exit_request(struct blk_mq_tag_set *set,
		struct request *rq, unsigned int hctx_idx)
{
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);

	page_frag_free(req->pdu);
}

static int nvme_tcp_init_request(struct blk_mq_tag_set *set,
		struct request *rq, unsigned int hctx_idx,
		unsigned int numa_node)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(set->driver_data);
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	struct nvme_tcp_cmd_pdu *pdu;
	int queue_idx = (set == &ctrl->tag_set) ? hctx_idx + 1 : 0;
	struct nvme_tcp_queue *queue = &ctrl->queues[queue_idx];
	u8 hdgst = nvme_tcp_hdgst_len(queue);

	req->pdu = page_frag_alloc(&queue->pf_cache,
		sizeof(struct nvme_tcp_cmd_pdu) + hdgst,
		GFP_KERNEL | __GFP_ZERO);
	if (!req->pdu)
		return -ENOMEM;

	pdu = req->pdu;
	req->queue = queue;
	nvme_req(rq)->ctrl = &ctrl->ctrl;
	nvme_req(rq)->cmd = &pdu->cmd;

	return 0;
}

static int nvme_tcp_init_hctx(struct blk_mq_hw_ctx *hctx, void *data,
		unsigned int hctx_idx)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(data);
	struct nvme_tcp_queue *queue = &ctrl->queues[hctx_idx + 1];

	hctx->driver_data = queue;
	return 0;
}

static int nvme_tcp_init_admin_hctx(struct blk_mq_hw_ctx *hctx, void *data,
		unsigned int hctx_idx)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(data);
	struct nvme_tcp_queue *queue = &ctrl->queues[0];

	hctx->driver_data = queue;
	return 0;
}

static enum nvme_tcp_recv_state
nvme_tcp_recv_state(struct nvme_tcp_queue *queue)
{
	return  (queue->pdu_remaining) ? NVME_TCP_RECV_PDU :
		(queue->ddgst_remaining) ? NVME_TCP_RECV_DDGST :
		NVME_TCP_RECV_DATA;
}

static void nvme_tcp_init_recv_ctx(struct nvme_tcp_queue *queue)
{
	queue->pdu_remaining = sizeof(struct nvme_tcp_rsp_pdu) +
				nvme_tcp_hdgst_len(queue);
	queue->pdu_offset = 0;
	queue->data_remaining = -1;
	queue->ddgst_remaining = 0;
}

static void nvme_tcp_error_recovery(struct nvme_ctrl *ctrl)
{
	if (!nvme_change_ctrl_state(ctrl, NVME_CTRL_RESETTING))
		return;

	dev_warn(ctrl->device, "starting error recovery\n");
	queue_work(nvme_reset_wq, &to_tcp_ctrl(ctrl)->err_work);
}

static int nvme_tcp_process_nvme_cqe(struct nvme_tcp_queue *queue,
		struct nvme_completion *cqe)
{
	struct nvme_tcp_request *req;
	struct request *rq;

	rq = nvme_find_rq(nvme_tcp_tagset(queue), cqe->command_id);
	if (!rq) {
		dev_err(queue->ctrl->ctrl.device,
			"got bad cqe.command_id %#x on queue %d\n",
			cqe->command_id, nvme_tcp_queue_id(queue));
		nvme_tcp_error_recovery(&queue->ctrl->ctrl);
		return -EINVAL;
	}

	req = blk_mq_rq_to_pdu(rq);
	if (req->status == cpu_to_le16(NVME_SC_SUCCESS))
		req->status = cqe->status;

	if (!nvme_try_complete_req(rq, req->status, cqe->result))
		nvme_complete_rq(rq);
	queue->nr_cqe++;

	return 0;
}

static int nvme_tcp_handle_c2h_data(struct nvme_tcp_queue *queue,
		struct nvme_tcp_data_pdu *pdu)
{
	struct request *rq;

	rq = nvme_find_rq(nvme_tcp_tagset(queue), pdu->command_id);
	if (!rq) {
		dev_err(queue->ctrl->ctrl.device,
			"got bad c2hdata.command_id %#x on queue %d\n",
			pdu->command_id, nvme_tcp_queue_id(queue));
		return -ENOENT;
	}

	if (!blk_rq_payload_bytes(rq)) {
		dev_err(queue->ctrl->ctrl.device,
			"queue %d tag %#x unexpected data\n",
			nvme_tcp_queue_id(queue), rq->tag);
		return -EIO;
	}

	queue->data_remaining = le32_to_cpu(pdu->data_length);

	if (pdu->hdr.flags & NVME_TCP_F_DATA_SUCCESS &&
	    unlikely(!(pdu->hdr.flags & NVME_TCP_F_DATA_LAST))) {
		dev_err(queue->ctrl->ctrl.device,
			"queue %d tag %#x SUCCESS set but not last PDU\n",
			nvme_tcp_queue_id(queue), rq->tag);
		nvme_tcp_error_recovery(&queue->ctrl->ctrl);
		return -EPROTO;
	}

	return 0;
}

static int nvme_tcp_handle_comp(struct nvme_tcp_queue *queue,
		struct nvme_tcp_rsp_pdu *pdu)
{
	struct nvme_completion *cqe = &pdu->cqe;
	int ret = 0;

	/*
	 * AEN requests are special as they don't time out and can
	 * survive any kind of queue freeze and often don't respond to
	 * aborts.  We don't even bother to allocate a struct request
	 * for them but rather special case them here.
	 */
	if (unlikely(nvme_is_aen_req(nvme_tcp_queue_id(queue),
				     cqe->command_id)))
		nvme_complete_async_event(&queue->ctrl->ctrl, cqe->status,
				&cqe->result);
	else
		ret = nvme_tcp_process_nvme_cqe(queue, cqe);

	return ret;
}

static void nvme_tcp_setup_h2c_data_pdu(struct nvme_tcp_request *req)
{
	struct nvme_tcp_data_pdu *data = nvme_tcp_req_data_pdu(req);
	struct nvme_tcp_queue *queue = req->queue;
	struct request *rq = blk_mq_rq_from_pdu(req);
	u32 h2cdata_sent = req->pdu_len;
	u8 hdgst = nvme_tcp_hdgst_len(queue);
	u8 ddgst = nvme_tcp_ddgst_len(queue);

	req->state = NVME_TCP_SEND_H2C_PDU;
	req->offset = 0;
	req->pdu_len = min(req->h2cdata_left, queue->maxh2cdata);
	req->pdu_sent = 0;
	req->h2cdata_left -= req->pdu_len;
	req->h2cdata_offset += h2cdata_sent;

	memset(data, 0, sizeof(*data));
	data->hdr.type = nvme_tcp_h2c_data;
	if (!req->h2cdata_left)
		data->hdr.flags = NVME_TCP_F_DATA_LAST;
	if (queue->hdr_digest)
		data->hdr.flags |= NVME_TCP_F_HDGST;
	if (queue->data_digest)
		data->hdr.flags |= NVME_TCP_F_DDGST;
	data->hdr.hlen = sizeof(*data);
	data->hdr.pdo = data->hdr.hlen + hdgst;
	data->hdr.plen =
		cpu_to_le32(data->hdr.hlen + hdgst + req->pdu_len + ddgst);
	data->ttag = req->ttag;
	data->command_id = nvme_cid(rq);
	data->data_offset = cpu_to_le32(req->h2cdata_offset);
	data->data_length = cpu_to_le32(req->pdu_len);
}

static int nvme_tcp_handle_r2t(struct nvme_tcp_queue *queue,
		struct nvme_tcp_r2t_pdu *pdu)
{
	struct nvme_tcp_request *req;
	struct request *rq;
	u32 r2t_length = le32_to_cpu(pdu->r2t_length);
	u32 r2t_offset = le32_to_cpu(pdu->r2t_offset);

	rq = nvme_find_rq(nvme_tcp_tagset(queue), pdu->command_id);
	if (!rq) {
		dev_err(queue->ctrl->ctrl.device,
			"got bad r2t.command_id %#x on queue %d\n",
			pdu->command_id, nvme_tcp_queue_id(queue));
		return -ENOENT;
	}
	req = blk_mq_rq_to_pdu(rq);

	if (unlikely(!r2t_length)) {
		dev_err(queue->ctrl->ctrl.device,
			"req %d r2t len is %u, probably a bug...\n",
			rq->tag, r2t_length);
		return -EPROTO;
	}

	if (unlikely(req->data_sent + r2t_length > req->data_len)) {
		dev_err(queue->ctrl->ctrl.device,
			"req %d r2t len %u exceeded data len %u (%zu sent)\n",
			rq->tag, r2t_length, req->data_len, req->data_sent);
		return -EPROTO;
	}

	if (unlikely(r2t_offset < req->data_sent)) {
		dev_err(queue->ctrl->ctrl.device,
			"req %d unexpected r2t offset %u (expected %zu)\n",
			rq->tag, r2t_offset, req->data_sent);
		return -EPROTO;
	}

	req->pdu_len = 0;
	req->h2cdata_left = r2t_length;
	req->h2cdata_offset = r2t_offset;
	req->ttag = pdu->ttag;

	nvme_tcp_setup_h2c_data_pdu(req);
	nvme_tcp_queue_request(req, false, true);

	return 0;
}

static int nvme_tcp_recv_pdu(struct nvme_tcp_queue *queue, struct sk_buff *skb,
		unsigned int *offset, size_t *len)
{
	struct nvme_tcp_hdr *hdr;
	char *pdu = queue->pdu;
	size_t rcv_len = min_t(size_t, *len, queue->pdu_remaining);
	int ret;
	
	ret = skb_copy_bits(skb, *offset,
		&pdu[queue->pdu_offset], rcv_len);
	if (unlikely(ret))
		return ret;

	queue->pdu_remaining -= rcv_len;
	queue->pdu_offset += rcv_len;
	*offset += rcv_len;
	*len -= rcv_len;
	if (queue->pdu_remaining)
		return 0;

	hdr = queue->pdu;
	if (queue->hdr_digest) {
		ret = nvme_tcp_verify_hdgst(queue, queue->pdu, hdr->hlen);
		if (unlikely(ret))
			return ret;
	}


	if (queue->data_digest) {
		ret = nvme_tcp_check_ddgst(queue, queue->pdu);
		if (unlikely(ret))
			return ret;
	}

	switch (hdr->type) {
	case nvme_tcp_c2h_data:
		return nvme_tcp_handle_c2h_data(queue, (void *)queue->pdu);
	case nvme_tcp_rsp:
		nvme_tcp_init_recv_ctx(queue);
		return nvme_tcp_handle_comp(queue, (void *)queue->pdu);
	case nvme_tcp_r2t:
		nvme_tcp_init_recv_ctx(queue);
		return nvme_tcp_handle_r2t(queue, (void *)queue->pdu);
	default:
		dev_err(queue->ctrl->ctrl.device,
			"unsupported pdu type (%d)\n", hdr->type);
		return -EINVAL;
	}
}

static inline void nvme_tcp_end_request(struct request *rq, u16 status)
{
	union nvme_result res = {};

	if (!nvme_try_complete_req(rq, cpu_to_le16(status << 1), res))
		nvme_complete_rq(rq);
}

/* rx-zcopy */
static inline bool is_pp_page(struct page *page)
{
	return (page->pp_magic & ~0x3UL) == PP_SIGNATURE;
}

static inline void apply_rss_delta_vec(struct mm_struct *mm, long *rss)
{
	int c;
	for (c = 0; c < NR_MM_COUNTERS; c++) {
		long d = rss[c];
		if (d)
			add_mm_counter(mm, c, d);
	}
}

static int stage_remap_pages(struct bio *bio, size_t start_idx, struct page **new_pages, int nr_pages) {
	struct my_bio_private *priv = bio->bi_private;
	struct my_ctx *ctx;
	struct mm_struct *mm;
	int success_count = 0;
	size_t i;

	size_t start = start_idx;
	size_t end = start + nr_pages;
	
	if (unlikely(!priv || priv->magic != MY_BIO_PRIVATE_MAGIC))	return 0;

	ctx = priv->ctx;
	if (unlikely(!ctx)) return 0;

	mm = ctx->mm;
	if (unlikely(!mm))	return 0;

	if (in_softirq() || in_interrupt()) {
		if (unlikely(!down_read_trylock(&mm->mmap_lock)))
			return 0;
	}
	else {
		if (unlikely(!down_read_trylock(&mm->mmap_lock)))
			down_read(&mm->mmap_lock);
	}

	unsigned long mm_flush_min = ULONG_MAX, mm_flush_max = 0;
	long *rss_delta = ctx->zc_rss_delta;

	struct vm_area_struct *cur_vma = NULL;
	unsigned long vma_end = 0;
	for (i = start; i < end;) {
		unsigned long addr = ctx->user_addr[i];
		struct vm_area_struct *vma = NULL;

		if (cur_vma && addr < vma_end && addr >= cur_vma->vm_start){
			vma = cur_vma;
		}
		else {
			vma = vma_lookup(mm, addr);
			if (!vma || addr < vma->vm_start || addr >= vma->vm_end) {i++; continue;}
			if (unlikely(vma->vm_flags & VM_PFNMAP)) {i++; continue;}
			cur_vma = vma;
			vma_end = cur_vma->vm_end;
		}

        unsigned long run_start = addr;
		unsigned long run_end = addr + PAGE_SIZE;
		unsigned long pmd_cap = pmd_addr_end(run_start, vma->vm_end);

		size_t j = i + 1;
		for (; j < end; j++) {
			unsigned long a = ctx->user_addr[j];
			if (unlikely(!a)) {
				pr_info("a is NULL\n");
				break;
			}
			if (a != run_end)
				break;
			if (run_end >= pmd_cap)
				break;
			run_end += PAGE_SIZE;
		}

		pmd_t *pmd = pmd_offset(
			pud_offset(p4d_offset(pgd_offset(mm, run_start), run_start), run_start),
			run_start);
		if (unlikely(pmd_none(*pmd) || pmd_bad(*pmd))) {
			i = j;
			continue;
		}
		if (unlikely(pmd_trans_huge(*pmd) || pmd_devmap(*pmd))) {
			split_huge_pmd(vma, pmd, run_start);
			if (unlikely(pmd_trans_huge(*pmd) || pmd_devmap(*pmd))) {
				i = j;
				continue;
			}
		}

		spinlock_t *ptl;
		pte_t *ptep0 = pte_offset_map_lock(mm, pmd, run_start, &ptl);
		pte_t *pbase = ptep0 - pte_index(run_start);

		bool vma_write = !!(vma->vm_flags & VM_WRITE);
		bool is_anon   = (vma->vm_file == NULL && !(vma->vm_flags & VM_PFNMAP));

		pte_t *p = pbase + pte_index(run_start);
		unsigned long a = run_start;

		for (size_t k = i; k < j; k++, a += PAGE_SIZE, p++) {
			pte_t old = READ_ONCE(*p);

			if (likely(pte_present(old))) {
				old = ptep_get_and_clear(mm, a, p);

				struct page  *old_page = pte_page(old);
				struct folio *old_f    = page_folio(old_page);

				rss_delta[mm_counter(old_f)]--;
				folio_remove_rmap_ptes(old_f, old_page, 1, vma);

				// old page 관리: pp만 모으고, normal은 여기서 put 
				if (likely(ctx->old_nr_pages < ctx->nr_pages)) {
					if (unlikely(!is_pp_page(old_page))) {
						//pr_info("[stage_remap_pages] old_page: %px, ref count: %d\n", old_page, page_ref_count(old_page), atomic_long_read(&old_page->pp_ref_count));
						put_page(old_page);
					} else {
						ctx->old_pages[ctx->old_nr_pages++] = old_page;
						//trace_printk("[stage_remap_pages] old_page: %px\n", old_page);
					}
				} else {
					// overflow면 안전하게 normal 처리 
					pr_info("[overflow] old_page: %px\n", old_page);
					//if (unlikely(!is_pp_page(old_page)))
						//put_page(old_page);
				}
			}
		
			if (pte_none(old) || pte_present(old)) {
				struct page *new_page = new_pages[k-start];
				struct folio *new_f = page_folio(new_page);
				pte_t np = mk_pte(new_page, vma->vm_page_prot);
				//if (vma_write) {
				if (vma->vm_flags & VM_WRITE) {
					np = pte_mkwrite(np, vma);
					np = pte_mkdirty(np);
				}
				np = pte_mkyoung(np);

				set_pte_at(mm, a, p, np);

				bool is_anon = (vma->vm_file == NULL && !(vma->vm_flags & VM_PFNMAP));
				if (is_anon) {
					folio_add_anon_rmap_ptes(new_f, new_page, 1, vma, a, RMAP_NONE);
				}
				else {
					folio_add_file_rmap_ptes(new_f, new_page, 1, vma);
				}
				rss_delta[mm_counter(new_f)]++;
			}

			//ctx->user_addr[k] = 0;
		}

		pte_unmap_unlock(ptep0, ptl);

		if (run_start < mm_flush_min)
			mm_flush_min = run_start;
		if (run_end > mm_flush_max)
			mm_flush_max = run_end;

		success_count += (j - i);
		i = j;
	}

	up_read(&mm->mmap_lock);

	if (mm_flush_min < mm_flush_max) {
		ctx->zc_staged = true;
		ctx->zc_flush_min = mm_flush_min;
		ctx->zc_flush_max = mm_flush_max;
		ctx->zc_staged_pages = success_count;
	} 

	//pr_info("stage_remap_pages success_count=%d\n", success_count);
	return success_count;
}
static int zc_finish_cleanup_ctx(struct request *rq)
{
	int done_pages = 0;
	for (struct bio *bio = rq->bio; bio; bio = bio->bi_next) {
		struct my_bio_private *priv = bio->bi_private;
		if (!priv || priv->magic != MY_BIO_PRIVATE_MAGIC)
			continue;
		struct my_ctx *ctx = priv->ctx;
		if (!ctx || ctx->magic != MY_CTX_MAGIC)
			continue;
	
		struct mm_struct *mm = ctx->mm;

		/* RSS 적용 */
		apply_rss_delta_vec(mm, ctx->zc_rss_delta);

		ctx->zc_staged = false;
		done_pages += ctx->zc_staged_pages;
		ctx->zc_staged_pages = 0;
	}
    return done_pages;
}


//static int batch_remap_pages(struct bio *bio)
static int batch_remap_pages(struct bio *bio, size_t start_idx, struct page **new_pages, int nr_pages)
{
	struct my_bio_private *priv = bio->bi_private;
	struct my_ctx *ctx = NULL;
	struct mm_struct *mm = NULL;
	int success_count = 0;
	size_t i;


	size_t start = start_idx;
	size_t end = start + (size_t)nr_pages;
	

	if (unlikely(!priv || priv->magic != MY_BIO_PRIVATE_MAGIC)){
		pr_info("[zerocopy] batch_remap FAIL: priv=NULL or priv->magic != MY_BIO_PRIVATE_MAGIC\n");
		return 0;
	}

	ctx = priv->ctx;
	if (unlikely(!ctx)){
		pr_info("[zerocopy] batch_remap FAIL: ctx=NULL\n");
		return 0;
	}

	mm = ctx->mm;
//	int start = ctx->next_flush_index; // mostly 0
//	int end = start + ctx->pending_cnt;

	if (unlikely(!mm )){
		pr_info("[zerocopy] batch_remap FAIL: mm=%p\n", 
			mm);
		return 0;
	}

	// 소프트IRQ 문맥이면 절대 sleep 금지: trylock 실패시 빠르게 탈출 
	if (in_softirq() || in_interrupt()) {
		if (unlikely(!down_read_trylock(&mm->mmap_lock)))
			return 0;
	} else {
		// workqueue/kthread 문맥이면 실패 시 블로킹락 폴백 
		if (unlikely(!down_read_trylock(&mm->mmap_lock)))
			down_read(&mm->mmap_lock);
	}

	//pr_info("[[[ batch remap start : page count = %d\n", end - start);
	unsigned long mm_flush_min = ULONG_MAX, mm_flush_max = 0;
	long rss_delta[NR_MM_COUNTERS] = {0}; 

	struct vm_area_struct *cur_vma = NULL;
	unsigned long vma_end = 0;	
	for (i = start; i < end;) {
		unsigned long addr = ctx->user_addr[i];
		struct vm_area_struct *vma = NULL;

		if (cur_vma && addr < vma_end && addr >= cur_vma->vm_start){
			vma = cur_vma;
		}
		else {
			vma = vma_lookup(mm, addr);
			if (!vma || addr < vma->vm_start || addr >= vma->vm_end) {i++; continue;}
			if (unlikely(vma->vm_flags & VM_PFNMAP)) {i++; continue;}
			cur_vma = vma;
			vma_end = cur_vma->vm_end;
		}

		// 같은 pmd 안에서 연속인 run 경계를 찾자
		unsigned long run_start = addr;
		unsigned long run_end   = addr + PAGE_SIZE;
		unsigned long pmd_cap = pmd_addr_end(run_start, vma->vm_end);

		size_t j = i + 1;
		for (; j < end; j++) {
			unsigned long a = ctx->user_addr[j];
			if (unlikely(!a)) {
				pr_info("a is NULL\n");
				break;
			}
			if (a != run_end) break;               // 비연속이면 중단
			// pmd 경계 넘어가면 중단
			if (run_end >= pmd_cap) break;
			run_end += PAGE_SIZE;
		}

		// 이제 [i..j-1]가 같은 pmd의 연속 페이지 run
		pmd_t *pmd = pmd_offset(
			pud_offset(p4d_offset(pgd_offset(mm, run_start), run_start), run_start), run_start);
		if (unlikely(pmd_none(*pmd) || pmd_bad(*pmd))) {
			i = j;
			continue;
		}
		if (unlikely(pmd_trans_huge(*pmd) || pmd_devmap(*pmd))) {
			split_huge_pmd(vma, pmd, run_start);
			if (unlikely(pmd_trans_huge(*pmd) || pmd_devmap(*pmd))) {
				// split 지연/실패: 안전하게 이 run은 건너뛰기
				i = j; 
				continue;
			}
		}
		
		spinlock_t *ptl;
		pte_t *ptep0 = pte_offset_map_lock(mm, pmd, run_start, &ptl);
		pte_t *pbase = ptep0 - pte_index(run_start);

		// 1) old PTE들 clear (flush 보류)
		for (size_t k = i; k < j; k++) {
			unsigned long a = ctx->user_addr[k];
			//pr_info("user_address: %lx\n", a);
			pte_t *p = pbase + pte_index(a);

			if (likely(k + 1 < j)) {
				unsigned long na = ctx->user_addr[k + 1];
				prefetchw(pbase + pte_index(na));

				int ni = (int)((k + 1) - start);
				if (likely((unsigned)ni < (unsigned)nr_pages))
					prefetchw(&new_pages[ni]->flags);
			}


			pte_t old = READ_ONCE(*p);
			
			if (likely(pte_present(old))){
				old = ptep_get_and_clear(mm, a, p);  // 여기선 flush 안 함

				struct page *old_page = pte_page(old);
				struct folio *old_f = page_folio(old_page);
				// rmap & RSS 감소
				rss_delta[mm_counter(old_f)]--;
				folio_remove_rmap_ptes(old_f, old_page, 1, vma);

				if (ctx->old_nr_pages >= ctx->nr_pages) {
					pr_info("[batch_remap_pages] old_nr_pages overflow: %d > %d\n",
							ctx->old_nr_pages, ctx->nr_pages);
				} else {
					if (unlikely(!is_pp_page(old_page))){
//						pr_info("[batch_remap_pages] old_page is not pp page: %px, ref count: %d\n", old_page, page_ref_count(old_page));
						put_page(old_page);
					}
					else {
						ctx->old_pages[ctx->old_nr_pages++] = old_page;
					}
				}
			}	
			if (pte_none(old) || pte_present(old)){
				struct page *new_page = new_pages[k-start];
				struct folio *new_f   = page_folio(new_page);
				pte_t np = mk_pte(new_page, vma->vm_page_prot);
				if (vma->vm_flags & VM_WRITE){
					np = pte_mkwrite(np, vma);
					np = pte_mkdirty(np);
				}
				np = pte_mkyoung(np);

				bool is_anon = (vma->vm_file == NULL && !(vma->vm_flags & VM_PFNMAP));
				set_pte_at(mm, a, p, np);
				if (is_anon){
					folio_add_anon_rmap_ptes(new_f, new_page, 1, vma, a, RMAP_NONE);
				}
				else{
					folio_add_file_rmap_ptes(new_f, new_page, 1, vma);
				}
				rss_delta[mm_counter(new_f)]++;
			}
			else {
				pr_info("pte_none(old) or pte_present(old) is not true\n");
			}
		
			//ctx->user_addr[k] = 0;
		}

	
		pte_unmap_unlock(ptep0, ptl);

		if (run_start < mm_flush_min) mm_flush_min = run_start;
		if (run_end   > mm_flush_max) mm_flush_max = run_end;
		success_count += (j - i);
		i = j;
	}


	// === 배치 종료: 여기서 단 한 번 TLBI & free & RSS 적용 === 
	if (mm_flush_min < mm_flush_max) {
		flush_tlb_mm_range(mm, mm_flush_min, mm_flush_max, PAGE_SHIFT, false);
	}

	apply_rss_delta_vec(mm, rss_delta);

	up_read(&mm->mmap_lock);
	//pr_info("batch remap end : page count = %d ]]]\n", success_count);
	return success_count;
}

static inline bool zc_is_full_4k_page_frag(const skb_frag_t *f)
{
	return skb_frag_size(f) == PAGE_SIZE && skb_frag_off(f) == 0;
}

/*
 * Cached (buffered) I/O zerocopy support.
 *
 * For direct I/O, we remap NIC page-pool pages into the user's page table so
 * the app sees the data without any kernel copy.  For buffered I/O there is no
 * user VA to remap into, but we can still skip one copy by *swapping* the
 * NIC frag page into the bio_vec in place of the kernel page-cache page that
 * was originally there.  The data then lives directly in the frag page inside
 * the page cache.  No page-table walk, no TLB flush, no mmap_lock – just a
 * pointer swap inside the bio_vec array.
 *
 * Lifecycle of the swapped-in frag page:
 *   1.  get_page() + page_pool_ref_page() while we hold it.
 *   2.  Installed as bv_page in the bio.  Old cache page is put_page()'d.
 *   3.  Bio completes: VFS end_io marks the page uptodate, unlocks it,
 *       and calls put_page() – consuming the get_page() ref from step 1.
 *   4.  Our wrapped end_io calls page_pool_unref_page() to release the
 *       pool's in-flight accounting, then put_page() for the pool ref.
 *
 * Activated by enable_zerocopy == 2.
 */

#define MY_CACHED_ZC_MAGIC  0x63616368u   /* "cach" */

struct nvme_tcp_cached_zc_priv {
	u32		magic;		/* MY_CACHED_ZC_MAGIC */
	u16		nr_frag_pages;
	u16		max_frag_pages;
	void		*orig_private;
	bio_end_io_t	*orig_end_io;
	struct page	*frag_pages[];	/* flexible array, allocated with struct */
};

static void nvme_tcp_cached_zc_bio_end_io(struct bio *bio)
{
	struct nvme_tcp_cached_zc_priv *priv = bio->bi_private;

	/* Release pool refs for all frag pages we swapped into the bio. */
	for (int i = 0; i < priv->nr_frag_pages; i++) {
		struct page *p = priv->frag_pages[i];
		if (p) {
			page_pool_unref_page(p, 1);
			put_page(p);
		}
	}

	bio->bi_private = priv->orig_private;
	bio->bi_end_io  = priv->orig_end_io;
	kfree(priv);

	if (bio->bi_end_io)
		bio->bi_end_io(bio);
}

/*
 * Attach (or return existing) nvme_tcp_cached_zc_priv to bio->bi_private.
 * Called from softirq – GFP_ATOMIC only.
 */
static struct nvme_tcp_cached_zc_priv *
nvme_tcp_cached_zc_ensure_priv(struct bio *bio, int max_pages)
{
	struct nvme_tcp_cached_zc_priv *priv = bio->bi_private;

	/* Already installed by an earlier chunk for this bio. */
	if (priv && priv->magic == MY_CACHED_ZC_MAGIC)
		return priv;

	/* Never wrap a direct-IO bio that already owns bi_private. */
	if (priv) {
		struct my_bio_private *dp = (struct my_bio_private *)priv;
		if (dp->magic == MY_BIO_PRIVATE_MAGIC)
			return NULL;
	}

	size_t sz = sizeof(*priv) + (size_t)max_pages * sizeof(struct page *);
	priv = kmalloc(sz, GFP_ATOMIC);
	if (!priv)
		return NULL;

	priv->magic		= MY_CACHED_ZC_MAGIC;
	priv->nr_frag_pages	= 0;
	priv->max_frag_pages	= max_pages;
	priv->orig_private	= bio->bi_private;
	priv->orig_end_io	= bio->bi_end_io;

	bio->bi_private = priv;
	bio->bi_end_io  = nvme_tcp_cached_zc_bio_end_io;

	return priv;
}

static inline bool can_use_zerocopy_cached(struct nvme_tcp_queue *queue,
					   struct nvme_tcp_request *req,
					   int recv_len)
{
	if (!enable_zerocopy)
		return false;
	if (queue->data_digest)
		return false;
	if (!req->curr_bio || recv_len < PAGE_SIZE)
		return false;

	/*
	 * Don't step on a bio already owned by the direct-IO zerocopy path.
	 * Both wrappers put their magic as the first u32 of bi_private.
	 */
	u32 *magic = (u32 *)req->curr_bio->bi_private;
	if (magic && *magic == MY_BIO_PRIVATE_MAGIC)
		return false;

	/* Iterator must sit at a page boundary. */
	if (req->iter.iov_offset != 0)
		return false;

	return true;
}

/*
 * Swap NIC page-pool frag pages into the bio_vec in-place, avoiding the
 * NIC->page-cache memcpy entirely.
 *
 * Returns  0   on full success  – caller must advance req->iter by recv_len.
 * Returns -1   on any failure   – caller falls back to skb_copy_datagram_iter.
 */
static int do_zerocopy_cached(struct nvme_tcp_queue *queue,
			       struct sk_buff *skb,
			       struct nvme_tcp_request *req,
			       int recv_len, unsigned int offset)
{
	struct bio *bio	     = req->curr_bio;
	int nr_pages         = recv_len >> PAGE_SHIFT;
	unsigned int cur_off = offset;

	/*
	 * bio->bi_iter.bi_size is the bio's original transfer size and is not
	 * decremented during receive processing, so it gives the true page
	 * count for the frag_pages[] array bound.
	 */
	int max_pages = DIV_ROUND_UP(bio->bi_iter.bi_size, PAGE_SIZE);
	struct nvme_tcp_cached_zc_priv *priv =
		nvme_tcp_cached_zc_ensure_priv(bio, max_pages);
	if (!priv)
		return -1;

	/*
	 * req->iter.bvec points directly into bio->bi_io_vec[].  The array is
	 * writable; the const qualifier is just an iov_iter API guard.  Cast
	 * it away so we can swap bv_page in-place.
	 */
	struct bio_vec *bv = (struct bio_vec *)req->iter.bvec;

	for (int i = 0; i < nr_pages; i++) {
		/* Every slot must be exactly one full unshifted page. */
		if (unlikely(bv[i].bv_len != PAGE_SIZE || bv[i].bv_offset != 0))
			goto error;

		/* Locate the matching 4K page-pool frag in the SKB. */
		struct sk_buff *owner = NULL;
		int frag_index = -1;
		unsigned int page_off = 0;

		if (zc_find_next_4k_stateful(queue, skb, cur_off,
					     &owner, &frag_index, &page_off))
			goto error;
		if (unlikely(page_off != cur_off))
			goto error;

		skb_frag_t *frag = &skb_shinfo(owner)->frags[frag_index];
		if (unlikely(skb_frag_size(frag) != PAGE_SIZE ||
			     skb_frag_off(frag)  != 0))
			goto error;

		struct page *fp = skb_frag_page(frag);
		if (unlikely(!is_pp_page(fp)))
			goto error;

		/*
		 * Two references on the frag page:
		 *   get_page()           – keeps the page alive until the VFS
		 *                          end_io's put_page() runs.
		 *   page_pool_ref_page() – prevents the pool from reclaiming the
		 *                          page when the SKB drops its own frag
		 *                          reference before our end_io fires.
		 */
		if (!get_page_unless_zero(fp))
			goto error;
		page_pool_ref_page(fp);

		/* Evict the old cache page and install the frag page. */
		struct page *old_page = bv[i].bv_page;
		bv[i].bv_page = fp;
		put_page(old_page);

		/* Track fp so end_io can release both refs. */
		if (likely(priv->nr_frag_pages < priv->max_frag_pages))
			priv->frag_pages[priv->nr_frag_pages++] = fp;

		cur_off += PAGE_SIZE;
	}

	ZC_LOG("cached zc: bio=%px swapped %d pages\n", bio, nr_pages);
	return 0;

error:
	zc_cursor_invalidate(queue);
	return -1;
}

static __always_inline void zc_cursor_reset(struct nvme_tcp_queue *q,
					    struct sk_buff *root)
{
	struct zc_skb_cursor *c = &q->zc_cur;

	c->root = root;
	c->skb  = root;
	c->fskb = NULL;

	c->base = 0;
	c->pos  = skb_headlen(root);  /* linear 끝 */
	c->frag = 0;
}

static __always_inline bool zc_cursor_next_skb(struct zc_skb_cursor *c)
{
	struct sk_buff *next;

	if (!c->fskb) {
		next = skb_shinfo(c->root)->frag_list;
		if (!next)
			return false;

		/* nested frag_list면 여기선 fastpath 포기(원하면 slowpath로) */
		if (unlikely(skb_shinfo(next)->frag_list))
			return false;

		/* root의 frags 끝(pos)이 frag_list의 시작 base */
		c->base = c->pos;
		c->skb  = next;
		c->fskb = next;
	} else {
		next = c->fskb->next;
		if (!next)
			return false;

		if (unlikely(skb_shinfo(next)->frag_list))
			return false;

		/* 재귀 코드의 pos += fskb->len 과 동일한 의미 */
		c->base += c->fskb->len;
		c->skb  = next;
		c->fskb = next;
	}

	c->pos  = c->base + skb_headlen(c->skb);
	c->frag = 0;
	return true;
}


/* copy fallback 등으로 “커서 신뢰 불가”가 되면 무조건 invalidate */
static __always_inline void zc_cursor_invalidate(struct nvme_tcp_queue *q)
{
	q->zc_cur.root = NULL;
}

/* return 0 on found, else -ENOENT */
static int zc_find_next_4k_stateful(struct nvme_tcp_queue *q,
				   struct sk_buff *root,
				   unsigned int cur_off,
				   struct sk_buff **owner,
				   int *frag_idx,
				   unsigned int *page_off)
{
	struct zc_skb_cursor *c = &q->zc_cur;

	/* 새 skb면 커서 reset */
	if (unlikely(c->root != root))
		zc_cursor_reset(q, root);

	/*
	 * caller가 offset을 “뒤로” 되돌려서 요청하는 경우(재시도/에러 경로 등),
	 * 이미 커서가 앞으로 전진해 버렸을 수 있으니 reset.
	 * (정상 경로면 offset은 단조 증가)
	 */
	if (unlikely(cur_off < c->base || cur_off < c->pos))
		zc_cursor_reset(q, root);

	for (;;) {
		struct skb_shared_info *si = skb_shinfo(c->skb);
		unsigned int head_end = c->base + skb_headlen(c->skb);

		/* linear 안이면 linear 끝으로 */
		if (cur_off < head_end)
			cur_off = head_end;

		/* frags[] 스캔: 커서 위치부터 앞으로만 */
		while (c->frag < si->nr_frags) {
			skb_frag_t *f = &si->frags[c->frag];
			unsigned int start = c->pos;
			unsigned int end   = start + skb_frag_size(f);

			if (cur_off < end) {
				/* 경계 정확히 일치 + full 4K page frag면 성공 */
				if (cur_off == start && likely(zc_is_full_4k_page_frag(f))) {
					*owner   = c->skb;
					*frag_idx = c->frag;
					*page_off = start;

					/* 다음 호출을 위해 커서 advance */
					c->pos = end;
					c->frag++;
					return 0;
				}

				/* 아니면 이 frag는 통째로 skip */
				cur_off = end;
			}

			c->pos = end;
			c->frag++;
		}

		/* 이 skb에서 못 찾았으면 frag_list의 다음 skb로 */
		if (!zc_cursor_next_skb(c))
			return -ENOENT;
	}
}

static inline void zc_unwind_pages(struct page **pages, int nr)
{
    for (int i = 0; i < nr; i++) {
        struct page *p = pages[i];
        if (!p) continue;
        put_page(p);
        page_pool_unref_page(p, 1);
        pages[i] = NULL;
    }
}


static inline int do_zerocopy(struct nvme_tcp_queue *queue, struct sk_buff *skb, struct nvme_tcp_request *req,
                              int recv_len, unsigned int offset)
{
    struct my_ctx *ctx;
    struct my_bio_private *priv;
    size_t need = recv_len;

	/* main change: new_pages is passed as an argument*/
	struct page *new_pages[ZC_MAX_STAGE_PAGES];
	int chunk_cnt = 0;
    size_t chunk_base = 0;

    if (unlikely(!req->curr_bio)) {
        pr_info("req->curr_bio is null\n");
        return -1;
    }

    priv = req->curr_bio->bi_private;
    if (unlikely(!priv || priv->magic != MY_BIO_PRIVATE_MAGIC)) {
        pr_info("priv is null or priv->magic is not MY_BIO_PRIVATE_MAGIC\n");
        return -1;
    }

    ctx = priv->ctx;
    if (unlikely(!ctx)) {
        pr_info("ctx is null\n");
        return -1;
    }

    /* 4K 미만은 여기서 zc 못함: caller가 copy 하도록 */
    if (recv_len < PAGE_SIZE)
        return recv_len;

    /* iov_iter_count is the amount of data bytes left to copy */
    size_t consumed      = ctx->total_bytes - iov_iter_count(&req->iter);
    size_t page_idx = consumed >> PAGE_SHIFT;
	unsigned int cur_off = offset;

	chunk_base = page_idx;
//	trace_printk("**** do_zerocopy: consumed: %zu , total_bytes: %zu, page_idx: %zu, chunk_base: %zu\n", consumed, ctx->total_bytes, page_idx, chunk_base);
	if ((consumed & (PAGE_SIZE - 1)) != 0) {
   		trace_printk("ZC forbid: consumed not aligned: %zu\n", consumed);
	 //return -1;
	}


    /*
     * 기존 로직은 remaining_bytes/start_frag_page_index로 이어붙였는데,
     * frag_list까지 고려하면 “frag_index 재개”가 의미가 없어짐.
     * 여기서는 partial 상태면 그냥 fallback 권장.
     */
    if (ctx->remaining_bytes > 0) {
        pr_info("remaining_bytes: %ld -> fallback\n", ctx->remaining_bytes);
        return -1;
    }

    while (need >= PAGE_SIZE) {
        unsigned long uaddr = ctx->user_addr[page_idx];

        if (unlikely(!uaddr || !access_ok((void __user*)uaddr, PAGE_SIZE))) {
            pr_info(" [user address] %px is not valid\n", (void __user*)uaddr);
            goto error;
        }
		if (unlikely(uaddr & (PAGE_SIZE-1))) {
			trace_printk("ZC BAD: uaddr not aligned: uaddr=%lx\n", uaddr);
		}

        /* (중요) cur_off에서 '정확히 시작하는' 4K page frag만 remap */
        struct sk_buff *owner = NULL;
        int frag_index = -1;
		unsigned int page_off = 0;
		if (zc_find_next_4k_stateful(queue, skb, cur_off, &owner, &frag_index, &page_off))
			goto error;
		if (unlikely(page_off != cur_off))
			goto error;

        skb_frag_t *frag = &skb_shinfo(owner)->frags[frag_index];
        /* 이중 체크 */
        if (unlikely(skb_frag_size(frag) != PAGE_SIZE || skb_frag_off(frag) != 0)) {
            pr_info("found frag not remappable? size=%u off=%u\n",
                    skb_frag_size(frag), skb_frag_off(frag));
            goto error;
        }

        struct page *fp = skb_frag_page(frag);

        if (unlikely(!is_pp_page(fp))) {
            pr_info("not pp page: %px\n", fp);
            goto error;
        }

        if (!get_page_unless_zero(fp)) {
            pr_info("failed to get_page: %px\n", fp);
            goto error;
        }

        page_pool_ref_page(fp);
		/* main change: new_pages is passed as an argument*/
        //ctx->pages[base_page_idx + count] = fp;
		new_pages[chunk_cnt++] = fp;

        need -= PAGE_SIZE;
        page_idx++;
		cur_off += PAGE_SIZE;

		if (chunk_cnt == ZC_MAX_STAGE_PAGES){
			int rc = 0;
			if (nvme_tcp_rx_zc_batch_flush){
				rc = stage_remap_pages(req->curr_bio, chunk_base, new_pages, chunk_cnt);
			}
			else {
				rc = batch_remap_pages(req->curr_bio, chunk_base, new_pages, chunk_cnt);
			}

			if (rc != chunk_cnt){
				zc_unwind_pages(new_pages, chunk_cnt);
				pr_info("batch_remap_pages failed: rc:%d != chunk_cnt:%d\n", rc, chunk_cnt);
				return -1;
			}
			req->zc_staged_pages += chunk_cnt;
			chunk_cnt = 0;
			chunk_base = page_idx;
		}
    }


	if (chunk_cnt > 0){
		int rc = 0;
		if (nvme_tcp_rx_zc_batch_flush){
			rc = stage_remap_pages(req->curr_bio, chunk_base, new_pages, chunk_cnt);
		}
		else {
			rc = batch_remap_pages(req->curr_bio, chunk_base, new_pages, chunk_cnt);
		}
		if (rc != chunk_cnt){
			zc_unwind_pages(new_pages, chunk_cnt);
			pr_info("batch_remap_pages failed: rc:%d != chunk_cnt:%d\n", rc, chunk_cnt);
			return -1;
		}
		req->zc_staged_pages += chunk_cnt;
		chunk_cnt = 0;
	}

    /* 여기 오면 아직 flush 타이밍이 아니라는 뜻: 성공적으로 stage 됐다고 보고 0 */
    return 0;

error:
    pr_info("[ctx:%px] error - consumed:%zu total:%zu iter_left:%zu\n",
            ctx, consumed, ctx->total_bytes, iov_iter_count(&req->iter));
	zc_cursor_invalidate(queue);
	zc_unwind_pages(new_pages, chunk_cnt);

    return -1;
}

#define ZC_FLUSH_CHUNK 256
#define ZC_CTX_MAX     2048   /* batch 내 ctx 최대치 가드 */
struct mm_range {
    struct mm_struct *mm;
    unsigned long min, max;
};

static inline bool zc_ctx_flushable(struct my_ctx *ctx)
{
    return ctx && ctx->zc_staged &&
           ctx->mm &&
           (ctx->zc_flush_min < ctx->zc_flush_max);
}

static inline bool zc_ctx_seen(struct my_ctx **arr, u32 n, struct my_ctx *ctx)
{
    for (u32 i = 0; i < n; i++)
        if (arr[i] == ctx)
            return true;
    return false;
}

/* (1) rq의 bio 체인에서 ctx들을 모으고, (2) mm_range를 merge, (3) cleanup 대상 ctx list에 담기 */
static void zc_collect_ctx_and_ranges(struct request *rq,
                                     struct mm_range *mrs, u32 *mcnt)
{
    struct bio *bio;

    for (bio = rq->bio; bio; bio = bio->bi_next) {
        struct my_bio_private *priv;
        struct my_ctx *ctx;

        priv = bio->bi_private;
        if (!priv || priv->magic != MY_BIO_PRIVATE_MAGIC)
            continue;

        ctx = priv->ctx;
        if (!zc_ctx_flushable(ctx))
            continue;

        /* mm range merge */
        {
            struct mm_struct *mm = ctx->mm;
            bool merged = false;

            for (u32 j = 0; j < *mcnt; j++) {
                if (mrs[j].mm == mm) {
                    if (ctx->zc_flush_min < mrs[j].min) mrs[j].min = ctx->zc_flush_min;
                    if (ctx->zc_flush_max > mrs[j].max) mrs[j].max = ctx->zc_flush_max;
                    merged = true;
                    break;
                }
            }

            if (!merged && *mcnt < ZC_FLUSH_CHUNK) {
                mrs[*mcnt].mm  = mm;
                mrs[*mcnt].min = ctx->zc_flush_min;
                mrs[*mcnt].max = ctx->zc_flush_max;
                (*mcnt)++;
            }
        }
    }
}

static void nvme_tcp_zc_flush_workfn(struct work_struct *work)
{
    struct nvme_tcp_queue *q = container_of(work, struct nvme_tcp_queue, zc_flush_work);
    unsigned long flags;
    u32 depth = q->zc_queue_depth;

    u16 cids[ZC_FLUSH_CHUNK];
    u32 cid_cnt = 0;
	struct request *rqs[ZC_FLUSH_CHUNK];
	u32 rq_cnt = 0;
	
	if (unlikely(!depth || !q->zc_pend_cids))
	{
		pr_info("[nvme_tcp_zc_flush_workfn] depth or q->zc_pend_cids is null\n");
    	return;
	}

	// 1) pop chunk 
    spin_lock_irqsave(&q->zc_lock, flags);
    while (q->zc_cnt && cid_cnt < ARRAY_SIZE(cids)) {
        cids[cid_cnt++] = q->zc_pend_cids[q->zc_head];
        q->zc_head = (q->zc_head + 1) % depth;
        q->zc_cnt--;
    }


    spin_unlock_irqrestore(&q->zc_lock, flags);

	if (!cid_cnt) return;

	struct mm_range mrs[ZC_FLUSH_CHUNK];
    u32 mcnt = 0;

	u32 miss = 0;

    for (u32 i = 0; i < cid_cnt; i++) {
		struct request *rq = nvme_find_rq(nvme_tcp_tagset(q), cids[i]);
		if (!rq) {
			miss++;
			continue;
		}
		rqs[rq_cnt++] = rq;
		zc_collect_ctx_and_ranges(rq, mrs, &mcnt);
	}

    for (u32 i = 0; i < mcnt; i++) {
        flush_tlb_mm_range(mrs[i].mm, mrs[i].min, mrs[i].max, PAGE_SHIFT, false);
    }

	int done_pages = 0;
    for (u32 i = 0; i < rq_cnt; i++) {
        done_pages += zc_finish_cleanup_ctx(rqs[i]);
		struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rqs[i]);
		nvme_tcp_end_request(rqs[i], le16_to_cpu(req->status));
    }
    q->nr_cqe += rq_cnt;
    q->zc_pending_pages -= done_pages;

    spin_lock_irqsave(&q->zc_lock, flags);
    bool more = (q->zc_cnt != 0);
    spin_unlock_irqrestore(&q->zc_lock, flags);
    
	if (more){
		queue_work(q->zc_wq, &q->zc_flush_work);
	}
	if (unlikely(miss)){
        pr_info("[zc_flush] miss rq=%u (cid_cnt=%u rq_cnt=%u)\n", miss, cid_cnt, rq_cnt);
	}
}

static enum hrtimer_restart nvme_tcp_zc_idle_timer_fn(struct hrtimer *t)
{
    struct nvme_tcp_queue *q = container_of(t, struct nvme_tcp_queue, zc_idle_timer);
    u64 now = ktime_get_ns();
    u64 last = READ_ONCE(q->zc_last_defer_ns);
    u64 idle_ns = (u64)nvme_tcp_rx_zc_idle_us * 1000ULL;
    u64 delta = now - last;

	if (atomic_read(&q->zc_idle_armed) == 0)
  	  return HRTIMER_NORESTART;

	if (READ_ONCE(q->zc_shutting_down)){
		atomic_set(&q->zc_idle_armed, 0);
		return HRTIMER_NORESTART;
	}

    /* 아직 defer가 들어오고 있으면(=idle 아님) 타이머를 뒤로 미룸 */
    if (delta < idle_ns) {
        u64 remain = idle_ns - delta;
        hrtimer_forward_now(t, ns_to_ktime(remain));
        return HRTIMER_RESTART;
    }

	//pr_info("[nvme_tcp_zc_idle_timer_fn] flush (QID:%d) - q->zc_cnt: %d\n", nvme_tcp_queue_id(q), q->zc_cnt);
    /* idle 상태에서만 flush: 링에 뭐라도 남아있을 때만 */
    if (READ_ONCE(q->zc_cnt) && likely(q->zc_wq)){
		//queue_work_on(q->io_cpu, q->zc_wq, &q->zc_flush_work);
		queue_work(q->zc_wq, &q->zc_flush_work);
	}

	atomic_set(&q->zc_idle_armed, 0);
    return HRTIMER_NORESTART;
}


static void nvme_tcp_defer_complete(struct nvme_tcp_queue *q, u16 cid,
                                    struct request *rq) {
	unsigned long flags;
	u32 depth = q->zc_queue_depth;
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	u32 pages = READ_ONCE(req->zc_staged_pages);
	bool arm_idle = false;
							
	if (unlikely(READ_ONCE(q->zc_shutting_down)))
	    goto fallback_complete;

	if (unlikely(!depth || !q->zc_pend_cids)){
		goto fallback_complete;	
	}

	/* zc가 실제로 staged된 게 없으면 굳이 defer할 이유가 없음 */
	if (!pages)
		goto fallback_complete;

	spin_lock_irqsave(&q->zc_lock, flags);

	if (unlikely(q->zc_cnt == depth)) {
		/* FULL: drop 금지. flush 스케줄 후, 여기서는 즉시 complete로 fallback */
		spin_unlock_irqrestore(&q->zc_lock, flags);
	    atomic_set(&q->zc_idle_armed, 0);

		if (likely(q->zc_wq))
			//queue_work_on(q->io_cpu, q->zc_wq, &q->zc_flush_work);
			queue_work(q->zc_wq, &q->zc_flush_work);
		goto fallback_complete;
	}

	if (q->zc_cnt == 0)
		arm_idle = true;

	q->zc_pend_cids[q->zc_tail] = cid;

	q->zc_tail = (q->zc_tail + 1) % depth;
	q->zc_cnt++;

	q->zc_pending_pages += pages;
	bool trigger = (q->zc_pending_pages >= (u32)nvme_tcp_rx_zc_batch_pages);

	spin_unlock_irqrestore(&q->zc_lock, flags);

	if (trigger) {
        if (likely(q->zc_wq))
            //queue_work_on(q->io_cpu, q->zc_wq, &q->zc_flush_work);
			queue_work(q->zc_wq, &q->zc_flush_work);

		 atomic_set(&q->zc_idle_armed, 0);
//        if (atomic_xchg(&q->zc_idle_armed, 0) == 1)
 //          hrtimer_try_to_cancel(&q->zc_idle_timer);

        return;
    }
	if (!trigger)
    	WRITE_ONCE(q->zc_last_defer_ns, ktime_get_ns());

	if (arm_idle) {
        if (atomic_cmpxchg(&q->zc_idle_armed, 0, 1) == 0) {
            hrtimer_start(&q->zc_idle_timer,
                          ns_to_ktime((u64)nvme_tcp_rx_zc_idle_us * 1000ULL),
                          HRTIMER_MODE_REL_PINNED);
        }
    }
	return;

fallback_complete:
	/* defer 실패하면 반드시 즉시 complete로 빠져야 “안 끝나는 I/O”가 안 생김 */
	nvme_tcp_end_request(rq, le16_to_cpu(req->status));
	q->nr_cqe++;
}

static inline bool can_use_zerocopy(struct nvme_tcp_queue *queue, struct nvme_tcp_request *req, int recv_len){
	if (enable_zerocopy != 1)
		return false;
	struct my_bio_private *priv = req->curr_bio->bi_private;
	if (unlikely(!priv || priv->magic != MY_BIO_PRIVATE_MAGIC)){
		pr_info("[zerocopy] can_use_zerocopy FAIL: priv=NULL or priv->magic != MY_BIO_PRIVATE_MAGIC\n");
		return false;
	}
	struct my_ctx *ctx = priv->ctx;
	if (unlikely(!ctx || ctx->magic != MY_CTX_MAGIC || ctx->error != 0)) {
		pr_info("[can_use_zerocopy] ctx is null\n");
		return false;
	}

	if (unlikely( nvme_tcp_rx_zc_batch_flush && queue->zc_pend_cids == NULL))
	{
		pr_info("[can_use_zerocopy] queue->zc_pend_cids is null\n");
		return false;
	}

	if (queue->data_digest) {
		req->zc_policy = ZC_DISABLED;
		return false;
	}

	if (ctx->head_aligned == false) {
		pr_info("[can_use_zerocopy] ctx->head_aligned is false\n");
		return false;
	}

	if (req->zc_policy == ZC_UNDECIDED) {
		/*
		 * Design assumption for rx-zcopy:
		 * - NVMe/TCP data payload starts 4K-aligned (offset 0)
		 * - Remap is only possible when the destination user buffer
		 *   is also 4K-aligned at the start of this req.
		 */
		req->zc_policy = (req->iter.iov_offset == 0) ? ZC_ENABLED : ZC_DISABLED;
		//pr_info("[can_use_zerocopy] req->zc_policy : %d, req->iter.iov_offset : %d\n", req->zc_policy, req->iter.iov_offset);
	}

	if (req->zc_policy != ZC_ENABLED){
		pr_info("[can_use_zerocopy] req->zc_policy is not ZC_ENABLED\n");
		return false;
	}

	if (ctx->tail_aligned == false) {
		trace_printk("[can_use_zerocopy][ctx: %px] ctx->tail_aligned is false\n", ctx);
	}
	/* we only remap when the amount of data to be remapped is at least PAGE_SIZE */
	if (recv_len < PAGE_SIZE) {
		trace_printk("[can_use_zerocopy] recv_len < PAGE_SIZE\n");
		if (ctx->total_bytes < PAGE_SIZE) {
			trace_printk("[can_use_zerocopy] ctx->total_bytes < PAGE_SIZE: %zu\n", ctx->total_bytes);
			//req->zc_policy = ZC_DISABLED;
			return false;
		}
		//return false;
	}

	return true;
}

static int nvme_tcp_recv_data(struct nvme_tcp_queue *queue, struct sk_buff *skb,
			      unsigned int *offset, size_t *len)
{
	struct nvme_tcp_data_pdu *pdu = (void *)queue->pdu;
	struct request *rq =
		nvme_cid_to_rq(nvme_tcp_tagset(queue), pdu->command_id);
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	int zcopy_len = 0;
	//trace_printk("---------[0]nvme_tcp_recv_data: start - len: %zu\n", *len);
	while (true) {
		int recv_len, ret, zc_recv_len;
		// 이번 pdu에서 필요한 만큼 
		recv_len = min_t(size_t, *len, queue->data_remaining);
		if (!recv_len)
			break;

		if (!iov_iter_count(&req->iter)) {
			req->curr_bio = req->curr_bio->bi_next;

			/*
			 * If we don`t have any bios it means that controller
			 * sent more data than we requested, hence error
			 */
			if (!req->curr_bio) {
				dev_err(queue->ctrl->ctrl.device,
					"queue %d no space in request %#x",
					nvme_tcp_queue_id(queue), rq->tag);
				nvme_tcp_init_recv_ctx(queue);
				return -EIO;
			}
			nvme_tcp_init_iter(req, ITER_DEST);
		}
		/* we can read only from what is left in this bio */
		recv_len = min_t(size_t, recv_len,
				iov_iter_count(&req->iter));
		//trace_printk("[1] nvme_tcp_recv_data: recv_len: %d, iov_iter_count: %zu, queue->data_remaining: %zu\n", recv_len, iov_iter_count(&req->iter), queue->data_remaining);
		// set recv_len to PAGE_SIZE aligned
		zc_recv_len = recv_len & ~(PAGE_SIZE - 1);
		//trace_printk("[2]nvme_tcp_recv_data: zc_recv_len: %d\n", zc_recv_len);
	
		if (queue->data_digest){
			ret = skb_copy_and_hash_datagram_iter(skb, *offset,
				&req->iter, recv_len, queue->rcv_hash);
		}
		else if (!can_use_zerocopy(queue, req, recv_len)){
			//trace_printk("[3] [nvme_tcp_recv_data] can_use_zerocopy, recv_len: %d\n", recv_len);
			/* Try cached (buffered) zerocopy before falling back to copy. */
			if (zc_recv_len > 0 &&
			    can_use_zerocopy_cached(queue, req, recv_len)) {
				recv_len = zc_recv_len;
				int rc = do_zerocopy_cached(queue, skb, req,
							    recv_len, *offset);
				if (rc == 0) {
					iov_iter_advance(&req->iter, recv_len);
					ret = 0;
				} else {
					ZC_LOG_RL("cached zc fallback, recv_len=%d\n",
						  recv_len);
					ret = skb_copy_datagram_iter(skb, *offset,
							&req->iter, recv_len);
				}
			} else {
				ret = skb_copy_datagram_iter(skb, *offset,
						&req->iter, recv_len);
			}
		}
		else if (zc_recv_len == 0)
		{
			//trace_printk("[4] [nvme_tcp_recv_data] zc_recv_len == 0, recv_len: %d\n", recv_len);
			// zc_recv_len == 0 means that the data is not aligned to PAGE_SIZE
			// so we need to copy the data to req->iter
			ret = skb_copy_datagram_iter(skb, *offset,
					&req->iter, recv_len);
		}
		else {
			// set recv_len to PAGE_SIZE aligned
			recv_len = zc_recv_len;
			zcopy_len = do_zerocopy(queue, skb, req, recv_len, *offset);
			//trace_printk("==> [nvme_tcp_recv_data] zc done - recv_len: %d, zcopy_len: %d\n", recv_len, zcopy_len);
			// remap/queueing done; completion is deferred (do not copy)
			if (zcopy_len ==0) 
			{
				//trace_printk("[4] [nvme_tcp_recv_data] zcopy_len == 0\n");
				iov_iter_advance(&req->iter, recv_len);
				ret = 0;
			}
			else if (zcopy_len == -1){
				pr_info("[Fallback to skb_copy_datagram_iter], recv_len: %d\n", recv_len);
				ret = skb_copy_datagram_iter(skb, *offset,
						&req->iter, recv_len);
			}

			// partial copy required due tail unaligned or error occured (partial remap)
			// zcopy_len > 0 is amount of data this need to be copied to req->iter
			else if (zcopy_len > 0)
			{
				trace_printk("[nvme_tcp_recv_data] recv_len: %d, zcopy_len: %d\n", recv_len, zcopy_len);
				if (recv_len - zcopy_len > 0){ // already mapped to req->iter = recv_len - zcopy_len
					iov_iter_advance(&req->iter, recv_len - zcopy_len);
				}
				ret = skb_copy_datagram_iter(skb, *offset + (recv_len - zcopy_len), &req->iter, zcopy_len);
			}

		}
		if (ret) {
			dev_err(queue->ctrl->ctrl.device,
				"queue %d failed to copy request %#x data",
				nvme_tcp_queue_id(queue), rq->tag);
			return ret;
		}

		*len -= recv_len;
		*offset += recv_len;
		queue->data_remaining -= recv_len;
	}

	if (!queue->data_remaining) {
		if (queue->data_digest) {
			nvme_tcp_ddgst_final(queue->rcv_hash, &queue->exp_ddgst);
			queue->ddgst_remaining = NVME_TCP_DIGEST_LENGTH;
		} else {
			if (pdu->hdr.flags & NVME_TCP_F_DATA_SUCCESS) {
				if (!nvme_tcp_rx_zc_batch_flush || !enable_zerocopy /*|| req->zc_policy != ZC_ENABLED*/) {
					//trace_printk("==> [nvme_tcp_recv_data] end_request - req->status: %d\n", le16_to_cpu(req->status));

					nvme_tcp_end_request(rq, le16_to_cpu(req->status));
					queue->nr_cqe++;
				} else {
					//trace_printk("==> [nvme_tcp_recv_data] defer_complete - req->status: %d\n", le16_to_cpu(req->status));

					nvme_tcp_defer_complete(queue, pdu->command_id, rq);
				}
			}
			nvme_tcp_init_recv_ctx(queue);
		}
	}
	return 0;
}

static int nvme_tcp_recv_ddgst(struct nvme_tcp_queue *queue,
		struct sk_buff *skb, unsigned int *offset, size_t *len)
{
	struct nvme_tcp_data_pdu *pdu = (void *)queue->pdu;
	char *ddgst = (char *)&queue->recv_ddgst;
	size_t recv_len = min_t(size_t, *len, queue->ddgst_remaining);
	off_t off = NVME_TCP_DIGEST_LENGTH - queue->ddgst_remaining;
	int ret;

	ret = skb_copy_bits(skb, *offset, &ddgst[off], recv_len);
	if (unlikely(ret))
		return ret;

	queue->ddgst_remaining -= recv_len;
	*offset += recv_len;
	*len -= recv_len;
	if (queue->ddgst_remaining)
		return 0;

	if (queue->recv_ddgst != queue->exp_ddgst) {
		struct request *rq = nvme_cid_to_rq(nvme_tcp_tagset(queue),
					pdu->command_id);
		struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);

		req->status = cpu_to_le16(NVME_SC_DATA_XFER_ERROR);

		dev_err(queue->ctrl->ctrl.device,
			"data digest error: recv %#x expected %#x\n",
			le32_to_cpu(queue->recv_ddgst),
			le32_to_cpu(queue->exp_ddgst));
	}

	if (pdu->hdr.flags & NVME_TCP_F_DATA_SUCCESS) {
		struct request *rq = nvme_cid_to_rq(nvme_tcp_tagset(queue),
					pdu->command_id);
		struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);

		nvme_tcp_end_request(rq, le16_to_cpu(req->status));
		queue->nr_cqe++;
	}

	nvme_tcp_init_recv_ctx(queue);
	return 0;
}

static int nvme_tcp_recv_skb(read_descriptor_t *desc, struct sk_buff *skb,
			     unsigned int offset, size_t len)
{
	struct nvme_tcp_queue *queue = desc->arg.data;
	size_t consumed = len;
	int result;

	if (unlikely(!queue->rd_enabled))
		return -EFAULT;
	
	while (len) {
		switch (nvme_tcp_recv_state(queue)) {
		case NVME_TCP_RECV_PDU:
			result = nvme_tcp_recv_pdu(queue, skb, &offset, &len);
			break;
		case NVME_TCP_RECV_DATA:
			result = nvme_tcp_recv_data(queue, skb, &offset, &len);
			break;
		case NVME_TCP_RECV_DDGST:
			result = nvme_tcp_recv_ddgst(queue, skb, &offset, &len);
			break;
		default:
			result = -EFAULT;
		}
		if (result) {
			dev_err(queue->ctrl->ctrl.device,
				"receive failed:  %d\n", result);
			queue->rd_enabled = false;
			nvme_tcp_error_recovery(&queue->ctrl->ctrl);
			return result;
		}
	}

	return consumed;
}

static void nvme_tcp_data_ready(struct sock *sk)
{
	struct nvme_tcp_queue *queue;

	trace_sk_data_ready(sk);

	read_lock_bh(&sk->sk_callback_lock);
	queue = sk->sk_user_data;
	if (likely(queue && queue->rd_enabled) &&
	    !test_bit(NVME_TCP_Q_POLLING, &queue->flags))
		queue_work_on(queue->io_cpu, nvme_tcp_wq, &queue->io_work);
	read_unlock_bh(&sk->sk_callback_lock);
}

static void nvme_tcp_write_space(struct sock *sk)
{
	struct nvme_tcp_queue *queue;

	read_lock_bh(&sk->sk_callback_lock);
	queue = sk->sk_user_data;
	if (likely(queue && sk_stream_is_writeable(sk))) {
		clear_bit(SOCK_NOSPACE, &sk->sk_socket->flags);
		queue_work_on(queue->io_cpu, nvme_tcp_wq, &queue->io_work);
	}
	read_unlock_bh(&sk->sk_callback_lock);
}

static void nvme_tcp_state_change(struct sock *sk)
{
	struct nvme_tcp_queue *queue;

	read_lock_bh(&sk->sk_callback_lock);
	queue = sk->sk_user_data;
	if (!queue)
		goto done;

	switch (sk->sk_state) {
	case TCP_CLOSE:
	case TCP_CLOSE_WAIT:
	case TCP_LAST_ACK:
	case TCP_FIN_WAIT1:
	case TCP_FIN_WAIT2:
		nvme_tcp_error_recovery(&queue->ctrl->ctrl);
		break;
	default:
		dev_info(queue->ctrl->ctrl.device,
			"queue %d socket state %d\n",
			nvme_tcp_queue_id(queue), sk->sk_state);
	}

	queue->state_change(sk);
done:
	read_unlock_bh(&sk->sk_callback_lock);
}

static inline void nvme_tcp_done_send_req(struct nvme_tcp_queue *queue)
{
	queue->request = NULL;
}

static void nvme_tcp_fail_request(struct nvme_tcp_request *req)
{
	if (nvme_tcp_async_req(req)) {
		union nvme_result res = {};

		nvme_complete_async_event(&req->queue->ctrl->ctrl,
				cpu_to_le16(NVME_SC_HOST_PATH_ERROR), &res);
	} else {
		nvme_tcp_end_request(blk_mq_rq_from_pdu(req),
				NVME_SC_HOST_PATH_ERROR);
	}
}

static int nvme_tcp_try_send_data(struct nvme_tcp_request *req)
{
	struct nvme_tcp_queue *queue = req->queue;
	int req_data_len = req->data_len;
	u32 h2cdata_left = req->h2cdata_left;

	while (true) {
		struct bio_vec bvec;
		struct msghdr msg = {
			.msg_flags = MSG_DONTWAIT | MSG_SPLICE_PAGES,
		};
		struct page *page = nvme_tcp_req_cur_page(req);
		size_t offset = nvme_tcp_req_cur_offset(req);
		size_t len = nvme_tcp_req_cur_length(req);
		bool last = nvme_tcp_pdu_last_send(req, len);
		int req_data_sent = req->data_sent;
		int ret;

		if (last && !queue->data_digest && !nvme_tcp_queue_more(queue))
			msg.msg_flags |= MSG_EOR;
		else
			msg.msg_flags |= MSG_MORE;

		if (!sendpage_ok(page))
			msg.msg_flags &= ~MSG_SPLICE_PAGES;

		bvec_set_page(&bvec, page, len, offset);
		iov_iter_bvec(&msg.msg_iter, ITER_SOURCE, &bvec, 1, len);
		ret = sock_sendmsg(queue->sock, &msg);
		if (ret <= 0)
			return ret;

		if (queue->data_digest)
			nvme_tcp_ddgst_update(queue->snd_hash, page,
					offset, ret);

		/*
		 * update the request iterator except for the last payload send
		 * in the request where we don't want to modify it as we may
		 * compete with the RX path completing the request.
		 */
		if (req_data_sent + ret < req_data_len)
			nvme_tcp_advance_req(req, ret);

		/* fully successful last send in current PDU */
		if (last && ret == len) {
			if (queue->data_digest) {
				nvme_tcp_ddgst_final(queue->snd_hash,
					&req->ddgst);
				req->state = NVME_TCP_SEND_DDGST;
				req->offset = 0;
			} else {
				if (h2cdata_left)
					nvme_tcp_setup_h2c_data_pdu(req);
				else
					nvme_tcp_done_send_req(queue);
			}
			return 1;
		}
	}
	return -EAGAIN;
}

static int nvme_tcp_try_send_cmd_pdu(struct nvme_tcp_request *req)
{
	struct nvme_tcp_queue *queue = req->queue;
	struct nvme_tcp_cmd_pdu *pdu = nvme_tcp_req_cmd_pdu(req);
	struct bio_vec bvec;
	struct msghdr msg = { .msg_flags = MSG_DONTWAIT | MSG_SPLICE_PAGES, };
	bool inline_data = nvme_tcp_has_inline_data(req);
	u8 hdgst = nvme_tcp_hdgst_len(queue);
	int len = sizeof(*pdu) + hdgst - req->offset;
	int ret;

	if (inline_data || nvme_tcp_queue_more(queue))
		msg.msg_flags |= MSG_MORE;
	else
		msg.msg_flags |= MSG_EOR;

	if (queue->hdr_digest && !req->offset)
		nvme_tcp_hdgst(queue->snd_hash, pdu, sizeof(*pdu));

	bvec_set_virt(&bvec, (void *)pdu + req->offset, len);
	iov_iter_bvec(&msg.msg_iter, ITER_SOURCE, &bvec, 1, len);
	ret = sock_sendmsg(queue->sock, &msg);
	if (unlikely(ret <= 0))
		return ret;

	len -= ret;
	if (!len) {
		if (inline_data) {
			req->state = NVME_TCP_SEND_DATA;
			if (queue->data_digest)
				crypto_ahash_init(queue->snd_hash);
		} else {
			nvme_tcp_done_send_req(queue);
		}
		return 1;
	}
	req->offset += ret;

	return -EAGAIN;
}

static int nvme_tcp_try_send_data_pdu(struct nvme_tcp_request *req)
{
	struct nvme_tcp_queue *queue = req->queue;
	struct nvme_tcp_data_pdu *pdu = nvme_tcp_req_data_pdu(req);
	struct bio_vec bvec;
	struct msghdr msg = { .msg_flags = MSG_DONTWAIT | MSG_MORE, };
	u8 hdgst = nvme_tcp_hdgst_len(queue);
	int len = sizeof(*pdu) - req->offset + hdgst;
	int ret;

	if (queue->hdr_digest && !req->offset)
		nvme_tcp_hdgst(queue->snd_hash, pdu, sizeof(*pdu));

	if (!req->h2cdata_left)
		msg.msg_flags |= MSG_SPLICE_PAGES;

	bvec_set_virt(&bvec, (void *)pdu + req->offset, len);
	iov_iter_bvec(&msg.msg_iter, ITER_SOURCE, &bvec, 1, len);
	ret = sock_sendmsg(queue->sock, &msg);
	if (unlikely(ret <= 0))
		return ret;

	len -= ret;
	if (!len) {
		req->state = NVME_TCP_SEND_DATA;
		if (queue->data_digest)
			crypto_ahash_init(queue->snd_hash);
		return 1;
	}
	req->offset += ret;

	return -EAGAIN;
}

static int nvme_tcp_try_send_ddgst(struct nvme_tcp_request *req)
{
	struct nvme_tcp_queue *queue = req->queue;
	size_t offset = req->offset;
	u32 h2cdata_left = req->h2cdata_left;
	int ret;
	struct msghdr msg = { .msg_flags = MSG_DONTWAIT };
	struct kvec iov = {
		.iov_base = (u8 *)&req->ddgst + req->offset,
		.iov_len = NVME_TCP_DIGEST_LENGTH - req->offset
	};

	if (nvme_tcp_queue_more(queue))
		msg.msg_flags |= MSG_MORE;
	else
		msg.msg_flags |= MSG_EOR;

	ret = kernel_sendmsg(queue->sock, &msg, &iov, 1, iov.iov_len);
	if (unlikely(ret <= 0))
		return ret;

	if (offset + ret == NVME_TCP_DIGEST_LENGTH) {
		if (h2cdata_left)
			nvme_tcp_setup_h2c_data_pdu(req);
		else
			nvme_tcp_done_send_req(queue);
		return 1;
	}

	req->offset += ret;
	return -EAGAIN;
}

static int nvme_tcp_try_send(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_request *req;
	unsigned int noreclaim_flag;
	int ret = 1;

	if (!queue->request) {
		queue->request = nvme_tcp_fetch_request(queue);
		if (!queue->request)
			return 0;
	}
	req = queue->request;

	noreclaim_flag = memalloc_noreclaim_save();
	if (req->state == NVME_TCP_SEND_CMD_PDU) {
		ret = nvme_tcp_try_send_cmd_pdu(req);
		if (ret <= 0)
			goto done;
		if (!nvme_tcp_has_inline_data(req))
			goto out;
	}

	if (req->state == NVME_TCP_SEND_H2C_PDU) {
		ret = nvme_tcp_try_send_data_pdu(req);
		if (ret <= 0)
			goto done;
	}

	if (req->state == NVME_TCP_SEND_DATA) {
		ret = nvme_tcp_try_send_data(req);
		if (ret <= 0)
			goto done;
	}

	if (req->state == NVME_TCP_SEND_DDGST)
		ret = nvme_tcp_try_send_ddgst(req);
done:
	if (ret == -EAGAIN) {
		ret = 0;
	} else if (ret < 0) {
		dev_err(queue->ctrl->ctrl.device,
			"failed to send request %d\n", ret);
		nvme_tcp_fail_request(queue->request);
		nvme_tcp_done_send_req(queue);
	}
out:
	memalloc_noreclaim_restore(noreclaim_flag);
	return ret;
}

static int nvme_tcp_try_recv(struct nvme_tcp_queue *queue)
{
	struct socket *sock = queue->sock;
	struct sock *sk = sock->sk;
	read_descriptor_t rd_desc;
	int consumed;

	rd_desc.arg.data = queue;
	rd_desc.count = 1;
	lock_sock(sk);
	queue->nr_cqe = 0;
	consumed = sock->ops->read_sock(sk, &rd_desc, nvme_tcp_recv_skb);
	release_sock(sk);
	return consumed;
}

static void nvme_tcp_io_work(struct work_struct *w)
{
	struct nvme_tcp_queue *queue =
		container_of(w, struct nvme_tcp_queue, io_work);
	unsigned long deadline = jiffies + msecs_to_jiffies(1);

	do {
		bool pending = false;
		int result;

		if (mutex_trylock(&queue->send_mutex)) {
			result = nvme_tcp_try_send(queue);
			mutex_unlock(&queue->send_mutex);
			if (result > 0)
				pending = true;
			else if (unlikely(result < 0))
				break;
		}

		result = nvme_tcp_try_recv(queue);
		if (result > 0)
			pending = true;
		else if (unlikely(result < 0))
			return;

		if (!pending || !queue->rd_enabled)
			return;

	} while (!time_after(jiffies, deadline)); /* quota is exhausted */

	queue_work_on(queue->io_cpu, nvme_tcp_wq, &queue->io_work);
}

static void nvme_tcp_free_crypto(struct nvme_tcp_queue *queue)
{
	struct crypto_ahash *tfm = crypto_ahash_reqtfm(queue->rcv_hash);

	ahash_request_free(queue->rcv_hash);
	ahash_request_free(queue->snd_hash);
	crypto_free_ahash(tfm);
}

static int nvme_tcp_alloc_crypto(struct nvme_tcp_queue *queue)
{
	struct crypto_ahash *tfm;

	tfm = crypto_alloc_ahash("crc32c", 0, CRYPTO_ALG_ASYNC);
	if (IS_ERR(tfm))
		return PTR_ERR(tfm);

	queue->snd_hash = ahash_request_alloc(tfm, GFP_KERNEL);
	if (!queue->snd_hash)
		goto free_tfm;
	ahash_request_set_callback(queue->snd_hash, 0, NULL, NULL);

	queue->rcv_hash = ahash_request_alloc(tfm, GFP_KERNEL);
	if (!queue->rcv_hash)
		goto free_snd_hash;
	ahash_request_set_callback(queue->rcv_hash, 0, NULL, NULL);

	return 0;
free_snd_hash:
	ahash_request_free(queue->snd_hash);
free_tfm:
	crypto_free_ahash(tfm);
	return -ENOMEM;
}

static void nvme_tcp_free_async_req(struct nvme_tcp_ctrl *ctrl)
{
	struct nvme_tcp_request *async = &ctrl->async_req;

	page_frag_free(async->pdu);
}

static int nvme_tcp_alloc_async_req(struct nvme_tcp_ctrl *ctrl)
{
	struct nvme_tcp_queue *queue = &ctrl->queues[0];
	struct nvme_tcp_request *async = &ctrl->async_req;
	u8 hdgst = nvme_tcp_hdgst_len(queue);

	async->pdu = page_frag_alloc(&queue->pf_cache,
		sizeof(struct nvme_tcp_cmd_pdu) + hdgst,
		GFP_KERNEL | __GFP_ZERO);
	if (!async->pdu)
		return -ENOMEM;

	async->queue = &ctrl->queues[0];
	return 0;
}

static void nvme_tcp_free_queue(struct nvme_ctrl *nctrl, int qid)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(nctrl);
	struct nvme_tcp_queue *queue = &ctrl->queues[qid];
	unsigned int noreclaim_flag;

	if (!test_and_clear_bit(NVME_TCP_Q_ALLOCATED, &queue->flags))
		return;

	if (queue->hdr_digest || queue->data_digest)
		nvme_tcp_free_crypto(queue);

	page_frag_cache_drain(&queue->pf_cache);

	noreclaim_flag = memalloc_noreclaim_save();
	/* ->sock will be released by fput() */
	fput(queue->sock->file);
	queue->sock = NULL;
	memalloc_noreclaim_restore(noreclaim_flag);

	kfree(queue->pdu);
	
	mutex_destroy(&queue->send_mutex);
	mutex_destroy(&queue->queue_lock);
}

static int nvme_tcp_init_connection(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_icreq_pdu *icreq;
	struct nvme_tcp_icresp_pdu *icresp;
	char cbuf[CMSG_LEN(sizeof(char))] = {};
	u8 ctype;
	struct msghdr msg = {};
	struct kvec iov;
	bool ctrl_hdgst, ctrl_ddgst;
	u32 maxh2cdata;
	int ret;

	icreq = kzalloc(sizeof(*icreq), GFP_KERNEL);
	if (!icreq)
		return -ENOMEM;

	icresp = kzalloc(sizeof(*icresp), GFP_KERNEL);
	if (!icresp) {
		ret = -ENOMEM;
		goto free_icreq;
	}

	icreq->hdr.type = nvme_tcp_icreq;
	icreq->hdr.hlen = sizeof(*icreq);
	icreq->hdr.pdo = 0;
	icreq->hdr.plen = cpu_to_le32(icreq->hdr.hlen);
	icreq->pfv = cpu_to_le16(NVME_TCP_PFV_1_0);
	icreq->maxr2t = 0; /* single inflight r2t supported */
	icreq->hpda = 0; /* no alignment constraint */
	if (queue->hdr_digest)
		icreq->digest |= NVME_TCP_HDR_DIGEST_ENABLE;
	if (queue->data_digest)
		icreq->digest |= NVME_TCP_DATA_DIGEST_ENABLE;

	iov.iov_base = icreq;
	iov.iov_len = sizeof(*icreq);
	ret = kernel_sendmsg(queue->sock, &msg, &iov, 1, iov.iov_len);
	if (ret < 0) {
		pr_warn("queue %d: failed to send icreq, error %d\n",
			nvme_tcp_queue_id(queue), ret);
		goto free_icresp;
	}

	memset(&msg, 0, sizeof(msg));
	iov.iov_base = icresp;
	iov.iov_len = sizeof(*icresp);
	if (nvme_tcp_tls(&queue->ctrl->ctrl)) {
		msg.msg_control = cbuf;
		msg.msg_controllen = sizeof(cbuf);
	}
	ret = kernel_recvmsg(queue->sock, &msg, &iov, 1,
			iov.iov_len, msg.msg_flags);
	if (ret < 0) {
		pr_warn("queue %d: failed to receive icresp, error %d\n",
			nvme_tcp_queue_id(queue), ret);
		goto free_icresp;
	}
	ret = -ENOTCONN;
	if (nvme_tcp_tls(&queue->ctrl->ctrl)) {
		ctype = tls_get_record_type(queue->sock->sk,
					    (struct cmsghdr *)cbuf);
		if (ctype != TLS_RECORD_TYPE_DATA) {
			pr_err("queue %d: unhandled TLS record %d\n",
			       nvme_tcp_queue_id(queue), ctype);
			goto free_icresp;
		}
	}
	ret = -EINVAL;
	if (icresp->hdr.type != nvme_tcp_icresp) {
		pr_err("queue %d: bad type returned %d\n",
			nvme_tcp_queue_id(queue), icresp->hdr.type);
		goto free_icresp;
	}

	if (le32_to_cpu(icresp->hdr.plen) != sizeof(*icresp)) {
		pr_err("queue %d: bad pdu length returned %d\n",
			nvme_tcp_queue_id(queue), icresp->hdr.plen);
		goto free_icresp;
	}

	if (icresp->pfv != NVME_TCP_PFV_1_0) {
		pr_err("queue %d: bad pfv returned %d\n",
			nvme_tcp_queue_id(queue), icresp->pfv);
		goto free_icresp;
	}

	ctrl_ddgst = !!(icresp->digest & NVME_TCP_DATA_DIGEST_ENABLE);
	if ((queue->data_digest && !ctrl_ddgst) ||
	    (!queue->data_digest && ctrl_ddgst)) {
		pr_err("queue %d: data digest mismatch host: %s ctrl: %s\n",
			nvme_tcp_queue_id(queue),
			queue->data_digest ? "enabled" : "disabled",
			ctrl_ddgst ? "enabled" : "disabled");
		goto free_icresp;
	}

	ctrl_hdgst = !!(icresp->digest & NVME_TCP_HDR_DIGEST_ENABLE);
	if ((queue->hdr_digest && !ctrl_hdgst) ||
	    (!queue->hdr_digest && ctrl_hdgst)) {
		pr_err("queue %d: header digest mismatch host: %s ctrl: %s\n",
			nvme_tcp_queue_id(queue),
			queue->hdr_digest ? "enabled" : "disabled",
			ctrl_hdgst ? "enabled" : "disabled");
		goto free_icresp;
	}

	if (icresp->cpda != 0) {
		pr_err("queue %d: unsupported cpda returned %d\n",
			nvme_tcp_queue_id(queue), icresp->cpda);
		goto free_icresp;
	}

	maxh2cdata = le32_to_cpu(icresp->maxdata);
	if ((maxh2cdata % 4) || (maxh2cdata < NVME_TCP_MIN_MAXH2CDATA)) {
		pr_err("queue %d: invalid maxh2cdata returned %u\n",
		       nvme_tcp_queue_id(queue), maxh2cdata);
		goto free_icresp;
	}
	queue->maxh2cdata = maxh2cdata;

	ret = 0;
free_icresp:
	kfree(icresp);
free_icreq:
	kfree(icreq);
	return ret;
}

static bool nvme_tcp_admin_queue(struct nvme_tcp_queue *queue)
{
	return nvme_tcp_queue_id(queue) == 0;
}

static bool nvme_tcp_default_queue(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_ctrl *ctrl = queue->ctrl;
	int qid = nvme_tcp_queue_id(queue);

	return !nvme_tcp_admin_queue(queue) &&
		qid < 1 + ctrl->io_queues[HCTX_TYPE_DEFAULT];
}

static bool nvme_tcp_read_queue(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_ctrl *ctrl = queue->ctrl;
	int qid = nvme_tcp_queue_id(queue);

	return !nvme_tcp_admin_queue(queue) &&
		!nvme_tcp_default_queue(queue) &&
		qid < 1 + ctrl->io_queues[HCTX_TYPE_DEFAULT] +
			  ctrl->io_queues[HCTX_TYPE_READ];
}

static bool nvme_tcp_poll_queue(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_ctrl *ctrl = queue->ctrl;
	int qid = nvme_tcp_queue_id(queue);

	return !nvme_tcp_admin_queue(queue) &&
		!nvme_tcp_default_queue(queue) &&
		!nvme_tcp_read_queue(queue) &&
		qid < 1 + ctrl->io_queues[HCTX_TYPE_DEFAULT] +
			  ctrl->io_queues[HCTX_TYPE_READ] +
			  ctrl->io_queues[HCTX_TYPE_POLL];
}

static void nvme_tcp_set_queue_io_cpu(struct nvme_tcp_queue *queue)
{
	struct nvme_tcp_ctrl *ctrl = queue->ctrl;
	int qid = nvme_tcp_queue_id(queue);
	int n = 0;

	if (nvme_tcp_default_queue(queue))
		n = qid - 1;
	else if (nvme_tcp_read_queue(queue))
		n = qid - ctrl->io_queues[HCTX_TYPE_DEFAULT] - 1;
	else if (nvme_tcp_poll_queue(queue))
		n = qid - ctrl->io_queues[HCTX_TYPE_DEFAULT] -
				ctrl->io_queues[HCTX_TYPE_READ] - 1;
	if (wq_unbound)
		queue->io_cpu = WORK_CPU_UNBOUND;
	else
		queue->io_cpu = cpumask_next_wrap(n - 1, cpu_online_mask, -1, false);
}

static void nvme_tcp_tls_done(void *data, int status, key_serial_t pskid)
{
	struct nvme_tcp_queue *queue = data;
	struct nvme_tcp_ctrl *ctrl = queue->ctrl;
	int qid = nvme_tcp_queue_id(queue);
	struct key *tls_key;

	dev_dbg(ctrl->ctrl.device, "queue %d: TLS handshake done, key %x, status %d\n",
		qid, pskid, status);

	if (status) {
		queue->tls_err = -status;
		goto out_complete;
	}

	tls_key = key_lookup(pskid);
	if (IS_ERR(tls_key)) {
		dev_warn(ctrl->ctrl.device, "queue %d: Invalid key %x\n",
			 qid, pskid);
		queue->tls_err = -ENOKEY;
	} else {
		ctrl->ctrl.tls_key = tls_key;
		queue->tls_err = 0;
	}

out_complete:
	complete(&queue->tls_complete);
}

static int nvme_tcp_start_tls(struct nvme_ctrl *nctrl,
			      struct nvme_tcp_queue *queue,
			      key_serial_t pskid)
{
	int qid = nvme_tcp_queue_id(queue);
	int ret;
	struct tls_handshake_args args;
	unsigned long tmo = tls_handshake_timeout * HZ;
	key_serial_t keyring = nvme_keyring_id();

	dev_dbg(nctrl->device, "queue %d: start TLS with key %x\n",
		qid, pskid);
	memset(&args, 0, sizeof(args));
	args.ta_sock = queue->sock;
	args.ta_done = nvme_tcp_tls_done;
	args.ta_data = queue;
	args.ta_my_peerids[0] = pskid;
	args.ta_num_peerids = 1;
	if (nctrl->opts->keyring)
		keyring = key_serial(nctrl->opts->keyring);
	args.ta_keyring = keyring;
	args.ta_timeout_ms = tls_handshake_timeout * 1000;
	queue->tls_err = -EOPNOTSUPP;
	init_completion(&queue->tls_complete);
	ret = tls_client_hello_psk(&args, GFP_KERNEL);
	if (ret) {
		dev_err(nctrl->device, "queue %d: failed to start TLS: %d\n",
			qid, ret);
		return ret;
	}
	ret = wait_for_completion_interruptible_timeout(&queue->tls_complete, tmo);
	if (ret <= 0) {
		if (ret == 0)
			ret = -ETIMEDOUT;

		dev_err(nctrl->device,
			"queue %d: TLS handshake failed, error %d\n",
			qid, ret);
		tls_handshake_cancel(queue->sock->sk);
	} else {
		dev_dbg(nctrl->device,
			"queue %d: TLS handshake complete, error %d\n",
			qid, queue->tls_err);
		ret = queue->tls_err;
	}
	return ret;
}

static int nvme_tcp_alloc_queue(struct nvme_ctrl *nctrl, int qid,
				key_serial_t pskid)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(nctrl);
	struct nvme_tcp_queue *queue = &ctrl->queues[qid];
	int ret, rcv_pdu_size;
	struct file *sock_file;

	mutex_init(&queue->queue_lock);
	queue->ctrl = ctrl;
	init_llist_head(&queue->req_list);
	INIT_LIST_HEAD(&queue->send_list);
	mutex_init(&queue->send_mutex);
	INIT_WORK(&queue->io_work, nvme_tcp_io_work);

	if (qid > 0)
		queue->cmnd_capsule_len = nctrl->ioccsz * 16;
	else
		queue->cmnd_capsule_len = sizeof(struct nvme_command) +
						NVME_TCP_ADMIN_CCSZ;

	ret = sock_create(ctrl->addr.ss_family, SOCK_STREAM,
			IPPROTO_TCP, &queue->sock);
	if (ret) {
		dev_err(nctrl->device,
			"failed to create socket: %d\n", ret);
		goto err_destroy_mutex;
	}

	sock_file = sock_alloc_file(queue->sock, O_CLOEXEC, NULL);
	if (IS_ERR(sock_file)) {
		ret = PTR_ERR(sock_file);
		goto err_destroy_mutex;
	}
	nvme_tcp_reclassify_socket(queue->sock);

	/* Single syn retry */
	tcp_sock_set_syncnt(queue->sock->sk, 1);

	/* Set TCP no delay */
	tcp_sock_set_nodelay(queue->sock->sk);

	/*
	 * Cleanup whatever is sitting in the TCP transmit queue on socket
	 * close. This is done to prevent stale data from being sent should
	 * the network connection be restored before TCP times out.
	 */
	sock_no_linger(queue->sock->sk);

	if (so_priority > 0)
		sock_set_priority(queue->sock->sk, so_priority);

	/* Set socket type of service */
	if (nctrl->opts->tos >= 0)
		ip_sock_set_tos(queue->sock->sk, nctrl->opts->tos);

	/* Set 10 seconds timeout for icresp recvmsg */
	queue->sock->sk->sk_rcvtimeo = 10 * HZ;

	queue->sock->sk->sk_allocation = GFP_ATOMIC;
	queue->sock->sk->sk_use_task_frag = false;
	nvme_tcp_set_queue_io_cpu(queue);
	queue->request = NULL;
	queue->data_remaining = 0;
	queue->ddgst_remaining = 0;
	queue->pdu_remaining = 0;
	queue->pdu_offset = 0;
	sk_set_memalloc(queue->sock->sk);

	if (nctrl->opts->mask & NVMF_OPT_HOST_TRADDR) {
		ret = kernel_bind(queue->sock, (struct sockaddr *)&ctrl->src_addr,
			sizeof(ctrl->src_addr));
		if (ret) {
			dev_err(nctrl->device,
				"failed to bind queue %d socket %d\n",
				qid, ret);
			goto err_sock;
		}
	}

	if (nctrl->opts->mask & NVMF_OPT_HOST_IFACE) {
		char *iface = nctrl->opts->host_iface;
		sockptr_t optval = KERNEL_SOCKPTR(iface);

		ret = sock_setsockopt(queue->sock, SOL_SOCKET, SO_BINDTODEVICE,
				      optval, strlen(iface));
		if (ret) {
			dev_err(nctrl->device,
			  "failed to bind to interface %s queue %d err %d\n",
			  iface, qid, ret);
			goto err_sock;
		}
	}

	queue->hdr_digest = nctrl->opts->hdr_digest;
	queue->data_digest = nctrl->opts->data_digest;
	if (queue->hdr_digest || queue->data_digest) {
		ret = nvme_tcp_alloc_crypto(queue);
		if (ret) {
			dev_err(nctrl->device,
				"failed to allocate queue %d crypto\n", qid);
			goto err_sock;
		}
	}

	rcv_pdu_size = sizeof(struct nvme_tcp_rsp_pdu) +
			nvme_tcp_hdgst_len(queue);
	queue->pdu = kmalloc(rcv_pdu_size, GFP_KERNEL);
	if (!queue->pdu) {
		ret = -ENOMEM;
		goto err_crypto;
	}

	dev_dbg(nctrl->device, "connecting queue %d\n",
			nvme_tcp_queue_id(queue));

	ret = kernel_connect(queue->sock, (struct sockaddr *)&ctrl->addr,
		sizeof(ctrl->addr), 0);
	if (ret) {
		dev_err(nctrl->device,
			"failed to connect socket: %d\n", ret);
		goto err_rcv_pdu;
	}

	/* If PSKs are configured try to start TLS */
	if (IS_ENABLED(CONFIG_NVME_TCP_TLS) && pskid) {
		ret = nvme_tcp_start_tls(nctrl, queue, pskid);
		if (ret)
			goto err_init_connect;
	}

	ret = nvme_tcp_init_connection(queue);
	if (ret)
		goto err_init_connect;

	set_bit(NVME_TCP_Q_ALLOCATED, &queue->flags);

	return 0;

err_init_connect:
	kernel_sock_shutdown(queue->sock, SHUT_RDWR);
err_rcv_pdu:
	kfree(queue->pdu);
err_crypto:
	if (queue->hdr_digest || queue->data_digest)
		nvme_tcp_free_crypto(queue);
err_sock:
	/* ->sock will be released by fput() */
	fput(queue->sock->file);
	queue->sock = NULL;
err_destroy_mutex:
	mutex_destroy(&queue->send_mutex);
	mutex_destroy(&queue->queue_lock);
	return ret;
}

static void nvme_tcp_restore_sock_ops(struct nvme_tcp_queue *queue)
{
	struct socket *sock = queue->sock;

	write_lock_bh(&sock->sk->sk_callback_lock);
	sock->sk->sk_user_data  = NULL;
	sock->sk->sk_data_ready = queue->data_ready;
	sock->sk->sk_state_change = queue->state_change;
	sock->sk->sk_write_space  = queue->write_space;
	write_unlock_bh(&sock->sk->sk_callback_lock);
}

static void nvme_tcp_zc_destroy_queue(struct nvme_tcp_queue *queue) {
	pr_info("nvme_tcp_zc_destroy_queue qid=%d\n", nvme_tcp_queue_id(queue));
	if (READ_ONCE(queue->zc_prepared)) {
		WRITE_ONCE(queue->zc_shutting_down, true);
		hrtimer_cancel(&queue->zc_idle_timer);
		cancel_work_sync(&queue->zc_flush_work);
		destroy_workqueue(queue->zc_wq);
		queue->zc_wq = NULL;
		WRITE_ONCE(queue->zc_prepared, false);
	}
/*
	while (queue->zc_cnt) {
//        struct request *rq = queue->zc_pending_rq[queue->zc_head];
        queue->zc_pend_cids[queue->zc_head] = 0;
        queue->zc_head = (queue->zc_head + 1) % queue->zc_queue_depth;
        queue->zc_cnt--;
    }
*/
	if (queue->zc_pend_cids) {
		kvfree(queue->zc_pend_cids);
		queue->zc_pend_cids = NULL;
	}

	queue->zc_head = queue->zc_tail = queue->zc_cnt = 0;
	queue->zc_pending_pages = 0;

}

static void __nvme_tcp_stop_queue(struct nvme_tcp_queue *queue)
{
	kernel_sock_shutdown(queue->sock, SHUT_RDWR);
	nvme_tcp_restore_sock_ops(queue);
	cancel_work_sync(&queue->io_work);

	if (nvme_tcp_rx_zc_batch_flush && enable_zerocopy)
		nvme_tcp_zc_destroy_queue(queue);
}

static void nvme_tcp_stop_queue(struct nvme_ctrl *nctrl, int qid)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(nctrl);
	struct nvme_tcp_queue *queue = &ctrl->queues[qid];

	if (!test_bit(NVME_TCP_Q_ALLOCATED, &queue->flags))
		return;

	mutex_lock(&queue->queue_lock);
	if (test_and_clear_bit(NVME_TCP_Q_LIVE, &queue->flags))
		__nvme_tcp_stop_queue(queue);
	mutex_unlock(&queue->queue_lock);
}

static void nvme_tcp_setup_sock_ops(struct nvme_tcp_queue *queue)
{
	write_lock_bh(&queue->sock->sk->sk_callback_lock);
	queue->sock->sk->sk_user_data = queue;
	queue->state_change = queue->sock->sk->sk_state_change;
	queue->data_ready = queue->sock->sk->sk_data_ready;
	queue->write_space = queue->sock->sk->sk_write_space;
	queue->sock->sk->sk_data_ready = nvme_tcp_data_ready;
	queue->sock->sk->sk_state_change = nvme_tcp_state_change;
	queue->sock->sk->sk_write_space = nvme_tcp_write_space;
#ifdef CONFIG_NET_RX_BUSY_POLL
	queue->sock->sk->sk_ll_usec = 1;
#endif
	write_unlock_bh(&queue->sock->sk->sk_callback_lock);
}

static inline void nvme_tcp_zc_prepare_queue(struct nvme_tcp_queue *q)
{
	if (cmpxchg(&q->zc_prepared, 0, 1) != 0){
        return;
	}
	pr_info("zc prepare qid=%d\n", nvme_tcp_queue_id(q));
    spin_lock_init(&q->zc_lock);
	q->zc_wq = alloc_workqueue("nvme_tcp_zc_wq",
                            WQ_HIGHPRI, 1);
	if (!q->zc_wq) {
		pr_info("failed to allocate zc_wq\n");
		WRITE_ONCE(q->zc_prepared, 0); 
		return;
	}
	INIT_WORK(&q->zc_flush_work, nvme_tcp_zc_flush_workfn);

	/* idle tail flush */
	atomic_set(&q->zc_idle_armed, 0);
    WRITE_ONCE(q->zc_last_defer_ns, ktime_get_ns());
    hrtimer_init(&q->zc_idle_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL_PINNED);
    q->zc_idle_timer.function = nvme_tcp_zc_idle_timer_fn;

    WRITE_ONCE(q->zc_prepared, true);
}

static void nvme_tcp_zc_init_queue(struct nvme_tcp_queue *queue)
{
    u32 depth;

    if (!nvme_tcp_rx_zc_batch_flush || !enable_zerocopy || !queue){
        return;
	}

	if (queue->zc_pend_cids){
		return;
	}

    depth = nvme_tcp_tagset(queue)->nr_tags;
	queue->zc_pend_cids = kvcalloc(depth, sizeof(u16), GFP_KERNEL);
	if (!queue->zc_pend_cids) {
		pr_info("failed to allocate zc_pend_cids\n");
		return;
	}

	queue->zc_head = queue->zc_tail = queue->zc_cnt = 0;
	queue->zc_pending_pages = 0;
	queue->zc_queue_depth = depth;

	pr_info("zc init qid=%d tags=%u pend=%p\n",
        nvme_tcp_queue_id(queue),
        nvme_tcp_tagset(queue)->nr_tags,
        queue->zc_pend_cids);
}


static int nvme_tcp_start_queue(struct nvme_ctrl *nctrl, int idx)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(nctrl);
	struct nvme_tcp_queue *queue = &ctrl->queues[idx];
	int ret;

	queue->rd_enabled = true;
	if (idx && nvme_tcp_rx_zc_batch_flush && enable_zerocopy)
		nvme_tcp_zc_prepare_queue(queue);
	nvme_tcp_init_recv_ctx(queue);
	nvme_tcp_setup_sock_ops(queue);

	if (idx){
		ret = nvmf_connect_io_queue(nctrl, idx);
	}else
		ret = nvmf_connect_admin_queue(nctrl);

	if (!ret) {
		set_bit(NVME_TCP_Q_LIVE, &queue->flags);

		if (idx && nvme_tcp_rx_zc_batch_flush && enable_zerocopy){
			nvme_tcp_zc_init_queue(queue);
		}
	} else {
		if (test_bit(NVME_TCP_Q_ALLOCATED, &queue->flags))
			__nvme_tcp_stop_queue(queue);
		dev_err(nctrl->device,
			"failed to connect queue: %d ret=%d\n", idx, ret);
	}
	return ret;
}

static void nvme_tcp_free_admin_queue(struct nvme_ctrl *ctrl)
{
	if (to_tcp_ctrl(ctrl)->async_req.pdu) {
		cancel_work_sync(&ctrl->async_event_work);
		nvme_tcp_free_async_req(to_tcp_ctrl(ctrl));
		to_tcp_ctrl(ctrl)->async_req.pdu = NULL;
	}

	nvme_tcp_free_queue(ctrl, 0);
}

static void nvme_tcp_free_io_queues(struct nvme_ctrl *ctrl)
{
	int i;

	for (i = 1; i < ctrl->queue_count; i++)
		nvme_tcp_free_queue(ctrl, i);
}

static void nvme_tcp_stop_io_queues(struct nvme_ctrl *ctrl)
{
	int i;

	for (i = 1; i < ctrl->queue_count; i++)
		nvme_tcp_stop_queue(ctrl, i);
}

static int nvme_tcp_start_io_queues(struct nvme_ctrl *ctrl,
				    int first, int last)
{
	int i, ret;

	for (i = first; i < last; i++) {
		ret = nvme_tcp_start_queue(ctrl, i);
		if (ret)
			goto out_stop_queues;
	}

	return 0;

out_stop_queues:
	for (i--; i >= first; i--)
		nvme_tcp_stop_queue(ctrl, i);
	return ret;
}

static int nvme_tcp_alloc_admin_queue(struct nvme_ctrl *ctrl)
{
	int ret;
	key_serial_t pskid = 0;

	if (nvme_tcp_tls(ctrl)) {
		if (ctrl->opts->tls_key)
			pskid = key_serial(ctrl->opts->tls_key);
		else
			pskid = nvme_tls_psk_default(ctrl->opts->keyring,
						      ctrl->opts->host->nqn,
						      ctrl->opts->subsysnqn);
		if (!pskid) {
			dev_err(ctrl->device, "no valid PSK found\n");
			return -ENOKEY;
		}
	}

	ret = nvme_tcp_alloc_queue(ctrl, 0, pskid);
	if (ret)
		return ret;

	ret = nvme_tcp_alloc_async_req(to_tcp_ctrl(ctrl));
	if (ret)
		goto out_free_queue;

	return 0;

out_free_queue:
	nvme_tcp_free_queue(ctrl, 0);
	return ret;
}

static int __nvme_tcp_alloc_io_queues(struct nvme_ctrl *ctrl)
{
	int i, ret;

	if (nvme_tcp_tls(ctrl) && !ctrl->tls_key) {
		dev_err(ctrl->device, "no PSK negotiated\n");
		return -ENOKEY;
	}
	for (i = 1; i < ctrl->queue_count; i++) {
		ret = nvme_tcp_alloc_queue(ctrl, i,
				key_serial(ctrl->tls_key));
		if (ret)
			goto out_free_queues;
	}

	return 0;

out_free_queues:
	for (i--; i >= 1; i--)
		nvme_tcp_free_queue(ctrl, i);

	return ret;
}

static int nvme_tcp_alloc_io_queues(struct nvme_ctrl *ctrl)
{
	unsigned int nr_io_queues;
	int ret;

	nr_io_queues = nvmf_nr_io_queues(ctrl->opts);
	ret = nvme_set_queue_count(ctrl, &nr_io_queues);
	if (ret)
		return ret;

	if (nr_io_queues == 0) {
		dev_err(ctrl->device,
			"unable to set any I/O queues\n");
		return -ENOMEM;
	}

	ctrl->queue_count = nr_io_queues + 1;
	dev_info(ctrl->device,
		"creating %d I/O queues.\n", nr_io_queues);

	nvmf_set_io_queues(ctrl->opts, nr_io_queues,
			   to_tcp_ctrl(ctrl)->io_queues);
	return __nvme_tcp_alloc_io_queues(ctrl);
}

static void nvme_tcp_destroy_io_queues(struct nvme_ctrl *ctrl, bool remove)
{
	nvme_tcp_stop_io_queues(ctrl);
	if (remove)
		nvme_remove_io_tag_set(ctrl);
	nvme_tcp_free_io_queues(ctrl);
}

static int nvme_tcp_configure_io_queues(struct nvme_ctrl *ctrl, bool new)
{
	int ret, nr_queues;

	ret = nvme_tcp_alloc_io_queues(ctrl);
	if (ret)
		return ret;

	if (new) {
		ret = nvme_alloc_io_tag_set(ctrl, &to_tcp_ctrl(ctrl)->tag_set,
				&nvme_tcp_mq_ops,
				ctrl->opts->nr_poll_queues ? HCTX_MAX_TYPES : 2,
				sizeof(struct nvme_tcp_request));
		if (ret)
			goto out_free_io_queues;
	}

	/*
	 * Only start IO queues for which we have allocated the tagset
	 * and limitted it to the available queues. On reconnects, the
	 * queue number might have changed.
	 */
	nr_queues = min(ctrl->tagset->nr_hw_queues + 1, ctrl->queue_count);
	ret = nvme_tcp_start_io_queues(ctrl, 1, nr_queues);
	if (ret)
		goto out_cleanup_connect_q;

	if (!new) {
		nvme_start_freeze(ctrl);
		nvme_unquiesce_io_queues(ctrl);
		if (!nvme_wait_freeze_timeout(ctrl, NVME_IO_TIMEOUT)) {
			/*
			 * If we timed out waiting for freeze we are likely to
			 * be stuck.  Fail the controller initialization just
			 * to be safe.
			 */
			ret = -ENODEV;
			nvme_unfreeze(ctrl);
			goto out_wait_freeze_timed_out;
		}
		blk_mq_update_nr_hw_queues(ctrl->tagset,
			ctrl->queue_count - 1);
		nvme_unfreeze(ctrl);
	}

	/*
	 * If the number of queues has increased (reconnect case)
	 * start all new queues now.
	 */
	ret = nvme_tcp_start_io_queues(ctrl, nr_queues,
				       ctrl->tagset->nr_hw_queues + 1);
	if (ret)
		goto out_wait_freeze_timed_out;

	return 0;

out_wait_freeze_timed_out:
	nvme_quiesce_io_queues(ctrl);
	nvme_sync_io_queues(ctrl);
	nvme_tcp_stop_io_queues(ctrl);
out_cleanup_connect_q:
	nvme_cancel_tagset(ctrl);
	if (new)
		nvme_remove_io_tag_set(ctrl);
out_free_io_queues:
	nvme_tcp_free_io_queues(ctrl);
	return ret;
}

static void nvme_tcp_destroy_admin_queue(struct nvme_ctrl *ctrl, bool remove)
{
	nvme_tcp_stop_queue(ctrl, 0);
	if (remove)
		nvme_remove_admin_tag_set(ctrl);
	nvme_tcp_free_admin_queue(ctrl);
}

static int nvme_tcp_configure_admin_queue(struct nvme_ctrl *ctrl, bool new)
{
	int error;

	error = nvme_tcp_alloc_admin_queue(ctrl);
	if (error)
		return error;

	if (new) {
		error = nvme_alloc_admin_tag_set(ctrl,
				&to_tcp_ctrl(ctrl)->admin_tag_set,
				&nvme_tcp_admin_mq_ops,
				sizeof(struct nvme_tcp_request));
		if (error)
			goto out_free_queue;
	}

	error = nvme_tcp_start_queue(ctrl, 0);
	if (error)
		goto out_cleanup_tagset;

	error = nvme_enable_ctrl(ctrl);
	if (error)
		goto out_stop_queue;

	nvme_unquiesce_admin_queue(ctrl);

	error = nvme_init_ctrl_finish(ctrl, false);
	if (error)
		goto out_quiesce_queue;

	return 0;

out_quiesce_queue:
	nvme_quiesce_admin_queue(ctrl);
	blk_sync_queue(ctrl->admin_q);
out_stop_queue:
	nvme_tcp_stop_queue(ctrl, 0);
	nvme_cancel_admin_tagset(ctrl);
out_cleanup_tagset:
	if (new)
		nvme_remove_admin_tag_set(ctrl);
out_free_queue:
	nvme_tcp_free_admin_queue(ctrl);
	return error;
}

static void nvme_tcp_teardown_admin_queue(struct nvme_ctrl *ctrl,
		bool remove)
{
	nvme_quiesce_admin_queue(ctrl);
	blk_sync_queue(ctrl->admin_q);
	nvme_tcp_stop_queue(ctrl, 0);
	nvme_cancel_admin_tagset(ctrl);
	if (remove)
		nvme_unquiesce_admin_queue(ctrl);
	nvme_tcp_destroy_admin_queue(ctrl, remove);
}

static void nvme_tcp_teardown_io_queues(struct nvme_ctrl *ctrl,
		bool remove)
{
	if (ctrl->queue_count <= 1)
		return;
	nvme_quiesce_admin_queue(ctrl);
	nvme_quiesce_io_queues(ctrl);
	nvme_sync_io_queues(ctrl);
	nvme_tcp_stop_io_queues(ctrl);
	nvme_cancel_tagset(ctrl);
	if (remove)
		nvme_unquiesce_io_queues(ctrl);
	nvme_tcp_destroy_io_queues(ctrl, remove);
}

static void nvme_tcp_reconnect_or_remove(struct nvme_ctrl *ctrl,
		int status)
{
	enum nvme_ctrl_state state = nvme_ctrl_state(ctrl);

	/* If we are resetting/deleting then do nothing */
	if (state != NVME_CTRL_CONNECTING) {
		WARN_ON_ONCE(state == NVME_CTRL_NEW || state == NVME_CTRL_LIVE);
		return;
	}

	if (nvmf_should_reconnect(ctrl, status)) {
		dev_info(ctrl->device, "Reconnecting in %d seconds...\n",
			ctrl->opts->reconnect_delay);
		queue_delayed_work(nvme_wq, &to_tcp_ctrl(ctrl)->connect_work,
				ctrl->opts->reconnect_delay * HZ);
	} else {
		dev_info(ctrl->device, "Removing controller (%d)...\n",
			 status);
		nvme_delete_ctrl(ctrl);
	}
}

static int nvme_tcp_setup_ctrl(struct nvme_ctrl *ctrl, bool new)
{
	struct nvmf_ctrl_options *opts = ctrl->opts;
	int ret;

	ret = nvme_tcp_configure_admin_queue(ctrl, new);
	if (ret)
		return ret;

	if (ctrl->icdoff) {
		ret = -EOPNOTSUPP;
		dev_err(ctrl->device, "icdoff is not supported!\n");
		goto destroy_admin;
	}

	if (!nvme_ctrl_sgl_supported(ctrl)) {
		ret = -EOPNOTSUPP;
		dev_err(ctrl->device, "Mandatory sgls are not supported!\n");
		goto destroy_admin;
	}

	if (opts->queue_size > ctrl->sqsize + 1)
		dev_warn(ctrl->device,
			"queue_size %zu > ctrl sqsize %u, clamping down\n",
			opts->queue_size, ctrl->sqsize + 1);

	if (ctrl->sqsize + 1 > ctrl->maxcmd) {
		dev_warn(ctrl->device,
			"sqsize %u > ctrl maxcmd %u, clamping down\n",
			ctrl->sqsize + 1, ctrl->maxcmd);
		ctrl->sqsize = ctrl->maxcmd - 1;
	}

	if (ctrl->queue_count > 1) {
		ret = nvme_tcp_configure_io_queues(ctrl, new);
		if (ret)
			goto destroy_admin;
	}

	if (!nvme_change_ctrl_state(ctrl, NVME_CTRL_LIVE)) {
		/*
		 * state change failure is ok if we started ctrl delete,
		 * unless we're during creation of a new controller to
		 * avoid races with teardown flow.
		 */
		enum nvme_ctrl_state state = nvme_ctrl_state(ctrl);

		WARN_ON_ONCE(state != NVME_CTRL_DELETING &&
			     state != NVME_CTRL_DELETING_NOIO);
		WARN_ON_ONCE(new);
		ret = -EINVAL;
		goto destroy_io;
	}

	nvme_start_ctrl(ctrl);
	return 0;

destroy_io:
	if (ctrl->queue_count > 1) {
		nvme_quiesce_io_queues(ctrl);
		nvme_sync_io_queues(ctrl);
		nvme_tcp_stop_io_queues(ctrl);
		nvme_cancel_tagset(ctrl);
		nvme_tcp_destroy_io_queues(ctrl, new);
	}
destroy_admin:
	nvme_stop_keep_alive(ctrl);
	nvme_tcp_teardown_admin_queue(ctrl, false);
	return ret;
}

static void nvme_tcp_reconnect_ctrl_work(struct work_struct *work)
{
	struct nvme_tcp_ctrl *tcp_ctrl = container_of(to_delayed_work(work),
			struct nvme_tcp_ctrl, connect_work);
	struct nvme_ctrl *ctrl = &tcp_ctrl->ctrl;
	int ret;

	++ctrl->nr_reconnects;

	ret = nvme_tcp_setup_ctrl(ctrl, false);
	if (ret)
		goto requeue;

	dev_info(ctrl->device, "Successfully reconnected (attempt %d/%d)\n",
		 ctrl->nr_reconnects, ctrl->opts->max_reconnects);

	ctrl->nr_reconnects = 0;

	return;

requeue:
	dev_info(ctrl->device, "Failed reconnect attempt %d/%d\n",
		 ctrl->nr_reconnects, ctrl->opts->max_reconnects);
	nvme_tcp_reconnect_or_remove(ctrl, ret);
}

static void nvme_tcp_error_recovery_work(struct work_struct *work)
{
	struct nvme_tcp_ctrl *tcp_ctrl = container_of(work,
				struct nvme_tcp_ctrl, err_work);
	struct nvme_ctrl *ctrl = &tcp_ctrl->ctrl;

	nvme_stop_keep_alive(ctrl);
	flush_work(&ctrl->async_event_work);
	nvme_tcp_teardown_io_queues(ctrl, false);
	/* unquiesce to fail fast pending requests */
	nvme_unquiesce_io_queues(ctrl);
	nvme_tcp_teardown_admin_queue(ctrl, false);
	nvme_unquiesce_admin_queue(ctrl);
	nvme_auth_stop(ctrl);

	if (!nvme_change_ctrl_state(ctrl, NVME_CTRL_CONNECTING)) {
		/* state change failure is ok if we started ctrl delete */
		enum nvme_ctrl_state state = nvme_ctrl_state(ctrl);

		WARN_ON_ONCE(state != NVME_CTRL_DELETING &&
			     state != NVME_CTRL_DELETING_NOIO);
		return;
	}

	nvme_tcp_reconnect_or_remove(ctrl, 0);
}

static void nvme_tcp_teardown_ctrl(struct nvme_ctrl *ctrl, bool shutdown)
{
	nvme_tcp_teardown_io_queues(ctrl, shutdown);
	nvme_quiesce_admin_queue(ctrl);
	nvme_disable_ctrl(ctrl, shutdown);
	nvme_tcp_teardown_admin_queue(ctrl, shutdown);
}

static void nvme_tcp_delete_ctrl(struct nvme_ctrl *ctrl)
{
	nvme_tcp_teardown_ctrl(ctrl, true);
}

static void nvme_reset_ctrl_work(struct work_struct *work)
{
	struct nvme_ctrl *ctrl =
		container_of(work, struct nvme_ctrl, reset_work);
	int ret;

	nvme_stop_ctrl(ctrl);
	nvme_tcp_teardown_ctrl(ctrl, false);

	if (!nvme_change_ctrl_state(ctrl, NVME_CTRL_CONNECTING)) {
		/* state change failure is ok if we started ctrl delete */
		enum nvme_ctrl_state state = nvme_ctrl_state(ctrl);

		WARN_ON_ONCE(state != NVME_CTRL_DELETING &&
			     state != NVME_CTRL_DELETING_NOIO);
		return;
	}

	ret = nvme_tcp_setup_ctrl(ctrl, false);
	if (ret)
		goto out_fail;

	return;

out_fail:
	++ctrl->nr_reconnects;
	nvme_tcp_reconnect_or_remove(ctrl, ret);
}

static void nvme_tcp_stop_ctrl(struct nvme_ctrl *ctrl)
{
	flush_work(&to_tcp_ctrl(ctrl)->err_work);
	cancel_delayed_work_sync(&to_tcp_ctrl(ctrl)->connect_work);
}

static void nvme_tcp_free_ctrl(struct nvme_ctrl *nctrl)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(nctrl);

	if (list_empty(&ctrl->list))
		goto free_ctrl;

	mutex_lock(&nvme_tcp_ctrl_mutex);
	list_del(&ctrl->list);
	mutex_unlock(&nvme_tcp_ctrl_mutex);

	nvmf_free_options(nctrl->opts);
free_ctrl:
	kfree(ctrl->queues);
	kfree(ctrl);
}

static void nvme_tcp_set_sg_null(struct nvme_command *c)
{
	struct nvme_sgl_desc *sg = &c->common.dptr.sgl;

	sg->addr = 0;
	sg->length = 0;
	sg->type = (NVME_TRANSPORT_SGL_DATA_DESC << 4) |
			NVME_SGL_FMT_TRANSPORT_A;
}

static void nvme_tcp_set_sg_inline(struct nvme_tcp_queue *queue,
		struct nvme_command *c, u32 data_len)
{
	struct nvme_sgl_desc *sg = &c->common.dptr.sgl;

	sg->addr = cpu_to_le64(queue->ctrl->ctrl.icdoff);
	sg->length = cpu_to_le32(data_len);
	sg->type = (NVME_SGL_FMT_DATA_DESC << 4) | NVME_SGL_FMT_OFFSET;
}

static void nvme_tcp_set_sg_host_data(struct nvme_command *c,
		u32 data_len)
{
	struct nvme_sgl_desc *sg = &c->common.dptr.sgl;

	sg->addr = 0;
	sg->length = cpu_to_le32(data_len);
	sg->type = (NVME_TRANSPORT_SGL_DATA_DESC << 4) |
			NVME_SGL_FMT_TRANSPORT_A;
}

static void nvme_tcp_submit_async_event(struct nvme_ctrl *arg)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(arg);
	struct nvme_tcp_queue *queue = &ctrl->queues[0];
	struct nvme_tcp_cmd_pdu *pdu = ctrl->async_req.pdu;
	struct nvme_command *cmd = &pdu->cmd;
	u8 hdgst = nvme_tcp_hdgst_len(queue);

	memset(pdu, 0, sizeof(*pdu));
	pdu->hdr.type = nvme_tcp_cmd;
	if (queue->hdr_digest)
		pdu->hdr.flags |= NVME_TCP_F_HDGST;
	pdu->hdr.hlen = sizeof(*pdu);
	pdu->hdr.plen = cpu_to_le32(pdu->hdr.hlen + hdgst);

	cmd->common.opcode = nvme_admin_async_event;
	cmd->common.command_id = NVME_AQ_BLK_MQ_DEPTH;
	cmd->common.flags |= NVME_CMD_SGL_METABUF;
	nvme_tcp_set_sg_null(cmd);

	ctrl->async_req.state = NVME_TCP_SEND_CMD_PDU;
	ctrl->async_req.offset = 0;
	ctrl->async_req.curr_bio = NULL;
	ctrl->async_req.data_len = 0;

	nvme_tcp_queue_request(&ctrl->async_req, true, true);
}

static void nvme_tcp_complete_timed_out(struct request *rq)
{
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	struct nvme_ctrl *ctrl = &req->queue->ctrl->ctrl;

	nvme_tcp_stop_queue(ctrl, nvme_tcp_queue_id(req->queue));
	nvmf_complete_timed_out_request(rq);
}

static enum blk_eh_timer_return nvme_tcp_timeout(struct request *rq)
{
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	struct nvme_ctrl *ctrl = &req->queue->ctrl->ctrl;
	struct nvme_tcp_cmd_pdu *pdu = nvme_tcp_req_cmd_pdu(req);
	struct nvme_command *cmd = &pdu->cmd;
	int qid = nvme_tcp_queue_id(req->queue);

	dev_warn(ctrl->device,
		 "I/O tag %d (%04x) type %d opcode %#x (%s) QID %d timeout\n",
		 rq->tag, nvme_cid(rq), pdu->hdr.type, cmd->common.opcode,
		 nvme_fabrics_opcode_str(qid, cmd), qid);

	if (nvme_ctrl_state(ctrl) != NVME_CTRL_LIVE) {
		/*
		 * If we are resetting, connecting or deleting we should
		 * complete immediately because we may block controller
		 * teardown or setup sequence
		 * - ctrl disable/shutdown fabrics requests
		 * - connect requests
		 * - initialization admin requests
		 * - I/O requests that entered after unquiescing and
		 *   the controller stopped responding
		 *
		 * All other requests should be cancelled by the error
		 * recovery work, so it's fine that we fail it here.
		 */
		nvme_tcp_complete_timed_out(rq);
		return BLK_EH_DONE;
	}

	/*
	 * LIVE state should trigger the normal error recovery which will
	 * handle completing this request.
	 */
	nvme_tcp_error_recovery(ctrl);
	return BLK_EH_RESET_TIMER;
}

static blk_status_t nvme_tcp_map_data(struct nvme_tcp_queue *queue,
			struct request *rq)
{
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	struct nvme_tcp_cmd_pdu *pdu = nvme_tcp_req_cmd_pdu(req);
	struct nvme_command *c = &pdu->cmd;

	c->common.flags |= NVME_CMD_SGL_METABUF;

	if (!blk_rq_nr_phys_segments(rq))
		nvme_tcp_set_sg_null(c);
	else if (rq_data_dir(rq) == WRITE &&
	    req->data_len <= nvme_tcp_inline_data_size(req))
		nvme_tcp_set_sg_inline(queue, c, req->data_len);
	else
		nvme_tcp_set_sg_host_data(c, req->data_len);

	return 0;
}

static blk_status_t nvme_tcp_setup_cmd_pdu(struct nvme_ns *ns,
		struct request *rq)
{
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	struct nvme_tcp_cmd_pdu *pdu = nvme_tcp_req_cmd_pdu(req);
	struct nvme_tcp_queue *queue = req->queue;
	u8 hdgst = nvme_tcp_hdgst_len(queue), ddgst = 0;
	blk_status_t ret;

	ret = nvme_setup_cmd(ns, rq);
	if (ret)
		return ret;

	req->state = NVME_TCP_SEND_CMD_PDU;
	req->status = cpu_to_le16(NVME_SC_SUCCESS);
	req->offset = 0;
	req->data_sent = 0;
	req->pdu_len = 0;
	req->pdu_sent = 0;
	req->h2cdata_left = 0;
	req->data_len = blk_rq_nr_phys_segments(rq) ?
				blk_rq_payload_bytes(rq) : 0;
	req->curr_bio = rq->bio;
	if (req->curr_bio && req->data_len)
		nvme_tcp_init_iter(req, rq_data_dir(rq));

	if (rq_data_dir(rq) == WRITE &&
	    req->data_len <= nvme_tcp_inline_data_size(req))
		req->pdu_len = req->data_len;

	pdu->hdr.type = nvme_tcp_cmd;
	pdu->hdr.flags = 0;
	if (queue->hdr_digest)
		pdu->hdr.flags |= NVME_TCP_F_HDGST;
	if (queue->data_digest && req->pdu_len) {
		pdu->hdr.flags |= NVME_TCP_F_DDGST;
		ddgst = nvme_tcp_ddgst_len(queue);
	}
	pdu->hdr.hlen = sizeof(*pdu);
	pdu->hdr.pdo = req->pdu_len ? pdu->hdr.hlen + hdgst : 0;
	pdu->hdr.plen =
		cpu_to_le32(pdu->hdr.hlen + hdgst + req->pdu_len + ddgst);

	ret = nvme_tcp_map_data(queue, rq);
	if (unlikely(ret)) {
		nvme_cleanup_cmd(rq);
		dev_err(queue->ctrl->ctrl.device,
			"Failed to map data (%d)\n", ret);
		return ret;
	}

	return 0;
}

static void nvme_tcp_commit_rqs(struct blk_mq_hw_ctx *hctx)
{
	struct nvme_tcp_queue *queue = hctx->driver_data;

	if (!llist_empty(&queue->req_list))
		queue_work_on(queue->io_cpu, nvme_tcp_wq, &queue->io_work);
}

static blk_status_t nvme_tcp_queue_rq(struct blk_mq_hw_ctx *hctx,
		const struct blk_mq_queue_data *bd)
{
	struct nvme_ns *ns = hctx->queue->queuedata;
	struct nvme_tcp_queue *queue = hctx->driver_data;
	struct request *rq = bd->rq;
	struct nvme_tcp_request *req = blk_mq_rq_to_pdu(rq);
	bool queue_ready = test_bit(NVME_TCP_Q_LIVE, &queue->flags);
	blk_status_t ret;

	if (!nvme_check_ready(&queue->ctrl->ctrl, rq, queue_ready))
		return nvme_fail_nonready_command(&queue->ctrl->ctrl, rq);

	ret = nvme_tcp_setup_cmd_pdu(ns, rq);
	if (unlikely(ret))
		return ret;

	nvme_start_request(rq);

	req->zc_policy = ZC_UNDECIDED;

	nvme_tcp_queue_request(req, true, bd->last);

	return BLK_STS_OK;
}

static void nvme_tcp_map_queues(struct blk_mq_tag_set *set)
{
	struct nvme_tcp_ctrl *ctrl = to_tcp_ctrl(set->driver_data);

	nvmf_map_queues(set, &ctrl->ctrl, ctrl->io_queues);
}

static int nvme_tcp_poll(struct blk_mq_hw_ctx *hctx, struct io_comp_batch *iob)
{
	struct nvme_tcp_queue *queue = hctx->driver_data;
	struct sock *sk = queue->sock->sk;

	if (!test_bit(NVME_TCP_Q_LIVE, &queue->flags))
		return 0;

	set_bit(NVME_TCP_Q_POLLING, &queue->flags);
	if (sk_can_busy_loop(sk) && skb_queue_empty_lockless(&sk->sk_receive_queue))
		sk_busy_loop(sk, true);
	nvme_tcp_try_recv(queue);
	clear_bit(NVME_TCP_Q_POLLING, &queue->flags);
	return queue->nr_cqe;
}

static int nvme_tcp_get_address(struct nvme_ctrl *ctrl, char *buf, int size)
{
	struct nvme_tcp_queue *queue = &to_tcp_ctrl(ctrl)->queues[0];
	struct sockaddr_storage src_addr;
	int ret, len;

	len = nvmf_get_address(ctrl, buf, size);

	mutex_lock(&queue->queue_lock);

	if (!test_bit(NVME_TCP_Q_LIVE, &queue->flags))
		goto done;
	ret = kernel_getsockname(queue->sock, (struct sockaddr *)&src_addr);
	if (ret > 0) {
		if (len > 0)
			len--; /* strip trailing newline */
		len += scnprintf(buf + len, size - len, "%ssrc_addr=%pISc\n",
				(len) ? "," : "", &src_addr);
	}
done:
	mutex_unlock(&queue->queue_lock);

	return len;
}

static const struct blk_mq_ops nvme_tcp_mq_ops = {
	.queue_rq	= nvme_tcp_queue_rq,
	.commit_rqs	= nvme_tcp_commit_rqs,
	.complete	= nvme_complete_rq,
	.init_request	= nvme_tcp_init_request,
	.exit_request	= nvme_tcp_exit_request,
	.init_hctx	= nvme_tcp_init_hctx,
	.timeout	= nvme_tcp_timeout,
	.map_queues	= nvme_tcp_map_queues,
	.poll		= nvme_tcp_poll,
};

static const struct blk_mq_ops nvme_tcp_admin_mq_ops = {
	.queue_rq	= nvme_tcp_queue_rq,
	.complete	= nvme_complete_rq,
	.init_request	= nvme_tcp_init_request,
	.exit_request	= nvme_tcp_exit_request,
	.init_hctx	= nvme_tcp_init_admin_hctx,
	.timeout	= nvme_tcp_timeout,
};

static const struct nvme_ctrl_ops nvme_tcp_ctrl_ops = {
	.name			= "tcp",
	.module			= THIS_MODULE,
	.flags			= NVME_F_FABRICS | NVME_F_BLOCKING,
	.reg_read32		= nvmf_reg_read32,
	.reg_read64		= nvmf_reg_read64,
	.reg_write32		= nvmf_reg_write32,
	.subsystem_reset	= nvmf_subsystem_reset,
	.free_ctrl		= nvme_tcp_free_ctrl,
	.submit_async_event	= nvme_tcp_submit_async_event,
	.delete_ctrl		= nvme_tcp_delete_ctrl,
	.get_address		= nvme_tcp_get_address,
	.stop_ctrl		= nvme_tcp_stop_ctrl,
};

static bool
nvme_tcp_existing_controller(struct nvmf_ctrl_options *opts)
{
	struct nvme_tcp_ctrl *ctrl;
	bool found = false;

	mutex_lock(&nvme_tcp_ctrl_mutex);
	list_for_each_entry(ctrl, &nvme_tcp_ctrl_list, list) {
		found = nvmf_ip_options_match(&ctrl->ctrl, opts);
		if (found)
			break;
	}
	mutex_unlock(&nvme_tcp_ctrl_mutex);

	return found;
}

static struct nvme_tcp_ctrl *nvme_tcp_alloc_ctrl(struct device *dev,
		struct nvmf_ctrl_options *opts)
{
	struct nvme_tcp_ctrl *ctrl;
	int ret;

	ctrl = kzalloc(sizeof(*ctrl), GFP_KERNEL);
	if (!ctrl)
		return ERR_PTR(-ENOMEM);

	INIT_LIST_HEAD(&ctrl->list);
	ctrl->ctrl.opts = opts;
	ctrl->ctrl.queue_count = opts->nr_io_queues + opts->nr_write_queues +
				opts->nr_poll_queues + 1;
	ctrl->ctrl.sqsize = opts->queue_size - 1;
	ctrl->ctrl.kato = opts->kato;

	INIT_DELAYED_WORK(&ctrl->connect_work,
			nvme_tcp_reconnect_ctrl_work);
	INIT_WORK(&ctrl->err_work, nvme_tcp_error_recovery_work);
	INIT_WORK(&ctrl->ctrl.reset_work, nvme_reset_ctrl_work);

	if (!(opts->mask & NVMF_OPT_TRSVCID)) {
		opts->trsvcid =
			kstrdup(__stringify(NVME_TCP_DISC_PORT), GFP_KERNEL);
		if (!opts->trsvcid) {
			ret = -ENOMEM;
			goto out_free_ctrl;
		}
		opts->mask |= NVMF_OPT_TRSVCID;
	}

	ret = inet_pton_with_scope(&init_net, AF_UNSPEC,
			opts->traddr, opts->trsvcid, &ctrl->addr);
	if (ret) {
		pr_err("malformed address passed: %s:%s\n",
			opts->traddr, opts->trsvcid);
		goto out_free_ctrl;
	}

	if (opts->mask & NVMF_OPT_HOST_TRADDR) {
		ret = inet_pton_with_scope(&init_net, AF_UNSPEC,
			opts->host_traddr, NULL, &ctrl->src_addr);
		if (ret) {
			pr_err("malformed src address passed: %s\n",
			       opts->host_traddr);
			goto out_free_ctrl;
		}
	}

	if (opts->mask & NVMF_OPT_HOST_IFACE) {
		if (!__dev_get_by_name(&init_net, opts->host_iface)) {
			pr_err("invalid interface passed: %s\n",
			       opts->host_iface);
			ret = -ENODEV;
			goto out_free_ctrl;
		}
	}

	if (!opts->duplicate_connect && nvme_tcp_existing_controller(opts)) {
		ret = -EALREADY;
		goto out_free_ctrl;
	}

	ctrl->queues = kcalloc(ctrl->ctrl.queue_count, sizeof(*ctrl->queues),
				GFP_KERNEL);
	if (!ctrl->queues) {
		ret = -ENOMEM;
		goto out_free_ctrl;
	}

	ret = nvme_init_ctrl(&ctrl->ctrl, dev, &nvme_tcp_ctrl_ops, 0);
	if (ret)
		goto out_kfree_queues;

	return ctrl;
out_kfree_queues:
	kfree(ctrl->queues);
out_free_ctrl:
	kfree(ctrl);
	return ERR_PTR(ret);
}

static struct nvme_ctrl *nvme_tcp_create_ctrl(struct device *dev,
		struct nvmf_ctrl_options *opts)
{
	struct nvme_tcp_ctrl *ctrl;
	int ret;

	ctrl = nvme_tcp_alloc_ctrl(dev, opts);
	if (IS_ERR(ctrl))
		return ERR_CAST(ctrl);

	ret = nvme_add_ctrl(&ctrl->ctrl);
	if (ret)
		goto out_put_ctrl;

	if (!nvme_change_ctrl_state(&ctrl->ctrl, NVME_CTRL_CONNECTING)) {
		WARN_ON_ONCE(1);
		ret = -EINTR;
		goto out_uninit_ctrl;
	}

	ret = nvme_tcp_setup_ctrl(&ctrl->ctrl, true);
	if (ret)
		goto out_uninit_ctrl;

	dev_info(ctrl->ctrl.device, "new ctrl: NQN \"%s\", addr %pISp, hostnqn: %s\n",
		nvmf_ctrl_subsysnqn(&ctrl->ctrl), &ctrl->addr, opts->host->nqn);

	mutex_lock(&nvme_tcp_ctrl_mutex);
	list_add_tail(&ctrl->list, &nvme_tcp_ctrl_list);
	mutex_unlock(&nvme_tcp_ctrl_mutex);

	return &ctrl->ctrl;

out_uninit_ctrl:
	nvme_uninit_ctrl(&ctrl->ctrl);
out_put_ctrl:
	nvme_put_ctrl(&ctrl->ctrl);
	if (ret > 0)
		ret = -EIO;
	return ERR_PTR(ret);
}

static struct nvmf_transport_ops nvme_tcp_transport = {
	.name		= "tcp",
	.module		= THIS_MODULE,
	.required_opts	= NVMF_OPT_TRADDR,
	.allowed_opts	= NVMF_OPT_TRSVCID | NVMF_OPT_RECONNECT_DELAY |
			  NVMF_OPT_HOST_TRADDR | NVMF_OPT_CTRL_LOSS_TMO |
			  NVMF_OPT_HDR_DIGEST | NVMF_OPT_DATA_DIGEST |
			  NVMF_OPT_NR_WRITE_QUEUES | NVMF_OPT_NR_POLL_QUEUES |
			  NVMF_OPT_TOS | NVMF_OPT_HOST_IFACE | NVMF_OPT_TLS |
			  NVMF_OPT_KEYRING | NVMF_OPT_TLS_KEY,
	.create_ctrl	= nvme_tcp_create_ctrl,
};

static int __init nvme_tcp_init_module(void)
{
	unsigned int wq_flags = WQ_MEM_RECLAIM | WQ_HIGHPRI | WQ_SYSFS;

	BUILD_BUG_ON(sizeof(struct nvme_tcp_hdr) != 8);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_cmd_pdu) != 72);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_data_pdu) != 24);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_rsp_pdu) != 24);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_r2t_pdu) != 24);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_icreq_pdu) != 128);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_icresp_pdu) != 128);
	BUILD_BUG_ON(sizeof(struct nvme_tcp_term_pdu) != 24);

	if (wq_unbound)
		wq_flags |= WQ_UNBOUND;

	nvme_tcp_wq = alloc_workqueue("nvme_tcp_wq", wq_flags, 0);
	if (!nvme_tcp_wq)
		return -ENOMEM;

	nvmf_register_transport(&nvme_tcp_transport);
	return 0;
}

static void __exit nvme_tcp_cleanup_module(void)
{
	struct nvme_tcp_ctrl *ctrl;

	nvmf_unregister_transport(&nvme_tcp_transport);

	mutex_lock(&nvme_tcp_ctrl_mutex);
	list_for_each_entry(ctrl, &nvme_tcp_ctrl_list, list)
		nvme_delete_ctrl(&ctrl->ctrl);
	mutex_unlock(&nvme_tcp_ctrl_mutex);
	flush_workqueue(nvme_delete_wq);

	destroy_workqueue(nvme_tcp_wq);
}

module_init(nvme_tcp_init_module);
module_exit(nvme_tcp_cleanup_module);

MODULE_DESCRIPTION("NVMe host TCP transport driver");
MODULE_LICENSE("GPL v2");

