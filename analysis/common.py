"""Shared data loading and helpers for the analysis.

One observation per JVM launch: the mean of the kept (non-warm-up) repetitions, as in
Section 5.6 of the paper. Energy is RAPL package + DRAM.
"""
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RUN_DIR = ROOT / "energy-bench" / "results" / "main-all"
PILOT_DIR = ROOT / "energy-bench" / "results" / "pilot"
OUT = Path(__file__).resolve().parent / "output"

BENCHMARKS = ["A", "B", "C"]
CONSTRUCTS = ["explicit", "pool", "fj", "vt"]
OTHERS = ["explicit", "pool", "fj"]  # compared against virtual threads
LABEL = {"explicit": "Explicit", "pool": "Pool", "fj": "Fork/Join", "vt": "Virtual"}
SHORT = {"explicit": "Exp.", "pool": "Pool", "fj": "FJ", "vt": "VT"}
B_LEVELS = [0.0, 0.25, 0.5, 0.75, 0.95]
C_LEVELS = [10, 100, 1000, 10000]
BASELINE = (0.0, 100)
TASKS = 20000

# Categorical slots 1-4 of the reference palette (fixed order) plus a marker per construct,
# so identity never depends on colour alone.
COLOR = {"explicit": "#eb6834", "pool": "#1baf7a", "fj": "#eda100", "vt": "#2a78d6"}
MARKER = {"explicit": "s", "pool": "^", "fj": "D", "vt": "o"}


def load_reps(run_dir=RUN_DIR):
    """All repetitions of the run, as written by bench.Bench."""
    return pd.read_csv(run_dir / "results.csv")


def idle_power(run_dir=RUN_DIR):
    """Idle power (W) measured before the session: mean of the 'start' windows."""
    idle = pd.read_csv(run_dir / "idle.csv")
    start = idle[idle.phase == "start"]
    return float(start.pkg_w.mean()), float(start.dram_w.mean())


def launches(run_dir=RUN_DIR):
    """One row per JVM launch with every metric of Table 1 (M1-M5)."""
    reps = load_reps(run_dir)
    kept = reps[reps.is_warmup == 0].copy()
    kept["pkg_j"] = kept.pkg_uj / 1e6
    kept["dram_j"] = kept.dram_uj / 1e6
    kept["time_s"] = kept.time_ns / 1e9
    keys = ["benchmark", "construct", "b", "C", "launch_no"]
    df = kept.groupby(keys, as_index=False).agg(
        pkg_j=("pkg_j", "mean"), dram_j=("dram_j", "mean"), time_s=("time_s", "mean"),
        tasks=("tasks", "first"), threads=("threads", "first"), n_reps=("rep", "size"),
        checksum_ok=("checksum_ok", "min"), task_errors=("task_errors", "sum"))
    idle_pkg, idle_dram = idle_power(run_dir)
    df["energy_j"] = df.pkg_j + df.dram_j                                  # M1
    df["energy_per_task_mj"] = df.energy_j / df.tasks * 1e3                # M2
    df["idle_j"] = (idle_pkg + idle_dram) * df.time_s
    df["energy_noidle_j"] = df.energy_j - df.idle_j
    df["energy_per_task_noidle_mj"] = df.energy_noidle_j / df.tasks * 1e3  # M2, idle removed
    df["throughput"] = df.tasks / df.time_s                                # M4
    df["edp"] = df.energy_j * df.time_s                                    # M5
    df["power_w"] = df.energy_j / df.time_s
    return df


def config_means(df):
    """Mean over the launches of each configuration (benchmark, construct, b, C)."""
    return df.groupby(["benchmark", "construct", "b", "C"]).mean(numeric_only=True)


def workloads():
    """The 60 workloads: (benchmark, b, C)."""
    return [(bm, b, c) for bm in BENCHMARKS for b in B_LEVELS for c in C_LEVELS]


def holm(p):
    """Holm-Bonferroni adjusted p-values (same order as the input)."""
    p = np.asarray(p, dtype=float)
    order = np.argsort(p)
    m = len(p)
    adj = np.empty(m)
    running = 0.0
    for rank, i in enumerate(order):
        running = max(running, (m - rank) * p[i])
        adj[i] = min(1.0, running)
    return adj


def fmt_p(p):
    return "<0.001" if p < 0.001 else f"{p:.3f}"


def pct(x):
    """Signed percentage, rounded like the paper ('+3', '-1', '-0' for small negatives)."""
    r = round(x)
    if r == 0 and x < 0:
        return "-0"
    return f"{r:+d}"


def md_table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(lines)


def out_path(rel):
    """Path under analysis/output/, creating the directory."""
    p = OUT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def save_fig(fig, name):
    """Save a figure as PDF (for the paper) and PNG (for viewing on GitHub)."""
    for ext in ("pdf", "png"):
        fig.savefig(out_path(f"figures/{name}.{ext}"), bbox_inches="tight", dpi=200)
