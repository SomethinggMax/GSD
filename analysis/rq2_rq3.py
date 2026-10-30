"""Sections 7.3 (RQ2, blocking ratio) and 7.4 (RQ3, concurrency level): Table 5, Table 6,
Figures 2 and 3, and the numbers in the text (power, idle-subtracted energy)."""
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from common import (B_LEVELS, BENCHMARKS, C_LEVELS, COLOR, CONSTRUCTS, LABEL, MARKER, OTHERS, SHORT,
                    config_means, fmt_p, holm, launches, md_table, out_path, pct, save_fig, workloads)
from stats import art_interaction, interaction_anova

REGIMES = ["b = 0", "b > 0, C = 10", "b > 0, C = 100", "b > 0, C >= 1000"]
TEST_METRICS = [("energy_per_task_mj", "Energy/task"), ("time_s", "Time"), ("edp", "EDP")]


def regime(b, c):
    if b == 0:
        return REGIMES[0]
    return REGIMES[1] if c == 10 else REGIMES[2] if c == 100 else REGIMES[3]


def relative_differences(means):
    """Per workload and construct: difference with virtual threads in percent."""
    rows = []
    for bm, b, c in workloads():
        vt = means.loc[(bm, "vt", b, c)]
        for o in OTHERS:
            x = means.loc[(bm, o, b, c)]
            rows.append({"benchmark": bm, "b": b, "C": c, "regime": regime(b, c), "construct": o,
                         "energy": (x.energy_j / vt.energy_j - 1) * 100,
                         "energy_noidle": (x.energy_noidle_j / vt.energy_noidle_j - 1) * 100,
                         "time": (x.time_s / vt.time_s - 1) * 100,
                         "edp": (x.edp / vt.edp - 1) * 100,
                         "power": (x.power_w / vt.power_w - 1) * 100})
    return pd.DataFrame(rows)


def table5(rel):
    med = rel.groupby(["benchmark", "regime", "construct"])[["energy", "time", "edp"]].median()
    rows = []
    for bm in BENCHMARKS:
        for r in REGIMES:
            row = [bm, r]
            for metric in ["energy", "time", "edp"]:
                row += [pct(med.loc[(bm, r, o), metric]) for o in OTHERS]
            rows.append(row)
    med.to_csv(out_path("tables/table5_regime_medians.csv"))
    header = ["Bench.", "Regime"] + [f"{m} {SHORT[o]}" for m in ["Energy %", "Time %", "EDP %"] for o in OTHERS]
    return md_table(header, rows)


def table6(df):
    tests = []
    for label, sub, factor in [("Construct x b (C = 100)", df[df.C == 100], "b"),
                               ("Construct x C (b = 0)", df[df.b == 0], "C")]:
        for bm in BENCHMARKS:
            x = sub[sub.benchmark == bm]
            for col, name in TEST_METRICS:
                f, p, _, _ = art_interaction(x[col].values, x.construct.values, x[factor].values)
                _, p_par, eta = interaction_anova(x[col].values, x.construct.values, x[factor].values)
                tests.append({"test": label, "benchmark": bm, "metric": name, "F_ART": f, "p_ART": p,
                              "partial_eta2": eta, "p_parametric": p_par})
    t = pd.DataFrame(tests)
    t["p_ART_holm"] = holm(t.p_ART)
    t["p_parametric_holm"] = holm(t.p_parametric)
    t.to_csv(out_path("tables/table6_interaction_tests.csv"), index=False)
    rows = []
    for bm in BENCHMARKS:
        for _, name in TEST_METRICS:
            r2 = t[(t.benchmark == bm) & (t.metric == name)]
            rows.append([bm, name] + [f"{v:.1f} / {e:.2f} / {fmt_p(p)}" for v, e, p in
                                      zip(r2.F_ART, r2.partial_eta2, r2.p_ART_holm)])
    return md_table(["Bench.", "Metric", "Construct x b: F_ART / partial eta2 / p_Holm",
                     "Construct x C: F_ART / partial eta2 / p_Holm"], rows)


