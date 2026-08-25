/* ================================================================
   CUSTOMER ANALYTICS SECTION
   (run this after you're done with laod_and_inspection.sql, 
    transformations.sql and normalization.sql)
   ----------------------------------------------------------------
   Purpose : End-to-end customer analytics on transactional retail
             data — RFM segmentation, cohort retention, and market
             basket (product affinity) analysis.

   Source tables
     - invoices        (invoice_no, customer_id, invoice_date,
                         is_cancelled, ...)
     - invoice_items    (invoice_no, stock_code, quantity,
                         unit_price, ...)

   Sections
     5A. RFM Segmentation            — customer scoring & segment summary
     5B. RFM Customer-Level Output   — per-customer RFM scores
     6.  Cohort Analysis             — monthly acquisition cohorts & retention
     7.  Market Basket Analysis      — frequently co-purchased product pairs
   ================================================================ */


-- ================================================================
-- 5A. RFM SEGMENTATION
-- ----------------------------------------------------------------
-- Scores every customer on Recency, Frequency, and Monetary value
-- (1-5 scale via NTILE quintiles), then buckets customers into
-- business-friendly segments. Output: one row per segment with
-- customer count and % share of the customer base.
-- ================================================================

WITH customers_orders AS (
    -- One row per customer: last purchase date, order frequency,
    -- and total spend. Cancelled orders and the anonymous "00000"
    -- guest ID are excluded so metrics reflect real, completed purchases.
    SELECT
        i.customer_id,
        MAX(i.invoice_date)                    AS last_purchase_date,
        COUNT(DISTINCT i.invoice_no)            AS frequency,
        SUM(ii.quantity * ii.unit_price)        AS monetary
    FROM invoices i
    JOIN invoice_items ii
        ON i.invoice_no = ii.invoice_no
    WHERE
        i.is_cancelled = FALSE
        AND i.customer_id != '00000'
    GROUP BY
        i.customer_id
),

rfm_calculation AS (
    -- Converts raw R/F/M values into 1-5 quintile scores.
    -- Reference date (2012-01-01) represents "today" for this dataset's
    -- analysis window; adjust to your own as-of date as needed.
    SELECT
        customer_id,

        DATE_PART('day', DATE '2012-01-01' - last_purchase_date)
            AS days_since_last_purchase,

        frequency,
        monetary,

        -- Recency: fewer days since last purchase = better,
        -- so the raw NTILE rank is inverted (6 - rank).
        (6 - NTILE(5) OVER (
            ORDER BY DATE_PART('day', DATE '2012-01-01' - last_purchase_date)
        )) AS recency_score,

        -- Frequency: more orders = better, so rank ascends naturally.
        NTILE(5) OVER (ORDER BY frequency) AS frequency_score,

        -- Monetary: higher spend = better, so rank ascends naturally.
        NTILE(5) OVER (ORDER BY monetary) AS monetary_score

    FROM customers_orders
),

rfm_score AS (
    -- Combines the three component scores into one overall RFM score (3-15).
    SELECT
        customer_id,
        recency_score,
        frequency_score,
        monetary_score,
        (recency_score + frequency_score + monetary_score) AS overall_rfm_score
    FROM rfm_calculation
),

segments AS (
    -- Maps score ranges to human-readable customer segments.
    -- Thresholds below are illustrative and can be tuned per business context.
    SELECT
        customer_id,
        overall_rfm_score,

        CASE
            WHEN recency_score = 5
             AND frequency_score = 5
             AND monetary_score = 5
                THEN 'Champions'                    -- best on all 3 dimensions

            WHEN overall_rfm_score >= 12
                THEN 'Returning and Loyal'

            WHEN overall_rfm_score >= 9
                THEN 'Less Frequent but Loyal'

            WHEN overall_rfm_score >= 6
                THEN 'At Risk'

            ELSE 'Dormant'
        END AS customer_segment

    FROM rfm_score
)

SELECT
    customer_segment,
    COUNT(*) AS customer_count,
    ROUND(
        COUNT(*) * 100.0 / (SELECT COUNT(*) FROM segments),
        2
    ) AS segment_percentage
FROM segments
GROUP BY customer_segment
ORDER BY customer_count DESC;


-- ================================================================
-- 5B. RFM CUSTOMER-LEVEL OUTPUT
-- ----------------------------------------------------------------
-- Same RFM scoring logic as 5A, but returned at the individual
-- customer grain (rather than aggregated by segment). A small
-- random jitter is added to each score purely for downstream
-- visualization purposes (e.g. scatter plots), so points don't
-- overlap exactly on integer grid lines.
-- ================================================================

