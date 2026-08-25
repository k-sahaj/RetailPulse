/*=====================================================================
TRANSFORMATION QUERIES (refined)

Running this whole at once is not recommended -- the transformations 
are meant to be applied in order, and some of the later ones depend on 
earlier ones having been applied. Run each section in order, validate 
the results, then move on to the next section.
=====================================================================
*/
-- ---------------------------------------------------------------------
-- A. Removing exact duplicate records
-- ---------------------------------------------------------------------
WITH duplicates AS (
    SELECT
        id,
        ROW_NUMBER() OVER (
            PARTITION BY
                invoice_no, stock_code, description, quantity,
                invoice_date, unit_price, customer_id, country
            ORDER BY id
        ) AS row_num
    FROM staging_source_table
)
DELETE FROM staging_source_table
WHERE id IN (SELECT id FROM duplicates WHERE row_num > 1);

-- validate: no duplicate groups should remain
SELECT COUNT(*) AS remaining_duplicate_groups
FROM (
    SELECT 1
    FROM staging_source_table
    GROUP BY
        invoice_no, stock_code, description, quantity,
        invoice_date, unit_price, customer_id, country
    HAVING COUNT(*) > 1
) d;


-- ---------------------------------------------------------------------
-- B. Handling missing CustomerID
-- ---------------------------------------------------------------------
UPDATE staging_source_table
SET customer_id = '00000'
WHERE customer_id IS NULL;

-- validate
SELECT
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS remaining_nulls,
    COUNT(*) FILTER (WHERE customer_id = '00000') AS unknown_customer_rows,
    COUNT(DISTINCT customer_id) AS unique_customer_ids
FROM staging_source_table;


-- ---------------------------------------------------------------------
-- C. Adding cancellation flag
-- ---------------------------------------------------------------------
ALTER TABLE staging_source_table
ADD COLUMN is_cancelled BOOLEAN DEFAULT FALSE;

UPDATE staging_source_table
SET is_cancelled = TRUE
WHERE quantity < 0;

-- validate: flag should line up exactly with negative quantities
SELECT
    COUNT(*) FILTER (WHERE quantity < 0) AS negative_quantity_rows,
    COUNT(*) FILTER (WHERE is_cancelled = TRUE) AS cancelled_rows,
    COUNT(*) FILTER (WHERE is_cancelled = FALSE AND quantity < 0) AS inconsistent_rows
FROM staging_source_table;


-- ---------------------------------------------------------------------
-- D. Handling unit_price anomalies
-- ---------------------------------------------------------------------

-- baseline
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE unit_price = 0) AS zero_prices,
    COUNT(*) FILTER (WHERE unit_price < 0) AS negative_prices,
    COUNT(*) FILTER (WHERE unit_price <= 0 AND is_cancelled = FALSE) AS non_cancelled_non_positive,
    COUNT(*) FILTER (WHERE unit_price <= 0 AND is_cancelled = TRUE) AS cancelled_non_positive
FROM staging_source_table;

-- inspect negative prices directly -- low-volume, worth eyeballing before touching
SELECT id, invoice_no, stock_code, description, quantity, unit_price, customer_id, is_cancelled
FROM staging_source_table
WHERE unit_price < 0
ORDER BY id;

-- D1. Non-product rows (postage/fees/etc.) sitting at zero price -- these aren't real sales, safe to drop
-- FIX vs. previous refined draft: this delete (and its preview below) had picked up an
-- AND is_cancelled = FALSE filter that the original script never had. The original deletes
-- ANY row with a non-numeric stock_code and unit_price = 0.00, cancelled or not. Filter removed
-- here to match the original's behavior exactly.
SELECT stock_code, COUNT(*) AS rows
FROM staging_source_table
WHERE stock_code !~ '[0-9]'
  AND unit_price <= 0
GROUP BY stock_code
ORDER BY rows DESC, stock_code;

DELETE FROM staging_source_table
WHERE stock_code !~ '[0-9]'
  AND unit_price = 0.00;

-- validate
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE unit_price = 0) AS zero_price_rows,
    COUNT(*) FILTER (WHERE unit_price < 0) AS negative_price_rows
