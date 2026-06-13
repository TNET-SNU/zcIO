# zcIO — NVMe-over-TCP RX Zero-Copy (host + target)

This kernel integrates **two independent RX zero-copy features** on top of a
shared NIC-side mechanism:

| Feature | What it does | Software toggle |
|---|---|---|
| **Initiator (host)** RX zero-copy | NVMe-oF *host* delivers received data straight into the I/O / user buffer (no `skb_copy_datagram_iter`) | `nvme_host_rx_zc` (int, nvme-tcp) |
| **Target (nvmet)** RX zero-copy | NVMe-oF *target* swaps received NIC pages into the command SGL (no copy in `recvmsg`) | `nvmet_rx_zc` (bool, built-in) |
| **NIC stride** (shared substrate) | Forces 4K (PAGE_SIZE) mlx5 MPWQE RX stride + SHAMPO TCP-doff/gso fixup that *both* features depend on | `rx_zc_stride` (mlx5 ethtool priv-flag) |

> **Key idea:** the two software toggles are fully independent, but **both
> require the shared `rx_zc_stride` NIC flag to be ON** to actually do
> zero-copy. With every flag OFF the data path is byte-for-byte vanilla 6.11.

All three default to **OFF**.

---

## 0. Prerequisites

* mlx5 NIC (ConnectX) with **HW-GRO / SHAMPO** and **striding RQ**.
* Kernel config (this tree was validated with):
  * `CONFIG_NVME_TCP=y` (built-in — required: some host-side functions must be built-in)
  * `CONFIG_NVME_TARGET_TCP=m`, `CONFIG_MLX5_CORE=m`
* `ethtool` installed.

Replace `<dev>` below with your NIC interface (e.g. `enp1s0f0np0`).

---

## 1. Shared NIC flag: `rx_zc_stride` (do this first, on BOTH machines)

The 4K stride is decided when the RX queue is created, so toggling it
**reopens the NIC channels** (brief link blip). It also needs striding RQ.

```bash
# striding RQ must be on (it is by default on mlx5)
sudo ethtool --set-priv-flags <dev> rx_striding_rq on

# enable the zero-copy 4K stride
sudo ethtool --set-priv-flags <dev> rx_zc_stride on

# verify
sudo ethtool --show-priv-flags <dev> | grep -E 'rx_striding_rq|rx_zc_stride'
#   rx_striding_rq : on
#   rx_zc_stride   : on
```

Turn the NIC behaviour back to **vanilla**:

```bash
sudo ethtool --set-priv-flags <dev> rx_zc_stride off
```

When `rx_zc_stride` is off, `mlx5e_mpwqe_get_log_stride_size()` returns the
stock `MLX5_MPWRQ_DEF_LOG_STRIDE_SZ(mdev)` and the per-packet SHAMPO
doff/gso rewrite in `en_rx.c` is skipped (`rq->mpwqe.zc_stride == 0`).

---

## 2. Initiator (host) RX zero-copy

Run on the **host / initiator** machine. The knob is a parameter of the
(built-in) `nvme_tcp` module.

```bash
# turn ON  (runtime, takes effect for new I/O)
echo 1 | sudo tee /sys/module/nvme_tcp/parameters/nvme_host_rx_zc

# turn OFF -> exact vanilla host RX path
echo 0 | sudo tee /sys/module/nvme_tcp/parameters/nvme_host_rx_zc

# check
cat /sys/module/nvme_tcp/parameters/nvme_host_rx_zc
```

Or at boot via kernel cmdline:

```
nvme_tcp.nvme_host_rx_zc=1
```

**Full host zero-copy =** `rx_zc_stride on` (§1) **AND** `nvme_host_rx_zc=1`.

---

## 3. Target (nvmet) RX zero-copy

Run on the **target** machine. The knob lives in the built-in `tcp_zc`
object (the symbol is `EXPORT_SYMBOL`'d for nvmet-tcp and mlx5):

```bash
# turn ON
echo 1 | sudo tee /sys/module/tcp_zc/parameters/nvmet_rx_zc

# turn OFF -> exact vanilla target RX path
echo 0 | sudo tee /sys/module/tcp_zc/parameters/nvmet_rx_zc

# check
cat /sys/module/tcp_zc/parameters/nvmet_rx_zc
```

Or at boot:

```
tcp_zc.nvmet_rx_zc=1
```

> The exact `/sys/module/<name>/parameters/` path for the built-in target
> flag depends on `KBUILD_MODNAME` for `net/ipv4/tcp_zc.o`. If `tcp_zc` is
> not present, find it with:
> ```bash
> sudo grep -rl nvmet_rx_zc /sys/module/*/parameters/ 2>/dev/null
> ```

**Full target zero-copy =** `rx_zc_stride on` (§1) **AND** `nvmet_rx_zc=1`.

---

## 4. Typical setups

**Host-only zero-copy** (target stays vanilla):
```bash
# on host:
sudo ethtool --set-priv-flags <dev> rx_zc_stride on
echo 1 | sudo tee /sys/module/nvme_tcp/parameters/nvme_host_rx_zc
```

**Target-only zero-copy** (host stays vanilla):
```bash
# on target:
sudo ethtool --set-priv-flags <dev> rx_zc_stride on
echo 1 | sudo tee /sys/module/tcp_zc/parameters/nvmet_rx_zc
```

**Back to full vanilla** (either machine):
```bash
echo 0 | sudo tee /sys/module/nvme_tcp/parameters/nvme_host_rx_zc   # host
echo 0 | sudo tee /sys/module/tcp_zc/parameters/nvmet_rx_zc         # target
sudo ethtool --set-priv-flags <dev> rx_zc_stride off
```

---

## 5. Notes / gotchas

* **`rx_zc_stride` reopens channels** — expect a momentary RX pause when you
  flip it. The two software flags (`nvme_host_rx_zc`, `nvmet_rx_zc`) are
  cheap runtime reads and do **not** reopen anything.
* The two software toggles are **separate symbols** (`int nvme_host_rx_zc`
  vs `bool nvmet_rx_zc`) so host and target can be enabled independently and
  there is no symbol collision.
* `rx_zcopy_head_size` (mlx5, default 90) is the SHAMPO split-header size the
  sender produces for PDU-aligned ZC; it is a separate `nvme_tcp`/mlx5
  module param and normally does not need changing.
* This is research code: there are still debug `pr_info`/`trace_printk`
  statements and commented blocks on the ZC paths. They are inert when the
  toggles are off but should be cleaned before any upstreaming.

## 6. Source map (what changed vs vanilla v6.11)

* Host: `drivers/nvme/host/tcp.c`, `zcopy_mem.c`, `block/{fops,bio,zcopy_ctx}.c`,
  `fs/iomap/direct-io.c`, `lib/iov_iter.c`, `include/linux/zcopy_*.h`
* Target: `drivers/nvme/target/tcp.c`, `net/ipv4/{tcp,tcp_input,ip_input,tcp_zc}.c`,
  `include/linux/nvmet_tcp_zc.h`
* Shared NIC: `drivers/net/ethernet/mellanox/mlx5/core/{en.h,en_main.c,en_rx.c,en_ethtool.c,en/params.c}`

See the `[zcIO]` commits for the integration-specific changes (renames,
the `rx_zc_stride` priv-flag, and the off==vanilla gating).
