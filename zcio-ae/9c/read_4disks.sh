# read_4disks.sh  (CPU/THREADS parameterized + taskset removed)
#!/bin/bash
set -e

MODE="${1:-readrand}"          # readseq or readrand
NUM_OPS="${2:-100000}"        # Total operations
THREADS="${3:-512}"            # Total threads
BATCH_SIZE="${4:-512}"
NUM_RECORDS="${5:-1024}"     # Records per disk (must match make_4disks.sh)
CPU_LIST="${6:-}"              # e.g., "6,7,8,9" (optional)

DB_BASE="/mnt/rocksdb_test"

for i in 1 2 3 4; do
    if [ ! -L "$DB_BASE/testdb$i" ] && [ ! -d "$DB_BASE/testdb$i" ]; then
        echo "Error: Database not found at $DB_BASE/testdb$i"
        echo "Run ./make_4disks.sh first"
        exit 1
    fi
done

echo "=========================================="
echo "RocksDB Read Benchmark (4 Disks)"
echo "=========================================="
echo "DB Base: $DB_BASE"
echo "Read Mode: $MODE"
echo "Total Operations: $NUM_OPS"
echo "Threads: $THREADS"
echo "Batch Size: $BATCH_SIZE"
if [ -n "$CPU_LIST" ]; then
  echo "CPU List: $CPU_LIST"
fi
echo ""

ulimit -l unlimited

# If CPU_LIST is given, pin the app to those cpus (taskset) instead of relying on
# offlined cores — lets the kernel I/O path run on all cores while compute is 1 core.
TASKSET=""
[ -n "$CPU_LIST" ] && TASKSET="taskset -c $CPU_LIST"
sudo $TASKSET time ${ROCKSDB_BIN:-/opt/rocksdb-env/custom_rocksdb} \
  --db "$DB_BASE" \
  --mode "$MODE" \
  --num "$NUM_RECORDS" \
  --ops "$NUM_OPS" \
  --num_disks 4 \
  --threads "$THREADS" \
  --batch_n "$BATCH_SIZE" \
  --fill_cache 0 \
  --direct_reads 1
