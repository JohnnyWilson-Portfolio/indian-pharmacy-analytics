-- =====================================================================
-- Pharmacy Inventory Management System — Database Schema (Step 1)
-- =====================================================================
-- Engine: SQLite 3
-- Run with: sqlite3 data/pharmacy.db < sql/schema.sql
--
-- Design notes:
--  * SQLite has no native BOOLEAN — we store 0/1 in INTEGER columns.
--  * SQLite has no native DATE — we store ISO-8601 strings ('YYYY-MM-DD')
--    in TEXT columns. SQLite's date() and julianday() functions work on
--    these strings out-of-the-box.
--  * Foreign keys are OFF by default in SQLite. We turn them on per
--    connection (see the PRAGMA at the top).
-- =====================================================================

PRAGMA foreign_keys = ON;   -- Enforce referential integrity on this connection.

-- Drop in reverse-dependency order so a re-run is idempotent.
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS sales_transactions;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS medicines;


-- ---------------------------------------------------------------------
-- 1. medicines  — the master catalog (one row per SKU)
-- ---------------------------------------------------------------------
-- Source: indian_medicine_data.csv (253,973 rows)
-- The CSV column "price(₹)" is renamed to price_inr — the ₹ symbol and
-- parentheses make the original name a pain to reference in SQL.
-- Is_discontinued from the CSV ("TRUE"/"FALSE") is normalized to 0/1.
CREATE TABLE medicines (
    medicine_id          INTEGER PRIMARY KEY,         -- Reuse the CSV "id" column as PK.
    name                 TEXT    NOT NULL,
    price_inr            REAL,                        -- Indian Rupees. Nullable: a few rows are blank.
    is_discontinued      INTEGER NOT NULL DEFAULT 0   -- 0 = active, 1 = discontinued
                         CHECK (is_discontinued IN (0, 1)),
    manufacturer_name    TEXT,
    type                 TEXT,                        -- All values are "allopathy" in this dataset.
    pack_size_label      TEXT,                        -- Free text e.g. "strip of 10 tablets".
    short_composition1   TEXT,                        -- Primary active ingredient + dose.
    short_composition2   TEXT                         -- Secondary ingredient + dose (often NULL).
);

-- Speed up the very common "search by manufacturer" and "search by name" queries.
CREATE INDEX idx_medicines_manufacturer ON medicines (manufacturer_name);
CREATE INDEX idx_medicines_name         ON medicines (name);


-- ---------------------------------------------------------------------
-- 2. inventory  — current stock-on-hand per medicine, per warehouse
-- ---------------------------------------------------------------------
-- One row per (medicine, warehouse) pair. Keeping this separate from the
-- medicines catalog means we can re-load the catalog without losing
-- live stock state, and we can later add multiple warehouses without
-- schema churn.
CREATE TABLE inventory (
    inventory_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    medicine_id          INTEGER NOT NULL,
    stock_quantity       INTEGER NOT NULL CHECK (stock_quantity >= 0),
    reorder_level        INTEGER NOT NULL CHECK (reorder_level   >= 0),
    last_restocked_date  TEXT,                        -- ISO date 'YYYY-MM-DD'
    expiry_date          TEXT    NOT NULL,            -- ISO date 'YYYY-MM-DD'
    warehouse_location   TEXT    NOT NULL,
    FOREIGN KEY (medicine_id) REFERENCES medicines (medicine_id)
        ON DELETE CASCADE
);

CREATE INDEX idx_inventory_medicine   ON inventory (medicine_id);
CREATE INDEX idx_inventory_expiry     ON inventory (expiry_date);
CREATE INDEX idx_inventory_warehouse  ON inventory (warehouse_location);


-- ---------------------------------------------------------------------
-- 3. sales_transactions  — append-only log of every sale
-- ---------------------------------------------------------------------
-- This is our fact table. Every analytical question about velocity,
-- seasonality, trends, etc. ultimately groups/joins against this.
-- Stored as a flat log (one row per sale) so window functions and
-- GROUP BY queries stay simple.
CREATE TABLE sales_transactions (
    transaction_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    medicine_id          INTEGER NOT NULL,
    quantity_sold        INTEGER NOT NULL CHECK (quantity_sold > 0),
    sale_date            TEXT    NOT NULL,            -- ISO date 'YYYY-MM-DD'
    season               TEXT    NOT NULL
                         CHECK (season IN ('Summer', 'Monsoon', 'Winter', 'Spring')),
    FOREIGN KEY (medicine_id) REFERENCES medicines (medicine_id)
        ON DELETE CASCADE
);

-- Composite index: most queries filter by date AND group by medicine_id.
CREATE INDEX idx_sales_medicine_date ON sales_transactions (medicine_id, sale_date);
CREATE INDEX idx_sales_date          ON sales_transactions (sale_date);
CREATE INDEX idx_sales_season        ON sales_transactions (season);


-- ---------------------------------------------------------------------
-- 4. suppliers  — who supplies what, at what cost and lead time
-- ---------------------------------------------------------------------
-- Modelled as one row per (supplier, medicine) pair so a single supplier
-- can supply many medicines, and a medicine can have multiple suppliers
-- competing on price / lead time. This is what lets us rank suppliers
-- by cost-efficiency in Step 3E.
CREATE TABLE suppliers (
    supplier_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    supplier_name        TEXT    NOT NULL,
    medicine_id          INTEGER NOT NULL,
    lead_time_days       INTEGER NOT NULL CHECK (lead_time_days >= 0),
    unit_cost            REAL    NOT NULL CHECK (unit_cost      >= 0),
    FOREIGN KEY (medicine_id) REFERENCES medicines (medicine_id)
        ON DELETE CASCADE
);

CREATE INDEX idx_suppliers_medicine ON suppliers (medicine_id);
CREATE INDEX idx_suppliers_name     ON suppliers (supplier_name);
