# zcIO: NVMe/TCP RX zero-copy (host and target)

This kernel (v6.11 + zcIO, `EXTRAVERSION = -zcio`) adds receive-side zero-copy
to both ends of NVMe/TCP, on top of a shared mlx5 mechanism:

| Feature | What it does | Switch |
|---|---|---|
| **Host (initiator) RX zero-copy** | Read data arriving from the target is remapped into the reader's buffer instead of copied | `nvme_tcp.rx_zc` (int) |
| **Target (nvmet) RX zero-copy** | Write data arriving from the host is put into the I/O scatterlist instead of copied | `nvmet_tcp.rx_zc` (bool) |
| **NIC: 4K stride + PDU-header fixup** | mlx5 receives payload into whole 4K page-pool pages and hands a ToS-marked PDU header back to the payload | `rx_zc_stride` (mlx5 ethtool priv-flag), `mlx5_core.rx_zc_tos_mask` |

Both modules name their switch `rx_zc`; the other host parameters are
`rx_zc_batch_*` / `rx_zc_idle_us` next to it. (Builds before 2026-11-11 called
them `nvme_host_rx_zc` and `nvmet_rx_zc`.) All switches default to off. With them off, the receive paths behave as in
vanilla v6.11; only a few "is zero-copy on?" checks are left in them.

How it works: the **sender** puts the 24-byte header of each NVMe/TCP data PDU
into the TCP header (doff +6 words) of the PDU's first segment and marks that
segment with ToS (IPv4) / Traffic Class (IPv6) bit `0x04`. The receiving mlx5
then splits the headers off (SHAMPO), so the PDU data starts at offset 0 of a
4K stride page. It also turns the 24 bytes back into payload and clears the
mark. Each page-aligned 4K of PDU data is then one whole page-pool page, which
nvme-tcp / nvmet-tcp take instead of copying it. Anything else is copied as
usual.

---

## 0. Requirements

* mlx5 (ConnectX) NIC with striding RQ and hardware GRO (SHAMPO) on the
  **receiving** side; MTU 9000 was used.
* Kernel config: `CONFIG_NVME_TCP=y` (block/ and iomap call into it, so it must
  be built in), `CONFIG_NVME_TARGET_TCP=m`, `CONFIG_MLX5_CORE=m`. x86-64.
* Install kernel and modules **from the same build** (`make install` and
  `make modules_install`): with `CONFIG_MODVERSIONS` a module from a newer build
  fails to load with `Invalid argument`.
* A **sender that marks PDU-header segments**: a kernel with PDU-aligned send
  (branch `pdu_align_only`, or the `5.15.189-pduwin` kernel) and
  `sysctl -w net.ipv4.nvme_pdu_align=2`. Its mark bit must equal the receiver's
  `rx_zc_tos_mask` (both `0x04`). Without it nothing breaks, but every byte is
  copied.

| Zero-copy on | receives | sender that must mark |
|---|---|---|
| host | C2H data (reads) | the target node |
| target | H2C / in-capsule data (writes) | the host node |

---

## 1. NIC (receiving node)

```bash
# hw-GRO must be on: enable it at MTU 1500, then raise the MTU
sudo ip link set <dev> mtu 1500
sudo ethtool -K <dev> rx-gro-hw on gro on tso on
sudo ip link set <dev> mtu 9000

sudo ethtool --set-priv-flags <dev> rx_striding_rq on
sudo ethtool --set-priv-flags <dev> rx_zc_stride on      # reopens the channels
cat /sys/module/mlx5_core/parameters/rx_zc_tos_mask      # 4
```

`rx_zc_stride` is applied when the RX queues are created, so changing it
reopens the NIC channels (a short link blip). Change it before connecting.
With it off, the stride is the stock one and the PDU-header fixup is skipped.
`rx_zc_tos_mask` (0 = never match) can be changed at runtime.

---

## 2. Host (initiator) RX zero-copy

```bash
echo 1 | sudo tee /sys/module/nvme_tcp/parameters/rx_zc
# optional batched TLB flush; read at connect time, so set it before connecting
echo Y | sudo tee /sys/module/nvme_tcp/parameters/rx_zc_batch_flush
```

| Parameter | Default | Meaning |
|---|---|---|
| `rx_zc` | 0 | remap received read data into the reader's buffer |
| `rx_zc_batch_flush` | N | complete requests from a per-queue worker that flushes the TLB once per batch (applies to queues connected afterwards) |
| `rx_zc_batch_pages` | 64 | staged pages that start a batch flush |
| `rx_zc_idle_us` | 50 | flush a partial batch after this idle time |

**Covered reads:** async `O_DIRECT` on a raw block device (libaio, io_uring)
and filesystem direct I/O through iomap (ext4, xfs). They must land in
**private anonymous memory**, such as a `malloc()`ed buffer, and the buffer
must start on a page boundary. Other reads are copied: buffered I/O,
synchronous raw block DIO, io_uring fixed buffers (bvec iterators), shared or
file mappings, unaligned buffers.

