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
        # A) "Lat -7.282302 Long 112.754749"   (Geo-Tagging Camera, EN)
        # A') "Lat -7008929 Long 112507992"    (same fmt tapi OCR drop dot →
        #                                       recover via Indonesia bounds)
        # B) "-7,0090°, 112,5080°"             (alt camera, comma decimal + °)
        # C) "-7.2822, 112.7548"               (plain coord pair, no degree)
        def repair_coord(raw, kind):
            """Recover decimal point if OCR dropped it. kind='lat' or 'lon'.
            Indonesia: lat -11..6 (1-2 digits before .), lon 95..141 (3 before).
            Strips whitespace dari raw (OCR kadang split '-7. 624698')."""
            s = raw.replace(',', '.').replace(' ', '').replace('\t', '').rstrip('.')
            if '.' in s:
                try:
                    val = float(s)
                    # Check bounds — kalau ada trailing dot tanpa digit ('-7.'),
                    # python float bisa parse '-7.' = -7.0 yang salah. Validate.
                    if s.endswith('.'):
                        raise ValueError("trailing dot, treat as missing-decimal")
                    return val
                except ValueError:
                    pass
            sign = -1 if s.startswith('-') else 1
            digits = s.lstrip('-')
            if not digits.isdigit():
                raise ValueError(f"bad digits: {raw}")
            if kind == 'lat':
                # Try 1 or 2-digit integer part
                for split in (1, 2):
                    if len(digits) > split:
                        candidate = sign * float(f"{digits[:split]}.{digits[split:]}")
                        if -11 <= candidate <= 6:
                            return candidate
            else:  # lon
                for split in (2, 3):
                    if len(digits) > split:
                        candidate = sign * float(f"{digits[:split]}.{digits[split:]}")
                        if 95 <= candidate <= 141:
                            return candidate
            raise ValueError(f"can't repair: {raw}")

        # Lat/Long with optional OCR garbage between keyword + digits.
        # `Lat ui 624698 Long 111.494828` — OCR misread `-7.` as `ui`.
        # `Lat-7. 624698 Long 111.494828` — OCR split decimal cluster.
        # Capture greedy cluster of digits/dot/comma/space between Lat..Long,
        # then strip whitespace dlm repair_coord.
        m = re.search(r'Lat[^0-9\-]*(-?[\d.,\s]+?)[\s°]*(?:Long|Lon|Lng)[^0-9\-]*(-?[\d.,]+)°?', text, re.I)
        # D) "8.058290°S, 111.704704°E" — degree+hemisphere (no Lat/Long keyword)
        nsew_match = None
        if not m:
            nsew_match = re.search(r'(\d+[.,]\d+)\s*°\s*([NS])\s*,?\s*(\d+[.,]\d+)\s*°\s*([EW])', text, re.I)
        if not m and not nsew_match:
            m = re.search(r'(-?\d+[.,]\d{3,})\s*°[°,\s]+(-?\d+[.,]\d{3,})\s*°?', text)
        if not m and not nsew_match:
            m = re.search(r'(-?\d+[.,]\d{4,})[\s,]+(-?\d+[.,]\d{4,})', text)
        # E) "-71548°, 113,4816°" — lat decimal hilang OCR, lon comma-decimal
        if not m and not nsew_match:
            m = re.search(r'(-?\d{4,})\s*°[°,\s]+(-?\d+[.,]\d{3,})\s*°?', text)
        if nsew_match:
            try:
                lat = float(nsew_match.group(1).replace(',', '.'))
                lon = float(nsew_match.group(3).replace(',', '.'))
                if nsew_match.group(2).upper() == 'S': lat = -lat
                if nsew_match.group(4).upper() == 'W': lon = -lon
                if -11 <= lat <= 6 and 95 <= lon <= 141:
                    result["has_geotag"] = True
                    result["lat"] = lat
                    result["lon"] = lon
            except ValueError:
                pass
        elif m:
            try:
                lat = repair_coord(m.group(1), 'lat')
                lon = repair_coord(m.group(2), 'lon')
                if -11 <= lat <= 6 and 95 <= lon <= 141:
                    result["has_geotag"] = True
                    result["lat"] = lat
                    result["lon"] = lon
            except ValueError:
                pass

        # Timestamp: "2026/05/30 21:46" / "31/05/2026, 00:44" / "03/6/2026 03:36 PM"
        # Normalize ke ISO 'YYYY-MM-DD HH:MM' di timestamp_iso (Postgres parseable).
        import datetime
        result["timestamp_iso"] = None
        mt = re.search(r'(\d{4})/(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})', text)
        if mt:
            y, mo, d, hh, mm = mt.group(1), mt.group(2), mt.group(3), mt.group(4), mt.group(5)
            result["timestamp"] = f"{y}/{int(mo):02d}/{int(d):02d} {int(hh):02d}:{mm}"
            try:
                result["timestamp_iso"] = f"{y}-{int(mo):02d}-{int(d):02d} {int(hh):02d}:{mm}:00"
            except ValueError:
                pass
        else:
            # dd/m/yyyy with optional AM/PM
            mt = re.search(r'(\d{1,2})/(\d{1,2})/(\d{4}),?\s+(\d{1,2}):(\d{2})\s*(AM|PM)?', text, re.I)
            if mt:
                d, mo, y, hh, mm, ampm = mt.group(1), mt.group(2), mt.group(3), int(mt.group(4)), mt.group(5), mt.group(6)
                if ampm:
                    if ampm.upper() == 'PM' and hh < 12: hh += 12
                    elif ampm.upper() == 'AM' and hh == 12: hh = 0
                result["timestamp"] = f"{int(d):02d}/{int(mo):02d}/{y} {hh:02d}:{mm}"
                try:
                    result["timestamp_iso"] = f"{y}-{int(mo):02d}-{int(d):02d} {hh:02d}:{mm}:00"
                except ValueError:
                    pass

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
