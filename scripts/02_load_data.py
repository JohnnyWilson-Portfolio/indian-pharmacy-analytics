"""
Step 2 — Populate the database.

  • Load indian_medicine_data.csv into the `medicines` table.
  • Generate realistic FAKE data for inventory / sales_transactions / suppliers
    using Faker + NumPy.

Run from the project root:
    python scripts/02_load_data.py
"""

import random
import sqlite3
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from faker import Faker

# --- Paths ----------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH      = PROJECT_ROOT / "data" / "pharmacy.db"
# CSV ships with the repo (data/indian_medicine_data.csv, ~30 MB).
# Falls back to ~/Downloads if you've moved it.
CSV_PATH     = PROJECT_ROOT / "data" / "indian_medicine_data.csv"
if not CSV_PATH.exists():
    CSV_PATH = Path.home() / "Downloads" / "indian_medicine_data.csv"

# --- Determinism ----------------------------------------------------------
# Same seed → same fake data every run. Critical for a portfolio project so
# the numbers in your README match the numbers in your DB.
RNG_SEED = 42
random.seed(RNG_SEED)
np.random.seed(RNG_SEED)
fake = Faker("en_IN")
Faker.seed(RNG_SEED)

# --- Knobs you can tune ---------------------------------------------------
# These trade realism vs. runtime. With the defaults the script finishes in
# ~30s on a modern laptop and produces a DB around ~80MB.
WAREHOUSES         = ["Mumbai-WH", "Delhi-WH", "Bangalore-WH",
                      "Chennai-WH", "Kolkata-WH"]
N_SUPPLIER_BRANDS  = 50         # distinct supplier company names
SAMPLE_ACTIVE_MEDS = 5_000      # only this many SKUs actually move (realistic — most catalog SKUs are slow)
AVG_SALES_PER_MED  = 100        # mean transactions/year for an active SKU
SUPPLIERS_PER_MED  = 3          # competing suppliers per medicine

# Indian seasons. Months map to seasons at INSERT time so the `season`
# column matches the `sale_date` deterministically — no risk of drift.
MONTH_TO_SEASON = {
    12: "Winter",  1: "Winter",  2: "Winter",
     3: "Spring",  4: "Spring",
     5: "Summer",  6: "Summer",  7: "Summer",
     8: "Monsoon", 9: "Monsoon", 10: "Monsoon", 11: "Monsoon",
}

TODAY = date.today()


# =========================================================================
# medicines  ← CSV
# =========================================================================
def load_medicines(conn: sqlite3.Connection) -> pd.DataFrame:
    print("Loading medicines from CSV...")
    df = pd.read_csv(CSV_PATH)

    # The CSV column "price(₹)" is awkward to query — rename it.
    # `id` → `medicine_id` to match our schema.
    df = df.rename(columns={
        "id":             "medicine_id",
        "price(₹)":       "price_inr",
        "Is_discontinued": "is_discontinued",
    })

    # SQLite has no native BOOLEAN → store 0/1 in INTEGER.
    # The CSV uses the strings "TRUE"/"FALSE"; map them explicitly.
    df["is_discontinued"] = (
        df["is_discontinued"].astype(str).str.upper()
          .map({"TRUE": 1, "FALSE": 0}).fillna(0).astype(int)
    )
    # A handful of rows have blank prices — coerce them to NaN, not 0.
    df["price_inr"] = pd.to_numeric(df["price_inr"], errors="coerce")

    # Keep only the columns that exist in the medicines table.
    cols = ["medicine_id", "name", "price_inr", "is_discontinued",
            "manufacturer_name", "type", "pack_size_label",
            "short_composition1", "short_composition2"]
    df = df[cols]

    df.to_sql("medicines", conn, if_exists="append", index=False, chunksize=10_000)
    print(f"  → {len(df):,} medicines loaded")
    return df


# =========================================================================
# inventory  ← Faker
# =========================================================================
def gen_inventory(conn: sqlite3.Connection, meds: pd.DataFrame) -> None:
    print("Generating inventory...")
    n = len(meds)

    # Stock between 0 and 600 — some at zero so the "low stock" query has hits.
    stock     = np.random.randint(0, 600, n)
    reorder   = np.random.randint(50, 200, n)
    restocked = np.random.randint(1, 120, n)                # 1-120 days ago
    expiry    = np.random.randint(-30, 730, n)              # -30 (already expired) to +730 days

    inv = pd.DataFrame({
        "medicine_id":         meds["medicine_id"].values,
        "stock_quantity":      stock,
        "reorder_level":       reorder,
        "last_restocked_date": [(TODAY - timedelta(days=int(d))).isoformat() for d in restocked],
        "expiry_date":         [(TODAY + timedelta(days=int(d))).isoformat() for d in expiry],
        "warehouse_location":  np.random.choice(WAREHOUSES, n),
    })

    inv.to_sql("inventory", conn, if_exists="append", index=False, chunksize=10_000)
    print(f"  → {len(inv):,} inventory rows")


