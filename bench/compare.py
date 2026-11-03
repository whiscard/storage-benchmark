#!/usr/bin/env python3
"""Put several storage-benchmark result files side by side.

    python3 bench/compare.py results/2026-11-02/*.txt /var/tmp/storage-benchmark-*.txt

Arguments are result files written by bench/storage-benchmark.sh, or directories containing
them. One column per file (named after the machine, plus a suffix when the same machine appears
more than once, e.g. before and after a change), one row per metric. Nothing is run: this only
reads the files. The output is Markdown, which also reads fine as plain text.
"""
import glob
import os
import re
import sys

JOBS = ["rr8k_qd1", "rr8k_qd32", "rw8k_fsync_qd1", "seqread_1m", "seqwrite_1m"]
NUM = r"([0-9]+(?:\.[0-9]+)?)"

# What a database server needs from its disk (the floor we aim for, not a luxury).
TARGETS = [
    ("pg_test_fsync fdatasync (commits/s)", "pgtf_fdatasync", ">=", 600.0),
    ("8k random read qd1 p99 latency (ms)", ("rr8k_qd1", "read", "p99"), "<=", 3.0),
    ("1 MB sequential write (MB/s)", ("seqwrite_1m", "write", "mbs"), ">=", 100.0),
]


def parse(path):
    txt = open(path, errors="replace").read()
    h = {"file": path}
    m = re.search(r"== (?:INF-745 )?storage benchmark: (\S+)\s+(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \S+)", txt)
    if not m:
        return None
    h["host"], h["date"] = m.group(1), m.group(2)
    for key, rx in (("kernel", r"kernel: (\S+)"), ("cpus", r"cpus: (\d+)"), ("mem", r"mem: ([\d.]+ G)"),
                    ("scratch", r"scratch: \S+ on (.+)"), ("virt", r"virt: (\S+)"),
                    ("load_before", r"load before: ([\d. ]+)"), ("load_after", r"load after: ([\d. ]+)"),
                    ("fio", r"fio: (fio-\S+)"), ("runtime", r"runtime (\d+)s"), ("size", r"size (\S+)")):
        mm = re.search(rx, txt)
        h[key] = mm.group(1).strip() if mm else "-"
    for key in ("open_datasync", "fdatasync", "fsync"):   # first block of pg_test_fsync = one 8 kB write
        mm = re.search(r"^\s+%s\s+%s ops/sec" % (key, NUM), txt, re.M)
        h["pgtf_" + key] = mm.group(1) if mm else "-"
    summ = txt.split("== SUMMARY", 1)
    block = summ[1] if len(summ) == 2 else txt
    for job in JOBS:
        mm = re.search(r"^\s+%s\s+(.*)$" % re.escape(job), block, re.M)
        line = mm.group(1) if mm else ""
        d = {}
        for kind in ("read", "write"):
            k = re.search(kind + r": " + NUM + r" IOPS " + NUM + r" MB/s\s+lat p50 (\S+) ms p99 (\S+) ms mean " + NUM + " ms", line)
            if k:
                d[kind] = dict(iops=k.group(1), mbs=k.group(2), p50=k.group(3), p99=k.group(4), mean=k.group(5))
        k = re.search(r"fsync: p50 " + NUM + r" ms p99 " + NUM + r" ms mean " + NUM + " ms", line)
        if k:
            d["fsync"] = dict(p50=k.group(1), p99=k.group(2), mean=k.group(3))
        if "FAILED" in line:
            d["failed"] = line
        h[job] = d
    return h


def value(h, key):
    try:
        if isinstance(key, str):
            v = h[key]
        else:
            v = h[key[0]][key[1]][key[2]]
        return float(v)
    except (KeyError, TypeError, ValueError):
        return None


def expand(args):
    for a in args:
        if os.path.isdir(a):
            for p in sorted(glob.glob(os.path.join(a, "*.txt"))):
                yield p
        else:
            yield a


