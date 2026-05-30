#!/usr/bin/env python3
"""Extract Geo-Tagging Camera watermark dari foto via OCR.

Usage:
  python3 scripts/check_photo_geotag.py <image_path>

Output JSON to stdout:
  {"has_geotag": bool, "lat": float|null, "lon": float|null,
   "timestamp": str|null, "address": str|null, "raw_ocr": str}

Mengandalkan pytesseract + Pillow. Crop bottom 30% (watermark area)
untuk akurasi OCR + speed.
"""
import sys
import os
import re
import json
from pathlib import Path

# Force UTF-8 stdio (cron / launchd env often lacks LANG).
os.environ.setdefault("LANG", "en_US.UTF-8")
os.environ.setdefault("LC_ALL", "en_US.UTF-8")
os.environ.setdefault("PYTHONUTF8", "1")
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: check_photo_geotag.py <path>"}))
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.is_file():
        print(json.dumps({"error": f"file not found: {path}"}))
        sys.exit(1)

    try:
        from PIL import Image
    except ImportError as e:
        print(json.dumps({"error": f"missing PIL: {e}"}))
        sys.exit(1)

    result = {
        "has_geotag": False,
        "lat": None,
        "lon": None,
        "timestamp": None,
        "address": None,
        "raw_ocr": "",
    }

    try:
        import subprocess
        import tempfile

        img = Image.open(path)
        w, h = img.size
        # Crop bottom 30% — watermark area (Geo-Tagging Camera, GPS Map Camera, etc.)
        crop = img.crop((0, int(h * 0.70), w, h))

        # Call tesseract directly via subprocess (avoids pytesseract's locale-
        # sensitive decoding which fails in cron env). Save crop ke tempfile,
        # tesseract reads file → outputs to stdout, decode dengan errors='replace'.
        # macOS TCC blocks tesseract from reading /tmp — use project-local tmp dir.
        tmp_dir = Path(__file__).resolve().parent.parent / "tmp"
        tmp_dir.mkdir(exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(suffix=".jpg", dir=str(tmp_dir))
        os.close(fd)
        crop.convert("RGB").save(tmp_path, format="JPEG", quality=90)
        if not (os.path.isfile(tmp_path) and os.path.getsize(tmp_path) > 0):
            result["error"] = f"tmpfile write failed: {tmp_path}"
            print(json.dumps(result, ensure_ascii=False)); sys.exit(0)
        try:
            proc = subprocess.run(
                ["/opt/homebrew/bin/tesseract", tmp_path, "-", "-l", "eng"],
                capture_output=True, timeout=15,
            )
            text = proc.stdout.decode("utf-8", errors="replace")
            if not text.strip():
                result["tesseract_stderr"] = proc.stderr.decode("utf-8", errors="replace")[:300]
                result["tesseract_returncode"] = proc.returncode
        finally:
            os.unlink(tmp_path)

        result["raw_ocr"] = text

        # Coords — try multiple watermark formats:
        # A) "Lat -7.282302 Long 112.754749"  (Geo-Tagging Camera)
        # B) "© -7,2822° 112,7548°"            (alt camera, comma decimal + °)
        # C) "-7.2822, 112.7548"               (plain coord pair)
        m = re.search(r'Lat\s*(-?\d+[.,]\d+)\s*Long\s*(-?\d+[.,]\d+)', text, re.I)
        if not m:
            m = re.search(r'(-?\d+[.,]\d{3,})\s*°\s*(-?\d+[.,]\d{3,})\s*°', text)
        if not m:
            # Pair like "-7.282302, 112.754749" (no degree symbol)
            m = re.search(r'(-?\d+[.,]\d{4,})[\s,]+(-?\d+[.,]\d{4,})', text)
        if m:
            try:
                lat = float(m.group(1).replace(',', '.'))
                lon = float(m.group(2).replace(',', '.'))
                # Sanity check: Indonesia bounds (-11 to 6 lat, 95 to 141 lng)
                if -11 <= lat <= 6 and 95 <= lon <= 141:
                    result["has_geotag"] = True
                    result["lat"] = lat
                    result["lon"] = lon
            except ValueError:
                pass

        # Timestamp: "2026/05/30 21:46" or "31/05/2026, 00:44"
        mt = re.search(r'(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2})', text)
        if not mt:
            mt = re.search(r'(\d{2}/\d{2}/\d{4},?\s+\d{2}:\d{2})', text)
        if mt:
            result["timestamp"] = mt.group(1)

        # Address: line starting with "Jl." or "Kec." or containing "Indonesia"
        addr_lines = [l.strip() for l in text.split("\n")
                      if l.strip() and re.search(r'\b(Jl\.|Kec\.|Indonesia|Jawa|Sumatera|Bali|Kalimantan|Sulawesi|Papua)', l)]
        if addr_lines:
            result["address"] = " | ".join(addr_lines[:3])

    except Exception as e:
        result["error"] = str(e)

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
