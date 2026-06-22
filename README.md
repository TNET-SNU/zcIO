# zcIO

zcIO is a Linux kernel including a novel Linux NVMe/TCP stack that achieves seamless zero-copy I/Os through record-aware networking.


# Why zero-copy needed?

<p align="center">
  <img width="800" src="https://github.com/user-attachments/assets/bfda35d0-75b4-4e37-a3fe-c83876c31a72">
</p>

Our profiling confirms that data copies during H2CData/C2HData PDU processing dominate the receive (RX) path for both READ operation and WRITE operation for large block data via NVMe/TCP (41.99%/40.52% of total CPU cycles for READ, and WRITE, respectively).


# Prerequisites

You need to configure your path MTU to be 9000 B. Make sure the interface MTUs of initiator and target to be 9000 B. If there is any switch between initiator and target, make the MTUs of the switch ports to be 9000 B.

Both endpoints need ConnectX-7. Theoritically, any NICs that support header-data split can be used, but our prototype currently supports only ConnectX-7. To enable PDU-aligned packetization, you should enable GSO or TSO for the interfaces on both endpoints.


# How to build

Since zcIO is embedded in our Linux kernel, it is enough to simply build the kernel.


# How to enable

To enable PDU-aligned packetization, configure kernel parameter like below.

```Bash
sudo sysctl net.ipv4.nvme_pdu_align=2
```

To enable RX zero-copy for NVMe/TCP initiator, configure module parameters like below.

```Bash
echo 1 | sudo tee /sys/module/nvme_tcp/parameters/enable_zerocopy
echo 8 | sudo tee /sys/module/nvme_tcp/parameters/rx_zc_batch_pages
echo Y | sudo tee /sys/module/nvme_tcp/parameters/rx_zc_batch_flush
echo 200000 | sudo tee /sys/module/nvme_tcp/parameters/rx_zc_idle_us
```

To enable RX zero-copy for NVMe/TCP target, configure a module parameter like below.

```Bash
echo 1 | sudo tee /sys/module/tcp_zc/parameters/enable_zerocopy
```

Artifact evaluation scripts for reproducing the paper's figures live in `zcio-ae/` (one directory per figure).
