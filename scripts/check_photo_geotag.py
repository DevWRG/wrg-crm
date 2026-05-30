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
import re
import json
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: check_photo_geotag.py <path>"}))
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.is_file():
        print(json.dumps({"error": f"file not found: {path}"}))
        sys.exit(1)

    try:
        import pytesseract
        from PIL import Image
    except ImportError as e:
        print(json.dumps({"error": f"missing dep: {e}"}))
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
        img = Image.open(path)
        w, h = img.size
        # Crop bottom 30% — watermark area (Geo-Tagging Camera, GPS Map Camera, etc.)
        crop = img.crop((0, int(h * 0.70), w, h))
        text = pytesseract.image_to_string(crop)
        result["raw_ocr"] = text

        # Coords: "Lat -7.282302 Long 112.754749"
        m = re.search(r'Lat\s*(-?\d+\.\d+)\s*Long\s*(-?\d+\.\d+)', text, re.I)
        if m:
            result["has_geotag"] = True
            result["lat"] = float(m.group(1))
            result["lon"] = float(m.group(2))

        # Timestamp: "2026/05/30 21:46"
        mt = re.search(r'(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2})', text)
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
