import pandas as pd


input_file = r"C:\local disk C files\OneDrive\Desktop\PPrep\DS\Data_Analyst_Projects\RetailPulse\data\Online Retail.xlsx"
output_file = r"C:\local disk C files\OneDrive\Desktop\PPrep\DS\Data_Analyst_Projects\RetailPulse\data\OnlineRetail.csv"

df = pd.read_excel(input_file)

print(df.shape)
print(df.columns.tolist())
print(df.dtypes)

df.to_csv(output_file, index=False)

print(f"\nSaved to: {output_file}")