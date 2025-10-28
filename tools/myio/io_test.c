// io_ring_linear_verify.c — C(gnu11) 순정 빌드 OK
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <libaio.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <assert.h>
#include <sys/ioctl.h>
#include <linux/fs.h>

#define DEV_PATH                                                               \
  "/dev/zcopy_dev"     // mmap용 (없으면 shm/posix_memalign로 대체 가능)
#define BASE_ALIGN 512 // 4Kn이면 4096
#define PAGE_SZ 4096

// === 워크로드 파라미터 ==
#define QD 128
#define NUM_JOBS 10
#define DURATION 25
#define TIME_BASED 1 // 0: 파일 범위 끝까지, 1: 시간 기반
#define VERIFY 0
#define DEVICE_LIST {"/dev/nvme0n1", "/dev/nvme0n2"}

// 혼합 I/O 크기(모두 BASE_ALIGN 배수여야 함)
static const int BS_SET[] = {4096*32};
static const int BS_WEIGHT[] = {100};
static const int BS_N = sizeof(BS_SET) / sizeof(BS_SET[0]);

#define WINDOW_SLACK 80
#define FILE_SIZE_FACTOR 5
#define MAX_DEVICES 8

// ===== 테스트 정책 토글 =====
// 검증 실패/IO 에러 시 즉시 중단할지 여부(0=로그만, 1=abort)
#ifndef EXIT_ON_ERROR
#define EXIT_ON_ERROR 0
#endif
// 패턴 헥스덤프 로그 억제(1=조용히)
#ifndef QUIET_PATTERN_LOG
#define QUIET_PATTERN_LOG 1
#endif

// ===== 유틸 =====
// 값을 a의 배수로 올림
static inline size_t align_up(size_t x, size_t a) {
  return ((x + a - 1) / a) * a;
}
// 오프셋을 a의 배수로 올림
static inline off_t align_up_off(off_t x, size_t a) {
  return ((x + a - 1) / a) * a;
}

#if !VERIFY
typedef struct {
  int items[QD];
  int top; // next free index
} freelist_t;

static inline void fl_init(freelist_t *fl) { fl->top = 0; }
static inline void fl_push(freelist_t *fl, int v) { fl->items[fl->top++] = v; }
static inline int fl_pop(freelist_t *fl) { return fl->top ? fl->items[--fl->top] : -1; }
#endif

// 랜덤 I/O 크기 선택
static inline int pick_bs(unsigned *seed) {
  int r = rand_r(seed) % 100, acc = 0;
  for (int i = 0; i < BS_N; i++) {
    acc += BS_WEIGHT[i];
    if (r < acc)
      return BS_SET[i];
  }
  return BS_SET[BS_N - 1];
}

static inline int overlapped(size_t s0, size_t e0, size_t s1, size_t e1) {
  return !(e0 <= s1 || e1 <= s0);
}

static inline uint8_t pattern_at(int job_id, off_t off, size_t i) {
  return (uint8_t)(((uint64_t)job_id * 0x9E3779B97F4A7C15ULL + (uint64_t)off +
                    (uint64_t)i) &
                   0xFF);
}
static inline void fill_pattern(uint8_t *buf, size_t len, int job_id,
                                off_t off) {
  for (size_t i = 0; i < len; i++)
    buf[i] = pattern_at(job_id, off, i);
#if !QUIET_PATTERN_LOG
  // print hexdump pattern
  size_t b = (0 > 16 ? 0 : 0);
  size_t e = (len < 16 ? len : 16);
  fprintf(stderr, "hexdump pattern:");
  for (size_t k=b; k<e; k++) fprintf(stderr, " %02x", buf[k]);
  fprintf(stderr, "\n");
#endif
}
static inline int verify_pattern(uint8_t *buf, size_t len, int job_id,
                                 off_t off) {
  for (size_t i = 0; i < len; i++) {
    uint8_t exp = pattern_at(job_id, off, i);
    if (buf[i] != exp) {
      fprintf(stderr, "verify fail: i=%zu got=%u exp=%u job=%d off=%lld\n", i,
              (unsigned)buf[i], (unsigned)exp, job_id, (long long)off);
        size_t b = (i > 16 ? i-16 : 0);
        size_t e = (i+16 < len ? i+16 : len);
        fprintf(stderr, "hexdump around mismatch:");
        for (size_t k=b; k<e; k++) fprintf(stderr, " %02x", buf[k]);
        fprintf(stderr, "\n");
#if EXIT_ON_ERROR
      abort();
#else
      return -1;
#endif
    }
  }
  return 0;
}

