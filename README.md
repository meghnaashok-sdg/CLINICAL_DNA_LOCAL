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

```bash
python -i scripts/explore.py
>>> show('int_hills_us_clinic_dna_clusters')          # peek at any model
>>> df = tbl('int_hills_us_clinic_dna_clinic_opportunity')   # -> pandas DataFrame
>>> con.execute("select cluster, count(*) from int_hills_us_clinic_dna_clusters group by 1").df()
```

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

TBD
---

## Files

```
run_pipeline.py       ← the runner (loads CSVs, translates, runs 9 models)
models/               ← the 9 compiled dbt models (BASE — do not edit)
data/                 ←  CSVs go here (git-ignored)
output/               ← results land here (git-ignored)
scripts/explore.py    ← interactive: inspect any intermediate table
requirements.txt
.vscode/              ← recommended extensions + settings
```
