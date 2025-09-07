#!/usr/bin/env python3
"""
Synopsis linter for MSP-Resources.

- Fails CI if any script is missing a synopsis header.
- Supported:
  * PowerShell: .ps1/.psm1/.ps1xml — must contain a comment-help block with .SYNOPSIS
  * Bash: .sh/.bash — must include a non-empty leading # synopsis comment (after shebang)
  * Python: .py — must include a module docstring; first line serves as synopsis (fallback to leading #)

Targets: ConnectWise-RMM-Asio/Scripts (Windows/Linux/Mac subfolders recommended).
"""
from __future__ import annotations
from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parents[1]
ROOTS = [
    REPO / "ConnectWise-RMM-Asio" / "Scripts",
]

PS_EXTS   = {".ps1", ".psm1", ".ps1xml"}
BASH_EXTS = {".sh", ".bash"}
PY_EXTS   = {".py"}

def read_text(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""

def has_ps_synopsis(text: str) -> bool:
    m = re.search(r"<#([\s\S]*?)#>", text, re.MULTILINE)
    if not m:
        return False
    block = m.group(1)
    return re.search(r"(?im)^\s*\.SYNOPSIS\s*\n\s*\S+", block) is not None

def extract_bash_synopsis(text: str) -> str:
    lines = text.splitlines()
    i = 0
    if lines and lines[0].startswith("#!"):
        i = 1
    for ln in lines[i:]:
        s = ln.strip()
        if s.startswith("#"):
            s = s.lstrip("#").strip()
            if s:
                return s
        elif s:
            break
    return ""

def extract_py_synopsis(text: str) -> str:
    m = re.match(r'\s*[rRuU]?("""|\'\'\')([\s\S]*?)(\1)', text)
    if m:
        doc = m.group(2).strip()
        if doc:
            return doc.splitlines()[0].strip()
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("#"):
            s = s.lstrip("#").strip()
            if s:
                return s
        elif s:
            break
    return ""

def main() -> int:
    missing = []

    for root in ROOTS:
        if not root.exists():
            continue
        for p in sorted(root.rglob("*")):
            if not p.is_file():
                continue
            ext = p.suffix.lower()
            txt = read_text(p)

            if ext in PS_EXTS:
                if not has_ps_synopsis(txt):
                    missing.append((p, "PowerShell script missing .SYNOPSIS in a comment-help block (<# ... #>)"))
            elif ext in BASH_EXTS:
                if not extract_bash_synopsis(txt):
                    missing.append((p, "Bash script missing a leading # synopsis comment"))
            elif ext in PY_EXTS:
                if not extract_py_synopsis(txt):
                    missing.append((p, "Python script missing module docstring (or leading # synopsis)"))

    if missing:
        print("❌ Synopsis check failed for the following scripts:\n")
        for p, why in missing:
            print(f"- {p.relative_to(REPO)} → {why}")
        print("\nAdd a short synopsis header (see README Script Documentation Template).")
        return 1

    print("✅ All scripts have required synopsis headers.")
    return 0

if __name__ == "__main__":
    sys.exit(main())