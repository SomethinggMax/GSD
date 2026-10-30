"""Section 7.6 / Table 8: JFR counts per 1,000 tasks and average CPU load, from the profiling runs
made by energy-bench/scripts/profile.sh (results/profile/profile.csv). Counts include warm-up."""
import pandas as pd

from common import LABEL, ROOT, md_table, out_path

PROFILE = ROOT / "energy-bench" / "results" / "profile" / "profile.csv"


def run():
    lines = ["## Table 8: JFR profiling", ""]
    if not PROFILE.exists():
        lines.append(f"`{PROFILE.relative_to(ROOT)}` not found: run `sudo ./scripts/profile.sh` in energy-bench "
                     "first (about 30 minutes). Table 8 is skipped.")
        return "\n".join(lines)
    p = pd.read_csv(PROFILE)
    per_k = 1000 / (p.reps * p.tasks)
    p["starts_per_1000"] = p.thread_starts * per_k
    p["parks_per_1000"] = p.parks * per_k
    p.to_csv(out_path("tables/table8_jfr.csv"), index=False)
    rows = [[f"{r.benchmark}, b = {r.b:g}, C = {r.C:,}", LABEL[r.construct], f"{r.starts_per_1000:.2f}",
             f"{r.parks_per_1000:.0f}", r.pinned, r.gcs, f"{r.cpu_machine_pct:.0f}"] for r in p.itertuples()]
    lines.append(md_table(["Workload", "Construct", "starts/1000 tasks", "parks/1000 tasks", "pinned", "GCs",
                           "CPU (%)"], rows))
    return "\n".join(lines)
