"""Section 7.2 (RQ1): baseline b = 0, C = 100. Table 4, Figure 1, Kruskal-Wallis and
pairwise Mann-Whitney U tests against virtual threads (Holm-corrected)."""
import matplotlib.pyplot as plt
import pandas as pd
from scipy import stats

from common import (BASELINE, BENCHMARKS, COLOR, CONSTRUCTS, LABEL, OTHERS, fmt_p, holm, launches,
                    md_table, out_path, save_fig)

METRICS = [("energy_per_task_mj", "Energy per task (mJ)"), ("time_s", "Execution time (s)")]


def run():
    df = launches()
    base = df[(df.b == BASELINE[0]) & (df.C == BASELINE[1])]
    groups = {(bm, c): base[(base.benchmark == bm) & (base.construct == c)] for bm in BENCHMARKS for c in CONSTRUCTS}

    lines = ["## 7.2 RQ1: baseline comparison (b = 0, C = 100)", ""]
    pairwise = {}
    for col, name in METRICS:
        # Kruskal-Wallis per benchmark, Holm over the three benchmarks
        kw = [stats.kruskal(*[groups[(bm, c)][col] for c in CONSTRUCTS]) for bm in BENCHMARKS]
        kw_p = holm([r.pvalue for r in kw])
        lines.append(f"Kruskal-Wallis, {name}: " + "; ".join(
            f"{bm}: H = {r.statistic:.1f}, p_Holm = {fmt_p(p)}" for bm, r, p in zip(BENCHMARKS, kw, kw_p)))
        # Mann-Whitney U, virtual threads vs each other construct, Holm over the 9 tests per metric
        keys = [(bm, c) for bm in BENCHMARKS for c in OTHERS]
        raw = [stats.mannwhitneyu(groups[k][col], groups[(k[0], "vt")][col], alternative="two-sided").pvalue
               for k in keys]
        pairwise[col] = dict(zip(keys, holm(raw)))
    lines.append("")

    rows, csv_rows = [], []
    for bm in BENCHMARKS:
        for c in CONSTRUCTS:
            row = [bm, LABEL[c]]
            rec = {"benchmark": bm, "construct": c}
            for col, _ in METRICS:
                x, vt = groups[(bm, c)][col], groups[(bm, "vt")][col]
                rel = (x.mean() / vt.mean() - 1) * 100
                row.append(f"{x.mean():.3f} ({x.std():.3f})")
                if c == "vt":
                    row += ["-", "-"]
                else:
                    row += [f"{rel:+.1f}%", f"{pairwise[col][(bm, c)]:.3f}"]
                rec |= {f"{col}_mean": x.mean(), f"{col}_sd": x.std(), f"{col}_vs_vt_pct": rel,
                        f"{col}_p_holm": pairwise[col].get((bm, c))}
            rows.append(row)
            csv_rows.append(rec)
    lines.append("**Table 4.** Baseline: mean (sd) over 10 launches; vs. VT in percent; p = Holm-corrected "
                 "Mann-Whitney U.")
    lines.append("")
    lines.append(md_table(["Bench.", "Construct", "Energy/task mJ", "vs. VT", "p", "Time s", "vs. VT", "p"], rows))
    lines.append("")
    pd.DataFrame(csv_rows).to_csv(out_path("tables/table4_baseline.csv"), index=False)

    figure1(groups)
    lines.append("Figure 1: `figures/fig1_baseline_boxplots.pdf`")
    return "\n".join(lines)


def figure1(groups):
    fig, axes = plt.subplots(2, 3, figsize=(10, 5.5), constrained_layout=True)
    for i, (col, name) in enumerate(METRICS):
        for j, bm in enumerate(BENCHMARKS):
            ax = axes[i, j]
            data = [groups[(bm, c)][col] for c in CONSTRUCTS]
            box = ax.boxplot(data, patch_artist=True, widths=0.6, medianprops={"color": "black"})
            for patch, c in zip(box["boxes"], CONSTRUCTS):
                patch.set_facecolor(COLOR[c])
                patch.set_alpha(0.8)
            ax.set_xticks(range(1, 5), [LABEL[c] for c in CONSTRUCTS])
            ax.grid(axis="y", color="#dddddd", linewidth=0.6)
            ax.set_axisbelow(True)
            if i == 0:
                ax.set_title(f"Benchmark {bm}")
            if j == 0:
                ax.set_ylabel(name)
    save_fig(fig, "fig1_baseline_boxplots")
    plt.close(fig)
