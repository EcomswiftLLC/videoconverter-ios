"""Builds the App Store screenshots for the iPad 13 inch display (2064 x 2752) from the iPad CI screenshots.

Usage: python tools/make_store_shots_ipad.py <folder-with-CI-pngs> <output-folder>
  e.g. python tools/make_store_shots_ipad.py ci/screenshots-ipad design/store/ipad13

Inputs are the PNGs of the `screenshots-ipad` artifact of the fluxa-ios workflow (setup-mp4.png, formats-grid.png, ..., see SLIDES).
Layout and copy live in tools/store_shots_common.py. Missing captures are skipped and listed, never invented.
Needs Pillow and numpy.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store_shots_common as common  # noqa: E402

W, H = 2064, 2752
OPTS = dict(head=160, sub=72, top=170, icon=190, gap=64, shot_w=1640, shot_gap=110, min_shot_top=780, radius=72, fit_margin=70)

if __name__ == "__main__":
    common.run(sys.argv, W, H, OPTS, "iPad 13 inch")
