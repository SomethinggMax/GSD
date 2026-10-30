"""Statistical tests used in Section 7 that scipy does not provide directly."""
import itertools

import numpy as np
import pandas as pd
from scipy import stats


def _two_way_ss(y, a, b):
    """Sums of squares of a balanced two-way full-factorial design.
    Returns (ss_a, ss_b, ss_ab, ss_err, df_a, df_b, df_ab, df_err)."""
    y = np.asarray(y, float)
    a_lv, a_idx = np.unique(a, return_inverse=True)
    b_lv, b_idx = np.unique(b, return_inverse=True)
    na, nb = len(a_lv), len(b_lv)
    cell = np.zeros((na, nb))
    count = np.zeros((na, nb))
    np.add.at(cell, (a_idx, b_idx), y)
    np.add.at(count, (a_idx, b_idx), 1)
    if count.min() != count.max():
        raise ValueError("design must be balanced")
    n = count[0, 0]
    cell /= n
    g = y.mean()
    ma, mb = cell.mean(axis=1), cell.mean(axis=0)
    ss_a = nb * n * ((ma - g) ** 2).sum()
    ss_b = na * n * ((mb - g) ** 2).sum()
    ss_ab = n * ((cell - ma[:, None] - mb[None, :] + g) ** 2).sum()
    ss_err = ((y - cell[a_idx, b_idx]) ** 2).sum()
    return ss_a, ss_b, ss_ab, ss_err, na - 1, nb - 1, (na - 1) * (nb - 1), len(y) - na * nb


def interaction_anova(y, a, b):
    """Parametric two-way ANOVA: F, p and partial eta^2 of the a x b interaction."""
    _, _, ss_ab, ss_err, _, _, df_ab, df_err = _two_way_ss(y, a, b)
    f = (ss_ab / df_ab) / (ss_err / df_err)
    return f, stats.f.sf(f, df_ab, df_err), ss_ab / (ss_ab + ss_err)


def art_interaction(y, a, b):
    """Aligned rank transform ANOVA (Wobbrock et al. 2011) for the a x b interaction:
    align the response for the interaction, rank it, and run the full-factorial ANOVA on the
    ranks; the interaction term of that ANOVA is the test. Returns (F, p, df_num, df_den)."""
    y = np.asarray(y, float)
    d = pd.DataFrame({"y": y, "a": np.asarray(a), "b": np.asarray(b)})
    cell = d.groupby(["a", "b"]).y.transform("mean")
    ma = d.groupby("a").y.transform("mean")
    mb = d.groupby("b").y.transform("mean")
    aligned = (y - cell) + (cell - ma - mb + y.mean())
    ranks = stats.rankdata(aligned)
    _, _, ss_ab, ss_err, _, _, df_ab, df_err = _two_way_ss(ranks, a, b)
    f = (ss_ab / df_ab) / (ss_err / df_err)
    return f, stats.f.sf(f, df_ab, df_err), df_ab, df_err


def kendall_tau(x, y):
    """Kendall's tau between two rankings of the same items (tau-a; no ties in our data)."""
    s = 0
    for i, j in itertools.combinations(range(len(x)), 2):
        s += np.sign(x[i] - x[j]) * np.sign(y[i] - y[j])
    return s / (len(x) * (len(x) - 1) / 2)


def mean_tau_permutation(pairs):
    """Mean Kendall's tau over workloads and its exact one-sided permutation p-value
    (H1: the rankings are positively related). Under H0 the time ranking is a random
    permutation within each workload, independently, so the null distribution of the summed
    tau is the convolution of the per-workload distributions over all k! permutations.
    `pairs` is a list of (energy_values, time_values) without ties."""
    k = len(pairs[0][0])
    n_pairs = k * (k - 1) // 2
    observed = [round(kendall_tau(e, t) * n_pairs) for e, t in pairs]  # integer concordance scores
    one = {}
    for perm in itertools.permutations(range(k)):
        s = round(kendall_tau(list(range(k)), list(perm)) * n_pairs)
        one[s] = one.get(s, 0) + 1
    total = {0: 1}
    for _ in pairs:
        nxt = {}
        for a, ca in total.items():
            for b, cb in one.items():
                nxt[a + b] = nxt.get(a + b, 0) + ca * cb
        total = nxt
    s_obs = sum(observed)
    p = sum(c for s, c in total.items() if s >= s_obs) / sum(total.values())
    return s_obs / (n_pairs * len(pairs)), p
