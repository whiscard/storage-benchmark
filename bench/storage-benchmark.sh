#!/usr/bin/env bash
#
# storage-benchmark.sh -- one storage profile, the same on every machine, so that two
# virtual machines (or the same one before and after a change) can be compared.
#
# Run it AS ROOT on the machine being measured:
#
#     sudo bash bench/storage-benchmark.sh                 # about 12 minutes, needs 6 GB free
#     QUICK=1 sudo bash bench/storage-benchmark.sh         # 20 s per fio job (smoke test only)
#     DATADIR=/some/dir sudo bash bench/storage-benchmark.sh   # test another volume
#
# Everything it prints is also written to /var/tmp/storage-benchmark-<hostname>-<timestamp>.txt
# so you do not need to capture the screen. The raw fio JSON is kept under
# /root/storage-benchmark/<timestamp>/ for later analysis.
#
# What it measures:
#   pg_test_fsync   5 s per method, in a scratch directory on DATADIR, as the postgres user:
#                   how many times per second one 8 kB block can be written AND forced to
#                   durable storage (what a database does on every committed transaction)
#   fio, direct I/O (no page cache), one 4 GB file on the same volume, 60 s each:
#     rr8k_qd1        8 kB random read, one request at a time    -> per-request latency
#     rr8k_qd32       8 kB random read, 32 requests in flight    -> IOPS ceiling
#     rw8k_fsync_qd1  8 kB random write + fsync after each write -> write-ahead-log pattern
#     seqread_1m      1 MB sequential read, 8 in flight          -> backup / restore read side
#     seqwrite_1m     1 MB sequential write, 8 in flight         -> restore / bulk-load write side
#
# Needs: fio (installed with apt if missing), and pg_test_fsync, which comes with the
# PostgreSQL server package (postgresql-16 on Ubuntu). If pg_test_fsync is absent that part is
# skipped and the fio part still runs.
#
# Safety: refuses with less than 6 GB free on the volume; prints the load average before and
# after so a result taken while something else was busy can be recognised; the scratch
# directory is removed at the end (also on interrupt). Nothing touches an existing database.
# Do not run it on a machine that is serving users: the write tests saturate the disk.
set -u
set -o pipefail

RUNTIME="${RUNTIME:-60}"; [ "${QUICK:-}" = 1 ] && RUNTIME=20
SIZE="${SIZE:-4G}"
DATADIR="${DATADIR:-/var/lib/postgresql}"
[ -d "$DATADIR" ] || DATADIR=/var/tmp
STAMP="$(date +%Y%m%d-%H%M%S)"
KEEP="/root/storage-benchmark/$STAMP"
JOBS="rr8k_qd1 rr8k_qd32 rw8k_fsync_qd1 seqread_1m seqwrite_1m"

die() { echo "FAILED: $*" >&2; exit 1; }
say() { echo; echo "== $*"; }

summarise() { # json-file job-name  -> one line
    python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); name = sys.argv[2]
j = d["jobs"][0]
def pct(sec, key):
    p = sec.get("clat_ns", {}).get("percentile", {})
    v = p.get(key)
    return "%.2f" % (v / 1e6) if v is not None else "-"
out = []
for kind in ("read", "write"):
    s = j.get(kind, {})
    if s.get("io_bytes", 0) == 0:
        continue
    out.append("%s: %.0f IOPS %.1f MB/s  lat p50 %s ms p99 %s ms mean %.2f ms" % (
        kind, s["iops"], s["bw_bytes"] / 1048576.0, pct(s, "50.000000"), pct(s, "99.000000"),
        s.get("clat_ns", {}).get("mean", 0) / 1e6))
sy = j.get("sync", {})
if sy.get("total_ios", 0):
    p = sy.get("lat_ns", {}).get("percentile", {})
    out.append("fsync: p50 %.2f ms p99 %.2f ms mean %.2f ms" % (
        p.get("50.000000", 0) / 1e6, p.get("99.000000", 0) / 1e6, sy.get("lat_ns", {}).get("mean", 0) / 1e6))
print("  %-16s %s" % (name, "   ".join(out) if out else "no I/O recorded"))
PY
}

[ "$(id -u)" = 0 ] || [ "${ALLOW_NONROOT:-}" = 1 ] || die "run as root: sudo bash $0"

OUT="${OUT:-/var/tmp/storage-benchmark-$(hostname)-$STAMP.txt}"
touch "$OUT" 2>/dev/null && chmod 0644 "$OUT" 2>/dev/null && exec > >(tee -a "$OUT") 2>&1

