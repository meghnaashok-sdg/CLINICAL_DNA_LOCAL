"""
Clinic DNA — local pipeline runner (DuckDB)
--------------------------------------------
Runs the compiled dbt models locally against the CSV extracts,
instead of Snowflake. Each model's output becomes a table the next model reads,
exactly like the real warehouse.

Usage:
    python run_pipeline.py            # run all models, save final output
    python run_pipeline.py --peek     # also print row count + 3 sample rows per model

Requires: pip install duckdb pandas
"""

import duckdb
import pandas as pd
import argparse
import re
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
ROOT = Path(__file__).parent
DATA = ROOT / "data"        # put CSVs here
MODELS = ROOT / "models"    # the compiled .sql files
OUTPUT = ROOT / "output"    # final result written here

# The prefix the compiled code uses for every warehouse table.
# We strip it so "SBX_EXT_SALES_HUB.HILLS_US.int_..._clusters" -> "int_..._clusters",
# which will be a local DuckDB table/view instead.
SCHEMA_PREFIX = "SBX_EXT_SALES_HUB.HILLS_US."

# The 4 SOURCE tables  exported as CSVs -> map warehouse name : csv filename.
# (These are the pipeline's inputs; everything else is BUILT by the models.)
SOURCE_CSVS = {
    "int_hills_us_clinic_dna_scenario_analysis_joined":
        "int_hills_us_clinic_dna_scenario_analysis_joined.csv",
    "int_hills_us_clinic_dna_action_summary":
        "int_hills_us_clinic_dna_action_summary.csv",
    "int_hills_us_clinic_dna_recommendation_setup":
        "int_hills_us_clinic_dna_recommendation_setup.csv",
    "con_hills_us_clinic_dna_executive_summary":
        "con_hills_us_clinic_dna_executive_summary_2024_to_date.csv",
}

# The 9 models, in DEPENDENCY ORDER (each reads only the ones above it + sources).
MODEL_ORDER = [
    "int_hills_us_clinic_dna_clusters",
    "int_hills_us_clinic_dna_next_step",
    "int_hills_us_clinic_dna_clinic_distributions",
    "int_hills_us_clinic_dna_cluster_distributions",
    "int_hills_us_clinic_dna_clinic_opportunity",
    "int_hills_us_clinic_dna_forecast_opportunity",
    "int_hills_us_clinic_dna_final_opportunity",
    "int_hills_us_clinic_dna_monthly_recommendations",
    "con_hills_us_clinic_dna_recommendation_analysis",
]

FINAL_MODEL = "con_hills_us_clinic_dna_recommendation_analysis"


# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
def install_snowflake_compat(con):
    """Register DuckDB macros so Snowflake-only functions in the compiled SQL
    (dateadd, datediff, to_date) run unchanged. DuckDB already supports
    date_trunc, cume_dist, percentile_cont, qualify, etc."""
    con.execute("""
        -- dateadd(part, n, date)  ->  date + n * INTERVAL part
        CREATE OR REPLACE MACRO dateadd(part, n, d) AS
            (d + (n::INTEGER * to_months(0) )) ;  -- placeholder, overridden below
    """)
    # to_months only covers months; we need a general version, so define per-part
    # via a CASE using DuckDB's date arithmetic. Simpler: use a SQL macro table.
    con.execute("""
        CREATE OR REPLACE MACRO dateadd(part, n, d) AS (
            CASE lower(part)
                WHEN 'year'  THEN (d::TIMESTAMP + (n || ' years')::INTERVAL)
                WHEN 'month' THEN (d::TIMESTAMP + (n || ' months')::INTERVAL)
                WHEN 'day'   THEN (d::TIMESTAMP + (n || ' days')::INTERVAL)
                WHEN 'week'  THEN (d::TIMESTAMP + (n || ' weeks')::INTERVAL)
                ELSE (d::TIMESTAMP + (n || ' days')::INTERVAL)
            END
        );
    """)
    con.execute("""
        -- datediff(part, start, end) -> integer difference in `part`
        CREATE OR REPLACE MACRO datediff(part, s, e) AS
            date_diff(lower(part), s::TIMESTAMP, e::TIMESTAMP);
    """)
    con.execute("""
        -- to_date(x) -> DATE
        CREATE OR REPLACE MACRO to_date(x) AS x::DATE;
    """)


