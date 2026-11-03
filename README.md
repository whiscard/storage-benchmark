# Storage benchmark

A small, repeatable test of how fast a server's disk is for database work, and a way to
compare two machines side by side (or one machine before and after a change).

Banda Health built it to compare the virtual machines of two hosting providers and an
on-premises server. The results of our own runs are included under `results/`, so anyone who
runs the test on another machine can compare their numbers with ours in one command.

No experience with Git or GitHub is needed. Follow the steps in order.

## What the test does

Two standard, freely available tools are run with fixed settings:

- **pg_test_fsync** (part of PostgreSQL) writes one 8 kB block and forces it to durable storage,
  over and over, for 5 seconds per method. The result is "how many confirmed writes per second"
  this disk can do. A database does exactly this for every committed transaction, so this
  number sets the ceiling on how many saves per second the database can confirm.
- **fio** (the standard disk benchmark on Linux) runs five jobs of 60 seconds each on a 4 GB
  file, bypassing the operating system's cache:

| job | what it does | what it tells you |
|---|---|---|
| `rr8k_qd1` | 8 kB random reads, one at a time | how long one small read takes (latency) |
| `rr8k_qd32` | 8 kB random reads, 32 at a time | how many reads per second the disk can serve under load |
| `rw8k_fsync_qd1` | 8 kB random writes, each followed by fsync | the database write-ahead-log pattern |
| `seqread_1m` | 1 MB sequential reads, 8 at a time | backup / large copy read speed |
| `seqwrite_1m` | 1 MB sequential writes, 8 at a time | restore / large copy write speed |

The whole run takes about 12 minutes, uses 4 GB of scratch space that is deleted afterwards,
and does not touch any existing data. Do not run it on a machine that is serving users: the
write tests load the disk fully while they run.

## Step 1: a test machine

Create a virtual machine that matches the one you want to compare with. For a like-for-like
comparison with our `db2server` result, use:

- Ubuntu 24.04 LTS (22.04 also works)
- 4 vCPU, 8 GB RAM
- a disk of at least 50 GB on the storage you want to measure (ours is 311 GB)
- outbound internet access, for the package installs below

Log in to it as a user who can run `sudo`.

## Step 2: install the tools

```bash
sudo apt-get update
sudo apt-get install -y git fio postgresql-16 python3
```

`postgresql-16` is needed only for its `pg_test_fsync` program. It also starts an empty
database service, which is harmless; if you prefer, `sudo systemctl disable --now postgresql`
afterwards. On Ubuntu 22.04 the package is `postgresql-14`.

## Step 3: get the files

Option A, with git:

```bash
git clone https://github.com/whiscard/storage-benchmark.git
cd storage-benchmark
```

Option B, without git: on https://github.com/whiscard/storage-benchmark click the green
**Code** button, choose **Download ZIP**, copy the ZIP to the test machine and run
`unzip storage-benchmark-main.zip && cd storage-benchmark-main`.

## Step 4: run the benchmark

```bash
sudo bash bench/storage-benchmark.sh
```

It prints what it is doing and finishes with a block that starts `== SUMMARY`. Everything it
printed is also saved to `/var/tmp/storage-benchmark-<hostname>-<date>.txt` (the last line of
the output tells you the exact name), and the raw fio output is kept under
`/root/storage-benchmark/<date>/`.

If the machine has less than 6 GB free on `/var/lib/postgresql` the script stops and says so.
To test a different volume: `DATADIR=/mnt/somewhere sudo bash bench/storage-benchmark.sh`.

## Step 5: compare with our results

```bash
python3 bench/compare.py results/2026-11-02/*.txt /var/tmp/storage-benchmark-*.txt
```

This prints two tables, one column per machine: the context of each run (kernel, CPUs, RAM,
volume, load before and after), then the measurements, and finally a pass/fail line per
column against the three targets we need for a database server:

| target | why |
|---|---|
| pg_test_fsync fdatasync >= 600 confirmed writes per second | about half of what our current production host does; below this the application queues on every save |
| 8 kB random read, p99 latency <= 3 ms | a single slow read should not be noticeable to a user |
| 1 MB sequential write >= 100 MB/s | so that a 20 GB restore or standby rebuild takes minutes, not hours |

You can paste the output into an e-mail or a ticket as it is.

