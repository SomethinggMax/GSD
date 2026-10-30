"""Section 7.1: data quality, idle power, variation between launches, normality checks."""
import pandas as pd
from scipy import stats

from common import (BENCHMARKS, RUN_DIR, config_means, idle_power, launches, load_reps, md_table,
                    out_path)

METRICS = {"energy": "energy_per_task_mj", "time": "time_s"}


def residual_normality(df):
    """Shapiro-Wilk on the residuals (launch minus the mean of its group) per analysis."""
    analyses = {
        "RQ1 (b=0, C=100)": (df[(df.b == 0) & (df.C == 100)], ["construct"]),
        "RQ2 (C=100, all b)": (df[df.C == 100], ["construct", "b"]),
        "RQ3 (b=0, all C)": (df[df.b == 0], ["construct", "C"]),
    }
    rows = []
    for name, (sub, groups) in analyses.items():
        for bm in BENCHMARKS:
            x = sub[sub.benchmark == bm]
            row = [name, bm]
            for col in METRICS.values():
                resid = x[col] - x.groupby(groups)[col].transform("mean")
                row.append(f"{stats.shapiro(resid).pvalue:.2f}")
            rows.append(row)
    return rows


def run():
    reps = load_reps()
    launch_log = pd.read_csv(RUN_DIR / "launches.csv")
    df = launches()
    means = config_means(df)
    groups = df.groupby(["benchmark", "construct", "b", "C"])
    cv = groups[["energy_j", "time_s"]].std() / groups[["energy_j", "time_s"]].mean() * 100
    idle_pkg, idle_dram = idle_power()
    share = means.idle_j / means.energy_j * 100
    worst = share.idxmax()
    failures = (RUN_DIR / "failures.csv")

    lines = ["## 7.1 Data quality", ""]
    lines.append(f"- JVM launches: {len(launch_log)} in launches.csv, {len(df)} with results "
                 f"({df.groupby(['benchmark', 'construct', 'b', 'C']).ngroups} configurations); "
                 f"non-zero exit codes: {(launch_log.exit_code != 0).sum()}; "
                 f"failures.csv present: {failures.exists()}")
    lines.append(f"- Checksum errors: {(reps.checksum_ok != 1).sum()}; task errors: {reps.task_errors.sum()}; "
                 f"kept repetitions per launch: {', '.join(map(str, sorted(df.n_reps.unique())))}")
    lines.append(f"- RAPL counter wraps corrected (all repetitions): {int(reps.pkg_wrapped.sum() + reps.dram_wrapped.sum())}")
    lines.append(f"- Idle power before the session: package {idle_pkg:.2f} W, DRAM {idle_dram:.2f} W, "
                 f"total {idle_pkg + idle_dram:.2f} W")
    lines.append(f"- Idle energy share of measured energy: median {share.median():.0f}% over "
                 f"{len(share)} configurations, max {share.max():.0f}% at {worst[0]}, {worst[1]}, "
                 f"b = {worst[2]:g}, C = {worst[3]:,}")
    lines.append(f"- CV between launches: median {cv.energy_j.median():.1f}% (energy), "
                 f"{cv.time_s.median():.1f}% (time); > 10% in {(cv.energy_j > 10).sum()} configurations "
                 f"for energy and {(cv.time_s > 10).sum()} for time")
    high = cv[(cv.energy_j > 10) | (cv.time_s > 10)].reset_index()
    lines.append(f"  - of those, at C <= 100: {(high.C <= 100).sum()} of {len(high)}; by construct: "
                 f"{_counts(high.construct)}; by b: {_counts(high.b)}")
    lines += ["", "Shapiro-Wilk p-values of the residuals (launch minus group mean):", "",
              md_table(["Analysis", "Bench.", "Energy/task", "Time"], residual_normality(df)), ""]

    cv.round(2).to_csv(out_path("tables/cv_per_configuration.csv"))
    means.to_csv(out_path("tables/configuration_means.csv"))
    df.to_csv(out_path("tables/launches.csv"), index=False)
    return "\n".join(lines)



def _counts(col):
    return ", ".join(f"{k}: {v}" for k, v in col.value_counts().sort_index().items())