def load_sources(con):
    """Register each source CSV as a DuckDB view named after its warehouse table."""
    # Money/volume columns that must be EXACT decimals (not float) so that
    # sales+returns that cancel sum to exactly 0 — matching Snowflake, and
    # letting the code's nullif(...,0) guards work. Otherwise float residue
    # (e.g. 3e-14) slips past nullif and blows up the seasonality ratios.
    DECIMAL_CAST = {
        "int_hills_us_clinic_dna_scenario_analysis_joined": [
            "SALES_USD_CLINIC", "SALES_VOLUME_CLINIC",
            "SALES_USD_DISEASE_CATEGORY", "SALES_VOLUME_DISEASE_CATEGORY",
        ],
    }

    print("Loading source CSVs ".ljust(60, "-"))
    for table, csv_name in SOURCE_CSVS.items():
        path = DATA / csv_name
        if not path.exists():
            raise FileNotFoundError(
                f"Missing source CSV: {path}\n"
                f"  -> put CSV expor '{csv_name}' in the data/ folder."
            )
        # Build a SELECT that casts the money columns to DECIMAL(38,6) if needed.
        if table in DECIMAL_CAST:
            casts = ", ".join(
                f'CAST("{c}" AS DECIMAL(38,6)) AS "{c}"' for c in DECIMAL_CAST[table]
            )
            select_clause = f"* REPLACE ({casts})"
        else:
            select_clause = "*"
        # read_csv_auto handles types, quotes, the BOM, and spaces-in-headers.
        con.execute(f'''
            CREATE OR REPLACE VIEW "{table}" AS
            SELECT {select_clause}
            FROM read_csv_auto('{path.as_posix()}',
                               header=true, all_varchar=false,
                               ignore_errors=true)
        ''')
        n = con.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
        print(f"  loaded {table:55s} {n:>10,} rows")
    print()


# Words that are valid table aliases in Snowflake but RESERVED in DuckDB.
# The compiled code uses `at` as an alias; we quote it so DuckDB accepts it.
# (We do this at run-time so the base .sql files stay byte-for-byte identical
#  to what's in Git — no manual edits to the vendor code.)
DUCKDB_RESERVED_ALIASES = ["at"]


def read_model_sql(model_name):
    """Read a compiled model file, strip the warehouse prefix, and make it
    DuckDB-safe — without modifying the file on disk."""
    sql = (MODELS / f"{model_name}.sql").read_text()

    # 1) Strip the schema prefix -> references become bare local table names.
    sql = sql.replace(SCHEMA_PREFIX, "")

    # 2) Quote reserved-word aliases: bare `at` -> `"at"`, and `at.col` -> `"at".col`.
    #    Word-boundary regex so we never touch words like "creATe" or "dATa".
    for kw in DUCKDB_RESERVED_ALIASES:
        sql = re.sub(rf'\b{kw}\b', f'"{kw}"', sql)

    # 3) In dateadd()/datediff(), Snowflake takes the date-part as a bare keyword
    #    (e.g. dateadd(month, -11, x)). Our DuckDB macros expect a string, so wrap
    #    that first argument in quotes: dateadd(month, ...) -> dateadd('month', ...).
    parts = "year|quarter|month|week|day|hour|minute|second"
    sql = re.sub(rf'\b(dateadd|datediff)\s*\(\s*({parts})\b',
                 lambda m: f"{m.group(1)}('{m.group(2)}'",
                 sql, flags=re.IGNORECASE)

    # 4) Snowflake row generator -> DuckDB range().
    #    `table(generator(rowcount => 12))` produces 12 rows; `seq4()` numbers them.
    sql = re.sub(r'table\s*\(\s*generator\s*\(\s*rowcount\s*=>\s*(\d+)\s*\)\s*\)',
                 lambda m: f"range({m.group(1)})", sql, flags=re.IGNORECASE)
    sql = re.sub(r'\bseq4\s*\(\s*\)', "range", sql, flags=re.IGNORECASE)

    # 5) Snowflake type names -> DuckDB. `number` (no precision) -> double;
    #    number(p,s) also -> decimal(p,s) works in DuckDB, so only bare `number`
    #    needs mapping. Only touch it right after `as ` inside a cast.
    sql = re.sub(r'\bas\s+number\b(?!\s*\()', "as double", sql, flags=re.IGNORECASE)
    sql = re.sub(r'\bnumber\s*\(', "decimal(", sql, flags=re.IGNORECASE)

    return sql