static inline void submit_one(io_context_t ctx, struct iocb *cb,
                              struct iocb **lst, int *inflight) {
  lst[0] = cb;
  int n = io_submit(ctx, 1, lst);
  if (n != 1)
    perror("io_submit");
  else
    (*inflight)++;
}

// ===== 인플라이트 메타 & IO 슬롯 =====
typedef enum { PH_READ = 0, PH_WRITE = 1, PH_READ_VERIFY = 2 } phase_t;

// i/o metadata
typedef struct {
  size_t start;   // 윈도우 내 바이트 오프셋 (wrap 없음)
  size_t len;     // 예약 길이
  uint64_t seq;   // 제출 순서 (소비 재조립 키)
  int in_use;     // 예약됨
  int ready;      // 소비 가능(READ 성공 or VERIFY 통과)
  off_t file_off; // 파일 오프셋
  phase_t phase;  // VERIFY 단계
  int job_id;     // 패턴용
} inflight_t;

// i/o slot - qd 만큼 존재
typedef struct {
  struct iocb cb;
  inflight_t *meta; // cb->data가 가리킬 메타
  int live;
} slot_io_t;

// ===== Job 설정 =====
typedef struct {
  int job_id, dev_id, numjobs;
  const char *dev_path;
  int nvme_fd; // 블록/파일 디바이스 FD
  int zfd;     // DEV_PATH (mmap)
  size_t qd;

  off_t file_start;
  off_t file_end;

  int duration;
  int time_based;

  uint8_t *win_base; // 연속 버퍼 시작
  size_t win_bytes;  // 윈도우 전체 크기
} job_arg_t;

// === 헬퍼들 (C 함수 버전) ===
static int find_free_slot(slot_io_t *slots, inflight_t *metas) {
  for (int i = 0; i < QD; i++) {
    if (!slots[i].live && !metas[i].in_use)
      return i;
  }
  return -1;
}

// O(1) 예약: head/tail 용량 기반, wrap 가능(비분할), empty 처리
static int try_reserve(size_t *p_head, size_t tail, int empty, size_t need,
                       size_t W, size_t *out_start) {
  size_t head = align_up(*p_head, BASE_ALIGN);

  // 빈 상태: 전 구간이 여유
  if (empty) {
    if (need > W)
      return 0; // 필요 크기가 창보다 큼(비정상)
    *out_start = head;
    // head 정렬로 인한 패딩이 생겨도 빈 상태에선 문제없음
    if (head + need <= W) {
      *p_head = head + need;
      return 1;
    }
    // 끝에 안 맞으면 0으로 감아서 할당
    if (need <= tail /*==head (empty에선 head==tail)*/ || need <= W) {
      *out_start = 0;
      *p_head = need;
      return 1;
    }
    return 0;
  }

  // 비어있지 않은 일반 케이스
  if (head <= tail) {
    // head..tail 사이의 빈 구간
    size_t free_mid = tail - head;
    if (need <= free_mid) {
      *out_start = head;
      *p_head = head + need;
      return 1;
    }
    return 0;
  } else {
    // head..W 끝쪽 먼저 시도
    size_t free_end = W - head;
    if (need <= free_end) {
      *out_start = head;
      *p_head = head + need;
      return 1;
    }
    // wrap: 0..tail
    if (tail == 0)
      return 0;
    if (need <= tail) {
      *out_start = 0;
      *p_head = need;
      return 1;
    }
    return 0;
  }
}

/*
static int try_reserve(size_t *p_head, size_t need, size_t W, inflight_t *metas,
                       size_t *out_start) {
  size_t head = align_up(*p_head, BASE_ALIGN);
  if (head + need > W)
    head = 0; // wrap (이 구현은 "예약 구간은 wrap하지 않는다" 정책)

  size_t s0 = head, e0 = head + need;
  for (int i = 0; i < QD; i++) {
    if (!metas[i].in_use)
      continue;
    size_t s1 = metas[i].start, e1 = s1 + metas[i].len;
    if (overlapped(s0, e0, s1, e1))
      return 0;
  }
  *out_start = head;
  *p_head = e0;
  return 1;
}
*/

