# 🗄️ SQL Pipeline

This folder holds the full transformation pipeline that turns the raw `OnlineRetail.csv` file into a clean, normalized, analytics-ready PostgreSQL database. Everything here is designed to be run **in order**, top to bottom, once per file — each script depends on the state left behind by the one before it.

```
01_load_and_inspection.sql   →   02_transformation.sql   →   03_normalization.sql   →   analytics.sql
   (load + profile)               (clean the staging          (flat table → 5-table         (RFM, cohort,
                                    table in place)              relational schema)            market basket)
```

> 🧭 Before starting here, make sure you've completed the data prep steps in **[`data/README.md`](../data/)** — you'll need `OnlineRetail.csv` ready to import.

---

## 📜 Files in this folder

### `01_load_and_inspection.sql`
**Purpose:** Creates the flat staging table and loads the raw CSV into it, then runs an initial diagnostic pass — before any cleaning happens.

**What it does:**
- Drops and recreates `staging_source_table` (8 raw columns + surrogate `id`)
- *(Manual step, noted inline)*: the `.csv` is imported into this table via your tool of choice — see [`data/README.md`](../data/) for `\copy` / pgAdmin instructions
- Runs a **baseline profile**: total rows, distinct invoices/stock codes/customers, missing `customer_id`/`description` counts, non-positive quantity/price counts, and cancellation-row counts (`invoice_no LIKE 'C%'`)
- Runs a **duplicate analysis**: how many exact-duplicate row groups exist, and how many excess rows they add
- Runs a **cancellation structure** check: row-level vs. invoice-level cancellation counts (these differ because one invoice can have many line items)
- Profiles **zero/negative unit prices** by exact value, and how many distinct products are affected

**Why it matters:** This is your "ground truth" snapshot of exactly how messy the raw export is, before you touch anything. Every number here becomes the "before" side of the before/after comparison you validate against in the next script.

---

### `02_transformation.sql`
**Purpose:** Cleans `staging_source_table` in place. This is the largest and most consequential file in the pipeline — read the header comment block before running it.

> ⚠️ **Run section by section, not all at once.** The transformations are ordered on purpose (later steps assume earlier ones already ran), and each section is followed by a validation query you should check before moving to the next.

**What it does, in order:**

| Section | Action |
|---|---|
| **A. Duplicate removal** | Deletes exact-duplicate rows (same invoice, stock code, description, quantity, date, price, customer, country) via `ROW_NUMBER()`, keeping the first occurrence |
| **B. Missing `customer_id`** | Fills `NULL` customer IDs with a `'00000'` placeholder, preserving revenue-bearing rows instead of dropping them |
| **C. Cancellation flag** | Adds an `is_cancelled BOOLEAN` column, set `TRUE` wherever `quantity < 0` |
| **D. Unit price anomalies** | Multi-step resolution of zero/negative prices: drops non-product junk rows (postage/fees at £0), drops low-value junk entries, then imputes remaining zero/negative prices using each stock code's own average of valid (`> 0`) prices — anything with no valid comparator is dropped |
| **E. Description recovery** | Recovers missing/blank descriptions by matching another row with the same `stock_code`; anything still missing gets a `'orders do not have description'` placeholder |
| **F. Stock code validation** | *Diagnostic only* — flags non-numeric stock codes (`POST`, `DOT`, `M`, `BANK CHARGES`, etc.) on non-cancelled, positively-priced rows for a deliberate downstream decision; no rows are deleted here |
| **G. Invoice date validation** | Confirms no null dates and reports the min/max date range |
| **H. Customer validation** | Confirms placeholder vs. real customer ID counts |
| **I. Final staging checkpoint** | A full re-run of the baseline profile from script 01, so you can diff before/after side by side |

**Why it matters:** This is where raw, inconsistent data becomes trustworthy. Every deletion, imputation, and flag here is logged and validated immediately after — nothing is silently dropped. The file's closing comment block also documents three bugs found and fixed versus an earlier draft of this script (a stray filter on the postage-row delete, an out-of-order imputation step, and a self-referential average in the price-imputation logic) — worth reading if you want to understand *why* certain choices were made, not just what they do.

