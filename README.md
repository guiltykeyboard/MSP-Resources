import os
import sys
import re
import subprocess
import requests

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "ConnectWise-RMM-Asio", "Scripts")

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY")
GITHUB_SHA = os.environ.get("GITHUB_SHA")
GITHUB_SERVER_URL = os.environ.get("GITHUB_SERVER_URL", "https://github.com")

ISSUE_TITLE = "Lint: scripts missing synopsis headers"
ISSUE_LABELS = ["ci", "lint"]

def check_powershell(file_path):
    """
    Check if PowerShell script contains .SYNOPSIS in comment-help.
    """
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return False

    # Look for .SYNOPSIS in a block comment or comment-based help
    # PowerShell comment help usually starts with <# and ends with #>
    # .SYNOPSIS should appear inside that block
    block_comments = re.findall(r"<#.*?#>", content, re.DOTALL)
    for block in block_comments:
        if re.search(r"\.SYNOPSIS\s", block, re.IGNORECASE):
            return True
    return False


def check_bash(file_path):
    """
    Check if Bash script contains a leading comment synopsis line.
    """
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return False

    # Look for a comment line near the top that looks like a synopsis
    # Typically the first non-shebang line that starts with #
    for line in lines[:10]:
        line = line.strip()
        if line.startswith("#") and len(line) > 1:
            # Consider any non-empty comment line as synopsis
            return True
        # Skip blank lines or shebang lines
        if line and not line.startswith("#") and not line.startswith("#!"):
            break
    return False


def check_python(file_path):
    """
    Check if Python script contains a docstring or a comment synopsis near the top.
    """
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return False

    # Check for module docstring at top (triple quotes)
    docstring_match = re.match(r'\s*(["\']{3})(.*?)\1', content, re.DOTALL)
    if docstring_match:
        docstring = docstring_match.group(2).strip()
        if docstring:
            return True

    # If no docstring, check for comment synopsis in first 10 lines
    lines = content.splitlines()
    for line in lines[:10]:
        line = line.strip()
        if line.startswith("#") and len(line) > 1:
            return True
        if line and not line.startswith("#"):
            break
    return False


def is_script_file(filename):
    """
    Determine if the file is a script we want to lint based on extension.
    """
    ext = os.path.splitext(filename)[1].lower()
    return ext in [".ps1", ".psm1", ".sh", ".py"]


def check_file(file_path):
    """
    Check a single file for synopsis header based on its type.
    Returns True if synopsis found, False otherwise.
    """
    ext = os.path.splitext(file_path)[1].lower()
    if ext in [".ps1", ".psm1"]:
        return check_powershell(file_path)
    elif ext == ".sh":
        return check_bash(file_path)
    elif ext == ".py":
        return check_python(file_path)
    else:
        # Not a script file we check
        return True


def find_missing_synopsis():
    """
    Walk through scripts directory and find files missing synopsis.
    Returns list of file paths with missing synopsis.
    """
    missing = []
    for root, dirs, files in os.walk(SCRIPTS_DIR):
        for f in files:
            if is_script_file(f):
                path = os.path.join(root, f)
                if not check_file(path):
                    # Store relative path from repo root
                    rel_path = os.path.relpath(path, REPO_ROOT)
                    missing.append(rel_path)
    return missing


def print_results(missing):
    print("\nLint Results:")
    if missing:
        print(f"Found {len(missing)} script(s) missing synopsis headers:\n")
        for f in missing:
            print(f" - {f}")
        print("\nPlease add synopsis headers to these scripts.")
    else:
        print("All scripts have synopsis headers.")


def github_api_headers():
    return {
        "Authorization": f"token {GITHUB_TOKEN}",
        "Accept": "application/vnd.github.v3+json",
    }


def get_existing_issue():
    """
    Return the issue dict if an open issue with the lint title exists, else None.
    """
    if not GITHUB_TOKEN or not GITHUB_REPOSITORY:
        return None

    url = f"{GITHUB_SERVER_URL}/api/v3/repos/{GITHUB_REPOSITORY}/issues"
    params = {"state": "open", "labels": ",".join(ISSUE_LABELS), "per_page": 100}
    headers = github_api_headers()
    try:
        resp = requests.get(url, headers=headers, params=params)
        resp.raise_for_status()
        issues = resp.json()
        for issue in issues:
            if issue.get("title") == ISSUE_TITLE:
                return issue
    except Exception:
        return None
    return None


def create_or_update_issue(missing):
    """
    Create or update GitHub issue with missing synopsis files.
    """
    if not GITHUB_TOKEN or not GITHUB_REPOSITORY:
        return

    issue = get_existing_issue()
    body_lines = [
        "The following scripts are missing synopsis headers, which are required for proper linting and documentation:\n"
    ]
    for f in missing:
        url = f"{GITHUB_SERVER_URL}/{GITHUB_REPOSITORY}/blob/{GITHUB_SHA}/{f}"
        body_lines.append(f"- [{f}]({url})")
    body_lines.append("\nPlease add synopsis headers to these scripts to comply with repository standards.")

    body = "\n".join(body_lines)

    headers = github_api_headers()
    url = f"{GITHUB_SERVER_URL}/api/v3/repos/{GITHUB_REPOSITORY}/issues"
    if issue:
        # Update existing issue
        patch_url = issue["url"]
        data = {"body": body}
        try:
            resp = requests.patch(patch_url, headers=headers, json=data)
            resp.raise_for_status()
        except Exception:
            pass
    else:
        # Create new issue
        data = {
            "title": ISSUE_TITLE,
            "body": body,
            "labels": ISSUE_LABELS,
        }
        try:
            resp = requests.post(url, headers=headers, json=data)
            resp.raise_for_status()
        except Exception:
            pass


def main():
    missing = find_missing_synopsis()
    print_results(missing)
    if missing and GITHUB_TOKEN and GITHUB_REPOSITORY and GITHUB_SHA:
        create_or_update_issue(missing)
    if missing:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()

<!-- GENERATED-CATALOG:START -->
- **ConnectWise-RMM-Asio/Scripts**
  - `ConnectWise-RMM-Asio/Scripts/Windows/backupBitlockerKeys.ps1` — Backup and inventory BitLocker recovery keys on this device.
  - `ConnectWise-RMM-Asio/Scripts/Windows/checkIfBitlockerEnabled.ps1`
  - `ConnectWise-RMM-Asio/Scripts/backupBitlockerKeys.ps1` — Backup BitLocker Recovery Keys to files and optionally to Active Directory.
<!-- GENERATED-CATALOG:END -->