static int consume_ready(uint8_t *base, size_t W, slot_io_t *slots,
                         inflight_t *metas, uint64_t *p_consume_seq,
                         size_t *p_tail) {
  int advanced = 0;
  while (1) {
    int idx = -1;
    for (int i = 0; i < QD; i++) {
      // 소비 가능한 io 찾기 (ready이고 seq가 일치하는)
      if (metas[i].in_use && metas[i].ready && metas[i].seq == *p_consume_seq) {
        idx = i;
        break;
      }
    }
    if (idx < 0)
      break;

    // 여기서 base + metas[idx].start .. +len 이 연속 버퍼에서 in-order
    (void)base;
    (void)W; // (상위 레이어 전달이 필요하면 여기서 사용)

    // tail 업데이트 - start +len 은 ring buffer 내에서의 위치
    *p_tail = (metas[idx].start + metas[idx].len) % W;
    metas[idx].in_use = 0;
    metas[idx].ready = 0;
    slots[idx].live = 0;
    (*p_consume_seq)++;
    // 이번 호출에서 tail이 소비되었음을 알림
    advanced = 1;
  }
  return advanced;
}


// 위의 잘못된 포인터 산술을 방지하기 위해 별도 버전 제공:
static void prep_and_submit_idx(io_context_t ctx, int nvme_fd, uint8_t *base,
                                slot_io_t *slots, int s, inflight_t *m,
                                struct iocb **lst, int *inflight) {
  struct iocb *cb = &slots[s].cb;
  memset(cb, 0, sizeof(*cb));
  uint8_t *ubuf = base + m->start;

  if (!VERIFY) {
    io_prep_pread(cb, nvme_fd, ubuf, m->len, m->file_off);
    m->phase = PH_READ;
  } else {
    if (m->phase == PH_WRITE) {
      fill_pattern(ubuf, m->len, m->job_id, m->file_off);
      io_prep_pwrite(cb, nvme_fd, ubuf, m->len, m->file_off);
    } else { // PH_READ_VERIFY
      io_prep_pread(cb, nvme_fd, ubuf, m->len, m->file_off);
    }
  }
  cb->data = m;
  submit_one(ctx, cb, lst, inflight);
}