FROM staging_source_table;

-- D2. Remaining non-cancelled non-positive rows with placeholder customer + thin description
-- are low-value junk entries (likely data-entry artifacts) -- safe to drop outright
SELECT COUNT(*) AS rows_to_remove
FROM staging_source_table
WHERE unit_price <= 0
  AND is_cancelled = FALSE
  AND customer_id = '00000'
  AND description IS NOT NULL
  AND LENGTH(description) < 15;

DELETE FROM staging_source_table
WHERE unit_price <= 0
  AND is_cancelled = FALSE
  AND customer_id = '00000'
  AND description IS NOT NULL
  AND LENGTH(description) < 15;

-- D3. Impute remaining non-positive rows (zero and negative prices) using each stock_code's
-- mean of its own valid (>0) prices. This runs once, after the D2 junk-row delete -- same
-- position as the single imputation pass in the original script.
-- FIX vs. original: the average below is computed only from that stock_code's *valid* (>0)
-- prices. The original version averaged over ALL rows for the stock_code -- including the
-- zero/negative ones being fixed -- which quietly dragged the imputed value down. Any stock_code
-- with no valid positive-price comparator now correctly stays untouched and gets swept by the
-- final DELETE below, instead of being imputed from a skewed average.
WITH avg_unit_price_calculated AS (
    SELECT stock_code, ROUND(AVG(unit_price), 2) AS avg_unit_price
    FROM staging_source_table
    WHERE unit_price > 0
      AND stock_code IN (
          SELECT stock_code FROM staging_source_table
          WHERE unit_price <= 0 AND is_cancelled = FALSE
      )
    GROUP BY stock_code
)
UPDATE staging_source_table AS sst
SET unit_price = aupc.avg_unit_price
FROM avg_unit_price_calculated AS aupc
WHERE sst.unit_price <= 0
  AND sst.is_cancelled = FALSE
  AND sst.stock_code = aupc.stock_code;

-- catch-all: anything still non-positive and non-cancelled has no valid comparator -- drop it
DELETE FROM staging_source_table
WHERE unit_price <= 0
  AND is_cancelled = FALSE;

-- FINAL PRICE VALIDATION
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE unit_price < 0) AS negative_price_rows,
    COUNT(*) FILTER (WHERE unit_price = 0) AS zero_price_rows,
    COUNT(*) FILTER (WHERE unit_price <= 0 AND is_cancelled = FALSE) AS active_non_positive_prices
FROM staging_source_table;


-- ---------------------------------------------------------------------
-- E. Description validation and recovery
-- ---------------------------------------------------------------------

-- current state
SELECT
    COUNT(*) FILTER (WHERE description IS NULL OR TRIM(description) = '') AS missing_descriptions
FROM staging_source_table;

-- how many missing descriptions have a match elsewhere for the same stock_code?
SELECT COUNT(*) AS missing_rows_with_recoverable_description
FROM staging_source_table s
WHERE (s.description IS NULL OR TRIM(s.description) = '')
  AND EXISTS (
      SELECT 1 FROM staging_source_table x
      WHERE x.stock_code = s.stock_code
        AND x.description IS NOT NULL
        AND TRIM(x.description) <> ''
  );

-- FIX vs. original: the recovery check above existed before, but the actual UPDATE never used
-- it -- it just overwrote every NULL with the placeholder text. This applies the recovery for
-- real: pull a matching description from another row with the same stock_code where one exists.
UPDATE staging_source_table AS s
SET description = (
    SELECT x.description
    FROM staging_source_table x
    WHERE x.stock_code = s.stock_code
      AND x.description IS NOT NULL
      AND TRIM(x.description) <> ''
    LIMIT 1
)
WHERE (s.description IS NULL OR TRIM(s.description) = '');

-- whatever's still missing has no comparator anywhere in the dataset -- placeholder it
-- (also now catches blank-string descriptions, not just NULLs, matching the checks above)
UPDATE staging_source_table
SET description = 'orders do not have description'
WHERE description IS NULL OR TRIM(description) = '';

