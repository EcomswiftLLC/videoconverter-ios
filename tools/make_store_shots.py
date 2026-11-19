"""Builds the App Store screenshots for the iPhone 6.9 inch display (1320 x 2868) from the CI screenshots.

Usage: python tools/make_store_shots.py <folder-with-CI-pngs> <output-folder>
  e.g. python tools/make_store_shots.py ci/screenshots design/store/6.9

Inputs are the PNGs of the `screenshots` artifact of the fluxa-ios workflow (setup-mp4.png, formats-grid.png, ..., see SLIDES).
Layout and copy live in tools/store_shots_common.py. Missing captures are skipped and listed, never invented.
Needs Pillow and numpy.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store_shots_common as common  # noqa: E402

W, H = 1320, 2868
OPTS = dict(head=128, sub=58, top=170, icon=150, gap=56, shot_w=1120, shot_gap=96, min_shot_top=740, radius=96, fit_margin=70)

if __name__ == "__main__":
    common.run(sys.argv, W, H, OPTS, "iPhone 6.9 inch")
