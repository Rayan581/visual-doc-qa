# DocChat — Document Intelligence

A professional desktop app for extracting answers from scanned documents,
forms, invoices, receipts, and any image-based document — powered by
Microsoft's UDOP multimodal model.

---

## Architecture

```
docchat/
  backend.py        ← Python FastAPI server  (port 8000)
  requirements.txt  ← Python dependencies
  main.dart         ← Flutter desktop UI  (drop into lib/)
  pubspec.yaml      ← Flutter project config
```

---

## Step 1 — Python Backend

### 1a. System dependencies

**Linux (Ubuntu/Debian):**
```bash
sudo apt install tesseract-ocr poppler-utils
```

**macOS:**
```bash
brew install tesseract poppler
```

**Windows:**
- Tesseract: https://github.com/UB-Mannheim/tesseract/wiki
- Poppler:   https://github.com/oschwartz10612/poppler-windows (add bin/ to PATH)

### 1b. Python packages
```bash
pip install -r requirements.txt
```

### 1c. Run
```bash
python backend.py
```

First run downloads the UDOP model (~3 GB) from HuggingFace.
Subsequent runs load from cache instantly.

Expected output:
```
DocChat UDOP Backend starting up …
Device: CPU
PDF support: True
Loading UDOP model …
Model loaded in 12.3s on CPU.
INFO: Uvicorn running on http://127.0.0.1:8000
```

Verify: http://127.0.0.1:8000/health

---

## Step 2 — Flutter App

### 2a. Flutter project setup

In an existing Flutter project (or create one with `flutter create docchat`):

1. Copy `main.dart`   → `lib/main.dart`
2. Copy `pubspec.yaml` → `pubspec.yaml`
3. Run:

```bash
flutter pub get
```

### 2b. Enable desktop

```bash
flutter config --enable-linux-desktop    # Linux
flutter config --enable-macos-desktop    # macOS
flutter config --enable-windows-desktop  # Windows
```

### 2c. Run

```bash
flutter run -d linux      # or macos / windows
```

---

## How to Use

1. Ensure backend is running — check the ONLINE indicator in the top bar
2. Click the upload zone (left panel) to load your document
3. Select analysis strategy:
   - **SMART** — fast; OCR-ranks pages, runs UDOP on top matches (default)
   - **ALL PAGES** — thorough; runs UDOP on every page
4. Type your question in the query terminal (right panel)
5. Press **Enter** or click the send button
6. The answer appears as an UDOP message with metadata (page number, inference time, strategy)

---

## GPU Acceleration

For CUDA-capable NVIDIA GPUs:
```bash
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

The backend automatically detects and uses GPU. Speed improvement: 5–15×.

---

## Model Info

- **Model:**   `microsoft/udop-large-512-300k`
- **HuggingFace:** https://huggingface.co/microsoft/udop-large-512-300k
- **License:** MIT
- **Size:**    ~3 GB
- **Paper:**   https://arxiv.org/abs/2212.02623