-- validate
SELECT
    COUNT(*) FILTER (WHERE description IS NULL OR TRIM(description) = '') AS remaining_missing,
    COUNT(*) FILTER (WHERE description = 'orders do not have description') AS placeholder_descriptions
FROM staging_source_table;


-- ---------------------------------------------------------------------
-- F. Stock code validation
-- ---------------------------------------------------------------------
-- FLAG: diagnostic only, no action taken. Non-numeric codes (POST, DOT, M, BANK CHARGES, etc.)
-- on non-cancelled rows with a POSITIVE price are still in the table. Decide deliberately
-- whether these belong in product-level sales analysis or should be excluded/moved -- don't
-- let it be an accident of what earlier price-based deletes happened to catch.
SELECT stock_code, COUNT(*) AS rows
FROM staging_source_table
WHERE stock_code !~ '[0-9]'
  AND is_cancelled = FALSE
GROUP BY stock_code
ORDER BY rows DESC, stock_code;


-- ---------------------------------------------------------------------
-- G. Invoice date validation
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE invoice_date IS NULL) AS null_invoice_dates,
    MIN(invoice_date) AS earliest_invoice_date,
    MAX(invoice_date) AS latest_invoice_date
FROM staging_source_table;


-- ---------------------------------------------------------------------
-- H. Customer validation
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE customer_id = '00000') AS placeholder_customer_ids,
    COUNT(DISTINCT customer_id) AS unique_customer_ids
FROM staging_source_table;


-- ---------------------------------------------------------------------
-- I. Final staging checkpoint
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT invoice_no) AS unique_invoices,
    COUNT(DISTINCT stock_code) AS unique_stock_codes,
    COUNT(DISTINCT NULLIF(customer_id, '00000')) AS unique_real_customers,
    COUNT(*) FILTER (WHERE quantity <= 0) AS non_positive_quantity,
    COUNT(*) FILTER (WHERE unit_price <= 0) AS non_positive_price,
    COUNT(*) FILTER (WHERE description IS NULL OR TRIM(description) = '') AS null_descriptions,
    COUNT(*) FILTER (WHERE invoice_date IS NULL) AS null_invoice_dates
FROM staging_source_table;

/*
What I fixed:

Bug — D1's delete had picked up an `is_cancelled = FALSE` filter that the original script
never had. The original deletes any row with a non-numeric stock_code and unit_price = 0.00,
regardless of cancellation status. Removed the filter so this step matches the original exactly.

Bug — an extra imputation step (previously "D2") ran immediately after D1, before the
short-description junk delete (previously "D3"). That let some rows get their price imputed
via stock_code average and therefore *survive* the junk delete that follows, which is not what
the original does -- the original deletes junk first, with a single imputation pass only
afterward. Removed the early step entirely; imputation now happens once, after the junk delete
(now D2 -> D3), in the same order as the original.

Bug — negative-price imputation was self-referential. In the avg_unit_price_calculated CTE, the average was computed over all rows for a stock_code, including the very zero/negative-price rows being fixed. This skews the average down. I filtered the inner average to unit_price > 0 only — this also means it now correctly leaves untouched any stock_code that has no valid positive-price comparator, which then gets caught cleanly by the final DELETE.

Gap — description recovery was investigated but never applied. The original script queried for recoverable descriptions (matching stock_code from other rows) but then just blanket-set everything to 'orders do not have description' without ever using the recovered values, and it only checked IS NULL (missing the TRIM = '' case). I added an actual recovery UPDATE that pulls a matching description before falling back to the placeholder, and made the placeholder step catch blank strings too.

Unresolved — Section F (non-numeric stock codes) is diagnostic only, no action taken. Codes like POST, DOT, M, BANK CHARGES etc. for non-cancelled orders with positive prices are still sitting in the table untouched. Whether that's correct depends on your downstream analysis (postage/fees may or may not belong in product-level sales data) — worth a deliberate decision rather than leaving it implicit.

So there is a chance that the reproduced dataset will differ slightly from the original, but the differences are all deliberate and defensible. The original script had a few bugs and gaps that I fixed, and I left one open question (non-numeric stock codes) for you to decide on.
*/