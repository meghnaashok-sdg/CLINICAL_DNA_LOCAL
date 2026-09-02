"""
Save the CURRENT contents of output/ as a permanent baseline snapshot.

Run this once, right after a run you trust (e.g. right after confirming
the pipeline matches production). From then on, every future run gets
compared against this baseline by 03_compare_to_baseline.ipynb.

Usage:
    python run_pipeline.py              # produce a run
    python scripts/save_baseline.py     # freeze it as the baseline
    ... make changes, re-run ...
    # open notebooks/03_compare_to_baseline.ipynb to see what changed
"""
import shutil
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

ROOT = Path(__file__).parent.parent
OUTPUT = ROOT / "output"
BASELINE = ROOT / "baseline"


def main():
    final_csv = OUTPUT / "recommendations_local.csv"
    if not final_csv.exists():
        print("No output found — run `python run_pipeline.py` first.")
        sys.exit(1)

    if BASELINE.exists() and any(BASELINE.glob("*.csv")):
        resp = input(
            "A baseline already exists and will be OVERWRITTEN. "
            "Continue? [y/N] "
        ).strip().lower()
        if resp != "y":
            print("Cancelled — existing baseline kept.")
            sys.exit(0)

    BASELINE.mkdir(exist_ok=True)
    (BASELINE / "models").mkdir(exist_ok=True)

    # 1) the final recommendations
    shutil.copy(final_csv, BASELINE / "recommendations_baseline.csv")

    # 2) every intermediate model, if they were dumped
    models_dir = OUTPUT / "models"
    n_models = 0
    if models_dir.exists():
        for f in models_dir.glob("*.csv"):
            shutil.copy(f, BASELINE / "models" / f.name)
            n_models += 1

    # 3) a small manifest so you know when/what this baseline is
    manifest = {
        "saved_at": datetime.now(timezone.utc).isoformat(),
        "final_rows": sum(1 for _ in open(BASELINE / "recommendations_baseline.csv")) - 1,
        "models_included": n_models,
        "note": "Snapshot of output/ at save time. Compare future runs against "
                "this with notebooks/03_compare_to_baseline.ipynb.",
    }
    with open(BASELINE / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Baseline saved to {BASELINE}/")
    print(f"  recommendations_baseline.csv  ({manifest['final_rows']:,} rows)")
    print(f"  models/  ({n_models} intermediate tables)")
    print(f"  manifest.json")


if __name__ == "__main__":
    main()
