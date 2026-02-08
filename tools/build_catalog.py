#!/usr/bin/env python3
from __future__ import annotations
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple, DefaultDict
from collections import defaultdict

# --- repo locations ---
REPO = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO / "ConnectWise-RMM-Asio" / "Scripts"
STANDALONE_DIR = REPO / "Standalone"
PSA_DIR = REPO / "ConnectWise-PSA"
README = REPO / "README.md"

# which file types count as scripts in the catalog
SCRIPT_EXTS = {".ps1", ".psm1", ".py", ".sh"}

# Simple synopsis detector for PowerShell files
_SYNOPSIS_RE = re.compile(r"^\s*<\#.*?\.SYNOPSIS.*?\#>", re.IGNORECASE | re.DOTALL | re.MULTILINE)

MARKER_START = "<!-- GENERATED-CATALOG:START -->"
MARKER_END = "<!-- GENERATED-CATALOG:END -->"


def render_catalog_block(data: Dict[str, Dict[str, List[Tuple[str, bool]]]], docs: Dict[str, str]) -> str:
    lines: List[str] = []
    for cat in sorted(data.keys()):
        lines.append(f"### {cat}\n\n")
        for sec in sorted(data[cat].keys()):
            lines.append(f"#### {sec}\n\n")
            for rel, syn in data[cat][sec]:
                base = Path(rel).name
                syn_tag = " (synopsis)" if syn else ""
                doc = docs.get(rel)
                doc_part = f" — [docs]({doc})" if doc else ""
                lines.append(f"- [{base}]({rel}){doc_part}{syn_tag}\n")
            lines.append("\n")
        lines.append("\n")
    return "".join(lines)


def has_synopsis(p: Path) -> bool:
    if p.suffix.lower() in {".ps1", ".psm1"}:
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            return False
        return bool(_SYNOPSIS_RE.search(text))
    # for non-PS scripts, don't enforce synopsis
    return True


def discover_scripts() -> List[Path]:
    roots: List[Path] = []
    for root in [SCRIPTS_DIR, STANDALONE_DIR, PSA_DIR]:
        if root.is_dir():
            for p in root.rglob("*"):
                if p.is_file() and p.suffix.lower() in SCRIPT_EXTS:
                    roots.append(p)
    return sorted({p for p in roots})


def section_for(p: Path) -> Tuple[str, str]:
    parts = p.parts
    # ConnectWise RMM scripts: ConnectWise-RMM-Asio / Scripts / <Platform> / file
    if "Scripts" in parts:
        try:
            idx = parts.index("Scripts")
            if idx + 1 < len(parts):
                return "ConnectWise RMM (Asio)", parts[idx + 1]
        except ValueError:
            pass
    # Standalone scripts: Standalone / <Category?> / file
    if "Standalone" in parts:
        try:
            idx = parts.index("Standalone")
            if idx + 1 < len(parts):
                return "Standalone", parts[idx + 1]
            return "Standalone", "General"
        except ValueError:
            pass
    # ConnectWise PSA scripts: ConnectWise-PSA / <Category?> / file
    if "ConnectWise-PSA" in parts:
        try:
            idx = parts.index("ConnectWise-PSA")
            if idx + 1 < len(parts):
                return "ConnectWise PSA", parts[idx + 1]
            return "ConnectWise PSA", "General"
        except ValueError:
            pass
    return "Misc", "Misc"


def normalize_name(s: str) -> str:
    # strip non-alnum, lowercase
    return "".join(re.findall(r"[A-Za-z0-9]+", s)).lower()


def build_doc_lookup() -> Dict[str, str]:
    """Return mapping of script relative path -> doc relative path (best-effort)."""
    docs: List[Path] = []

    # Collect docs that look like README files under known documentation roots
    doc_roots = [REPO / "ConnectWise-RMM-Asio" / "CW-RMM-Documentation", STANDALONE_DIR, REPO / "ConnectWise-PSA" / "psaDocumentation"]
    for root in doc_roots:
        if root.is_dir():
            for p in root.rglob("*"):
                if p.is_file() and p.name.lower() in {"readme.md", "readme"}:
                    docs.append(p)

    # Index docs by normalized folder name (parent dir) to match scripts by stem
    doc_index: Dict[str, Path] = {}
    for doc in docs:
        key = normalize_name(doc.parent.name or doc.stem)
        doc_index[key] = doc

    mapping: Dict[str, str] = {}

    def best_doc_for(script: Path) -> Path | None:
        # 1) Same directory README/readme or <script>.md
        for candidate in [script.parent / "README.md", script.parent / "readme.md", script.parent / f"{script.stem}.md"]:
            if candidate.is_file():
                return candidate

        # 2) If in CW RMM tree, try sibling doc folder keyed by script stem
        stem_key = normalize_name(script.stem)
        if stem_key in doc_index:
            return doc_index[stem_key]

        # 3) Fuzzy match on doc folder names (helpful for cases like M365Cleanup vs cleanupM365)
        import difflib

        if not doc_index:
            return None
        matches = difflib.get_close_matches(stem_key, doc_index.keys(), n=1, cutoff=0.5)
        if matches:
            return doc_index[matches[0]]
        return None

    for script in discover_scripts():
        doc = best_doc_for(script)
        if doc:
            mapping[script.relative_to(REPO).as_posix()] = doc.relative_to(REPO).as_posix()
    return mapping


