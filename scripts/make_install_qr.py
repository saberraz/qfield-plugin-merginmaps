"""Regenerates docs/media/install-qr.png (the QR code in README's Install section) and checks that it decodes.

Usage: python -I scripts/make_install_qr.py   (needs: pip install segno zxing-cpp pillow)
QField's "Install plugin from URL" dialog has a scan button that reads this code and installs straight away.
"""
import os, segno, zxingcpp
from PIL import Image

URL = "https://github.com/saberraz/qfield-plugin-merginmaps/releases/latest/download/qfield-plugin-merginmaps.zip"
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "media", "install-qr.png")
# opaque white background + 4-module quiet zone: a transparent code is unreadable on dark themes
segno.make(URL, error="m", micro=False).save(out, scale=8, border=4, dark="#000000", light="#ffffff")
decoded = [r.text for r in zxingcpp.read_barcodes(Image.open(out))]
assert decoded == [URL], decoded
print("wrote", os.path.normpath(out), "->", URL)