// ===== Job 스레드 =====
void *job_thread(void *arg) {
  job_arg_t *cfg = (job_arg_t *)arg;

  size_t max_io = 0;
  for (int i = 0; i < BS_N; i++)
    if ((size_t)BS_SET[i] > max_io)
      max_io = (size_t)BS_SET[i];

  uint8_t *base = cfg->win_base;
  size_t W = cfg->win_bytes;

  io_context_t ctx = 0;
  if (io_setup(cfg->qd, &ctx) < 0) {
    perror("io_setup");
    return NULL;
  }

  slot_io_t slots[QD];
  inflight_t metas[QD];
  memset(slots, 0, sizeof(slots));
  memset(metas, 0, sizeof(metas));
  for (int i = 0; i < QD; i++) {
    slots[i].meta = &metas[i];
  }

  struct iocb *lst[QD];
  struct io_event evs[QD];

  size_t head = 0;
  size_t tail = 0;
  uint64_t next_seq = 0, consume_seq = 0;
  off_t file_off = cfg->file_start;

  unsigned seed = (unsigned)time(NULL) ^ (unsigned)(uintptr_t)pthread_self();
  int inflight_cnt = 0;
  // time out을 nonblock으로
  //struct timespec ts = {.tv_sec = 0, .tv_nsec = 0};
  struct timespec ts = {.tv_sec = 0, .tv_nsec = 100 * 1000};
  time_t start = time(NULL);

#if !VERIFY
    // free-list: 시작 시 모든 슬롯을 free로
    freelist_t free_slots; fl_init(&free_slots);
    for (int i = 0; i < QD; i++) fl_push(&free_slots, i);

    // in-order 소비용 매핑/플래그
    int by_seq[QD];                 // index = (seq & (QD-1)) → slot index
    unsigned char ready[QD];        // index = (seq & (QD-1)) → 0/1
    memset(ready, 0, sizeof(ready));
    const uint64_t SEQ_MASK = (uint64_t)QD - 1; // QD는 2의 거듭제곱 권장
#endif

  while (1) {
    int time_over =
        cfg->time_based ? ((time(NULL) - start) >= cfg->duration) : 0;
    if (!cfg->time_based) {
      if (file_off >= cfg->file_end && inflight_cnt == 0)
        break;
    } else {
      if (time_over && inflight_cnt == 0)
        break;
    }

    // 완료 수거
    if (inflight_cnt > 0) {
      int got = io_getevents(ctx, 1, QD, evs, &ts);
      if (got < 0) {
        perror("io_getevents");
        break;
      }
      //inflight_cnt -= got;
      for (int i = 0; i < got; i++) {
        inflight_t *m = (inflight_t *)evs[i].data;
        inflight_cnt--;

        if ((ssize_t)evs[i].res < 0) {
          fprintf(
              stderr,
              "io error: res=%lld seq=%llu off=%lld len=%zu phase=%d errno=%d\n",
              (long long)evs[i].res, (unsigned long long)m->seq,
              (long long)m->file_off, m->len, m->phase, (int)-evs[i].res);
#if !VERIFY
          ready[m->seq & SEQ_MASK] = 1;
#else
          m->ready = 1; // 흐름 유지용
#endif          
        } else if ((size_t)evs[i].res != m->len) {
          fprintf(stderr, "short io: res=%zu expect=%zu seq=%llu\n",
                  (size_t)evs[i].res, m->len, (unsigned long long)m->seq);
#if !VERIFY
          ready[m->seq & SEQ_MASK] = 1;
#else
          m->ready = 1;
#endif
        } else {
#if !VERIFY
          ready[m->seq & SEQ_MASK] = 1;
#else
  //       m->ready = 1;
#if VERIFY
          if (m->phase == PH_WRITE) {
            // WRITE 완료 → 같은 범위 READ로 전환
            m->phase = PH_READ_VERIFY;
            int s = -1;
            for (int k = 0; k < QD; k++)
              if (slots[k].meta == m) {
                s = k;
                break;
              }
            if (s >= 0) {
              slots[s].live = 1;
              prep_and_submit_idx(ctx, cfg->nvme_fd, base, slots, s, m, lst,
                                  &inflight_cnt);
            }
            continue;
          } else {
            // READ_VERIFY 완료 → 검증
            if (verify_pattern(base + m->start, m->len, m->job_id,
                               m->file_off) < 0) {
              // 실패 로깅만
            }
      //      m->ready = 1;
          }
          m->ready = 1;
#else 
          m->ready = 1;
#endif
#endif
        }
      }
    }

    // 소비
#if !VERIFY
    while(ready[consume_seq & SEQ_MASK]) {
      int s = by_seq[consume_seq & SEQ_MASK];
      inflight_t *m = &metas[s];
      tail = (m->start + m->len) % W;
      slots[s].live = 0;
      m->in_use = 0;
      ready[consume_seq & SEQ_MASK] = 0;
      fl_push(&free_slots, s);
      consume_seq++;
    }
#else
    (void)consume_ready(base, W, slots, metas, &consume_seq, &tail);
#endif
    int batch = 0;
    // 새 제출
    while (1) {
      if (!cfg->time_based && file_off >= cfg->file_end)
        break;
      if (cfg->time_based && time_over)
        break;

#if !VERIFY
      int s = fl_pop(&free_slots);
      if (s < 0)
        break;
      if (metas[s].in_use || slots[s].live) continue;
#else
      int s = find_free_slot(slots, metas);
      if (s < 0)
        break;
#endif
      size_t bs = (size_t)pick_bs(&seed);
      bs = align_up(bs, BASE_ALIGN);
      if (bs > max_io)
        bs = max_io;

      //size_t start_off = 0;
      //if (!try_reserve(&head, tail, bs, W, &start_off))
      int empty = (inflight_cnt == 0); // first submit or when all inflight are completed
      size_t start_off = 0;
      if (!try_reserve(&head, tail, empty, bs, W, &start_off))
      {
#if !VERIFY
        fl_push(&free_slots, s);
#endif
        break;
      }

      if (cfg->time_based && file_off + (off_t)bs > cfg->file_end){
        file_off = cfg->file_start;
        file_off = align_up_off(file_off, BASE_ALIGN);
      }

      inflight_t *m = &metas[s];
      *m = (inflight_t){.start = start_off,
                        .len = bs,
                        .seq = next_seq++,
                        .in_use = 1,
                        .ready = 0,
                        .file_off = file_off,
                        .phase = VERIFY ? PH_WRITE : PH_READ,
                        .job_id = cfg->job_id};
      slots[s].live = 1;

#if !VERIFY
      by_seq[m->seq & SEQ_MASK] = s;
      struct iocb *cb = &slots[s].cb;
      memset(cb, 0, sizeof(*cb));
      uint8_t *ubuf = base + m->start;
      io_prep_pread(cb, cfg->nvme_fd, ubuf, m->len, m->file_off);
      cb->data = m ;
      lst[batch++] = cb;
#else
      prep_and_submit_idx(ctx, cfg->nvme_fd, base, slots, s, m, lst,
                          &inflight_cnt);
#endif 
      file_off = align_up_off(file_off + (off_t)bs, BASE_ALIGN);
      if (cfg->time_based && file_off + (off_t)bs > cfg->file_end){
        file_off = cfg->file_start;
        file_off = align_up_off(file_off, BASE_ALIGN);
      }
#if !VERIFY
      if (batch == QD) break;
#endif
    }
#if !VERIFY
    if(batch > 0) {
      int n = io_submit(ctx, batch, lst);
      if (n < 0) perror("io_submit");
      else inflight_cnt += n;
    }
#endif
  }

  // drain
  while (inflight_cnt > 0) {
    int got = io_getevents(ctx, 1, QD, evs, NULL);
    if (got < 0) {
      perror("io_getevents");
      break;
    }
    inflight_cnt -= got;
    for (int i = 0; i < got; i++) {
      inflight_t *m = (inflight_t *)evs[i].data;
      if (!VERIFY) {
        m->ready = 1;
      } else {
        if (m->phase == PH_WRITE) {
          // WRITE만 끝났으면 READ_VERIFY로 전환
          int s = -1;
          for (int k = 0; k < QD; k++)
            if (slots[k].meta == m) {
              s = k;
              break;
            }
          if (s >= 0) {
            m->phase = PH_READ_VERIFY;
            slots[s].live = 1;
            prep_and_submit_idx(ctx, cfg->nvme_fd, base, slots, s, m, lst,
                                &inflight_cnt);
            // 방금 다시 제출했으니 inflight_cnt는 위 함수 내부에서 증가됨
          }
        } else {
          m->ready = 1;
        }
      }
    }
    (void)consume_ready(base, W, slots, metas, &consume_seq, &tail);
  }

  io_destroy(ctx);
  fprintf(stderr, "job %d done (dev=%d), window=%zu bytes, verify=%d\n",
          cfg->job_id, cfg->dev_id, W, VERIFY);
  return NULL;
}

