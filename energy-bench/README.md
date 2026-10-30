# energy-bench

Measurement harness for the study *Energy and Performance of Virtual Threads Compared to Established
JVM Concurrency Constructs* (Liebeton & van Zanten). It measures energy (Intel RAPL via Linux powercap)
and execution time of virtual threads, explicit threads, a fixed thread pool and Fork/Join.
Everything runs from the shell: plain Java without a build tool, plus a few bash scripts.

```
build.sh                   compiles src/ into build/ (JDK 21+, the study used JDK 25)
config.env                 all parameters (iterations, tasks, launches, pause, JVM flags, seed)
src/bench/Bench.java       one JVM launch: one configuration, REPS repetitions, one CSV line per repetition
src/bench/Work.java        the task: CPU phase (A: arithmetic loop, B: build a string + hash, C: arithmetic loop) + blocking phase
src/bench/Runner.java      the four constructs: explicit, pool, fj, vt
src/bench/Rapl.java        reads RAPL from /sys/class/powercap, including wrap-around correction
src/bench/EchoServer.java  local server for benchmark C (replies after t_block)
src/bench/Calib.java       pilot helper: RAPL check, iteration calibration, sleep/socket accuracy
src/bench/Plan.java        builds the shuffled launch list (fixed seed)
scripts/run.sh             runs a launch list; resumes by itself after a crash or reboot
scripts/pilot.sh           pilot steps p1 to p5
scripts/experiment.sh      main experiment: all at once, or per session
scripts/all.sh             the whole study unattended (pilots + main experiment) as a systemd service
scripts/profile.sh         JFR profiling runs for Table 8 (separate from the energy measurements)
scripts/precheck.sh        checks before a session (--fix turns turbo off, stops update timers, ...)
scripts/idle.sh            measures idle power
scripts/status.sh          shows progress during a run
scripts/estimate.sh        machine-time estimate for the main experiment, from measured durations
scripts/setup-once.sh      one-time settings (no suspend, sysctls, pin the JDK version)
scripts/restore.sh         afterwards: undo all system changes (original values are in /var/lib/energy-bench)
scripts/machine_state.sh   machine state for the record (stored with every run)
scripts/server-info.sh     hardware/software summary of the machine (results/environment/server-info.txt)
```

## 1. Install on the measurement machine (once)

The machine must be bare metal with an Intel CPU that exposes RAPL through powercap. The study used an
Intel Core i7-9700 (8 cores, no hyper-threading), 16 GB RAM, Ubuntu 26.04.1 and OpenJDK 25.0.4.1.

```bash
git clone <repo-url> && cd <repo>/energy-bench
sudo apt install -y openjdk-25-jdk-headless
./build.sh
sudo ./scripts/setup-once.sh
sudo ./scripts/precheck.sh --fix
```

`precheck.sh` must end with `0 FAIL`. Read through the WARN lines; they are also stored in the log of every run.

## 2. Pilot

Start long steps detached from your SSH session, so a dropped connection does not stop the run:

```bash
sudo systemd-run --unit=pilot-p3 --working-directory="$PWD" ./scripts/pilot.sh p3
journalctl -fu pilot-p3                 # follow (Ctrl-C only stops following)
./scripts/status.sh results/pilot/p3    # short status
```

| Step | Command | Duration | Then |
| --- | --- | --- | --- |
| P1 instrument | `sudo ./scripts/pilot.sh p1` | ~10 min | Check `results/pilot/p1/rapl.txt`: is the DRAM domain called `dram`, does the counter increase, how often is it updated, when does it wrap? |
| P2 calibration | `sudo ./scripts/pilot.sh p2` | ~10 min | Put `ITERS_A` and `ITERS_B` in `config.env`. Check `b_effective` per construct in `blocking.csv`. |
| P3 smoke test | `sudo ./scripts/pilot.sh p3` | ~2 h | `results/pilot/p3/estimate.txt`: machine time per option, runs < 2 s, checksum errors. `failures.csv` must be empty. |
| P4 variance | `sudo ./scripts/pilot.sh p4` | ~8–10 h | `results/pilot/p4/results.csv`: warm-up curve (energy/time per `rep`), CV between launches, temperature per repetition. |
| P5 JFR | `sudo ./scripts/pilot.sh p5` | ~15 min | `.jfr` files plus counts of pinning, park and GC events; run time with and without JFR in `results.csv`. |

Commit `config.env` after P2, so the values used are in git.

## 3. Main experiment

Two ways, with the same configurations and the same seed:

```bash
# everything in one shuffled list  -> results/main-all   (this is what the paper used)
sudo systemd-run --unit=exp --working-directory="$PWD" ./scripts/experiment.sh all

# or per session: session k = launch k of every configuration  -> results/main-s01 ... main-s10
sudo systemd-run --unit=exp-s1 --working-directory="$PWD" ./scripts/experiment.sh session 1
```

Override parameters without editing `config.env`:

```bash
sudo systemd-run --unit=exp --working-directory="$PWD" \
  --setenv=LAUNCHES=7 --setenv=WARMUP=5 --setenv=AXES_ONLY=B,C ./scripts/experiment.sh all
```

`AXES_ONLY=B,C` runs B and C only at C = 100 (all b, RQ2) and b = 0 (all C, RQ3); A still runs the full grid.

**Stopped?** (crash, power, reboot) Run the same command again. Launches in `done.txt` are skipped;
the rows of a half-finished launch go to `aborted_rows.csv` and that launch runs again.
If `config.env` changed in the meantime, the script refuses to resume (otherwise half the run would use other settings).
After a reboot turbo is on again: run `sudo ./scripts/precheck.sh --fix` first.