def main(args):
    if not args:
        sys.exit(__doc__)
    hosts = []
    seen = {}
    for p in expand(args):
        h = parse(p)
        if not h:
            print("skipped (not a result file): %s" % p, file=sys.stderr)
            continue
        name = h["host"]
        seen[name] = seen.get(name, 0) + 1
        if seen[name] > 1:
            name = "%s (%d)" % (name, seen[name])
        h["col"] = name
        hosts.append(h)
    if not hosts:
        sys.exit("no result files could be read")
    names = [h["col"] for h in hosts]

    def row(label, getter):
        cells = []
        for h in hosts:
            try:
                cells.append(getter(h) or "-")
            except (KeyError, TypeError):
                cells.append("-")
        print("| %s | %s |" % (label, " | ".join(cells)))

    print("## Storage benchmark -- %s" % ", ".join(names))
    print()
    print("| context | %s |" % " | ".join(names))
    print("|---|%s|" % "|".join("---" for _ in names))
    row("run (machine time)", lambda h: h["date"])
    row("file", lambda h: h["file"].rsplit("/", 1)[-1])
    row("kernel / vCPU / RAM", lambda h: "%s / %s / %s" % (h["kernel"], h["cpus"], h["mem"]))
    row("virtualisation", lambda h: h["virt"])
    row("volume tested", lambda h: h["scratch"])
    row("fio / runtime / size", lambda h: "%s / %ss / %s" % (h["fio"], h["runtime"], h["size"]))
    row("load before -> after", lambda h: "%s -> %s" % (h["load_before"], h["load_after"]))
    print()
    print("| metric (higher is better unless it says latency) | %s |" % " | ".join(names))
    print("|---|%s|" % "|".join("---" for _ in names))
    row("pg_test_fsync fdatasync (commits/s)", lambda h: h["pgtf_fdatasync"])
    row("pg_test_fsync open_datasync (commits/s)", lambda h: h["pgtf_open_datasync"])
    row("8k random read qd1: IOPS", lambda h: h["rr8k_qd1"]["read"]["iops"])
    row("8k random read qd1: latency p50 / p99 (ms)", lambda h: "%s / %s" % (h["rr8k_qd1"]["read"]["p50"], h["rr8k_qd1"]["read"]["p99"]))
    row("8k random read qd32: IOPS", lambda h: h["rr8k_qd32"]["read"]["iops"])
    row("8k random read qd32: latency p99 (ms)", lambda h: h["rr8k_qd32"]["read"]["p99"])
    row("8k random write + fsync qd1: IOPS", lambda h: h["rw8k_fsync_qd1"]["write"]["iops"])
    row("8k random write + fsync qd1: write latency p99 (ms)", lambda h: h["rw8k_fsync_qd1"]["write"]["p99"])
    row("8k random write + fsync qd1: fsync time p50 / p99 (ms)", lambda h: "%s / %s" % (h["rw8k_fsync_qd1"]["fsync"]["p50"], h["rw8k_fsync_qd1"]["fsync"]["p99"]))
    row("1 MB sequential read: MB/s", lambda h: h["seqread_1m"]["read"]["mbs"])
    row("1 MB sequential write: MB/s", lambda h: h["seqwrite_1m"]["write"]["mbs"])
    failed = [(h["col"], j, h[j]["failed"]) for h in hosts for j in JOBS if "failed" in h.get(j, {})]
    if failed:
        print()
        print("Failed jobs:")
        for n, j, line in failed:
            print("- %s %s: %s" % (n, j, line))
    print()
    print("Targets for a database server (pass/fail per column):")
    print()
    print("| target | %s |" % " | ".join(names))
    print("|---|%s|" % "|".join("---" for _ in names))
    for label, key, op, limit in TARGETS:
        cells = []
        for h in hosts:
            v = value(h, key)
            if v is None:
                cells.append("-")
                continue
            ok = v >= limit if op == ">=" else v <= limit
            cells.append("%s %g" % ("PASS" if ok else "FAIL", v))
        print("| %s %s %g | %s |" % (label, op, limit, " | ".join(cells)))


if __name__ == "__main__":
    main(sys.argv[1:])
