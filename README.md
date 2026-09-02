# Clinic DNA — Local Pipeline (DuckDB)

## One-time setup

```bash
# 1. clone your repo, then from the project root:
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 2. put the 4 CSVs in data/  (see data/README.md — they're git-ignored)
```

## Run it

```bash
python run_pipeline.py           # runs all 9 models -> output/recommendations_local.csv
python run_pipeline.py --peek    # also prints 3 sample rows per model
```

You should see all 9 models build and end with `~37,830 rows`.

## Explore any intermediate table

`scripts/explore.py` is an **inspection tool, not a storage location** — it runs
the whole pipeline in memory and gives you a Python prompt to look at any table.
Nothing is saved by it; if you want files on disk, use `--dump-models` (below).

```bash
python -i scripts/explore.py
>>> show('int_hills_us_clinic_dna_clusters')          # peek at any model
>>> df = tbl('int_hills_us_clinic_dna_clinic_opportunity')   # -> pandas DataFrame
>>> con.execute("select cluster, count(*) from int_hills_us_clinic_dna_clusters group by 1").df()
```

## Saving every model's output to disk

By default, every run also writes each of the 9 models to `output/models/*.csv`
(overwritten each run — this is "what did the last run produce," not a baseline).
Skip it with `--no-dump-models` if you just want the final file, faster.

## Baselines — comparing runs over time

`output/` is always the **latest** run and gets overwritten every time. To actually
compare "before my change" vs "after," freeze a trusted run as a **baseline**:

```bash
python run_pipeline.py              # a run you trust
python scripts/save_baseline.py     # freeze output/ -> baseline/
# ... make changes, re-run ...
# open notebooks/03_compare_to_baseline.ipynb to see exactly what changed
```

See `notebooks/` and `CONTRIBUTING.md` for the full workflow.

---

## The 4 source tables (inputs)

| CSV | What it is | Feeds |
|---|---|---|
| `scenario_analysis_joined` | **The sales spine** — clinic × category × species × month, sales/volume + scenario stickers | everything |
| `executive_summary` | Raw field-activity + channel sales (ECC/Chewy/VSHD, $ and LBS) | clusters (history) |
| `action_summary` | Per-clinic visit/education/sample totals + last-dates | final_opportunity |
| `recommendation_setup` | Clinic names, territory/region/district | naming in models 8–9 |

Data range: ~24 months (models use a 12-month rolling window + a 24-months-ago baseline).
Current extract = 2024-09 → 2026-08, so the run produces **September 2026** recommendations.

---

## How the Snowflake→DuckDB translation works (in `run_pipeline.py`)

All done at run time so the base SQL stays untouched:

1. **Schema prefix** `SBX_EXT_SALES_HUB.HILLS_US.` stripped → bare local table names.
2. **Reserved alias** `at` → `"at"` (reserved word in DuckDB).
3. **Date functions** `dateadd` / `datediff` → DuckDB macros; bare date-parts (`month`) quoted.
4. **Row generator** `table(generator(rowcount => 12))` + `seq4()` → `range(12)`.
5. **Types** `number` → `double` / `decimal`.
6. **Exact-decimal load** — the money/volume columns are cast to `DECIMAL(38,6)` so
   sales+returns that cancel sum to **exactly 0** (matching Snowflake). *Without this,
   floating-point residue slips past the code's `nullif(...,0)` guards and blows up the
   seasonality ratios to 1e16.* (This was the one real gotcha — see git history.)

If a future model uses another Snowflake-only function, add it to the same rewrite section.
---

## Validating against production

`output/recommendations_local.csv` should match the shape of 
`august_2026_recommendations.csv` (same 29 columns, ~37.8k rows, opportunity mean ~$20–30,
median $0, exactly 14 samples/TM, education on ~5–13% of clinics). The month differs
(this run = September, because the data now extends to Aug). Use the
**Recommendation-QA notebook** to diff any run against the baseline.

---

## Day-to-day workflow

```bash
# 1. Get a trusted baseline (do this once, or after pulling a teammate's change)
python run_pipeline.py
python scripts/save_baseline.py          # freeze output/ -> baseline/

# 2. Make a change
git checkout -b feat/my-change
# ... edit a model in models/, or add new logic ...

# 3. Re-run and see what changed
python run_pipeline.py
# open notebooks/03_compare_to_baseline.ipynb  -> "did my change break anything?"

# 4. If it looks right, commit
git add -A && git commit -m "Describe the change"
git push -u origin feat/my-change

# 5. Once merged to main, refresh the baseline so it reflects the new normal
python scripts/save_baseline.py
```

## The two notebooks — when to use which

| Notebook | Compares local run to... | Use it when... |
|---|---|---|
| `02_validate_output.ipynb` | Manish's real **production** CSV | You changed the *runner* (translation logic, source loading) and want to confirm local still reproduces what the warehouse actually does. Run occasionally, not every commit. |
| `03_compare_to_baseline.ipynb` | Your own saved **baseline** | You changed the *methodology* (a model's logic) and want to see exactly what shifted. **Run this after every change.** |
