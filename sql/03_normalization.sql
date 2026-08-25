/* ================================================================
   DATABASE NORMALIZATION — STAR/RELATIONAL SCHEMA BUILD
   ----------------------------------------------------------------
   Purpose : Normalizes a flat staging table (staging_source_table)
             into a relational schema of 5 tables, removing
             redundancy and enforcing referential integrity via
             foreign keys.

   Source  : staging_source_table — a single denormalized table
             (e.g. raw retail transaction export) containing
             customer, product, and invoice line-item data mixed
             together in one wide format.

   Resulting schema
     customers        — one row per unique customer
     products         — one row per unique stock/product code
     product_details  — description & price info per product
     invoices         — one row per unique invoice (header-level)
     invoice_items     — one row per line item on an invoice

   Build order matters: parent tables (customers, products) are
   created and populated before child tables (product_details,
   invoices, invoice_items) that reference them via foreign key.
   ================================================================ */


-- ================================================================
-- 0. RESET
-- ----------------------------------------------------------------
-- Drops existing tables (if re-running this script) in reverse
-- dependency order, using CASCADE to also drop any dependent
-- constraints/objects. Safe to run repeatedly during development.
-- ================================================================

DROP TABLE IF EXISTS invoice_items CASCADE;
DROP TABLE IF EXISTS invoices CASCADE;
DROP TABLE IF EXISTS product_details CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS customers CASCADE;


-- ================================================================
-- A. CUSTOMERS
-- ----------------------------------------------------------------
-- Deduplicated customer list with their country. This is the
-- parent table referenced by invoices.customer_id.
-- ================================================================

CREATE TABLE customers (
    id      VARCHAR(20) PRIMARY KEY,
    country VARCHAR(50)
);

-- Populate from staging data, skipping rows with a null customer_id
-- (typically guest/unidentified transactions). ON CONFLICT DO NOTHING
-- guards against duplicate customer_id values in the source data.
INSERT INTO customers (id, country)
SELECT DISTINCT
    customer_id,
    country
FROM staging_source_table
WHERE customer_id IS NOT NULL
ON CONFLICT (id) DO NOTHING;

-- Sanity check: row count for customers table.
SELECT COUNT(*) AS customer_count
FROM customers;


-- ================================================================
-- B. PRODUCTS
-- ----------------------------------------------------------------
-- Deduplicated list of product/stock codes. Kept as a slim table
-- (just the key) so it can be safely referenced by both
-- product_details and invoice_items without duplicating attributes.
-- ================================================================

CREATE TABLE products (
    stock_code VARCHAR(50) PRIMARY KEY
);

INSERT INTO products (stock_code)
SELECT DISTINCT stock_code
FROM staging_source_table;

-- Sanity check: row count for products table.
SELECT COUNT(*) AS product_count
FROM products;


-- ================================================================
-- C. PRODUCT DETAILS
-- ----------------------------------------------------------------
-- Descriptive attributes (description, unit_price) split out from
-- products since a single stock_code can appear with multiple
-- description/price combinations in the source data over time.
-- Surrogate SERIAL key avoids forcing a false 1:1 constraint on
-- products_id.
-- ================================================================

CREATE TABLE product_details (
    id           SERIAL PRIMARY KEY,
    description  TEXT,
    unit_price   NUMERIC(10,2),
    products_id  VARCHAR(50),
    CONSTRAINT product_fk
        FOREIGN KEY (products_id)
        REFERENCES products (stock_code)
        ON DELETE SET NULL
);

INSERT INTO product_details (description, unit_price, products_id)
SELECT DISTINCT
    description,
    unit_price,
    stock_code
FROM staging_source_table;

-- Sanity check: row count for product_details table.
SELECT COUNT(*) AS product_detail_count
FROM product_details;


-- ================================================================
-- D. INVOICES
-- ----------------------------------------------------------------
-- Header-level record: one row per unique invoice_no, capturing
-- the invoice date, customer, and cancellation flag. DISTINCT ON
-- collapses any duplicate header rows in the staging data down to
-- a single representative row per (invoice_no, customer_id,
-- is_cancelled) combination, keeping the earliest invoice_date.
-- ================================================================

CREATE TABLE invoices (
    invoice_no    VARCHAR(20) PRIMARY KEY,
    invoice_date  TIMESTAMP NOT NULL,
    customer_id   VARCHAR(20),
    is_cancelled  BOOLEAN DEFAULT FALSE,
    CONSTRAINT customer_fk
        FOREIGN KEY (customer_id)
        REFERENCES customers (id)
        ON DELETE SET NULL
);

INSERT INTO invoices (invoice_no, invoice_date, customer_id, is_cancelled)
SELECT DISTINCT ON (invoice_no, customer_id, is_cancelled)
    invoice_no,
    invoice_date,
    customer_id,
    is_cancelled
FROM staging_source_table
ORDER BY
    invoice_no,
    customer_id,
    is_cancelled,
    invoice_date;

-- Sanity check: total rows vs. distinct invoice numbers should match
-- (confirms no duplicate invoice_no values slipped through).
SELECT
    COUNT(*)                    AS invoice_rows,
    COUNT(DISTINCT invoice_no)  AS unique_invoice_numbers
FROM invoices;


-- ================================================================
-- E. INVOICE ITEMS
-- ----------------------------------------------------------------
-- Line-item (fact) table: one row per product sold on an invoice,
-- with quantity and the price at time of sale. References both
-- invoices and products, forming the many-to-many link between them.
-- ================================================================

CREATE TABLE invoice_items (
    invoice_item_id  SERIAL PRIMARY KEY,
    invoice_no       VARCHAR(20),
    stock_code       VARCHAR(20),
    quantity         INT NOT NULL,
    unit_price       NUMERIC(10,2) NOT NULL,
    CONSTRAINT invoice_no_fk
        FOREIGN KEY (invoice_no)
        REFERENCES invoices (invoice_no),
    CONSTRAINT products_fk
        FOREIGN KEY (stock_code)
        REFERENCES products (stock_code)
);

INSERT INTO invoice_items (invoice_no, stock_code, quantity, unit_price)
SELECT
    invoice_no,
    stock_code,
    quantity,
    unit_price
FROM staging_source_table;

-- Sanity check: line-item count plus how many distinct invoices/products
-- are represented — useful for spotting orphaned or missing references.
SELECT
    COUNT(*)                    AS invoice_item_rows,
    COUNT(DISTINCT invoice_no)  AS invoices,
    COUNT(DISTINCT stock_code)  AS products
FROM invoice_items;