def text_numbers(df, means, rel):
    lines = []
    r = rel[(rel.b > 0) & (rel.C >= 100)]
    med = r.groupby(["benchmark", "regime", "construct"]).time.median()
    for o in OTHERS:
        lines.append(f"- b > 0, C >= 100: {LABEL[o]} takes {med.xs(o, level='construct').min():.0f}-"
                     f"{med.xs(o, level='construct').max():.0f}% longer than VT (range of regime medians)")
    tput = means.loc[("A", slice(None), 0.95, 10000), "throughput"].droplevel([0, 2, 3])
    lines.append(f"- A, b = 0.95, C = 10,000 throughput (tasks/s): "
                 + ", ".join(f"{LABEL[c]} {tput[c]:,.0f}" for c in CONSTRUCTS))
    m = means.reset_index()
    p = m[(m.b > 0) & (m.C >= 1000)].groupby(["benchmark", "construct"]).power_w.median().unstack()
    lines.append("- Median power (W) at b > 0, C >= 1000: " + "; ".join(
        f"{bm}: " + ", ".join(f"{SHORT[c]} {p.loc[bm, c]:.1f}" for c in CONSTRUCTS) for bm in BENCHMARKS))
    fj = rel[(rel.construct == "fj") & (rel.b > 0)]
    fj_med = fj.groupby(["benchmark", "regime"])[["energy", "edp"]].median()
    lines.append(f"- Fork/Join energy vs VT at b > 0, C = 100 (medians): "
                 + ", ".join(f"{fj_med.loc[(bm, REGIMES[2]), 'energy']:+.0f}%" for bm in BENCHMARKS)
                 + "; EDP at C >= 100: "
                 + f"{fj_med.loc[(slice(None), REGIMES[2:]), 'edp'].min():+.0f}% to "
                 + f"{fj_med.loc[(slice(None), REGIMES[2:]), 'edp'].max():+.0f}%")
    noidle = rel[(rel.b > 0) & (rel.C >= 100) & rel.construct.isin(["pool", "explicit"])]
    g = noidle.groupby(["benchmark", "regime", "construct"])[["energy", "energy_noidle"]].median()
    lines.append(f"- Subtracting idle energy changes the median difference of Pool/Explicit vs VT at b > 0, "
                 f"C >= 100 by at most {(g.energy_noidle - g.energy).abs().max():.1f} percentage points")
    c10 = rel[(rel.b == 0) & (rel.construct == "explicit")].set_index(["benchmark", "C"]).energy
    lines.append("- RQ3, Explicit vs VT energy at b = 0: " + "; ".join(
        f"C = {c}: " + ", ".join(f"{bm} {c10[(bm, c)]:+.1f}%" for bm in BENCHMARKS) for c in C_LEVELS))
    others = rel[(rel.b == 0) & rel.construct.isin(["pool", "fj"])].energy.abs().max()
    lines.append(f"- RQ3, Pool and Fork/Join vs VT at b = 0: max |difference| {others:.1f}%")
    return lines


def lines_figure(means, axis, fixed, name, xlabel, logx):
    """Energy per task against one factor, mean +- sd over launches, one line per construct."""
    if axis == "b":
        panels = [(bm, c) for bm in BENCHMARKS for c in C_LEVELS]
        nrows, ncols = 3, 4
    else:
        panels = [(bm, None) for bm in BENCHMARKS]
        nrows, ncols = 1, 3
    fig, axes = plt.subplots(nrows, ncols, figsize=(3.0 * ncols, 2.6 * nrows + 0.6),
                             constrained_layout=True, squeeze=False)
    sd = means.attrs["sd"]
    for ax, (bm, c) in zip(axes.flat, panels):
        for k in CONSTRUCTS:
            if axis == "b":
                idx = [(bm, k, b, c) for b in B_LEVELS]
                xs = B_LEVELS
                ax.set_title(f"{bm}, C = {c:,}", fontsize=10)
            else:
                idx = [(bm, k, fixed, cc) for cc in C_LEVELS]
                xs = C_LEVELS
                ax.set_title(f"Benchmark {bm}, b = {fixed:g}", fontsize=10)
            ax.errorbar(xs, means.loc[idx, "energy_per_task_mj"], yerr=sd.loc[idx, "energy_per_task_mj"],
                        color=COLOR[k], marker=MARKER[k], markersize=5, linewidth=1.6, capsize=2,
                        label=LABEL[k])
        if logx:
            ax.set_xscale("log")
            ax.set_xticks(C_LEVELS, [f"{c:,}" for c in C_LEVELS])
            ax.minorticks_off()
        ax.grid(color="#dddddd", linewidth=0.6)
        ax.set_axisbelow(True)
    for ax in axes[-1]:
        ax.set_xlabel(xlabel)
    for ax in axes[:, 0]:
        ax.set_ylabel("Energy per task (mJ)")
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="outside upper center", ncol=4, frameon=False)
    save_fig(fig, name)
    plt.close(fig)


def run():
    df = launches()
    means = config_means(df)
    means.attrs["sd"] = df.groupby(["benchmark", "construct", "b", "C"]).std(numeric_only=True)
    rel = relative_differences(means)
    rel.to_csv(out_path("tables/relative_to_vt_per_workload.csv"), index=False)

    lines = ["## 7.3 RQ2 and 7.4 RQ3: blocking ratio and concurrency level", "",
             "**Table 5.** Median relative difference with virtual threads per regime "
             "(positive = more than VT).", "", table5(rel), "",
             "**Table 6.** Interaction tests: F of the aligned rank transform ANOVA, partial eta^2 of the "
             "parametric two-way ANOVA, Holm-corrected ART p.", "", table6(df), "",
             "Numbers in the text:", ""]
    lines += text_numbers(df, means, rel)
    lines_figure(means, "b", None, "fig2_energy_vs_blocking_ratio", "Blocking ratio b", logx=False)
    lines_figure(means, "C", 0.0, "fig3_energy_vs_concurrency", "Concurrency level C", logx=True)
    lines += ["", "Figures 2 and 3: `figures/fig2_energy_vs_blocking_ratio.pdf`, "
                  "`figures/fig3_energy_vs_concurrency.pdf`"]
    return "\n".join(lines)
