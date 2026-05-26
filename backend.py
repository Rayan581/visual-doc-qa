"""
DocChat  —  UDOP Document Intelligence Backend
===============================================
A professional document Q&A backend powered by Microsoft's UDOP model.

Strategies for multi-page PDFs:

  smart (default, fast):
    1. OCR every page with Tesseract
    2. Score pages by TF-IDF-style keyword overlap with the question
    3. Run UDOP only on top-N candidate pages
    4. Auto-escalates to "all" if no answer found

  all (thorough):
    Run UDOP on every page, return the highest-confidence answer

  single: automatic for single-page docs (no strategy selection needed)

Run:
    pip install -r requirements.txt
    python backend.py
"""

import io
import re
import math
import time
import logging
import unicodedata
from collections import Counter
from contextlib import asynccontextmanager
from typing import List, Tuple

import os
import torch
import uvicorn
import pytesseract
from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from PIL import Image
from transformers import AutoProcessor, UdopForConditionalGeneration

# ── Windows Tesseract Path Autodetect ──────────────────────────────────────────
tesseract_default_path = r"C:\Program Files\Tesseract-OCR\tesseract.exe"
if os.path.exists(tesseract_default_path):
    pytesseract.pytesseract.tesseract_cmd = tesseract_default_path

# ── optional PDF support ──────────────────────────────────────────────────────
try:
    from pdf2image import convert_from_bytes
    PDF_SUPPORT = True
except ImportError:
    PDF_SUPPORT = False
    print("[WARNING] pdf2image not installed — PDF uploads disabled.")
    print("  Linux : sudo apt install poppler-utils && pip install pdf2image")
    print("  macOS : brew install poppler && pip install pdf2image")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
)
log = logging.getLogger(__name__)

# ── config ────────────────────────────────────────────────────────────────────
MODEL_ID    = "microsoft/udop-large-512-300k"
PDF_DPI     = 200          # higher = better OCR quality on PDFs
SMART_TOP_N = 3            # pages UDOP runs on in smart mode
MAX_TOKENS  = 512          # max generation tokens per page

device    = "cuda" if torch.cuda.is_available() else "cpu"
processor = None
model     = None
model_ready = False

STOPWORDS = {
    "a","an","the","is","are","was","were","be","been","being",
    "have","has","had","do","does","did","will","would","could",
    "should","may","might","shall","can","to","of","in","on",
    "at","by","for","with","about","as","into","through","from",
    "and","or","but","if","then","so","what","which","who",
    "how","when","where","why","this","that","these","those",
    "me","my","your","their","its","our","we","i","you","he",
    "she","they","it","any","all","some","no","not","just",
}

# In-memory document session cache (max 5 documents to prevent memory leaks)
# key: MD5 file hash (str)
# value: dict with {"pages": List, "ocr_texts": Dict[int, str], "qa_cache": Dict[str, dict], "timestamp": float}
DOCUMENT_CACHE = {}


# ─────────────────────────────────────────────────────────────────────────────
# Startup / shutdown
# ─────────────────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    global processor, model, model_ready
    log.info("=" * 60)
    log.info("DocChat UDOP Backend starting up …")
    log.info(f"Device: {device.upper()}")
    log.info(f"PDF support: {PDF_SUPPORT}")
    log.info("Loading UDOP model (first run downloads ~3 GB) …")
    t0 = time.time()
    processor = AutoProcessor.from_pretrained(MODEL_ID)
    model     = UdopForConditionalGeneration.from_pretrained(MODEL_ID)
    model.to(device)
    model.eval()
    model_ready = True
    log.info(f"Model loaded in {time.time()-t0:.1f}s on {device.upper()}.")
    log.info("=" * 60)
    yield
    log.info("Shutting down DocChat backend.")


