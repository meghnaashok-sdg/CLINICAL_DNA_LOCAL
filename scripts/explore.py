"""
Quick interactive helper — run the pipeline and keep every model in memory
so you can inspect ANY intermediate table (not just the final output).

Usage (from the project root):
    python -i scripts/explore.py
Then, at the >>> prompt:
    show("int_hills_us_clinic_dna_clusters")           # peek at any model
    df = tbl("int_hills_us_clinic_dna_clinic_opportunity")   # get a DataFrame
    con.execute("select cluster, count(*) from int_hills_us_clinic_dna_clusters group by 1").df()
"""
import sys, duckdb
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
import run_pipeline as rp

con = duckdb.connect()
rp.install_snowflake_compat(con)
rp.load_sources(con)
for m in rp.MODEL_ORDER:
    rp.run_model(con, m)

def tbl(name):
    """Return a model/source as a pandas DataFrame."""
    return con.execute(f'select * from "{name}"').df()

def show(name, n=5):
    """Print row count, columns, and n sample rows for any table."""
    cnt = con.execute(f'select count(*) from "{name}"').fetchone()[0]
    df = con.execute(f'select * from "{name}" limit {n}').df()
    print(f"\n{name}  —  {cnt:,} rows, {len(df.columns)} cols")
    print("cols:", list(df.columns))
    print(df.to_string())

print("\nReady. Tables loaded:", ", ".join(rp.MODEL_ORDER))
print("Try:  show('int_hills_us_clinic_dna_clusters')   |   df = tbl('...')")
