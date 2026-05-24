# Pharmacy Inventory Management System

A SQL-first analytics project that monitors stock, surfaces expiration risk, and recommends seasonal restocking for an Indian pharmacy catalog of 253,973 medicines.

![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-3-003B57?logo=sqlite&logoColor=white)
![pandas](https://img.shields.io/badge/pandas-2.x-150458?logo=pandas&logoColor=white)
![Faker](https://img.shields.io/badge/Faker-20.x-2C3E50)
![Matplotlib](https://img.shields.io/badge/Matplotlib-3.x-11557C)
![seaborn](https://img.shields.io/badge/seaborn-0.12+-4C72B0)

---

## The business problem

A pharmacy chain carries hundreds of thousands of distinct SKUs. Three operational questions are constantly on fire:

1. **Stock visibility** — what's running out, what's already expired, and where is the money tied up?
2. **Demand pattern** — which medicines are moving fast, which are spiking unexpectedly, and how does demand shift across India's four seasons?
3. **Procurement** — given a medicine's velocity and a supplier's lead time, how much should we reorder, and from whom?

This project answers all three using a SQLite database, ~15 SQL queries (with CTEs, window functions, joins, and aggregations), and a Python reporting layer that exports CSVs and three diagnostic charts.

## Tech stack

| Layer        | Tool                                 | Why                                                    |
|--------------|--------------------------------------|--------------------------------------------------------|
| Database     | SQLite 3                             | Zero-setup, file-based, supports modern SQL features   |
| Data loading | Python + pandas + Faker              | Pure-stdlib `sqlite3`, fast bulk inserts via `to_sql`  |
| Analytics    | Raw SQL (CTEs, window functions)     | The logic lives in SQL, not in Python — portable       |
| Reporting    | Python script + matplotlib + seaborn | One script runs every query and renders three charts   |

## Dataset

`indian_medicine_data.csv` — 253,973 rows of real Indian medicines with the columns: `id`, `name`, `price(₹)`, `Is_discontinued`, `manufacturer_name`, `type`, `pack_size_label`, `short_composition1`, `short_composition2`.

Inventory, sales, and supplier rows are **synthesized with Faker + NumPy** (seeded for reproducibility) since no real ERP data is available.

## Database schema

```
                    ┌──────────────────────┐
                    │      medicines       │   253,973 rows
                    │ medicine_id  (PK)    │   master catalog from CSV
                    │ name, price_inr,     │
                    │ manufacturer_name,   │
                    │ is_discontinued,     │
                    │ short_composition1/2 │
                    └──────────┬───────────┘
                               │
       ┌───────────────────────┼────────────────────────┐
       │ 1:N                   │ 1:N                    │ 1:N
       ▼                       ▼                        ▼
┌────────────────┐  ┌──────────────────────┐  ┌───────────────────┐
│   inventory    │  │  sales_transactions  │  │     suppliers     │
│ stock_qty,     │  │  qty_sold, sale_date │  │ supplier_name,    │
│ reorder_level, │  │  season              │  │ lead_time_days,   │
│ expiry_date,   │  │                      │  │ unit_cost         │
│ warehouse      │  │  (the fact table)    │  │                   │
└────────────────┘  └──────────────────────┘  └───────────────────┘
```

## Repository layout

```
pharmacy-inventory/
├── README.md                       you are here
├── requirements.txt
├── sql/
│   ├── schema.sql                  CREATE TABLE statements
│   └── queries.sql                 15+ analytical queries (tagged @A1, @B2, ...)
├── scripts/
│   ├── 01_create_schema.py         build empty DB
│   ├── 02_load_data.py             CSV + Faker → DB
│   └── 03_report.py                run all queries + render 3 charts
├── data/
│   └── pharmacy.db                 generated SQLite database
└── outputs/
    ├── *.csv                       one per query
    └── chart_*.png                 three required charts
```

## How to run it

```bash
# 1. Set up a virtualenv (any tool works; pip shown here)
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 2. The dataset ships with the repo at data/indian_medicine_data.csv (~30 MB).
#    No download needed.

# 3. Build the database (3 commands, in order)
python scripts/01_create_schema.py     # creates data/pharmacy.db (empty)
python scripts/02_load_data.py         # loads CSV + synthesizes fake data  (~30s)
python scripts/03_report.py            # runs queries, writes CSVs + PNGs

# 4. Inspect anything ad-hoc
sqlite3 data/pharmacy.db
sqlite> .schema
sqlite> SELECT COUNT(*) FROM sales_transactions;
```

## Sample insights

After running `03_report.py`, the CSVs in `outputs/` answer:

- **Low-stock alerts** — medicines below their reorder level, sorted by urgency.
- **Expiration risk** — what's expiring in 30 / 60 / 90 days, AND what's overstocked while near expiry (money about to evaporate).
- **Fast movers** — top 20 by units in the last 90 days, plus a 7-day rolling-average view of the top 5.
- **Sales spikes** — days where a medicine sold > 2× its own historical daily average (early-warning signal for outbreaks or shortages).
- **Seasonal patterns** — top 5 medicines per season (Winter / Spring / Summer / Monsoon) via `RANK()`, and a restocking list for the upcoming season.
- **Procurement** — recommended reorder quantity per low-stock SKU (`avg_daily_sales × lead_time + 1-week safety stock`) and a cost-vs-speed ranking of every supplier for the top 10 movers.

## SQL techniques demonstrated

| Technique           | Example query                                                              |
|---------------------|----------------------------------------------------------------------------|
| `JOIN` + `USING`    | A1, A3, B1 — joining `medicines` with `inventory` / `sales` / `suppliers`  |
| `GROUP BY` + `SUM`  | A3, B1, D1 — aggregating stock value, units sold                           |
| CTEs (`WITH`)       | B2, B3, D3, E1 — multi-step analytical pipelines                           |
| Window functions    | B2 (`ROWS BETWEEN`), B3 (`AVG OVER`), D2 + E2 (`RANK OVER PARTITION BY`)   |
| `CASE` bucketing    | A2, C1 — days-to-expiry buckets                                            |
| Date arithmetic     | `julianday()`, `date('now', '-90 days')`, `strftime('%Y-%m', ...)`         |
| `CROSS JOIN`        | D3 — joining a 1-row "upcoming season" CTE to the main query               |

## What I learned

- **SQLite is more capable than people think.** It supports window functions, CTEs, JSON, and full-text search out of the box. For analytical workloads on a single laptop, it's hard to beat.
- **NULL is sneaky.** `NULL × anything = NULL`, so `SUM(stock * price)` silently under-counts when any price is missing. Always guard with `IS NOT NULL` or `COALESCE`.
- **Window functions trade compute for clarity.** Computing a 7-day rolling average in pure Python would be ugly; with `OVER (ORDER BY ... ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` it's a single SQL clause.
- **The schema *is* the design.** Normalizing into `medicines` / `inventory` / `sales_transactions` / `suppliers` makes every downstream query simpler. A flat denormalized table would have made seasonal joins miserable.
- **Foreign keys are off by default in SQLite.** A famous footgun — you have to `PRAGMA foreign_keys = ON;` on every connection.
- **Faker + NumPy + seeded RNGs** are enough to generate convincing test data for SQL portfolio projects without needing real ERP access.