## Step 6: measure again after a change

Keep the first result file as the baseline. After changing something on the storage side
(moving the VM to another storage tier, changing a limit, and so on), run Step 4 again and
compare the two files:

```bash
python3 bench/compare.py /var/tmp/storage-benchmark-*.txt
```

The same machine appears twice, in the order the runs were made, so the improvement (or not)
is visible per metric. Run each measurement at a quiet time and check that the "load before"
values are low; a run taken while something else was busy is not comparable.

## Reading the numbers

- **IOPS**: input/output operations per second, how many separate reads or writes the disk
  completes each second. Higher is better.
- **MB/s**: megabytes per second, the throughput for large transfers. Higher is better.
- **Latency**: how long one operation takes, in milliseconds. Lower is better.
- **p50 / p99**: the median and the 99th percentile. p50 is the typical operation; p99 is the
  slowest one in a hundred. A low p50 with a high p99 means the disk is usually fine but
  sometimes stalls, which users feel as random freezes.
- **Queue depth (qd)**: how many operations are in flight at once. qd1 shows the raw latency
  of the path to the disk; qd32 shows how much the disk can do in parallel.
- **Random vs sequential**: random means small reads/writes scattered over the file, as a
  database does; sequential means one long stream, as a backup does.
- **fsync / fdatasync**: the system call that forces written data from caches to permanent
  storage and returns only when that is done. The time it takes is the time a database makes
  a user wait for a confirmed save.

## Our reference results (2 November 2026)

Four machines, all idle, all running Ubuntu with PostgreSQL 16 and the test inside the
PostgreSQL data directory. Full files in `results/2026-11-02/`, raw fio JSON in
`results/2026-11-02/raw/`.

| metric | db1server (Seacom VM, 16 vCPU / 31 GB) | db2server (Seacom VM, 4 vCPU / 8 GB) | BandaGODB2 (DigitalOcean VM, 4 vCPU / 8 GB) | biserver (office server, 20 vCPU / 41 GB) |
|---|---|---|---|---|
| pg_test_fsync fdatasync (confirmed writes/s) | 79 | 30 | 1,252 | 244 |
| 8 kB random read qd1: IOPS | 2,473 | 1,970 | 5,774 | 3,909 |
| 8 kB random read qd1: p50 / p99 latency (ms) | 0.35 / 1.29 | 0.36 / 1.47 | 0.14 / 0.42 | 0.18 / 0.51 |
| 8 kB random read qd32: IOPS | 12,799 | 25,650 | 77,454 | 44,662 |
| 8 kB random write + fsync qd1: IOPS | 54 | 26 | 1,520 | 80 |
| 8 kB random write + fsync qd1: fsync p50 / p99 (ms) | 3.8 / 320.9 | 28.7 / 246.4 | ~0 / ~0 | 12.3 / 16.9 |
| 1 MB sequential read (MB/s) | 288 | 128 | 4,250 | 384 |
| 1 MB sequential write (MB/s) | 25 | 14 | 816 | 167 |

The file names say `INF-745` in their first line: that is our internal ticket number for this
work, nothing more.

## Restart time

`bench/boot-timeline.sh` is a second, independent check: how long a machine takes to be back
in service after a restart. It reads the system journal, so it needs no preparation, and it
prints one line per restart still in the journal (seconds until the network, SSH, Docker,
PostgreSQL or Apache were up, and how many services timed out while starting) plus the
slowest units of the current boot.

```bash
sudo bash bench/boot-timeline.sh
```

To measure a restart: note the time, restart the VM from your management console, wait until
you can log in again, and run the script. The `gap_before` value on the last line is how long
the machine was away; the `startup-finished` value is how long the operating system needed
after it was powered on.

## Files

| path | what |
|---|---|
| `bench/storage-benchmark.sh` | the benchmark; run as root |
| `bench/compare.py` | puts result files side by side and checks the targets |
| `bench/boot-timeline.sh` | restart / recovery timeline from the system journal |
| `results/2026-11-02/*.txt` | our four reference runs, as the script printed them |
| `results/2026-11-02/raw/<machine>/` | the raw fio JSON and pg_test_fsync output behind them |

## Licence

MIT, see `LICENSE`. The tools used (fio, pg_test_fsync) are the standard packages of their
distributions.
