#!/usr/bin/env python3
"""
README catalog generator (enhanced).
- Scans known script roots and collects script paths.
- Extracts synopses:
  * PowerShell: .SYNOPSIS in comment-help block
  * Bash: first leading # comment (after shebang)
  * Python: first line of module docstring (fallback to leading #)
- Rewrites content between <!-- GENERATED-CATALOG:START --> and <!-- GENERATED-CATALOG:END -->
  with a grouped, readable index under the ConnectWise RMM Scripts root.
"""
from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parents[1]
README = REPO / "README.md"

ROOTS = [
    REPO / "ConnectWise-RMM-Asio" / "Scripts",
]

PS_EXTS   = {".ps1", ".psm1", ".ps1xml"}
BASH_EXTS = {".sh", ".bash"}
PY_EXTS   = {".py"}
ALL_EXTS  = PS_EXTS | BASH_EXTS | PY_EXTS

START = "<!-- GENERATED-CATALOG:START -->"
END   = "<!-- GENERATED-CATALOG:END -->"

def text_of(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""

def syn_ps(text: str) -> str:
    m = re.search(r"<#([\s\S]*?)#>", text, re.MULTILINE)
    if not m:
        return ""
    block = m.group(1)
    s = re.search(r"(?im)^\s*\.SYNOPSIS\s*\n\s*(.+)", block)
    return s.group(1).strip() if s else ""

def syn_bash(text: str) -> str:
    lines = text.splitlines()
    idx = 1 if (lines and lines[0].startswith("#!")) else 0
    for ln in lines[idx:]:
        st = ln.strip()
        if st.startswith("#"):
            s = st.lstrip("#").strip()
            if s:
                return s
        elif st:  # hit code
            break
    return ""

def syn_py(text: str) -> str:
    m = re.match(r'\s*[rRuU]?("""|\'\'\')([\s\S]*?)(\1)', text)
    if m:
        doc = m.group(2).strip()
        if doc:
            return doc.splitlines()[0].strip()
    for ln in text.splitlines():
        st = ln.strip()
        if st.startswith("#"):
            s = st.lstrip("#").strip()
            if s:
                return s
        elif st:
            break
    return ""

def synopsis_for(path: Path) -> str:
    t = text_of(path)
    ext = path.suffix.lower()
    if ext in PS_EXTS:
        return syn_ps(t)
    if ext in BASH_EXTS:
        return syn_bash(t)
    if ext in PY_EXTS:
        return syn_py(t)
    return ""

def collect():
    grouped = {}
    for root in ROOTS:
        if not root.exists():
            continue
        key = root.relative_to(REPO).as_posix()
        items = []
        for p in sorted(root.rglob("*")):
            if p.is_file() and (p.suffix.lower() in ALL_EXTS):
                rel = p.relative_to(REPO).as_posix()
                syn = synopsis_for(p)
                items.append((rel, syn))
        if items:
            grouped[key] = items
    return grouped

def main():
    if not README.exists():
        print("README.md not found; aborting.")
        return 0

    data = collect()
    # ---- DEBUG: enumerate discovered items & pre-write count ----
    try:
        total = sum(len(v) for v in data.values())
        print(f"[build_catalog] Discovered {total} scripts (pre-write)")
        found_m365 = False
        for group, items in sorted(data.items()):
            for rel, syn in items:
                print(f"[build_catalog] ITEM path={rel} syn={'YES' if syn else 'NO'}")
                if rel.endswith("ConnectWise-RMM-Asio/Scripts/Windows/M365Cleanup.ps1"):
                    found_m365 = True
                    print(f"[build_catalog] ITEM-M365 matched for path={rel}")
        if not found_m365:
            print("[build_catalog] (warn) M365Cleanup.ps1 was NOT found in discovery list.")
    except Exception as _e:
        print(f"[build_catalog] (warn) enumerate items failed: {_e}")
    # ---- END DEBUG ----
    lines = []
    for group, items in sorted(data.items()):
        lines.append(f"- **{group}**")
        for rel, syn in items:
            lines.append(f"  - `{rel}`" + (f" — {syn}" if syn else ""))
    if not lines:
        lines = ["- _No scripts found yet_"]

    new_block = START + "\n" + "\n".join(lines) + "\n" + END

    md = README.read_text(encoding="utf-8")
    if START in md and END in md:
        pre, rest = md.split(START, 1)
        _, post = rest.split(END, 1)
        new_md = pre + new_block + post
    else:
        new_md = md.rstrip() + "\n\n" + new_block + "\n"

    if new_md != md:
        README.write_text(new_md, encoding="utf-8")
        print("Updated README.md with grouped catalog.")
    else:
        print("No README changes needed.")
    # ---- final discovery count ----
    try:
        total = sum(len(v) for v in data.values())
        print(f"[build_catalog] Discovered {total} scripts")
    except Exception as _e:
        print(f"[build_catalog] (warn) could not print discovery count: {_e}")
    # ---- END final discovery count ----
    return 0

if __name__ == "__main__":
    sys.exit(main())