def run_model(con, model_name, peek=False, dump_dir=None):
    """Materialise one model as a DuckDB table so later models can read it.
    If dump_dir is given, also write this model's full output as a CSV there
    (overwritten each run — output/models/ is always 'latest run', not a baseline)."""
    inner_sql = read_model_sql(model_name).strip().rstrip(";")
    con.execute(f'CREATE OR REPLACE TABLE "{model_name}" AS\n{inner_sql}')
    n = con.execute(f'SELECT count(*) FROM "{model_name}"').fetchone()[0]
    print(f"  built {model_name:55s} {n:>10,} rows")
    if peek:
        df = con.execute(f'SELECT * FROM "{model_name}" LIMIT 3').df()
        print(df.to_string(max_cols=8))
        print()
    if dump_dir is not None:
        dump_dir.mkdir(parents=True, exist_ok=True)
        out = dump_dir / f"{model_name}.csv"
        con.execute(f'''COPY "{model_name}" TO '{out.as_posix()}' (HEADER, DELIMITER ',')''')
    return n


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
def main(peek=False, dump_models=False):
    con = duckdb.connect()  # in-memory; nothing to clean up
    install_snowflake_compat(con)
    load_sources(con)

    dump_dir = (OUTPUT / "models") if dump_models else None

    print("Running models in order ".ljust(60, "-"))
    for model in MODEL_ORDER:
        try:
            run_model(con, model, peek=peek, dump_dir=dump_dir)
        except Exception as e:
            print(f"\n  ERROR building {model}:\n    {e}\n")
            raise

    # Save the final table to CSV so you can open/validate it.
    OUTPUT.mkdir(exist_ok=True)
    out_path = OUTPUT / "recommendations_local.csv"
    # Column names sometimes come out lowercase for expressions built with
    # AS <lowercase_alias> (DuckDB preserves the alias's exact case; Snowflake's
    # own export happens to render these as UPPERCASE). Normalize to uppercase
    # so local output is directly comparable to production without renaming.
    con.execute(f'''
        CREATE OR REPLACE TABLE "_final_upper" AS
        SELECT * FROM "{FINAL_MODEL}"
    ''')
    cols = con.execute('DESCRIBE "_final_upper"').df()["column_name"].tolist()
    select_upper = ", ".join(f'"{c}" AS "{c.upper()}"' for c in cols)
    con.execute(f'CREATE OR REPLACE TABLE "_final_upper" AS SELECT {select_upper} FROM "{FINAL_MODEL}"')
    con.execute(f'''COPY "_final_upper" TO '{out_path.as_posix()}'
                    (HEADER, DELIMITER ',')''')
    n = con.execute(f'SELECT count(*) FROM "{FINAL_MODEL}"').fetchone()[0]
    print("\nDone ".ljust(60, "-"))
    print(f"  final output: {out_path}  ({n:,} rows)")
    return con


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--peek", action="store_true",
                    help="print row count + 3 sample rows for each model")
    ap.add_argument("--no-dump-models", action="store_true",
                    help="skip saving each model's output to output/models/ "
                         "(by default every model IS dumped there, overwritten each run)")
    args = ap.parse_args()
    main(peek=args.peek, dump_models=not args.no_dump_models)