WITH customers_orders AS (
    SELECT
        i.customer_id,
        MAX(i.invoice_date)                    AS last_purchase_date,
        COUNT(DISTINCT i.invoice_no)            AS frequency,
        SUM(ii.quantity * ii.unit_price)        AS monetary
    FROM invoices i
    JOIN invoice_items ii
        ON i.invoice_no = ii.invoice_no
    WHERE
        i.is_cancelled = FALSE
        AND i.customer_id != '00000'
    GROUP BY
        i.customer_id
),

rfm_calculation AS (
    SELECT
        customer_id,

        DATE_PART('day', DATE '2012-01-01' - last_purchase_date)
            AS days_since_last_purchase,

        frequency,
        monetary,

        6 - NTILE(5) OVER (
            ORDER BY DATE_PART('day', DATE '2012-01-01' - last_purchase_date)
        ) AS recency_score,

        NTILE(5) OVER (ORDER BY frequency) AS frequency_score,
        NTILE(5) OVER (ORDER BY monetary)  AS monetary_score

    FROM customers_orders
)

SELECT
    customer_id,

    -- NOTE: RANDOM() jitter is for visualization spread only —
    -- it is not part of the underlying RFM score.
    ROUND((recency_score + RANDOM())::NUMERIC, 2)   AS recency,
    ROUND((frequency_score + RANDOM())::NUMERIC, 2) AS frequency,
    ROUND((monetary_score + RANDOM())::NUMERIC, 2)  AS monetary,

    (recency_score + frequency_score + monetary_score) AS overall_rfm_score

FROM rfm_calculation
ORDER BY overall_rfm_score DESC;


-- ================================================================
-- 6. COHORT ANALYSIS
-- ----------------------------------------------------------------
-- Groups customers into monthly acquisition cohorts (by first
-- purchase month) and tracks how many customers from each cohort
-- remain active in each subsequent month. Useful for building a
-- cohort retention heatmap/matrix.
-- ================================================================

WITH first_purchase AS (
    -- Each customer's first (earliest) completed purchase date.
    SELECT
        customer_id,
        MIN(invoice_date) AS first_purchase_date
    FROM invoices
    WHERE is_cancelled = FALSE
    GROUP BY customer_id
),

customer_orders AS (
    -- Every completed order tagged with its cohort month and how
    -- many months elapsed since that customer's first purchase.
    SELECT
        i.customer_id,
        i.invoice_date,
        fp.first_purchase_date,

        DATE_TRUNC('month', fp.first_purchase_date) AS cohort_month,

        (
            (DATE_PART('year', i.invoice_date) * 12 + DATE_PART('month', i.invoice_date))
            -
            (DATE_PART('year', fp.first_purchase_date) * 12 + DATE_PART('month', fp.first_purchase_date))
        ) AS months_since_first_purchase

    FROM invoices i
    JOIN first_purchase fp
        ON i.customer_id = fp.customer_id
    WHERE
        i.is_cancelled = FALSE
)

SELECT
    TO_CHAR(cohort_month, 'YYYY-MM')   AS cohort,
    months_since_first_purchase,
    COUNT(DISTINCT customer_id)        AS active_customers
FROM customer_orders
GROUP BY
    cohort_month,
    months_since_first_purchase
ORDER BY
    cohort_month,
    months_since_first_purchase;


-- ================================================================
-- 7. MARKET BASKET ANALYSIS
-- ----------------------------------------------------------------
-- Identifies pairs of products frequently purchased together
-- (co-occurring in the same invoice). Self-join on invoice_items
-- with a < b avoids duplicate/mirrored pairs and self-pairing.
-- Only pairs appearing together in more than 50 distinct invoices
-- are returned, ranked by co-occurrence frequency.
-- ================================================================

SELECT
    a.stock_code                       AS product_a,
    b.stock_code                       AS product_b,
    COUNT(DISTINCT a.invoice_no)       AS co_occurrence_count
FROM invoice_items a
JOIN invoice_items b
    ON a.invoice_no = b.invoice_no
    AND a.stock_code < b.stock_code    -- avoids (A,B)/(B,A) duplicates and A-A self pairs
GROUP BY
    a.stock_code,
    b.stock_code
HAVING
    COUNT(DISTINCT a.invoice_no) > 50
ORDER BY
    co_occurrence_count DESC
LIMIT 10;