**During a run** do nothing heavy on the machine, not even an open `htop`. `status.sh` and `tail` are fine.

The full main experiment (2,400 launches) took about 3.5 days of machine time.

## 3b. Everything unattended (pilots + main experiment)

This is how the data in `results/` was produced.

```bash
sudo ./scripts/all.sh install          # options: --until p5 (stop before the main experiment), --at "2026-10-14 21:00 CEST"
exit                                   # log out and close VS Code
./scripts/all.sh status                # later: progress
```

Runs as a systemd service (`energy-bench`): no SSH needed, and after a reboot it continues (turbo off again,
finished steps are skipped). It first waits until nobody is logged in and the VS Code server has exited.
After p2 it writes `ITERS_A`/`ITERS_B` into `config.env` itself (stops on FAIL); after p3 it stops on failed launches;
after p4 nothing is decided automatically: the main experiment uses `LAUNCHES`/`REPS`/`WARMUP` from `config.env`.
At the end (or on an error) it runs `restore.sh` and disables itself.
Outcome in `results/all/FINISHED` or `results/all/FAILED`, log in `results/all/all.log`.

## 3c. Profiling (Table 8)

```bash
sudo ./scripts/profile.sh              # ~30 min -> results/profile/
```

One launch per construct for each of the five workloads in Table 8, with the JVM flags, `REPS` and `WARMUP`
of the main experiment and a JFR recording (`settings=profile`). Writes the recordings, a `jfr summary` per
recording, and `profile.csv` (thread starts, parks, pinned events, GCs, mean CPU load), which
`analysis/reproduce.py` turns into Table 8. Profiling is never combined with the energy measurements.

## 4. Output

Per run directory (`results/...`):

| File | Contents |
| --- | --- |
| `results.csv` | one line per repetition (warm-up included, with `is_warmup=1`) |
| `launches.csv` | per launch: exit code, start time, wall-clock duration |
| `failures.csv` | launches with a checksum error (rc 3), time-out (rc 124/137) or crash; absent if there were none |
| `idle.csv` | idle power: start, every 6 hours during long runs, end |
| `precheck_*.txt`, `machine_state_*.txt` | machine state at start and end |
| `plan.tsv`, `config.env`, `settings.log` | exactly what ran, in which order, with which settings |
| `bench.log`, `progress.log`, `echo_server.log`, `done.txt` | logs and the resume list |

Columns of `results.csv`:

`timestamp, session, launch_id, launch_no, benchmark, construct, b, C, threads, tasks, iters, tcpu_ns, tblock_ns, rep, is_warmup,
pkg_uj, dram_uj, time_ns, pkg_wrapped, dram_wrapped, checksum_ok, task_errors, gc_count, gc_ms, pkg_temp_c, rapl_pkg, rapl_dram, java_version`

- `pkg_uj`/`dram_uj`: energy of the measured run in microjoules (`-1` if there is no DRAM domain).
- `time_ns`: wall-clock time of the measured run (`System.nanoTime`).
- `threads`: platform workers: N for pool, min(C, N) for explicit, 8 for fj, 8 carriers for vt.
- `gc_count`, `gc_ms`, `pkg_temp_c`: read outside the measurement window, for explanation afterwards.

The harness averages nothing: one value per launch (the mean of the kept repetitions) is computed in the
analysis (`../analysis/`).

## 5. Design choices in the code

- **Measurement window:** read RAPL → `nanoTime` → all batches → `nanoTime` → read RAPL. JVM start-up, creating the executor, precomputing the checksum and writing the CSV fall outside it.
- **Same work:** task *i* uses seed *i* mod 64. The expected checksum of a run is computed before the measurements; every repetition is checked against it (`checksum_ok`).
- **Batches:** a batch of C tasks must be completely finished before the next one starts. Pool, fj and vt receive every task through `execute()` and wait on a `CountDownLatch`; explicit starts min(C, N) threads per batch that divide the tasks round-robin, and joins them.
- **Executors** are created once per launch, before the warm-up, and reused across repetitions.
- **Fork/Join:** a dedicated `ForkJoinPool(8)`, tasks through `execute()`, no `ManagedBlocker`.
- **Benchmark C:** a new TCP connection to 127.0.0.1 per task. The client closes with an RST (`SO_LINGER 0`), so 200,000 connections per launch leave no TIME_WAIT sockets. The server uses one virtual thread per connection and runs for the whole session (also during idle measurements), so its energy is included in all measurements.
- **b = 0:** the blocking phase is skipped (also in C).
- **Effective b:** `Thread.sleep` always sleeps somewhat longer than requested, and not necessarily by the same amount on a virtual thread as on a platform thread. P2 measures this on the machine (`results/pilot/p2/blocking.csv`); Section 7.6 of the paper uses it.
- **Benchmark B:** every string is hashed 4× with FNV-1a instead of one `String.hashCode()`. With a single hash, B allocated ~2.4 GB/s per core and the CPU phase on 8 threads was 2.3× slower than on 1 thread (cache/memory contention, not GC pauses); now it is ~360 MB/s per core and ~10% difference. `Calib k` reports FAIL if 8 threads are more than 10% slower than 1.
- **Pool size:** N = round(8 / (1 − b)) = 8, 11, 16, 32, 160.

## AI use

This harness was written with help from Claude (Anthropic). The assignment allows AI for scripts that
automate the experiment, provided it is listed in the appendix: tool, purpose, scope and which files.
