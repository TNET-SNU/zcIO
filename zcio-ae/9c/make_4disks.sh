# make_4disks.sh  (original preserved + only the final du output bug fixed)
#!/bin/bash
set -e

ulimit -n 1048576

VALUE_SIZE="${1:-65536}"    # 128KB default
THREADS="${2:-4}"
BATCH_SIZE="${3:-1}"
NUM_RECORDS="${4:-4096}"

echo "=========================================="
echo "Creating RocksDB on 4 Disks"
echo "=========================================="
echo "Disk 1: /mnt/rocksdb_test/testdb1"
echo "Disk 2: /mnt/rocksdb_test/testdb2"
echo "Disk 3: /mnt/rocksdb_test/testdb3"
echo "Disk 4: /mnt/rocksdb_test/testdb4"
echo ""
echo "Number of Records per Disk: $NUM_RECORDS"
echo "Total Records: $((NUM_RECORDS * 4))"
echo "Value Size: $VALUE_SIZE bytes ($(($VALUE_SIZE / 1024))KB)"
echo "Batch Size: $BATCH_SIZE"
echo "Threads: $THREADS"
echo ""

for i in 1 2 3 4; do
    if [ ! -d "/mnt/rocksdb_test/testdb$i" ]; then
        echo "Error: /mnt/rocksdb_test/testdb$i not mounted!"
        echo "Please mount the disk first:"
        echo "  sudo mount /dev/nvme0n$i /mnt/rocksdb_test/testdb$i"
        exit 1
    fi
done

DB_BASE="/mnt/rocksdb_test"
echo "Cleaning existing data..."
for i in 1 2 3 4; do
    if [ -d "$DB_BASE/testdb$i" ]; then
        sudo rm -rf "$DB_BASE/testdb$i"/*
        sudo chown -R $USER:$USER "$DB_BASE/testdb$i"
        echo "Cleaned $DB_BASE/testdb$i"
    fi
done
echo ""

echo "Starting database fill..."
echo "NOTE: Direct I/O enabled"
echo ""
time ${ROCKSDB_BIN:-/opt/rocksdb-env/custom_rocksdb} \
  --db "$DB_BASE" \
  --mode fill \
  --num "$NUM_RECORDS" \
  --num_disks 4 \
  --threads "$THREADS" \
  --value_size "$VALUE_SIZE" \
  --batch_n "$BATCH_SIZE" \
  --disable_wal 1 \
  --direct_reads 1 

echo ""
echo "=========================================="
echo "Database creation complete!"
echo "=========================================="
echo ""
echo "Database locations:"
for i in 1 2 3 4; do
    size=$(sudo du -sh "$DB_BASE/testdb$i" 2>/dev/null | cut -f1 || echo "N/A")
    echo "  Disk $i (testdb$i): $size"
done
