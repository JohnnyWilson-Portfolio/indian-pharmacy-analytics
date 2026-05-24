-- =====================================================================
-- Pharmacy Inventory Management System — Analytical Queries (Step 3)
-- =====================================================================
-- Every query block below is named with a tag like `-- @A1 low_stock`.
-- The Python reporter (scripts/03_report.py) parses these tags to run
-- each query individually and export the result to CSV.
-- =====================================================================


-- =====================================================================
-- A) STOCK MONITORING
-- =====================================================================

-- @A1 low_stock_alert
-- All active medicines where stock has dipped below the reorder level.
-- Discontinued SKUs are excluded — re-stocking them would waste money.
SELECT
    m.medicine_id,
    m.name,
    m.manufacturer_name,
    i.warehouse_location,
    i.stock_quantity,
    i.reorder_level,
    (i.reorder_level - i.stock_quantity) AS units_short
FROM inventory i
JOIN medicines m USING (medicine_id)
WHERE i.stock_quantity < i.reorder_level
  AND m.is_discontinued = 0
ORDER BY units_short DESC
LIMIT 50;


-- @A2 expiring_soon
-- Medicines expiring within 90 days, bucketed into 30/60/90-day windows.
-- `julianday(date) - julianday('now')` gives the day delta as a float.
SELECT
    m.name,
    i.warehouse_location,
    i.stock_quantity,
    i.expiry_date,
    CAST(julianday(i.expiry_date) - julianday('now') AS INTEGER) AS days_to_expiry,
    CASE
        WHEN julianday(i.expiry_date) - julianday('now') <= 30 THEN '0-30 days'
        WHEN julianday(i.expiry_date) - julianday('now') <= 60 THEN '31-60 days'
        ELSE '61-90 days'
    END AS bucket
FROM inventory i
JOIN medicines m USING (medicine_id)
WHERE julianday(i.expiry_date) - julianday('now') BETWEEN 0 AND 90
ORDER BY days_to_expiry ASC
LIMIT 100;


-- @A3 inventory_value_by_manufacturer
-- Total rupee value of stock-on-hand per manufacturer (top 20).
-- price IS NOT NULL guard avoids NULL × number = NULL surprises.
SELECT
    m.manufacturer_name,
    COUNT(DISTINCT m.medicine_id)               AS distinct_skus,
    SUM(i.stock_quantity)                       AS total_units,
    ROUND(SUM(i.stock_quantity * m.price_inr), 2) AS inventory_value_inr
FROM inventory i
JOIN medicines m USING (medicine_id)
WHERE m.price_inr IS NOT NULL
GROUP BY m.manufacturer_name
ORDER BY inventory_value_inr DESC
LIMIT 20;


-- =====================================================================
-- B) FAST-MOVING DRUGS
-- =====================================================================

-- @B1 top_fast_movers_90d
-- The 20 best-selling medicines (by units) over the last 90 days.
-- Date filter uses SQLite's date('now', '-90 days') — concise and timezone-free.
SELECT
    m.medicine_id,
    m.name,
    m.manufacturer_name,
    SUM(s.quantity_sold) AS total_sold,
    COUNT(*)             AS n_transactions
FROM sales_transactions s
JOIN medicines m USING (medicine_id)
WHERE s.sale_date >= date('now', '-90 days')
GROUP BY m.medicine_id, m.name, m.manufacturer_name
ORDER BY total_sold DESC
LIMIT 20;