def build_catalog_data(paths: List[Path]) -> Dict[str, Dict[str, List[Tuple[str, bool]]]]:
    nested: DefaultDict[str, DefaultDict[str, List[Tuple[str, bool]]]] = defaultdict(lambda: defaultdict(list))
    for p in paths:
        rel = p.relative_to(REPO).as_posix()
        syn = has_synopsis(p)
        print(f"[build_catalog] ITEM path={rel} syn={'YES' if syn else 'NO'}")
        sec = section_for(p)
        category, section = sec
        nested[category][section].append((rel, syn))
        if p.name.lower().startswith("m365cleanup"):
            print(f"[build_catalog] ITEM-M365 matched for path={rel}")
    # sort entries within each section
    for cat in list(nested.keys()):
        for sec in list(nested[cat].keys()):
            nested[cat][sec].sort(key=lambda t: t[0].lower())
    return nested  # type: ignore


def render_readme(data: Dict[str, Dict[str, List[Tuple[str, bool]]]], docs: Dict[str, str]) -> str:
    catalog = render_catalog_block(data, docs)
    block = f"{MARKER_START}\n{catalog}{MARKER_END}\n"

    if README.exists():
        prev = README.read_text(encoding="utf-8")
        # Preferred: replace between markers
        if MARKER_START in prev and MARKER_END in prev:
            pre, _, rest = prev.partition(MARKER_START)
            _, _, post = rest.partition(MARKER_END)
            combined = f"{pre}{block}{post}"
            return combined
        # Legacy: replace a heading named '## Script Catalog' up to the next top-level heading
        LEGACY_H1 = "## Script Catalog"
        if LEGACY_H1 in prev:
            start = prev.index(LEGACY_H1)
            # find next H2 heading starting after start
            m = re.search(r"^##[\t ]+.+$", prev[start+len(LEGACY_H1):], flags=re.MULTILINE)
            if m:
                end = start + len(LEGACY_H1) + m.start()
            else:
                end = len(prev)
            combined = prev[:start] + block + prev[end:]
            return combined
        # Otherwise: append block to end
        return prev.rstrip() + "\n\n" + block
    else:
        # Minimal README scaffolding
        return "# MSP Resources\n\n" + block


def write_readme(new_md: str) -> None:
    prev = README.read_text(encoding="utf-8") if README.exists() else ""
    if new_md != prev:
        README.write_text(new_md, encoding="utf-8")
        print("Updated README.md with grouped catalog.")
    else:
        print("README.md already up-to-date.")


def validate_presence(data: Dict[str, Dict[str, List[Tuple[str, bool]]]]) -> None:
    """Write a marker file if any discovered script base name is absent from README."""
    txt = README.read_text(encoding="utf-8") if README.exists() else ""
    if MARKER_START in txt and MARKER_END in txt:
        txt = txt.split(MARKER_START, 1)[1].split(MARKER_END, 1)[0]
    missing: List[str] = []
    for cat in sorted(data.keys()):
        for sec in sorted(data[cat].keys()):
            for rel, _syn in data[cat][sec]:
                base = Path(rel).stem
                if base.lower() not in txt.lower():
                    missing.append(base)
    marker = REPO / ".catalog_validation_failed"
    if missing:
        try:
            marker.write_text("missing\n", encoding="utf-8")
        except Exception:
            pass
        print(f"[build_catalog] VALIDATION: missing entries in README: {', '.join(sorted(set(missing)))}")
    else:
        if marker.exists():
            try:
                marker.unlink()
            except Exception:
                pass
        print("[build_catalog] VALIDATION: all discovered scripts present in README.")


def main() -> int:
    scripts = discover_scripts()
    print(f"[build_catalog] Discovered {len(scripts)} scripts (pre-write)")
    data = build_catalog_data(scripts)
    doc_map = build_doc_lookup()
    print(f"[build_catalog] Matched docs for {len(doc_map)} scripts")
    new_md = render_readme(data, doc_map)
    write_readme(new_md)
    print(f"[build_catalog] Discovered {len(scripts)} scripts")
    validate_presence(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
