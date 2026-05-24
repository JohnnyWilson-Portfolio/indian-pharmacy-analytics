"""
Step 4 — Run every query in sql/queries.sql, export results to CSV, and
generate the three required charts.

Run from project root:
    python scripts/03_report.py

Outputs land in outputs/:
    *.csv                          — one per query (named after its @tag)
    chart_top10_fast_movers.png    — Top 10 fast-moving drugs (last 90 days)
    chart_monthly_trend.png        — Monthly sales trend
    chart_expiry_heatmap.png       — Expiry risk heatmap by warehouse
"""

import re
import sqlite3
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH      = PROJECT_ROOT / "data" / "pharmacy.db"
QUERIES_PATH = PROJECT_ROOT / "sql"  / "queries.sql"
OUT_DIR      = PROJECT_ROOT / "outputs"
OUT_DIR.mkdir(exist_ok=True)


# --- Tiny SQL-file parser -------------------------------------------------
# We split the queries.sql file on `-- @<tag> <name>` markers so each
# named query can be run individually. Keeping the SQL in a single .sql
# file means devs can also `sqlite3 data/pharmacy.db < sql/queries.sql`
# to inspect raw results without touching Python.
TAG_RE = re.compile(r"^--\s*@(\w+)\s+(\w+)", re.MULTILINE)


def parse_queries(sql_text: str) -> dict[str, str]:
    """Return {tag_name: sql_block} dict."""
    matches = list(TAG_RE.finditer(sql_text))
    queries: dict[str, str] = {}
    for i, m in enumerate(matches):
        start = m.end()
        end   = matches[i + 1].start() if i + 1 < len(matches) else len(sql_text)
        name  = f"{m.group(1)}_{m.group(2)}"     # e.g. "A1_low_stock_alert"
        queries[name] = sql_text[start:end].strip().rstrip(";") + ";"
    return queries


# --- Reporting helpers ----------------------------------------------------
def run_and_save(conn: sqlite3.Connection, name: str, sql: str) -> pd.DataFrame:
    df = pd.read_sql_query(sql, conn)
    df.to_csv(OUT_DIR / f"{name}.csv", index=False)
    print(f"\n=== {name}  ({len(df)} rows) ===")
    print(df.head(8).to_string(index=False))
    return df


# --- The three required charts -------------------------------------------
def chart_top10_fast_movers(conn: sqlite3.Connection) -> None:
    """Chart 1: horizontal bar of the 10 best-selling medicines (90d)."""
    df = pd.read_sql_query(
        """
        SELECT m.name, SUM(s.quantity_sold) AS total_sold
        FROM sales_transactions s
        JOIN medicines m USING (medicine_id)
        WHERE s.sale_date >= date('now', '-90 days')
        GROUP BY m.medicine_id, m.name
        ORDER BY total_sold DESC
        LIMIT 10;
        """,
        conn,
    )

    plt.figure(figsize=(11, 6))
    sns.barplot(data=df, y="name", x="total_sold", palette="viridis")
    plt.title("Top 10 Fast-Moving Medicines (last 90 days)", fontsize=14, weight="bold")
    plt.xlabel("Units sold")
    plt.ylabel("")
    plt.tight_layout()
    plt.savefig(OUT_DIR / "chart_top10_fast_movers.png", dpi=120)
    plt.close()


def chart_monthly_trend(conn: sqlite3.Connection) -> None:
    """Chart 2: monthly sales trend line."""
    df = pd.read_sql_query(
        """
        SELECT strftime('%Y-%m', sale_date) AS month,
               SUM(quantity_sold)           AS units_sold
        FROM sales_transactions
        GROUP BY month
        ORDER BY month;
        """,
        conn,
    )

    plt.figure(figsize=(11, 5))
    plt.plot(df["month"], df["units_sold"], marker="o", linewidth=2)
    plt.fill_between(df["month"], df["units_sold"], alpha=0.15)
    plt.xticks(rotation=45)
    plt.title("Monthly Sales Trend (units sold)", fontsize=14, weight="bold")
    plt.xlabel("Month")
    plt.ylabel("Units sold")
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUT_DIR / "chart_monthly_trend.png", dpi=120)
    plt.close()


def chart_expiry_heatmap(conn: sqlite3.Connection) -> None:
    """Chart 3: expiry-risk heatmap, warehouse × days-to-expiry bucket."""
    df = pd.read_sql_query(
        """
        SELECT
            i.warehouse_location,
            CASE
                WHEN julianday(i.expiry_date) - julianday('now') <  0   THEN '0_expired'
                WHEN julianday(i.expiry_date) - julianday('now') <= 30  THEN '1_<=30d'
                WHEN julianday(i.expiry_date) - julianday('now') <= 60  THEN '2_31-60d'
                WHEN julianday(i.expiry_date) - julianday('now') <= 90  THEN '3_61-90d'
                WHEN julianday(i.expiry_date) - julianday('now') <= 180 THEN '4_91-180d'
                ELSE '5_>180d'
            END AS bucket,
            COUNT(*) AS n_skus
        FROM inventory i
        GROUP BY i.warehouse_location, bucket
        ORDER BY i.warehouse_location, bucket;
        """,
        conn,
    )

    pivot = df.pivot(index="warehouse_location", columns="bucket",
                     values="n_skus").fillna(0)

    plt.figure(figsize=(11, 5))
    sns.heatmap(pivot, annot=True, fmt=".0f", cmap="YlOrRd",
                cbar_kws={"label": "SKU count"})
    plt.title("Expiry Risk Heatmap: SKU count by Warehouse × Days-to-Expiry",
              fontsize=14, weight="bold")
    plt.xlabel("Days to expiry bucket")
    plt.ylabel("Warehouse")
    plt.tight_layout()
    plt.savefig(OUT_DIR / "chart_expiry_heatmap.png", dpi=120)
    plt.close()


def main() -> None:
    if not DB_PATH.exists():
        raise FileNotFoundError(
            f"DB not found — run scripts/01_create_schema.py and 02_load_data.py first."
        )

    sql_text = QUERIES_PATH.read_text()
    queries  = parse_queries(sql_text)
    print(f"Found {len(queries)} named queries in {QUERIES_PATH.name}")

    sns.set_style("whitegrid")

    with sqlite3.connect(DB_PATH) as conn:
        for name, sql in queries.items():
            run_and_save(conn, name, sql)

        print("\nGenerating charts...")
        chart_top10_fast_movers(conn)
        chart_monthly_trend(conn)
        chart_expiry_heatmap(conn)

    print(f"\nDone. All CSVs + PNGs are in {OUT_DIR}/")


if __name__ == "__main__":
    main()