# =========================================================================
# sales_transactions  ← Faker
# =========================================================================
def gen_sales(conn: sqlite3.Connection, meds: pd.DataFrame) -> None:
    print("Generating sales transactions (this is the slow one)...")

    # Only a SAMPLE of medicines actually sells — the rest are catalog tail.
    # This matches reality: a pharmacy carries ~250k SKUs but only a few
    # thousand move regularly.
    active = meds.sample(n=min(SAMPLE_ACTIVE_MEDS, len(meds)), random_state=RNG_SEED)
    active_ids = active["medicine_id"].to_numpy()

    # Per-medicine sales count, normally distributed around AVG_SALES_PER_MED.
    n_per_med = np.maximum(
        1,
        np.random.normal(AVG_SALES_PER_MED, AVG_SALES_PER_MED // 3, len(active_ids))
    ).astype(int)

    # Inject "hot" medicines: top 5% get 3× their sales (creates spikes for query B3).
    hot_mask = np.random.random(len(active_ids)) < 0.05
    n_per_med[hot_mask] *= 3

    # Repeat each medicine_id n_per_med times → one row per transaction.
    medicine_ids = np.repeat(active_ids, n_per_med)
    total = len(medicine_ids)

    # Sale dates uniformly across the last 365 days.
    days_ago   = np.random.randint(0, 365, total)
    sale_dates = [TODAY - timedelta(days=int(d)) for d in days_ago]
    seasons    = [MONTH_TO_SEASON[d.month] for d in sale_dates]

    sales = pd.DataFrame({
        "medicine_id":   medicine_ids,
        "quantity_sold": np.random.randint(1, 20, total),
        "sale_date":     [d.isoformat() for d in sale_dates],
        "season":        seasons,
    })

    sales.to_sql("sales_transactions", conn, if_exists="append",
                 index=False, chunksize=20_000)
    print(f"  → {len(sales):,} sales transactions")


# =========================================================================
# suppliers  ← Faker
# =========================================================================
def gen_suppliers(conn: sqlite3.Connection, meds: pd.DataFrame) -> None:
    print("Generating suppliers...")
    supplier_brands = [f"{fake.company()} Pharma" for _ in range(N_SUPPLIER_BRANDS)]

    sample = meds.sample(n=min(SAMPLE_ACTIVE_MEDS, len(meds)), random_state=RNG_SEED)

    rows = []
    for _, med in sample.iterrows():
        mid        = int(med["medicine_id"])
        # Supplier cost should be a fraction of MRP, default if price missing.
        base_price = float(med["price_inr"]) if pd.notna(med["price_inr"]) else 50.0
        for _ in range(SUPPLIERS_PER_MED):
            rows.append((
                random.choice(supplier_brands),
                mid,
                int(np.random.randint(2, 30)),                                # lead time 2-30 days
                round(base_price * float(np.random.uniform(0.3, 0.7)), 2),    # cost = 30-70% of MRP
            ))

    sup = pd.DataFrame(rows, columns=["supplier_name", "medicine_id",
                                      "lead_time_days", "unit_cost"])
    sup.to_sql("suppliers", conn, if_exists="append", index=False, chunksize=10_000)
    print(f"  → {len(sup):,} supplier rows")


# =========================================================================
def main() -> None:
    if not CSV_PATH.exists():
        raise FileNotFoundError(f"CSV not found: {CSV_PATH}")
    if not DB_PATH.exists():
        raise FileNotFoundError(
            f"DB not found — run scripts/01_create_schema.py first: {DB_PATH}"
        )

    with sqlite3.connect(DB_PATH) as conn:
        # Speed knobs for bulk loading. WAL is the modern journal mode;
        # synchronous=OFF is unsafe for production but fine for test data.
        conn.execute("PRAGMA foreign_keys = ON;")
        conn.execute("PRAGMA journal_mode = WAL;")
        conn.execute("PRAGMA synchronous  = OFF;")

        # Truncate so re-runs are idempotent. Order matters: children first.
        for t in ("suppliers", "sales_transactions", "inventory", "medicines"):
            conn.execute(f"DELETE FROM {t};")
        conn.commit()

        meds = load_medicines(conn)
        gen_inventory(conn, meds)
        gen_sales(conn, meds)
        gen_suppliers(conn, meds)
        conn.commit()

    # Final row counts — proves the load worked.
    with sqlite3.connect(DB_PATH) as conn:
        for t in ("medicines", "inventory", "sales_transactions", "suppliers"):
            (n,) = conn.execute(f"SELECT COUNT(*) FROM {t};").fetchone()
            print(f"  {t:<22} {n:>10,}")

    print("Done.")


if __name__ == "__main__":
    main()
