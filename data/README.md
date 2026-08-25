# 📦 Data

This folder documents the source dataset for RetailPulse and provides the script used to convert it from its original Excel format into a database-loadable CSV. The raw data file itself is **not committed to this repository** (it's a third-party dataset — see [Getting the data](#-getting-the-data) below to download it yourself).

---

## 📖 Dataset Overview

RetailPulse is built on the **[Online Retail Dataset](https://archive.ics.uci.edu/dataset/352/online+retail)**, published by the UCI Machine Learning Repository.

| | |
|---|---|
| **Source** | UCI Machine Learning Repository |
| **Dataset name** | Online Retail |
| **Records** | 541,909 transactions (invoice line items) |
| **Time period** | 1 December 2010 – 9 December 2011 |
| **Business** | A UK-based, registered non-store online retailer selling unique all-occasion gifts |
| **Format as downloaded** | `Online Retail.xlsx` (single sheet) |
| **License** | CC BY 4.0 (per UCI listing) |

### Column dictionary

| Column | Description | Type |
|---|---|---|
| `InvoiceNo` | 6-digit unique invoice number. Invoices starting with **`C`** indicate a cancellation. | String |
| `StockCode` | 5-digit unique product/item code. | String |
| `Description` | Product name. | String |
| `Quantity` | Number of units per transaction line. Negative values correspond to cancellations. | Integer |
| `InvoiceDate` | Date and time the invoice was generated. | DateTime |
| `UnitPrice` | Product price per unit, in £ (sterling). | Float |
| `CustomerID` | 5-digit unique customer identifier. A meaningful share of rows have no `CustomerID` — these are treated in the SQL pipeline as unidentified/guest transactions. | Integer (nullable) |
| `Country` | Name of the country where the customer resides. | String |

These raw column names are renamed to `snake_case` (`invoice_no`, `stock_code`, `description`, `quantity`, `invoice_date`, `unit_price`, `customer_id`, `country`) once loaded into PostgreSQL — see [`sql/01_load_and_inspection.sql`](../sql/01_load_and_inspection.sql).

---

## ⬇️ Getting the Data

1. Go to the official UCI dataset page:
   **[https://archive.ics.uci.edu/dataset/352/online+retail](https://archive.ics.uci.edu/dataset/352/online+retail)**
2. Download the dataset archive and extract `Online Retail.xlsx`.
3. Place the file inside this `data/` folder (or update the path in `data_to_csv.py` — see below).

> ℹ️ The dataset is not redistributed in this repository in order to respect the original publisher's distribution terms. Always pull it fresh from the UCI source above.

---

## 🔄 Loading & Conversion Guide

The database load step in this pipeline expects a **CSV**, not the original `.xlsx` file. [`data_to_csv.py`](data_to_csv.py) handles that conversion.

### Step 1 — Convert Excel to CSV

```bash
pip install pandas openpyxl
```

Update the `input_file` and `output_file` paths at the top of [`data_to_csv.py`](data_to_csv.py) to point to your local copy of the workbook, then run it:

```bash
python data_to_csv.py
```

The script:
1. Reads `Online Retail.xlsx` with `pandas.read_excel`
2. Prints the shape, column names, and dtypes as a quick sanity check
3. Writes the result out to `OnlineRetail.csv` (no index column)

```python
df = pd.read_excel(input_file)
print(df.shape)
print(df.columns.tolist())
print(df.dtypes)
df.to_csv(output_file, index=False)
```

### Step 2 — Load the CSV into PostgreSQL

Once you have `OnlineRetail.csv`, it's loaded into a flat staging table before any cleaning happens. The table definition lives in [`sql/01_load_and_inspection.sql`](../sql/01_load_and_inspection.sql)


Import the CSV into this table using whichever tool suits your workflow, for example:

- **pgAdmin** — right-click the table → *Import/Export Data* → point it at `OnlineRetail.csv`, matching columns to the schema above (header row = yes).
- **psql `\copy`** (run from your local machine, not the server, so it can see the file):
  ```bash
  \copy staging_source_table (invoice_no, stock_code, description, quantity, invoice_date, unit_price, customer_id, country) FROM 'OnlineRetail.csv' WITH (FORMAT csv, HEADER true);
  ```
  

➡️ **Next:** head to **[`sql/README.md`](../sql/)** for the full cleaning → normalization → analytics pipeline.
