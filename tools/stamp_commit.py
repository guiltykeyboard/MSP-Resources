#!/usr/bin/env python3
"""
Replace 8050edbb32c77da92c6fe1e23d9da130a3b71afa placeholders in scripts with the current commit's short SHA.
Runs in CI after the original push completes, then pushes a follow-up commit
with [skip ci] to avoid infinite loops.
"""
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SHORT_SHA = os.environ.get("GIT_SHA", "").strip()
if not SHORT_SHA:
  # Fallback to local git if available
  try:
    import subprocess
    SHORT_SHA = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT
    ).decode("utf-8").strip()
  except Exception:
    print("ERROR: Unable to determine commit SHA", file=sys.stderr)
    sys.exit(1)

exts = {".ps1", ".psm1", ".psd1", ".sh", ".py"}
changed = 0

for path in REPO_ROOT.rglob("*"):
  if not path.is_file():
    continue
  if path.suffix.lower() not in exts:
    continue
  try:
    text = path.read_text(encoding="utf-8")
  except Exception:
    continue

  if "8050edbb32c77da92c6fe1e23d9da130a3b71afa" not in text:
    continue

  new_text = text.replace("8050edbb32c77da92c6fe1e23d9da130a3b71afa", SHORT_SHA)
  if new_text != text:
    path.write_text(new_text, encoding="utf-8")
    print(f"Stamped {path.relative_to(REPO_ROOT)} -> {SHORT_SHA}")
    changed += 1

if changed == 0:
  print("No placeholders found to stamp.")
else:
  print(f"Stamped {changed} file(s).")