app = FastAPI(
    title="DocChat UDOP — Document Intelligence API",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
def pdf_to_images(file_bytes: bytes) -> List[Image.Image]:
    if not PDF_SUPPORT:
        raise HTTPException(
            status_code=400,
            detail=(
                "PDF support requires pdf2image + poppler.\n"
                "  Linux : sudo apt install poppler-utils\n"
                "  macOS : brew install poppler\n"
                "  Windows: https://github.com/oschwartz10612/poppler-windows"
            ),
        )
    pages = convert_from_bytes(file_bytes, dpi=PDF_DPI)
    if not pages:
        raise HTTPException(status_code=400, detail="Could not read any pages from the PDF.")
    return pages


def load_pages(file_bytes: bytes, content_type: str) -> List[Image.Image]:
    """Return all pages as PIL RGB images."""
    if "pdf" in content_type:
        return pdf_to_images(file_bytes)
    try:
        img = Image.open(io.BytesIO(file_bytes)).convert("RGB")
        return [img]
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Cannot open image: {e}")


def run_udop(image: Image.Image, question: str) -> Tuple[str, float]:
    """
    Run UDOP on a single page image.
    Returns (answer_text, inference_time_seconds).
    """
    prompt   = f"Question answering. {question}"
    t0       = time.time()
    encoding = processor(
        image,
        prompt,
        return_tensors="pt",
        truncation=True,
    ).to(device)
    with torch.no_grad():
        ids = model.generate(
            **encoding,
            max_new_tokens=MAX_TOKENS,
            num_beams=4,
            early_stopping=True,
        )
    answer = processor.batch_decode(ids, skip_special_tokens=True)[0].strip()
    return answer, round(time.time() - t0, 2)


def answer_quality(answer: str) -> float:
    """
    Heuristic quality score. Returns 0 for empty / refused answers.
    Higher = more useful answer.
    """
    if not answer:
        return 0.0
    low = answer.lower().strip().rstrip(".")
    if low in ("", "no answer", "unanswerable", "none", "n/a", "unknown"):
        return 0.0
    words = re.findall(r"\b\w+\b", low)
    # Reward length + penalise very short single-token answers
    base = len(words) + len(answer) * 0.05
    if len(words) <= 1:
        base *= 0.5
    return base


def tokenize(text: str) -> List[str]:
    """Normalise, lowercase, remove stopwords."""
    text  = unicodedata.normalize("NFKD", text).lower()
    words = re.findall(r"\b[a-z]{2,}\b", text)
    return [w for w in words if w not in STOPWORDS]


def ocr_page(image: Image.Image, file_hash: str = None, page_idx: int = None) -> str:
    if file_hash and page_idx is not None:
        cache_entry = DOCUMENT_CACHE.get(file_hash)
        if cache_entry and page_idx in cache_entry["ocr_texts"]:
            log.info(f"    [OCR CACHE HIT] Page {page_idx + 1}")
            return cache_entry["ocr_texts"][page_idx]

    try:
        text = pytesseract.image_to_string(image)
    except Exception as e:
        log.warning(f"OCR error: {e}")
        text = ""

    if file_hash and page_idx is not None and file_hash in DOCUMENT_CACHE:
        DOCUMENT_CACHE[file_hash]["ocr_texts"][page_idx] = text

    return text


def relevance_score(page_text: str, question_tokens: List[str]) -> float:
    """TF-weighted keyword overlap between page OCR text and question tokens."""
    if not page_text or not question_tokens:
        return 0.0
    counts = Counter(tokenize(page_text))
    score  = 0.0
    for qt in set(question_tokens):
        tf = counts.get(qt, 0)
        if tf > 0:
            score += 1.0 + math.log(tf)
    return score


# ─────────────────────────────────────────────────────────────────────────────
# Strategy A — ALL pages
# ─────────────────────────────────────────────────────────────────────────────
def strategy_all(pages: List[Image.Image], question: str) -> dict:
    log.info(f"[ALL] UDOP across all {len(pages)} page(s) …")
    best_answer = ""
    best_score  = -1.0
    best_page   = 1
    total_time  = 0.0
    page_results = []

    i = 1
    while i <= len(pages):
        page = pages[i - 1]
        log.info(f"  Page {i}/{len(pages)} …")
        answer, t = run_udop(page, question)
        quality   = answer_quality(answer)
        total_time += t
        page_results.append({"page": i, "answer": answer, "quality": round(quality, 2), "time": t})
        log.info(f"    answer='{answer}'  quality={quality:.2f}  time={t}s")
        if quality > best_score:
            best_score  = quality
            best_answer = answer
            best_page   = i
        i += 1

    if best_score == 0.0:
        best_answer = "No answer found in the document."

    return {
        "answer":         best_answer,
        "page":           best_page,
        "strategy":       "all",
        "pages_searched": len(pages),
        "total_pages":    len(pages),
        "inference_time": round(total_time, 2),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Strategy B — SMART (OCR rank → top-N)
# ─────────────────────────────────────────────────────────────────────────────
def strategy_smart(
    pages: List[Image.Image],
    question: str,
    file_hash: str = None,
    top_n: int = SMART_TOP_N,
) -> dict:
    log.info(f"[SMART] OCR-ranking {len(pages)} pages, top-{top_n} candidates …")

    q_tokens: List[str] = tokenize(question)

    # Step 1: OCR + rank
    ranked: List[Tuple[int, float]] = []
    idx = 0
    while idx < len(pages):
        text  = ocr_page(pages[idx], file_hash, idx)
        score = relevance_score(text, q_tokens)
        ranked.append((idx, score))
        log.info(f"  Page {idx+1}: relevance={score:.2f}")
        idx += 1

    ranked.sort(key=lambda x: x[1], reverse=True)
    candidates = ranked[:top_n]

    # Fallback: if all scored 0, try first top_n pages
    if all(s == 0.0 for _, s in candidates):
        log.warning("  All pages scored 0 — trying first pages as fallback.")
        candidates = [(i, 0.0) for i in range(min(top_n, len(pages)))]

    log.info(f"  Candidates: pages {[idx+1 for idx, _ in candidates]}")

    # Step 2: UDOP on candidates only
    best_answer = ""
    best_score  = -1.0
    best_page   = candidates[0][0] + 1
    total_time  = 0.0

    for page_idx, _ in candidates:
        log.info(f"  Running UDOP on page {page_idx+1} …")
        answer, t = run_udop(pages[page_idx], question)
        quality   = answer_quality(answer)
        total_time += t
        log.info(f"    answer='{answer}'  quality={quality:.2f}  time={t}s")
        if quality > best_score:
            best_score  = quality
            best_answer = answer
            best_page   = page_idx + 1

    # Step 3: Escalate if still nothing
    if best_score == 0.0:
        log.warning("  Smart strategy found nothing — escalating to ALL pages …")
        result = strategy_all(pages, question)
        result["strategy"] = "smart→all (escalated)"
        return result

    return {
        "answer":         best_answer,
        "page":           best_page,
        "strategy":       "smart",
        "pages_searched": len(candidates),
        "total_pages":    len(pages),
        "inference_time": round(total_time, 2),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {
        "status":      "ok" if model_ready else "loading",
        "device":      device,
        "model":       MODEL_ID,
        "pdf_support": PDF_SUPPORT,
        "version":     "2.0.0",
    }


@app.post("/ask")
async def ask(
    file:     UploadFile = File(...),
    question: str        = Form(...),
    strategy: str        = Form("smart"),
):
    if not model_ready:
        raise HTTPException(status_code=503, detail="Model is still loading. Please wait.")

    question = question.strip()
    strategy = strategy.strip().lower()

    if not question:
        raise HTTPException(status_code=400, detail="Question cannot be empty.")
    if strategy not in ("smart", "all"):
        raise HTTPException(status_code=400, detail="strategy must be 'smart' or 'all'.")

    log.info(f"─── Request ─── file='{file.filename}' strategy='{strategy}' q='{question}'")

    file_bytes   = await file.read()
    content_type = (file.content_type or "").lower()

    # ── Cache Level 1 & 2 ─────────────────────────────────────────────────────
    import hashlib
    file_hash = hashlib.md5(file_bytes).hexdigest()

    # Level 1 Cache: Exact same document + exact same question
    if file_hash in DOCUMENT_CACHE:
        cache_entry = DOCUMENT_CACHE[file_hash]
        cache_entry["timestamp"] = time.time()  # Refresh LRU timestamp
        if question in cache_entry["qa_cache"]:
            log.info(f"🏆 [CACHE HIT L1] Direct Q&A match for: '{question}'")
            cached_res = dict(cache_entry["qa_cache"][question])
            # Tag it so the UI shows it was cached
            cached_res["strategy"] = cached_res.get("strategy", "") + " (cached)"
            return JSONResponse(cached_res)

        pages = cache_entry["pages"]
        log.info(f"⚡ [CACHE HIT L2] Reused loaded pages/images for hash {file_hash}")
    else:
        try:
            pages = load_pages(file_bytes, content_type)
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"Could not open file: {e}")

        # Initialize cached entry
        DOCUMENT_CACHE[file_hash] = {
            "pages": pages,
            "ocr_texts": {},
            "qa_cache": {},
            "timestamp": time.time(),
        }

        # Evict oldest if limit exceeded
        if len(DOCUMENT_CACHE) > 5:
            oldest_hash = min(DOCUMENT_CACHE.keys(), key=lambda h: DOCUMENT_CACHE[h]["timestamp"])
            DOCUMENT_CACHE.pop(oldest_hash)
            log.info(f"🧹 Cache pruned oldest entry: {oldest_hash}")

    log.info(f"Loaded {len(pages)} page(s).")

    # Single page — skip strategy selection
    if len(pages) == 1:
        try:
            answer, t = run_udop(pages[0], question)
        except Exception as e:
            log.exception("UDOP inference failed")
            raise HTTPException(status_code=500, detail=f"Inference error: {e}")

        if answer_quality(answer) == 0.0:
            answer = "No answer found in the document."

        result = {
            "answer":         answer,
            "page":           1,
            "strategy":       "single",
            "pages_searched": 1,
            "total_pages":    1,
            "inference_time": t,
        }
        # Save to Q&A Cache
        DOCUMENT_CACHE[file_hash]["qa_cache"][question] = result
        return JSONResponse(result)

    # Multi-page
    try:
        if strategy == "all":
            result = strategy_all(pages, question)
        else:
            result = strategy_smart(pages, question, file_hash=file_hash)
    except HTTPException:
        raise
    except Exception as e:
        log.exception("Strategy failed")
        raise HTTPException(status_code=500, detail=f"Processing error: {e}")

    # Save to Q&A Cache
    DOCUMENT_CACHE[file_hash]["qa_cache"][question] = result
    log.info(f"Result: {result}")
    return JSONResponse(result)


# ─────────────────────────────────────────────────────────────────────────────
# Run directly: python backend.py
if __name__ == "__main__":
    uvicorn.run("backend:app", host="127.0.0.1", port=8000, reload=False, log_level="info")

