"""
Partial-pipeline runner + single-CTE inspector.

Two things this gives you that run_pipeline.py doesn't:
  1. Stop the chain early -- e.g. build only clusters -> next_step -> clinic_opportunity,
     without running forecast/final/monthly_recommendations/recommendation_analysis too.
  2. Look INSIDE any one model's CTEs one at a time, without needing to materialize
     the whole model as a table first.

Usage (from the project root):
    python -i scripts/peek.py

Then, at the >>> prompt:
    run_upto('int_hills_us_clinic_dna_clinic_opportunity')
        # builds clusters -> next_step -> clinic_opportunity only, stops there.
        # (Order follows MODEL_ORDER in run_pipeline.py, so it always builds
        #  whatever that model actually depends on -- nothing more.)

    list_ctes('int_hills_us_clinic_dna_clinic_opportunity')
        # prints every CTE name in that model's SQL, in the order they appear,
        # so you know what names you can pass to peek().

    peek('int_hills_us_clinic_dna_clinic_opportunity', 'with_gap',
         where_clause="where clinic_id=807101")
        # runs the model's SQL truncated right after the 'with_gap' CTE and
        # selects from it -- i.e. "what does the data look like at THIS exact
        # step", without running the rest of the model.

IMPORTANT: peek() only works for CTEs *inside* the model you name. If that
model reads from OTHER models (e.g. clinic_opportunity reads from clusters
and next_step), those upstream models must already be built as real tables
in `con` first -- that's what run_upto() is for. Call run_upto() on the
model you actually want to inspect (it builds every dependency before it),
then peek() into any CTE inside it.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import duckdb
import run_pipeline as rp

con = duckdb.connect()
rp.install_snowflake_compat(con)
rp.load_sources(con)


def run_upto(model_name, peek_rows=False):
    """Materialize every model up to AND INCLUDING model_name, in dependency
    order -- then stop. Does not run anything after it in the pipeline.
    Set peek_rows=True to also print 3 sample rows from each model as it builds."""
    if model_name not in rp.MODEL_ORDER:
        raise ValueError(f"'{model_name}' is not one of: {rp.MODEL_ORDER}")
    idx = rp.MODEL_ORDER.index(model_name)
    for m in rp.MODEL_ORDER[: idx + 1]:
        rp.run_model(con, m, peek=peek_rows)
    print(f"\nStopped after building: {model_name}")
    print("(Nothing after it in the pipeline has been run.)")


def list_ctes(model_name):
    """Print every CTE name inside a model's SQL, in order, so you know what
    you can pass to peek()."""
    sql_text = rp.read_model_sql(model_name)
    names = re.findall(r"\n(\w+)\s+as\s*\(", sql_text, flags=re.IGNORECASE)
    for n in names:
        print(n)


def peek(model_name, cte_name, where_clause="", limit=10):
    """Show what ONE CTE inside a model looks like, without materializing the
    whole model. Truncates the model's SQL right after cte_name's closing
    paren and selects from it.

    model_name  : e.g. 'int_hills_us_clinic_dna_clinic_opportunity'
    cte_name    : e.g. 'with_gap' (see list_ctes() for valid names)
    where_clause: e.g. "where clinic_id = 807101" (optional)
    limit       : row cap (default 10)

    Requires: any OTHER models this one reads from must already be built --
    call run_upto() first if you haven't.
    """
    sql_text = rp.read_model_sql(model_name)
    pattern = re.compile(rf"\b{re.escape(cte_name)}\s+as\s*\(", re.IGNORECASE)
    m = pattern.search(sql_text)
    if not m:
        raise ValueError(
            f"CTE '{cte_name}' not found in {model_name}. "
            f"Run list_ctes('{model_name}') to see valid names."
        )
    start = m.end() - 1  # position of the opening '('
    depth, i = 0, start
    while i < len(sql_text):
        if sql_text[i] == "(":
            depth += 1
        elif sql_text[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    truncated = sql_text[: i + 1]
    query = f"{truncated}\nselect * from {cte_name} {where_clause} limit {limit}"
    return con.execute(query).df()


print("Ready. Sources loaded (nothing built yet).")
print()
print("Examples:")
print("  run_upto('int_hills_us_clinic_dna_clinic_opportunity')")
print("      # builds clusters -> next_step -> clinic_opportunity, stops there")
print()
print("  list_ctes('int_hills_us_clinic_dna_clinic_opportunity')")
print("      # see every CTE name you can peek() at")
print()
print("  peek('int_hills_us_clinic_dna_clinic_opportunity', 'with_gap',")
print("       where_clause='where clinic_id = 807101')")