SCRATCH="$DATADIR/storage-benchmark.$$"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

# ---- context ---------------------------------------------------------------------
say "storage benchmark: $(hostname)  $(date '+%F %T %Z')"
echo "kernel: $(uname -r)   cpus: $(nproc)   mem: $(awk '/MemTotal/ {printf "%.1f G", $2/1048576}' /proc/meminfo)"
echo "scratch: $SCRATCH on $(df -hT "$DATADIR" | awk 'NR==2 {print $1" ("$2") "$4" free of "$3}')"
echo "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)   load before: $(cut -d' ' -f1-3 /proc/loadavg)"
free_k="$(df -k --output=avail "$DATADIR" | tail -1 | tr -d ' ')"
[ "$free_k" -ge 6291456 ] || die "only $((free_k/1024)) M free on $DATADIR -- need 6 G for the 4 G scratch file plus headroom"
if command -v psql >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    echo "postgres clusters: $(pg_lsclusters -h 2>/dev/null | awk '{printf "%s/%s %s %s; ", $1,$2,$4,$5}')"
fi

# ---- tools -----------------------------------------------------------------------
if ! command -v fio >/dev/null 2>&1; then
    if [ "$(id -u)" = 0 ]; then
        say "installing fio (apt)"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q fio >/dev/null || die "apt-get install fio"
    else die "fio not installed"; fi
fi
echo "fio: $(fio --version)"
PGTF="$(find /usr/lib/postgresql -path "*/bin/pg_test_fsync" 2>/dev/null | sort -V | tail -1)"
[ -n "$PGTF" ] && echo "pg_test_fsync: $PGTF" || echo "pg_test_fsync: not found (install the postgresql server package) -- skipped"

mkdir -p "$SCRATCH" "$KEEP" || die "mkdir scratch/keep"
chmod 0777 "$SCRATCH"

# ---- pg_test_fsync -----------------------------------------------------------------
if [ -n "$PGTF" ] && [ "$(id -u)" = 0 ] && id postgres >/dev/null 2>&1; then
    say "pg_test_fsync -s 5 (as postgres, file in $SCRATCH)"
    runuser -u postgres -- "$PGTF" -s 5 -f "$SCRATCH/pg_test_fsync.out" 2>&1 | tee "$KEEP/pg_test_fsync.txt" | grep -vE '^\s*$'
    rm -f "$SCRATCH/pg_test_fsync.out"
fi

# ---- fio -------------------------------------------------------------------------
fio_job() { # name -> extra args
    case "$1" in
        rr8k_qd1)       echo "--rw=randread  --bs=8k --iodepth=1" ;;
        rr8k_qd32)      echo "--rw=randread  --bs=8k --iodepth=32" ;;
        rw8k_fsync_qd1) echo "--rw=randwrite --bs=8k --iodepth=1 --fsync=1" ;;
        seqread_1m)     echo "--rw=read      --bs=1M --iodepth=8" ;;
        seqwrite_1m)    echo "--rw=write     --bs=1M --iodepth=8" ;;
        *) return 1 ;;
    esac
}

say "fio: $SIZE file, direct=1, libaio, ${RUNTIME}s per job (time based), group_reporting"
SUMMARY=""
for job in $JOBS; do
    extra="$(fio_job "$job")"
    echo "-- $job  $(date '+%T')"
    # shellcheck disable=SC2086  # $extra is a list of fio flags on purpose
    if fio --name="$job" --filename="$SCRATCH/fio.dat" --size="$SIZE" --direct=1 --ioengine=libaio \
           --numjobs=1 --time_based --runtime="$RUNTIME" --group_reporting --output-format=json \
           --output="$KEEP/$job.json" $extra >/dev/null 2>"$KEEP/$job.err"; then
        line="$(summarise "$KEEP/$job.json" "$job")" || line="  $job  (summary failed: see $KEEP/$job.json)"
    else
        line="  $job  FAILED: $(tail -1 "$KEEP/$job.err")"
    fi
    echo "$line"; SUMMARY="$SUMMARY$line
"
done

say "SUMMARY  $(hostname)  $(date '+%F %T %Z')  runtime ${RUNTIME}s  size $SIZE  on $DATADIR"
printf '%s' "$SUMMARY"
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)"
echo "raw results kept in $KEEP"
echo "this report written to $OUT"
rm -rf "$SCRATCH"