-- @B2 sales_velocity
-- Average daily sales per medicine over its active window. The window
-- function shows the rolling 7-day average — useful for spotting trends
-- without the day-to-day noise.
WITH daily AS (
    SELECT
        medicine_id,
        sale_date,
        SUM(quantity_sold) AS day_qty
    FROM sales_transactions
    GROUP BY medicine_id, sale_date
),
ranked AS (
    SELECT
        d.medicine_id,
        d.sale_date,
        d.day_qty,
        AVG(d.day_qty) OVER (
            PARTITION BY d.medicine_id
            ORDER BY d.sale_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7d_avg
    FROM daily d
)
SELECT
    r.medicine_id,
    m.name,
    r.sale_date,
    r.day_qty,
    ROUND(r.rolling_7d_avg, 2) AS rolling_7d_avg
FROM ranked r
JOIN medicines m USING (medicine_id)
-- Limit to the 5 top sellers, otherwise we'd return millions of rows.
WHERE r.medicine_id IN (
    SELECT medicine_id FROM sales_transactions
    GROUP BY medicine_id
    ORDER BY SUM(quantity_sold) DESC
    LIMIT 5
)
ORDER BY r.medicine_id, r.sale_date;


-- @B3 sales_spikes
-- Days where a medicine sold >2× its own historical daily average.
-- The `med_avg > 1` filter strips out noise from medicines that only
-- sell ~once a week (where any sale day looks like a 7× spike).
WITH daily AS (
    SELECT medicine_id, sale_date, SUM(quantity_sold) AS day_qty
    FROM sales_transactions
    GROUP BY medicine_id, sale_date
),
with_avg AS (
    SELECT
        medicine_id, sale_date, day_qty,
        AVG(day_qty) OVER (PARTITION BY medicine_id) AS med_avg
    FROM daily
)
SELECT
    w.medicine_id,
    m.name,
    w.sale_date,
    w.day_qty,
    ROUND(w.med_avg, 2)            AS daily_avg,
    ROUND(w.day_qty / w.med_avg, 2) AS spike_multiplier
FROM with_avg w
JOIN medicines m USING (medicine_id)
WHERE w.day_qty > 2 * w.med_avg
  AND w.med_avg > 1
ORDER BY spike_multiplier DESC
LIMIT 25;


-- =====================================================================
-- C) EXPIRATION RISK
-- =====================================================================

-- @C1 overstock_near_expiry
-- The dangerous combination: medicines about to expire AND still sitting
-- on >2× their reorder level. This is money about to evaporate.
SELECT
    m.name,
    i.warehouse_location,
    i.stock_quantity,
    i.reorder_level,
    i.expiry_date,
    CAST(julianday(i.expiry_date) - julianday('now') AS INTEGER) AS days_to_expiry,
    ROUND(i.stock_quantity * m.price_inr, 2) AS value_at_risk_inr
FROM inventory i
JOIN medicines m USING (medicine_id)
WHERE julianday(i.expiry_date) - julianday('now') BETWEEN 0 AND 90
  AND i.stock_quantity > i.reorder_level * 2
  AND m.price_inr IS NOT NULL
ORDER BY value_at_risk_inr DESC
LIMIT 50;


-- @C2 discontinued_in_stock
-- Discontinued SKUs that still have stock — pure deadstock to be liquidated.
SELECT
    m.name,
    m.manufacturer_name,
    i.warehouse_location,
    i.stock_quantity,
    ROUND(i.stock_quantity * COALESCE(m.price_inr, 0), 2) AS deadstock_value_inr
FROM inventory i
JOIN medicines m USING (medicine_id)
WHERE m.is_discontinued = 1
  AND i.stock_quantity > 0
ORDER BY deadstock_value_inr DESC
LIMIT 30;


-- =====================================================================
-- D) SEASONAL DEMAND PATTERNS
-- =====================================================================

-- @D1 monthly_sales_by_season
-- Total units sold per calendar month, tagged with the season.
-- strftime('%Y-%m', ...) gives 'YYYY-MM' which sorts lexicographically
-- in chronological order — handy.
SELECT
    strftime('%Y-%m', sale_date) AS month,
    season,
    SUM(quantity_sold)           AS units_sold,
    COUNT(*)                     AS transactions
FROM sales_transactions
GROUP BY month, season
ORDER BY month;


-- @D2 top_per_season
-- The top 5 best-selling medicines in each season, using RANK().
-- RANK() (not DENSE_RANK or ROW_NUMBER) preserves ties — if two
-- medicines sold the same units they share a rank.
WITH season_sales AS (
    SELECT season, medicine_id, SUM(quantity_sold) AS units
    FROM sales_transactions
    GROUP BY season, medicine_id
),
ranked AS (
    SELECT
        season, medicine_id, units,
        RANK() OVER (PARTITION BY season ORDER BY units DESC) AS rnk
    FROM season_sales
)
SELECT r.season, r.rnk, m.name, r.units
FROM ranked r
JOIN medicines m USING (medicine_id)
WHERE r.rnk <= 5
ORDER BY r.season, r.rnk;


