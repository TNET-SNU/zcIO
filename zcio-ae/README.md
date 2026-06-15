# Artifact Evaluation

This page is for the Artifact Evaluation of zcIO (FAST '27).

First, log in to `stream5.snu.ac.kr` as the AE account `fast27` (password announced
in advance). To see the visual graphs, we recommend using X-window (X11 forwarding).

```bash
# at your local machine
ssh -Y fast27@stream5.snu.ac.kr
```

You are now in the `fast27` home; go to the `zcio-ae` directory (the repo is cloned
at `/home/fast27/zcIO`).

```bash
# at stream5, logged in as fast27
cd ~/zcIO/zcio-ae          # = /home/fast27/zcIO/zcio-ae
```

## One-time setup (`deploy.sh`)

Run this **once**, before any figure:

```bash
cd ~/zcIO/zcio-ae
./deploy.sh
```

`deploy.sh` sets up the shared experiment environment: passwordless SSH from
`stream5` to the other machines and NOPASSWD `sudo` on each of them, so the
figures can drive the whole testbed unattended. The environment is the same for
every figure, so **you do not re-run `deploy.sh` per figure** — once is enough.
Each figure's `all_in_one.sh` stages its own setup scripts to the machines
automatically.

## Running the figures

In this directory, each figure has its own directory, and each is run the same way:

```bash
cd <figure>          # e.g.  cd 9d
./all_in_one.sh
```

This is a **kernel-gated** experiment, so run the figures **in the order below**:
all the READ-path figures first, then the WRITE-path figures. Figures in the same
group share the same kernels, so you only switch (reboot) kernels once between the
two groups. Each `all_in_one.sh` checks the kernels and tells you exactly what to
do if they don't match.

| order | figure | path  | estimated time |
|-------|--------|-------|----------------|
| 1     | `8`    | read  |  |
| 2     | `7c`   | read  |  |
| 3     | `7d`   | read  |  |
| 4     | `9a`   | read  |  |
| 5     | `9b`   | read  |  |
| 6     | `9c`   | read  |  |
| 7     | `9d`   | read  |  |
| 8     | `7a`   | write | 13m |
| 9     | `7b`   | write | 20m |

## Topology

Most figures use 2 machines; figure `9d` additionally uses `creek1` as the nginx
client. `stream5` is the one you log in to and run from; it drives the others
over SSH (set up by `deploy.sh`).

| role   | machine              | does                                         |
|--------|----------------------|----------------------------------------------|
| host   | `stream5` (run here) | NVMe/TCP initiator (+ nginx server for `9d`) |
| target | `rapids0`            | NVMe/TCP target, 4× Samsung 9100 PRO         |
| client | `creek1` (9d only)   | 4× parallel `wrk` load generator             |

## Notes

Please refer to the README in each figure's directory for its expected output and
estimated time.

If a figure's `all_in_one.sh` prints N/A or 0 values, or a machine becomes
unreachable / stuck, recover it and re-run:

1. Power-cycle the stuck machine over its BMC (credentials are not stored in the
   repo — pass them in the environment):

```bash
cd ~/zcIO/zcio-ae
BMC_HOST=<bmc-ip> BMC_USER=admin BMC_PASS=<announced> ./bmc-reset.sh
```

2. After about 10 minutes, log back in to `stream5` as `fast27`.

3. Go back to the figure's directory and run `./all_in_one.sh` again.