---

### `03_normalization.sql`
**Purpose:** Decomposes the now-clean flat `staging_source_table` into a governed, five-table relational schema.

**What it does:**
- Drops and rebuilds (in dependency order) five tables:

  | Table | Grain | Key relationships |
  |---|---|---|
  | `customers` | 1 row / customer | Parent to `invoices.customer_id` |
  | `products` | 1 row / stock code | Parent to `product_details` and `invoice_items` |
  | `product_details` | 1 row / (description, price, product) | `FOREIGN KEY → products` |
  | `invoices` | 1 row / invoice (header-level) | `FOREIGN KEY → customers` |
  | `invoice_items` | 1 row / line item (fact table) | `FOREIGN KEY → invoices`, `FOREIGN KEY → products` |

- Populates each table from `staging_source_table`, with `ON CONFLICT DO NOTHING` guards and `DISTINCT ON` collapsing where duplicate header rows could otherwise violate a primary key
- Runs a sanity-check row count after every table is populated (e.g. confirming `invoices` row count matches distinct invoice numbers)

**Why it matters:** This is the schema every downstream query in `analytics.sql`, `EDA/`, and `Analysis/` actually queries against. Splitting `product_details` out from `products` matters specifically because a single `stock_code` can appear with multiple description/price combinations across the dataset's timespan — cramming that into `products` directly would force a false 1:1 assumption.

---

### `analytics.sql`
**Purpose:** The advanced-analytics layer — run this only after `01`, `02`, and `03` are complete. Produces the core analytical outputs used throughout `EDA/`, `Analysis/`, and the final case study.

**What it does, in four sections:**

| Section | Output |
|---|---|
| **5A. RFM Segmentation** | Scores every customer 1–5 on Recency, Frequency, and Monetary value (via `NTILE(5)` quintiles), combines them into an overall score (3–15), and buckets customers into five business-friendly segments (**Champions, Returning and Loyal, Less Frequent but Loyal, At Risk, Dormant**). Returns one row per segment with customer count and % share. |
| **5B. RFM Customer-Level Output** | Same scoring logic, returned at the individual customer grain (rather than aggregated), with a small random jitter added purely for scatter-plot visualization — not part of the underlying score. |
| **6. Cohort Analysis** | Groups customers into monthly acquisition cohorts by first completed purchase, then counts active customers in each subsequent month — the raw material for a retention heatmap/curve. |
| **7. Market Basket Analysis** | Self-joins `invoice_items` on shared `invoice_no` (with `a.stock_code < b.stock_code` to avoid mirrored/duplicate pairs) to find product pairs that co-occur in more than 50 distinct invoices, ranked by co-occurrence count. |

**Why it matters:** This file is where the pipeline stops being "clean data" and starts being "business insight." Every chart in the [`Analysis/`](../Analysis/) notebook and the dashboard's segmentation/retention views traces back to a query in this file.

---

## ▶️ How to Proceed

1. Stand up a PostgreSQL database (the notebooks default to a database named `sikkaretail_db` — rename as you like, just keep it consistent).
2. Run `01_load_and_inspection.sql` — create the staging table, import the CSV (see [`data/README.md`](../data/)), and review the baseline profile output.
3. Run `02_transformation.sql` **section by section**, checking each validation query before moving to the next section.
4. Run `03_normalization.sql` to build the five-table relational schema from the cleaned staging data.
5. Run `analytics.sql` to generate the RFM, cohort, and market basket outputs.
6. Move on to **[`EDA/README.md`](../EDA/)** and **[`Analysis/README.md`](../Analysis/)** to see these queries turned into charts and narrative insight.

> 💡 Every query in this pipeline can be run directly in `psql`, pgAdmin, or pulled into Python via `psycopg2` (as the notebooks in `EDA/` and `Analysis/` do).
