"""Section 7.5 (RQ4) and 8: energy vs execution-time rankings. Kendall's tau per workload,
permutation test on the mean tau, Figure 4, Table 7 and the constant-power (+10 W) analysis."""
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap

from common import (B_LEVELS, BENCHMARKS, C_LEVELS, CONSTRUCTS, LABEL, config_means, launches, md_table,
                    out_path, save_fig, workloads)
from stats import kendall_tau, mean_tau_permutation

# Diverging blue <-> red with a neutral grey midpoint (reference palette).
DIVERGING = LinearSegmentedColormap.from_list("tau", ["#e34948", "#f0efec", "#2a78d6"])


def values(means, w, col):
    bm, b, c = w
    return np.array([means.loc[(bm, k, b, c), col] for k in CONSTRUCTS])


def winners(means, score):
    count = dict.fromkeys(CONSTRUCTS, 0)
    for w in workloads():
        e, t = values(means, w, "energy_j"), values(means, w, "time_s")
        count[CONSTRUCTS[int(np.argmin(score(e, t)))]] += 1
    return count


def run():
    means = config_means(launches())
    ws = workloads()
    pairs = [(values(means, w, "energy_j"), values(means, w, "time_s")) for w in ws]
    taus = pd.DataFrame([{"benchmark": w[0], "b": w[1], "C": w[2], "tau": kendall_tau(e, t)}
                         for w, (e, t) in zip(ws, pairs)])
    taus.to_csv(out_path("tables/kendall_tau_per_workload.csv"), index=False)
    mean_tau, p = mean_tau_permutation(pairs)

    # robustness: only workloads where the constructs differ by more than 5% in both energy and time
    distinct = [(e, t) for e, t in pairs if e.max() / e.min() > 1.05 and t.max() / t.min() > 1.05]
    mean_tau_d, p_d = mean_tau_permutation(distinct)

    lines = ["## 7.5 RQ4: energy vs execution-time rankings", "",
             f"- Mean Kendall's tau over {len(pairs)} workloads: {mean_tau:.3f}; exact one-sided permutation "
             f"test (time ranking permuted within each workload): p = {p:.3f}",
             f"- Workloads where the constructs differ by > 5% in both energy and time: {len(distinct)}; "
             f"mean tau {mean_tau_d:.3f}, p = {p_d:.3f}", ""]

    criteria = {
        "Energy": lambda e, t: e,
        "Time": lambda e, t: t,
        "EDP": lambda e, t: e * t,
        "Energy + 10 W": lambda e, t: e + 10 * t,
        "Energy + 20 W": lambda e, t: e + 20 * t,
    }
    rows = [[name] + list(winners(means, f).values()) for name, f in criteria.items()]
    pd.DataFrame(rows, columns=["criterion"] + CONSTRUCTS).to_csv(out_path("tables/table7_winners.csv"), index=False)
    lines += ["**Table 7.** Number of workloads (of 60) in which each construct ranks first. The last two "
              "rows add a constant 10 W / 20 W for the rest of the machine (Section 8.3).", "",
              md_table(["Winner by"] + [LABEL[c] for c in CONSTRUCTS], rows), "",
              "Figure 4: `figures/fig4_kendall_tau_heatmap.pdf`"]
    figure4(taus)
    return "\n".join(lines)


def figure4(taus):
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.4), constrained_layout=True)
    for ax, bm in zip(axes, BENCHMARKS):
        grid = taus[taus.benchmark == bm].pivot(index="b", columns="C", values="tau").loc[B_LEVELS, C_LEVELS]
        im = ax.imshow(grid.values, cmap=DIVERGING, vmin=-1, vmax=1, origin="lower", aspect="auto")
        for i in range(len(B_LEVELS)):
            for j in range(len(C_LEVELS)):
                ax.text(j, i, f"{grid.values[i, j]:.2f}", ha="center", va="center", fontsize=9, color="#222222")
        ax.set_xticks(range(len(C_LEVELS)), [f"{c:,}" for c in C_LEVELS])
        ax.set_yticks(range(len(B_LEVELS)), [f"{b:g}" for b in B_LEVELS])
        ax.set_xlabel("Concurrency level C")
        ax.set_title(f"Benchmark {bm}")
    axes[0].set_ylabel("Blocking ratio b")
    fig.colorbar(im, ax=axes, label="Kendall's tau", shrink=0.9)
    save_fig(fig, "fig4_kendall_tau_heatmap")
    plt.close(fig)