-- @D3 seasonal_restocking_recs
-- Medicines that historically over-perform in the UPCOMING season
-- (current month + 1) but currently have thin stock. Buy these now.
WITH season_demand AS (
    SELECT medicine_id, season, SUM(quantity_sold) AS season_units
    FROM sales_transactions
    GROUP BY medicine_id, season
),
overall_avg AS (
    SELECT medicine_id, AVG(season_units) AS avg_season_units
    FROM season_demand
    GROUP BY medicine_id
),
upcoming_season AS (
    SELECT CASE strftime('%m', date('now', '+1 month'))
        WHEN '12' THEN 'Winter' WHEN '01' THEN 'Winter' WHEN '02' THEN 'Winter'
        WHEN '03' THEN 'Spring' WHEN '04' THEN 'Spring'
        WHEN '05' THEN 'Summer' WHEN '06' THEN 'Summer' WHEN '07' THEN 'Summer'
        ELSE 'Monsoon'
    END AS season
)
SELECT
    m.name,
    sd.season AS upcoming_season,
    sd.season_units,
    ROUND(o.avg_season_units, 1) AS avg_season_units,
    ROUND(sd.season_units * 1.0 / NULLIF(o.avg_season_units, 0), 2) AS seasonal_lift,
    i.stock_quantity
FROM season_demand sd
JOIN overall_avg   o  USING (medicine_id)
JOIN medicines     m  USING (medicine_id)
JOIN inventory     i  USING (medicine_id)
CROSS JOIN upcoming_season u
WHERE sd.season = u.season
  AND sd.season_units > 1.5 * o.avg_season_units      -- meaningful seasonal lift
  AND i.stock_quantity < sd.season_units / 4          -- < 1 quarter of expected demand
ORDER BY seasonal_lift DESC
LIMIT 20;


-- =====================================================================
-- E) SUPPLIER & RESTOCKING OPTIMIZATION
-- =====================================================================

-- @E1 reorder_quantity
-- Recommended reorder quantity = avg_daily_sales × lead_time + safety stock.
-- Safety stock = 7 days × avg_daily_sales (1 week buffer).
-- Only shows medicines that are currently below reorder_level.
WITH velocity AS (
    SELECT
        medicine_id,
        SUM(quantity_sold) * 1.0 / 365 AS avg_daily_sales
    FROM sales_transactions
    GROUP BY medicine_id
),
fastest_supplier AS (
    SELECT medicine_id, MIN(lead_time_days) AS lead_time_days
    FROM suppliers
    GROUP BY medicine_id
)
SELECT
    m.name,
    i.stock_quantity,
    i.reorder_level,
    ROUND(v.avg_daily_sales, 2)                                                     AS avg_daily_sales,
    fs.lead_time_days,
    CAST(v.avg_daily_sales * fs.lead_time_days + (v.avg_daily_sales * 7) AS INTEGER) AS recommended_qty
FROM velocity         v
JOIN medicines        m  USING (medicine_id)
JOIN inventory        i  USING (medicine_id)
JOIN fastest_supplier fs USING (medicine_id)
WHERE i.stock_quantity < i.reorder_level
ORDER BY recommended_qty DESC
LIMIT 30;


-- @E2 supplier_cost_ranking
-- For the 10 most-sold medicines, rank each available supplier by cost
-- and by lead-time. The supplier with cost_rank = 1 is cheapest;
-- speed_rank = 1 is fastest. Procurement chooses the trade-off.
WITH top_movers AS (
    SELECT medicine_id
    FROM sales_transactions
    GROUP BY medicine_id
    ORDER BY SUM(quantity_sold) DESC
    LIMIT 10
)
SELECT
    s.medicine_id,
    m.name,
    s.supplier_name,
    s.unit_cost,
    s.lead_time_days,
    RANK() OVER (PARTITION BY s.medicine_id ORDER BY s.unit_cost      ASC) AS cost_rank,
    RANK() OVER (PARTITION BY s.medicine_id ORDER BY s.lead_time_days ASC) AS speed_rank
FROM suppliers s
JOIN medicines m USING (medicine_id)
WHERE s.medicine_id IN (SELECT medicine_id FROM top_movers)
ORDER BY s.medicine_id, cost_rank;
