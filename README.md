# 📑 DocChat — Advanced Visual Document Intelligence

DocChat is a state-of-the-art visual document understanding and question-answering assistant. Built with a high-performance **FastAPI** backend and a sleek, ultra-modern **Flutter Web/Desktop** client, DocChat enables users to upload scanned documents, invoices, receipts, forms, or hand-written notes and ask questions about their content. 

Under the hood, the document reasoning is powered by Microsoft's massive multimodal **UDOP** (Unified Document Processing) transformer model, allowing it to seamlessly synthesize both textual content and spatial layout features.

---

## ✨ Features & Capabilities

* **🧠 Advanced Multimodal AI**: Leverages the `microsoft/udop-large-512-300k` model to understand text, spatial structure, and visual layouts simultaneously.
* **⚡ Dual-Level Memory Caching**:
  * **Level-1 Cache (Direct Q&A)**: Repeated questions on the same document return **instantly (0.0 seconds)** without calling the neural network.
  * **Level-2 Cache (Document OCR & Parsing)**: Subsequent queries on the same document skip the heavy PDF decoding and PyTesseract OCR processes entirely, speeding up inference by over **80%**.
  * **Memory Safeguards**: Built-in Least Recently Used (LRU) automatic pruning to keep RAM usage extremely optimized (stores up to 5 concurrent document sessions).
* **🔍 Multiple Analysis Strategies**:
  * **SMART Mode** *(Default)*: Performs keyword-overlap calculations against the document's OCR layout to rank and select the top-$N$ most relevant candidate pages, invoking UDOP only where it matters.
  * **ALL PAGES Mode**: Exhaustive page-by-page analysis to synthesize deep context.
* **🌐 Universal Web & Desktop Support**: Specially engineered with in-memory byte transfer to bypass sandboxed web browser constraints (completely resolving `null` path exceptions on Chrome).
* **🛠️ Automated Windows Integrations**: Features automated folder detection for Tesseract OCR, reducing manual environmental path setup.

---

## 🏗️ Architecture

```
visual-doc-qa/
  ├── backend.py                  # FastAPI Python Server (port 8000)
  ├── requirements.txt            # Python AI & Server dependencies
  ├── test.png                    # Preloaded visual Q&A sample drawing
  └── flutter_application_1/      # Flutter Client Application
      ├── lib/main.dart           # Single-file shell with responsive glassmorphism UI
      ├── pubspec.yaml            # Dart package constraints
      └── ...
```

---

## 🚀 Step 1: Deploy Python Backend

### 1a. System Dependencies

#### **Windows (Highly Recommended):**
1. **Tesseract OCR**: Download and run the 64-bit installer from [UB-Mannheim Tesseract Wiki](https://github.com/UB-Mannheim/tesseract/wiki). Use the default installation folder (`C:\Program Files\Tesseract-OCR\`). The backend will auto-detect it.
2. **Poppler (for PDF support)**: Download the Windows packages from [Poppler-Windows](https://github.com/oschwartz10612/poppler-windows/releases). Extract it and add its `bin/` directory to your system environment variables PATH.

#### **Linux (Ubuntu/Debian):**
```bash
sudo apt update && sudo apt install -y tesseract-ocr poppler-utils
```

#### **macOS:**
```bash
brew install tesseract poppler
```

### 1b. Python Environment & Setup

We recommend setting up a virtual environment:
```bash
# Create and activate virtual environment
python -m venv venv
venv\Scripts\activate      # Windows
source venv/bin/activate   # Linux/macOS

# Install package dependencies
pip install -r requirements.txt
```

### 1c. Run the Server
```bash
python backend.py
```
* The first launch will automatically pull the **3 GB UDOP model** from Hugging Face. Subsequent launches load it from cache in seconds.
* Confirm startup at `http://127.0.0.1:8000/health`.

---

## 📱 Step 2: Build & Run Flutter Frontend

The Flutter interface uses a state-of-the-art dark-themed dashboard. 

### 2a. System Preparation
On **Windows**, ensure **Developer Mode** is turned on in your Windows Settings (allows symlinks to build correctly for debuggers):
```powershell
start ms-settings:developers
```

### 2b. Enable Target Platforms
Enable the environment configurations for your build target:
```bash
flutter config --enable-windows-desktop
flutter config --enable-macos-desktop
flutter config --enable-linux-desktop
```

### 2c. Compile & Launch (Web/Chrome)
To run the fully functional web application locally inside Chrome:
```bash
cd flutter_application_1
flutter pub get
flutter run -d chrome
```

---

## ⚡ GPU Acceleration (NVIDIA CUDA)

By default, the backend runs on **CPU**. To speed up inference by **5–15×** using an NVIDIA GPU, install the CUDA-supported version of PyTorch:

```bash
# Uninstall CPU-only torch
pip uninstall torch torchvision

# Install CUDA-accelerated torch (example for CUDA 12.1)
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

Once installed, the backend will print `Device: CUDA` on startup, accelerating page analysis to mere milliseconds.

---

## 📖 How to Use

1. **Upload**: Drop or click the left **DOCUMENT** panel to load your image (`.png`, `.jpg`, `.jpeg`, `.webp`, `.bmp`, `.tiff`) or `.pdf` file.
2. **Mode Selection**: Keep **SMART** selected (highly recommended for multi-page documents to save CPU time) or switch to **ALL PAGES**.
3. **Query**: Type your query in the bottom input bar (e.g., *"What is the total balance due?"* or *"List all items purchased"*).
4. **Answer**: The response will stream directly into the query terminal, decorated with beautiful chips reflecting **page number**, **strategy used**, and **exact inference time**.

---

## 🛡️ License

This project is licensed under the MIT License. Microsoft's UDOP model is distributed under the MIT license.