// ===== 메인 =====
int main(void) {
  const char *NVME_PATHS[] = DEVICE_LIST;
  int NUM_DEVS = (int)(sizeof(NVME_PATHS) / sizeof(NVME_PATHS[0]));
  int numjobs = NUM_JOBS;

#if !VERIFY
  static_assert((QD & (QD - 1)) == 0, "QD must be a power of two for SEQ_MASK");
#endif
  // max_io
  size_t max_io = 0;
  for (int i = 0; i < BS_N; i++)
    if ((size_t)BS_SET[i] > max_io)
      max_io = (size_t)BS_SET[i];

  assert((max_io % BASE_ALIGN) == 0);

  // 윈도우 크기
  size_t window_bytes = (size_t)(QD + WINDOW_SLACK) * max_io;

  int zfd = open(DEV_PATH, O_RDWR);
  if (zfd < 0) {
    perror("open zcopy_dev");
    return 1;
  }

  // 페이지 정렬 공유 메모리 확보
  size_t per_job_window = window_bytes;
  size_t map_size = (size_t)NUM_DEVS * (size_t)numjobs * per_job_window;
  void *base = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, zfd, 0);
  if (base == MAP_FAILED) {
    perror("mmap");
    return 1;
  }

  // 디바이스 오픈
  int nvme[MAX_DEVICES];
  uint64_t dev_bytes[MAX_DEVICES] = {0};
  for (int d = 0; d < NUM_DEVS; d++) {
    int flags = (VERIFY ? O_RDWR : O_RDONLY) | O_DIRECT;
    nvme[d] = open(NVME_PATHS[d], flags);
    if (nvme[d] < 0) {
      perror("open nvme");
      return 1;
    }
    // 실제 용량 조회(바이트)
    if (ioctl(nvme[d], BLKGETSIZE64, &dev_bytes[d]) != 0) {
      perror("ioctl BLKGETSIZE64");
      return 1;
    }
    // 최소한의 정렬/크기 체크
    if (dev_bytes[d] < (uint64_t)window_bytes) {
      fprintf(stderr, "warning: device %d size (%llu) < window_bytes (%zu)\n",
              d, (unsigned long long)dev_bytes[d], window_bytes);
    }
  }

  // 파일 범위(예시)
  off_t total_range = (off_t)per_job_window * FILE_SIZE_FACTOR;
  //off_t per_job_range = align_up_off(total_range / numjobs, BASE_ALIGN);

  pthread_t tids[NUM_JOBS * MAX_DEVICES];
  job_arg_t args[NUM_JOBS * MAX_DEVICES];
  int idx = 0;

  for (int d = 0; d < NUM_DEVS; d++) {
    // 기본 계획(윈도우×계수)에서 시작하되, 장치 용량 한도 내로 clamp
    off_t plan_per_job = align_up_off((off_t)(total_range / numjobs), BASE_ALIGN);
    // dev_bytes[d] 내에서 numjobs개 구간이 들어가도록 조정
    off_t cap_per_job = (off_t)(dev_bytes[d] / (uint64_t)numjobs);
    cap_per_job = (off_t)align_up_off(cap_per_job, BASE_ALIGN);
    off_t per_job_range_d = plan_per_job;
    if ((uint64_t)per_job_range_d * (uint64_t)numjobs > dev_bytes[d]) {
      per_job_range_d = (off_t)cap_per_job;
      fprintf(stderr, "info: device %d per_job_range clamped to %lld bytes\n",
              d, (long long)per_job_range_d);
    }
    // 최소 보장: 한 번의 최대 I/O는 커버해야 함
    if (per_job_range_d < (off_t)max_io) {
      fprintf(stderr, "warning: device %d per_job_range(%lld) < max_io(%zu), bumping up\n",
              d, (long long)per_job_range_d, max_io);
      per_job_range_d = (off_t)max_io;
    }
    assert((per_job_range_d % BASE_ALIGN) == 0);


    for (int j = 0; j < numjobs; j++) {
      //off_t fstart = per_job_range * j;
      //off_t fend = fstart + per_job_range;
      off_t fstart = per_job_range_d * j;
      off_t fend = fstart + per_job_range_d;
      assert(((fstart % BASE_ALIGN) == 0) && ((fend % BASE_ALIGN) == 0));
      assert((fend - fstart) >= (off_t)max_io);

      args[idx] =
          (job_arg_t){.job_id = d * numjobs + j, // dev_id 섞어서 패턴 유일화
                      .dev_id = d,
                      .numjobs = numjobs,
                      .dev_path = NVME_PATHS[d],
                      .nvme_fd = nvme[d],
                      .zfd = zfd,
                      .qd = QD,
                      .file_start = fstart,
                      .file_end = fend,
                      .duration = DURATION,
                      .time_based = TIME_BASED,
                      .win_base = (uint8_t *)base +
                                  (size_t)(d * numjobs + j) * per_job_window,
                      .win_bytes = per_job_window};
      pthread_create(&tids[idx], NULL, job_thread, &args[idx]);
      idx++;
    }
  }

  for (int i = 0; i < idx; i++)
    pthread_join(tids[i], NULL);

  for (int d = 0; d < NUM_DEVS; d++)
    close(nvme[d]);
  munmap(base, map_size);
  close(zfd);
  return 0;
}  