**How:**
1. While the bio pins the user pages, the block layer records each page's user
   address (`lib/iov_iter.c`, `block/bio.c`).
2. `nvme_tcp_recv_data()` replaces the reader's PTEs with the received
   page-pool pages (`zc_remap_pages()`).
3. The TLB is flushed before the request completes, on every completion path.
   This happens right away, or per batch with `rx_zc_batch_flush`.

A remapped page holds a page-pool reference while it is mapped. It goes back
to its pool when the same buffer is read again (at bio completion), when the
mapping goes away (munmap, `madvise(MADV_DONTNEED)`, COW; mmu notifier in
`zcopy_mem.c`), or when the process exits. `PG_owner_priv_1` records that the
reference is still held, so it is returned exactly once, also after mremap().

---

## 3. Target (nvmet) RX zero-copy

```bash
sudo modprobe nvmet-tcp
echo 1 | sudo tee /sys/module/nvmet_tcp/parameters/rx_zc
```

**How:**
1. For a write on a non-TLS queue, the command gets a scatterlist **without
   pages**.
2. nvmet-tcp receives the PDU data with `read_sock()`. Each page-aligned 4K
   that arrived as one whole page-pool page becomes the `req->sg` entry at
   that index; the rest is copied into a page allocated for that entry.
3. When the command completes, the page-pool pages go back to their pool.

Whether a command uses zero-copy is decided when it arrives, so changing
`rx_zc` at runtime is safe. Any listener port works. Data digest works,
because it is computed over `req->sg`. Reads and TLS queues stay on the
vanilla path.

---

## 4. Checking it

Lab scripts live outside the tree, in `~/nvme-tcp-scripts` on creek1/creek2:

| Script | Node | Purpose |
|---|---|---|
| `initiator-zc-enable.sh` / `-disable.sh` | host | `nvme_tcp.rx_zc`, batch flush, `rx_zc_stride` |
| `initiator-zc-leak-test.sh` (+ `zc-leak-test.c`) | host | page-pool `inflight` before/after 2000 x 1MB reads per release path: reuse, munmap, madvise, mremap, exit. A leak shows as ~512000 pages |
| `target-zc-enable.sh` / `-disable.sh` | target | `nvmet_tcp.rx_zc`, `rx_zc_stride` |
| `target-zc-check.sh` | target | bpftrace count of 4K chunks taken by zero-copy vs. copied. Start it before the load when the target has one core |
| `target-ssd-clean.sh` | target | nvme-format the 9100 PRO SSDs before a write run |
| `initiator-pdu-align.sh` | sender | `net.ipv4.nvme_pdu_align` |

Page-pool `inflight` without the scripts:

```bash
python3 tools/net/ynl/cli.py --spec Documentation/netlink/specs/netdev.yaml \
    --dump page-pool-get
```

Reference numbers (creek1 / creek2, ConnectX, 8x Samsung 9100 PRO, one CPU core
on the receiving node):

| Workload | copy (switches off) | zcIO |
|---|---|---|
| host: 1MB random read, libaio O_DIRECT | ~34 Gbps | ~75 Gbps |
| target: 128k write | ~21 Gbps | ~83 Gbps |

Both nodes run with `init_on_alloc` on (the Ubuntu default), which zeroes
every page allocation.

---

## 5. Notes

* With the switches off the paths match vanilla, but `rx_zc_stride` also
  changes the RX stride for all traffic on that NIC.
* After a reboot the NIC settings (MTU, hw-GRO, `rx_zc_stride`) and the module
  params are gone: set them again.
* Do not change CPU hotplug state (offline/online cores) around NVMe/TCP host
  connections: connecting with some cores offline fails with `-EXDEV`, and
  onlining cores after a disconnect has oopsed. Use `nr_cpus=N` at boot, or
  connect with 1 core or all cores online.
* Debug output on the zero-copy paths is `pr_debug` (dynamic debug).

---

## 6. Source map (vs. vanilla v6.11)

| Area | Files |
|---|---|
| mlx5 | `drivers/net/ethernet/mellanox/mlx5/core/en_rx.c` (PDU-header fixup, `tot_len = 0` above 64KB), `en/params.c`, `en.h`, `en_main.c`, `en_ethtool.c` (`rx_zc_stride`) |
| shared | `net/core/zc_rx.c`, `include/net/zc_rx.h` (page lookup in an skb, held-reference flag), `include/linux/ip.h` (`ip_transport_len()` with `tot_len == 0`) |
| target | `drivers/nvme/target/tcp.c` |
| host driver | `drivers/nvme/host/tcp.c` (remap, TLB flush, batched completion), `drivers/nvme/host/zcopy_mem.c` (mmu notifier) |
| host block / fs | `block/zcopy_ctx.c`, `include/linux/zcopy_ctx.h`, `include/linux/zcopy_mem.h`, `block/bio.c`, `block/fops.c`, `fs/iomap/direct-io.c`, `lib/iov_iter.c` |

The TCP core (`net/ipv4`), `net/core/{gro,page_pool,skbuff}.c` and `mm/` are
unchanged.
