# 📊 DocChat Custom Evaluation Dataset (Benchmark Subset)

This document provides a comprehensive overview of the evaluation dataset curated for **DocChat**, our Visual Document Q&A and Information Extraction system powered by Microsoft's multimodal **UDOP** model.

---

## 1. Overview & Objectives

In accordance with the Computer Vision Course Project Guidelines, this dataset represents a **curated multimodal benchmark subset** designed to evaluate our end-to-end pipeline's ability to extract key-value fields, tabular records, and structured information from scanned document images. 

Rather than utilizing massive generic archives, we have constructed a **high-precision custom benchmark** consisting of three distinct domain templates, covering the most common real-world use cases of document intelligence.

---

## 2. Dataset Composition & Structure

The dataset resides in the `dataset/` directory and consists of high-contrast, rasterized document images along with a standardized ground-truth query-answer JSON dictionary.

### Directory Architecture:
```
dataset/
  ├── sample_invoice.png       # Financial Invoice Template
  ├── sample_receipt.png       # Scanned Cafe Retail Receipt Template
  ├── sample_form.png          # Academic Registration Form Template
  └── annotations.json         # Standardized ground-truth Q&A annotation mappings
```

---

## 3. Detailed Template Profiles

### 🧾 Template A: Financial Invoice (`sample_invoice.png`)
* **Domain**: Accounts Payable & Corporate Billing.
* **Layout Characteristics**: Tabular structure, vertical column bounds, metadata grids (Invoice #, Date, Customer details).
* **Evaluation Targets**:
  * Total balance due extraction (multi-step numerical scanning).
  * Date mapping (billing date vs due date).
  * Line-item description reading.

### ☕ Template B: Retail Cafe Receipt (`sample_receipt.png`)
* **Domain**: Expense Tracking & Point of Sale (POS) Extraction.
* **Layout Characteristics**: Narrow aspect ratio, single-column list structure, terminal transactional formatting (Subtotals, GST, Totals).
* **Evaluation Targets**:
  * Quantity multipliers extraction (e.g., `1x`, `2x`).
  * Final total matching.
  * Transaction metadata matching (Time, Receipt #).

### 📝 Template C: Student Registration Form (`sample_form.png`)
* **Domain**: Forms Processing & Administrative Digitization.
* **Layout Characteristics**: Label-value horizontal alignment, structured boundary boxes, signature line details.
* **Evaluation Targets**:
  * Entity name mapping (Student Name, Student ID, Email).
  * Handwriting-style text block segment OCR.
  * Instructor field association.

---

## 4. Ground-Truth Annotation Schema (`annotations.json`)

To facilitate automated, reproducible benchmark testing, the dataset is annotated in a standardized JSON schema. Each document features a set of test questions paired with exact, expected ground-truth answers:

```json
{
    "dataset_name": "DocChat evaluation benchmark subset",
    "total_documents": 3,
    "format": "png",
    "samples": [
        {
            "file_name": "sample_invoice.png",
            "document_type": "invoice",
            "annotations": [
                {"question": "What is the invoice number?", "answer": "GT-98432"},
                {"question": "Who is the customer?", "answer": "John Doe"},
                {"question": "What is the billing date?", "answer": "2026-05-24"},
                {"question": "What is the total due?", "answer": "$205.70"}
            ]
        },
        ...
    ]
}
```

---

## 5. Preprocessing & Formatting Pipeline

Before documents are passed to Microsoft's UDOP processor, they undergo a systematic preprocessing pipeline to ensure maximum OCR extraction fidelity and spatial accuracy:

1. **Resolution Standardization**: All input canvases are standardized to high-density layouts (e.g., $800 \times 1000$ pixels) to match the internal transformer input coordinates.
2. **Grayscale Binarization**: Scans are dynamically thresholded using PIL to increase Tesseract's character segmentation accuracy.
3. **Bounding Box Normalization**: Bounding boxes detected by Tesseract OCR are normalized to the standard $[0, 1000]$ coordinate range required by UDOP’s layout embeddings.

---

## 6. Ethical and Legal Considerations

* **Privacy & Anonymization**: All names, companies, email addresses, and student IDs are fully synthetic mock values (e.g., "John Doe", "johndoe@fast.edu.pk"). No real personally identifiable information (PII) is included.
* **Licensing**: All document templates are synthetically generated under a permissive MIT/Creative Commons Public Domain license, ensuring complete academic integrity and open-source availability.
