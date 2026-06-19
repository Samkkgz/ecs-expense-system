import os
from pdfminer.high_level import extract_text
import pandas as pd
from openpyxl import Workbook
from datetime import datetime

# --- Configuration ---
BASE_DIR = "/Users/sam.lu/Documents/Business Related/Finance/Expenses/ECS  Expanses"
MAY_DIR = os.path.join(BASE_DIR, "May 2026")
JUNE_DIR = os.path.join(BASE_DIR, "June 2026")
OUTPUT_FILENAME = "ECS报销明细表.xlsx"

# --- Helper Functions ---

def extract_text_from_pdf(pdf_path):
    """Extracts text content from a given PDF file path."""
    try:
        print(f"--- Extracting text from: {os.path.basename(pdf_path)} ---")
        text = extract_text(str(pdf_path))
        return text
    except Exception as e:
        print(f"Error reading PDF {os.path.basename(pdf_path)}: {e}")
        return None

def parse_invoice_data(text, pdf_path):
    """
    Placeholder function to simulate parsing structured data from raw text.
    In a real-world scenario, this would involve complex regex or NLP based on invoice layouts.
    For now, we'll extract basic metadata and assume some structure for demonstration.
    """
    if not text:
        return None

    # Simple heuristic extraction based on file name/path context if possible
    filename = os.path.basename(pdf_path)
    date_str = datetime.now().strftime("%Y-%m-%d") # Defaulting date for simulation
    amount = "N/A"
    description = f"Processed from invoice: {filename}"
    vendor = "Unknown Vendor"

    # Attempt to get a more specific date if the filename suggests it (e.g., contains YYYYMMDD)
    import re
    date_match = re.search(r'(\d{4})[0-9]{2}[0-9]{2}', filename)
    if date_match:
        # Assuming YYYYMMDD format from filenames like 26317000002024207309.pdf
        date_str = f"{date_match.group(1)}-{date_match.group(2):<2}{date_match.group(3):<2}"

    # Since we cannot reliably parse all invoice types without knowing their exact structure,
    # we will use a placeholder structure that the user can refine later.
    return {
        "原始文件名": filename,
        "提取日期": date_str,
        "金额": amount,
        "报销项目描述": description,
        "供应商/商家": vendor,
        "原始文本摘要": text[:500].replace("\n", " ") + "..." # Keep a snippet of the raw text
    }

def process_all_invoices():
    """Main function to orchestrate extraction and report generation."""
    all_records = []
    pdf_files = []

    # 1. Collect all PDFs
    print("Scanning directories for PDF invoices...")
    for directory in [MAY_DIR, JUNE_DIR]:
        if os.path.isdir(directory):
            for filename in os.listdir(directory):
                if filename.lower().endswith(".pdf"):
                    full_path = os.path.join(directory, filename)
                    pdf_files.append(full_path)

    if not pdf_files:
        print("No PDF files found in the specified directories.")
        return None

    # 2. Process each PDF
    for pdf_path in pdf_files:
        text = extract_text_from_pdf(pdf_path)
        record = parse_invoice_data(text, pdf_path)
        if record:
            all_records.append(record)

    if not all_records:
        print("Failed to process any records.")
        return None

    # 3. Create DataFrame and Report
    df = pd.DataFrame(all_records)
    print("\n--- Data Extraction Complete ---")
    print(f"Successfully processed {len(df)} records.")

    try:
        # Use openpyxl engine for writing, as pandas might default to xlsxwriter which needs setup
        with pd.ExcelWriter(OUTPUT_FILENAME, engine='openpyxl') as writer:
            df.to_excel(writer, sheet_name="报销明细", index=False)
        print(f"\n✅ Success! The consolidated report has been saved to {OUTPUT_FILENAME}")
    except Exception as e:
        print(f"Error writing Excel file: {e}")
        return None

    return OUTPUT_FILENAME

if __name__ == "__main__":
    process_all_invoices()
