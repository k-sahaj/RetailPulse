-- =====================================================================
-- LOAD & INSPECTION (refined)
-- Load the source data into a staging table and perform initial inspection and sanity checks.
-- =====================================================================

DROP TABLE IF EXISTS staging_source_table CASCADE;

CREATE TABLE staging_source_table (
    id SERIAL PRIMARY KEY,
    invoice_no VARCHAR(20) NOT NULL,
    stock_code VARCHAR(50) NOT NULL CHECK (LENGTH(stock_code) > 0),
    description TEXT,
    quantity INT NOT NULL,
    invoice_date TIMESTAMP NOT NULL,
    unit_price NUMERIC(10, 2) NOT NULL,
    customer_id VARCHAR(20),
    country VARCHAR(50) NOT NULL
);

-- Import the .csv manually from local.

-- Quick post-load sanity check: did the COPY finish and does it look right?
SELECT COUNT(*) AS total_rows
FROM staging_source_table;

SELECT *
FROM staging_source_table
LIMIT 10;

-- FLAG (removed): the original null-check here also tested invoice_date, unit_price and
-- quantity for NULLs. Those three columns (plus invoice_no, stock_code, country) are declared
-- NOT NULL above, so COPY would have failed outright on load if any were null -- the check can
-- only ever return 0 and adds noise. customer_id and description are the only nullable columns,
-- and both are already covered in the baseline profile below, so the separate query is dropped.

-- Baseline profile
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT invoice_no) AS unique_invoices,
    COUNT(DISTINCT stock_code) AS unique_stock_codes,
    COUNT(DISTINCT customer_id) AS unique_customers,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS missing_customer_ids,
    COUNT(*) FILTER (WHERE description IS NULL) AS missing_descriptions,
    COUNT(*) FILTER (WHERE quantity <= 0) AS non_positive_quantity,
    COUNT(*) FILTER (WHERE unit_price <= 0) AS non_positive_unit_price,

    -- FLAG (renamed): this was originally called `cancellation_invoices` but it's COUNT(*),
    -- i.e. a row count, not COUNT(DISTINCT invoice_no). With multiple line items per invoice
    -- these two numbers differ a lot -- renamed here to avoid conflating them. The true
    -- distinct-invoice version is computed separately below.
    COUNT(*) FILTER (WHERE invoice_no LIKE 'C%') AS cancellation_rows
FROM staging_source_table;

-- Duplicate analysis: how many groups are duplicated, and how many excess rows do they add?
-- (combined into one pass over the grouped result instead of scanning twice)
SELECT
    COUNT(*) AS duplicate_groups,
    COALESCE(SUM(occurrence_count - 1), 0) AS excess_duplicate_rows
FROM (
    SELECT COUNT(*) AS occurrence_count
    FROM staging_source_table
    GROUP BY
        invoice_no, stock_code, description, quantity,
        invoice_date, unit_price, customer_id, country
    HAVING COUNT(*) > 1
) d;

-- Cancellation structure: row-level vs. invoice-level counts, in one pass
SELECT
    COUNT(*) FILTER (WHERE invoice_no LIKE 'C%') AS cancelled_rows,
    COUNT(*) FILTER (WHERE invoice_no NOT LIKE 'C%') AS normal_rows,
    COUNT(DISTINCT invoice_no) FILTER (WHERE invoice_no LIKE 'C%') AS cancelled_invoices,
    COUNT(DISTINCT invoice_no) FILTER (WHERE invoice_no NOT LIKE 'C%') AS normal_invoices
FROM staging_source_table;

-- Zero/negative prices: breakdown by exact value tells you whether it's just $0 rows
-- or genuine negative values mixed in
SELECT
    unit_price,
    COUNT(*) AS rows
FROM staging_source_table
WHERE unit_price <= 0
GROUP BY unit_price
ORDER BY unit_price;

-- how widespread is it across distinct products?
SELECT
    COUNT(*) FILTER (WHERE unit_price = 0) AS zero_price_rows,
    COUNT(DISTINCT stock_code) FILTER (WHERE unit_price = 0) AS affected_stock_codes
FROM staging_source_table;