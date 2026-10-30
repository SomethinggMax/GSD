"""Section 7.6: effective blocking ratio. Thread.sleep and the socket call block longer than the
nominal t_block, and by a different amount on virtual and platform threads (pilot p2,
blocking.csv). We estimate each other construct's energy at the effective b of virtual threads by
linear interpolation between its own measured points (at their own effective b), and count how
often the sign of the difference with virtual threads changes."""
import numpy as np
import pandas as pd

from common import (B_LEVELS, LABEL, OTHERS, PILOT_DIR, config_means, launches, md_table, out_path,
                    workloads)


def effective_b(blocking, b, kind):
    """Effective blocking ratio from the measured mean blocking time (t_cpu = 1 ms)."""
    if b == 0:
        return 0.0
    t = blocking.loc[(b, kind), "mean_us"]
    return t / (t + 1000.0)


def run():
    blocking = pd.read_csv(PILOT_DIR / "p2" / "blocking.csv").set_index(["b", "kind"])
    over = blocking.assign(overshoot_us=blocking.mean_us - blocking.target_us).reset_index()
    rows = [[f"{r.b:g}", r.kind, f"{r.target_us:.0f}", f"{r.mean_us:.0f}", f"{r.overshoot_us:+.0f}",
             f"{effective_b(blocking, r.b, r.kind):.3f}"] for r in over.itertuples()]

    means = config_means(launches())
    changes = dict.fromkeys(OTHERS, 0)
    total = dict.fromkeys(OTHERS, 0)
    detail = []
    for bm, b, c in workloads():
        if b == 0:
            continue
        kind = "socket" if bm == "C" else "sleep"
        target = effective_b(blocking, b, f"{kind}-virtual")
        xs = [effective_b(blocking, bb, f"{kind}-platform") for bb in B_LEVELS]
        vt = means.loc[(bm, "vt", b, c), "energy_j"]
        for o in OTHERS:
            ys = [means.loc[(bm, o, bb, c), "energy_j"] for bb in B_LEVELS]
            est = float(np.interp(target, xs, ys))
            nominal = means.loc[(bm, o, b, c), "energy_j"]
            flipped = bool(np.sign(est - vt) != np.sign(nominal - vt))
            changes[o] += flipped
            total[o] += 1
            detail.append({"benchmark": bm, "b": b, "C": c, "construct": o, "b_eff_vt": target,
                           "energy_nominal_j": nominal, "energy_at_b_eff_vt_j": est, "energy_vt_j": vt,
                           "direction_changed": flipped})
    pd.DataFrame(detail).to_csv(out_path("tables/effective_b_comparison.csv"), index=False)

    lines = ["## 7.6 Effective blocking ratio", "",
             "Blocking-phase accuracy from pilot p2 (`energy-bench/results/pilot/p2/blocking.csv`):", "",
             md_table(["b", "kind", "target us", "mean us", "overshoot us", "b_eff"], rows), "",
             "Energy differences with VT whose direction changes when the other construct is evaluated at "
             "the effective b of VT: " + ", ".join(f"{LABEL[o]} {changes[o]} of {total[o]}" for o in OTHERS)]
    return "\n".join(lines)
