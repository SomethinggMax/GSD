# Energy and Performance of Virtual Threads Compared to Established JVM Concurrency Constructs

Replication package for the paper by Joost Liebeton and Max van Zanten (University of Twente).

We compare virtual threads with explicit multithreading, a fixed thread pool and the Fork/Join framework on
three synthetic server-side benchmarks, varying the blocking ratio b (0–0.95) and the concurrency level C
(10–10,000). Energy is measured with Intel RAPL (package + DRAM) on a bare-metal Intel Core i7-9700 with
turbo boost off; 240 configurations × 10 JVM launches × 10 repetitions (7 warm-up).

## Repository layout

```
energy-bench/                   measurement harness (Java + bash), see energy-bench/README.md
  src/bench/                    benchmarks, the four constructs, RAPL reader, echo server, calibration
  scripts/                      pilot, main experiment, unattended runner, profiling, machine checks
  config.env                    every experiment parameter, including the calibrated iteration counts
  results/
    main-all/                   raw data of the main experiment (2,400 launches), used for all results
    pilot/p1 ... p5/            pilot steps: RAPL checks, calibration, smoke test, variance, JFR trial
    all/                        log of the unattended run (pilots + main experiment)
    environment/                hardware and software of the measurement machine
analysis/                       regenerates the tables, figures and numbers of Section 7
  reproduce.py                  entry point
  output/                       generated: REPORT.md, tables/*.csv, figures/*.pdf|png
```

## Reproducing the analysis (any machine, ~15 s)

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r analysis/requirements.txt
python analysis/reproduce.py
```

This reads `energy-bench/results/main-all/results.csv` (one row per repetition) and writes
`analysis/output/REPORT.md` together with the CSV tables and figures.

| Paper | Produced by | Output |
| --- | --- | --- |
| 7.1 data quality, idle power, CV, Shapiro–Wilk | `analysis/data_quality.py` | REPORT.md, `tables/cv_per_configuration.csv` |
| 7.2, Table 4, Figure 1 (RQ1) | `analysis/rq1_baseline.py` | `tables/table4_baseline.csv`, `figures/fig1_baseline_boxplots.*` |
| 7.3–7.4, Tables 5 and 6, Figures 2 and 3 (RQ2, RQ3) | `analysis/rq2_rq3.py` | `tables/table5_*.csv`, `tables/table6_*.csv`, `figures/fig2_*`, `figures/fig3_*` |
| 7.5, Table 7, Figure 4 (RQ4), 8.3 (+10 W) | `analysis/rq4_rankings.py` | `tables/table7_winners.csv`, `tables/kendall_tau_per_workload.csv`, `figures/fig4_*` |
| 7.6 effective blocking ratio | `analysis/effective_b.py` | `tables/effective_b_comparison.csv` |
| 7.6, Table 8 (JFR) | `energy-bench/scripts/profile.sh` + `analysis/jfr_table.py` | `tables/table8_jfr.csv` |

Statistical methods: Kruskal–Wallis and two-sided Mann–Whitney U (virtual threads vs. each other construct)
for RQ1, an aligned rank transform (ART) ANOVA for the construct × b and construct × C interactions (RQ2,
RQ3) with partial η² from the parametric two-way ANOVA, and Kendall's τ per workload with a permutation
test on the mean τ (RQ4). p-values are Holm-corrected: per metric over the 3 benchmarks (Kruskal–Wallis),
over the 9 pairwise tests (Mann–Whitney), and over the 18 interaction tests of Table 6.

### Agreement with the paper

Every value in Tables 4–7 and the numbers in Sections 7.1–7.6 and 8.3 are reproduced exactly from the raw
data, with two notes:

- **RQ4 permutation test.** The analysis computes the *exact* one-sided permutation p-value of the mean
  Kendall's τ (0.056), which is 0.203. The paper reports p = 0.19 from a Monte-Carlo permutation test. The
  conclusion (H0₄ not rejected) is the same.
- **Table 8 (JFR).** The recordings behind Table 8 are not part of this repository. `scripts/profile.sh`
  recreates them on the measurement machine; until then, `reproduce.py` skips Table 8. The pilot JFR trial
  (`results/pilot/p5/`) is included.

## Re-running the measurements

This needs a dedicated bare-metal Linux machine with an Intel CPU that exposes RAPL through powercap,
and root access. See [`energy-bench/README.md`](energy-bench/README.md) for the full procedure. In short:

```bash
cd energy-bench
./build.sh                                  # JDK 21+ (the study used OpenJDK 25.0.4.1)
sudo ./scripts/setup-once.sh
sudo ./scripts/all.sh install               # precheck, pilots p1–p5, main experiment, restore (~4 days)
sudo ./scripts/profile.sh                   # JFR profiling runs for Table 8 (~30 min)
```

Before measuring, the pilot calibrates the CPU phase to about 1 ms on your machine (`ITERS_A`, `ITERS_B`
in `config.env`); the values in the repository (`377410`, `5996`) are those of the original machine. The
launch order is shuffled with the fixed seed in `config.env` (`SEED=20261008`), so the same plan is
generated again (`results/main-all/plan.tsv`).

To analyse a new run, point `RUN_DIR` in `analysis/common.py` at its results directory.

## Measurement environment

| | |
| --- | --- |
| CPU | Intel Core i7-9700, 8 cores, no hyper-threading, 3.0 GHz, turbo boost off |
| Memory | 16 GB |
| OS | Ubuntu 26.04.1 LTS, kernel 7.0.0-34, `intel_pstate` with the `powersave` governor |
| JDK | OpenJDK 25.0.4.1 (build 25.0.4.1+1-1-26.04.4-Ubuntu) |
| JVM flags | `-XX:+UseG1GC -Xms2g -Xmx2g -XX:+AlwaysPreTouch` |

Full records: `energy-bench/results/environment/server-info.txt` and the `machine_state_*.txt` /
`precheck_*.txt` files of each run.

## AI use

The harness and the analysis scripts were written with help from Claude (Anthropic).
