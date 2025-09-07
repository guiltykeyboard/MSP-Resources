#!/usr/bin/env python3
"""
Synopsis linter for MSP-Resources.

- Fails CI if any script is missing a synopsis header.
- When running inside GitHub Actions (GITHUB_ACTIONS=true) and failures are found,
  the script will create or update a GitHub Issue with details **including direct links**
  to the offending files at the current commit SHA, and label it `ci` and `lint`.
- When all scripts pass, the script will find any open issue with the same title,
  post a comment that the issue is resolved with the current commit SHA, and close it.

Supported headers:
  * PowerShell: .ps1/.psm1/.ps1xml — comment-help block <# ... #> with a `.SYNOPSIS` line
  * Bash: .sh/.bash — first non-empty leading `#` comment (after shebang)
  * Python: .py — module docstring (first line synopsis) or first top-level `#` comment

Targets: ConnectWise-RMM-Asio/Scripts (Windows/Linux/Mac subfolders).
"""
from __future__ import annotations
from pathlib import Path
import os
import re
import sys
import json
import urllib.request
import urllib.error

REPO_ROOT = Path(__file__).resolve().parents[1]
ROOTS = [REPO_ROOT / "ConnectWise-RMM-Asio" / "Scripts"]

PS_EXTS   = {".ps1", ".psm1", ".ps1xml"}
BASH_EXTS = {".sh", ".bash"}
PY_EXTS   = {".py"}

ISSUE_TITLE = "Lint: scripts missing synopsis headers"

# ---------------------
# GitHub Issue helpers
# ---------------------

def gh_api(url: str, token: str, method: str = "GET", payload: dict | None = None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data) as resp:
        return json.loads(resp.read().decode("utf-8"))

def get_open_issue_by_title(repo: str, token: str, title: str):
    try:
        issues = gh_api(f"https://api.github.com/repos/{repo}/issues?state=open&per_page=100", token)
        for it in issues:
            if it.get("title") == title:
                return it
    except Exception as e:
        sys.stderr.write(f"Warning: failed to list issues: {e}\n")
    return None

def ensure_issue(repo: str, token: str, title: str, body: str):
    try:
        existing = get_open_issue_by_title(repo, token, title)
        if existing:
            gh_api(
                f"https://api.github.com/repos/{repo}/issues/{existing['number']}",
                token,
                method="PATCH",
                payload={"body": body, "labels": ["ci", "lint"]},
            )
            return existing['number']
        created = gh_api(
            f"https://api.github.com/repos/{repo}/issues",
            token,
            method="POST",
            payload={"title": title, "body": body, "labels": ["ci", "lint"]},
        )
        return created.get("number")
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"Warning: failed to create/update GitHub issue ({e.code}): {e.read().decode('utf-8', 'ignore')[:200]}\n")
        return None
    except Exception as e:
        sys.stderr.write(f"Warning: failed to create/update GitHub issue: {e}\n")
        return None

def close_issue_if_open(repo: str, token: str, title: str, comment: str):
    try:
        issue = get_open_issue_by_title(repo, token, title)
        if not issue:
            return None
        num = issue["number"]
        gh_api(
            f"https://api.github.com/repos/{repo}/issues/{num}/comments",
            token,
            method="POST",
            payload={"body": comment},
        )
        gh_api(
            f"https://api.github.com/repos/{repo}/issues/{num}",
            token,
            method="PATCH",
            payload={"state": "closed"},
        )
        return num
    except Exception as e:
        sys.stderr.write(f"Warning: failed to close issue: {e}\n")
        return None

# ---------------------
# Parsing helpers
# ---------------------

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
    return re.search(r"(?im)^\s*\.SYNOPSIS\b", block) is not None

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
    m = re.match(r'\s*[rRuU]?((?:"""|\'\'\'))([\s\S]*?)(\1)', text)
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

# ---------------------
# Main
# ---------------------

def main() -> int:
    missing: list[tuple[Path, str]] = []

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

    in_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("GITHUB_SHA", "main")
    token = os.environ.get("GITHUB_TOKEN", "")

    if missing:
        body_lines = [
            "## Synopsis linter failures",
            "The following scripts are missing required synopsis headers:",
            "",
        ]
        for p, why in missing:
            rel = p.relative_to(REPO_ROOT).as_posix()
            url = f"{server}/{repo}/blob/{sha}/{rel}"
            body_lines.append(f"- [`{rel}`]({url}) → {why}")
        body_lines += [
            "",
            "### How to fix",
            "- **PowerShell**: add a comment-based help block starting with `<#` and include a `.SYNOPSIS` line.",
            "- **Bash**: add a top `#` comment line after any shebang; the first non-empty one becomes the synopsis.",
            "- **Python**: add a module docstring at the top; the first line becomes the synopsis.",
        ]
        body = "\n".join(body_lines)

        if in_actions and repo and token:
            ensure_issue(repo, token, ISSUE_TITLE, body)
        elif in_actions:
            sys.stderr.write("Warning: GITHUB_REPOSITORY/GITHUB_TOKEN not available; skipping issue creation.\n")

        print("❌ Synopsis check failed for the following scripts:\n")
        for p, why in missing:
            print(f"- {p.relative_to(REPO_ROOT)} → {why}")
        print("\nAdd a short synopsis header (see README Script Documentation Template).")
        return 1

    if in_actions and repo and token:
        comment = f"Linter passed at {sha}. All scripts contain synopsis headers. Closing this issue."
        close_issue_if_open(repo, token, ISSUE_TITLE, comment)

    print("✅ All scripts have required synopsis headers.")
    return 0

if __name__ == "__main__":
    sys.exit(main())