#!/bin/bash
# unmount_4disk.sh — unmount the 4 NVMe/TCP data filesystems (best-effort, lazy).
# 9a/9b/9c only ever use 4 disks (testdb1..4). No `rm -rf` here: mount_4disk.sh
# re-mkfs's the disks on the next mount, and the datagen scripts recreate their
# own merge dir, so wiping /mnt/rocksdb_test/* is both unnecessary and unsafe
# (it would recurse into a still-mounted fs).
for n in 1 2 3 4; do
    mountpoint -q "/mnt/rocksdb_test/testdb$n" 2>/dev/null || continue
    sudo umount "/mnt/rocksdb_test/testdb$n" 2>/dev/null \
        || sudo umount -l "/mnt/rocksdb_test/testdb$n" 2>/dev/null || true
done
