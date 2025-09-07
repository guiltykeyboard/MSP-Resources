import os
import re
import sys
import subprocess
import requests

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SCRIPTS_DIR = os.path.join(REPO_ROOT, 'ConnectWise-RMM-Asio', 'Scripts')

GITHUB_TOKEN = os.environ.get('GITHUB_TOKEN')
GITHUB_REPOSITORY = os.environ.get('GITHUB_REPOSITORY')
GITHUB_SHA = os.environ.get('GITHUB_SHA')
GITHUB_SERVER_URL = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')

ISSUE_TITLE = "Lint: scripts missing synopsis headers"
ISSUE_LABELS = ["ci", "lint"]

def find_scripts():
    """Walk through Scripts directory and yield script file paths and types."""
    for root, dirs, files in os.walk(SCRIPTS_DIR):
        for file in files:
            path = os.path.join(root, file)
            ext = os.path.splitext(file)[1].lower()
            # Determine script type by extension
            if ext in ['.ps1', '.psm1']:
                yield path, 'powershell'
            elif ext in ['.sh', '']:
                # For bash, detect by shebang or extension
                # Some bash scripts may have no extension
                # We'll check extension first, then shebang
                if ext == '.sh':
                    yield path, 'bash'
                else:
                    # Check shebang for bash
                    try:
                        with open(path, 'r', encoding='utf-8') as f:
                            first_line = f.readline()
                            if re.match(r'^#!.*\bbash\b', first_line):
                                yield path, 'bash'
                    except Exception:
                        pass
            elif ext == '.py':
                yield path, 'python'

def check_powershell_synopsis(path):
    """Check if PowerShell script contains .SYNOPSIS in comment-based help."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
        # Look for .SYNOPSIS inside <# ... #> comment block
        # Extract all comment blocks
        blocks = re.findall(r'<#(.*?)#>', content, re.DOTALL)
        for block in blocks:
            if re.search(r'\.SYNOPSIS', block, re.IGNORECASE):
                return True
        return False
    except Exception:
        return False

def check_bash_synopsis(path):
    """Check if Bash script has a leading # synopsis comment."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line == '':
                    continue
                if line.startswith('#'):
                    # Accept any comment line as synopsis
                    return True
                else:
                    return False
        return False
    except Exception:
        return False

def check_python_synopsis(path):
    """Check if Python script has a docstring or comment synopsis at the top."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        # Skip shebang and blank lines
        idx = 0
        while idx < len(lines):
            line = lines[idx].strip()
            if line.startswith('#!') or line == '':
                idx += 1
                continue
            break

        if idx >= len(lines):
            return False

        line = lines[idx].strip()
        # Check for docstring (single or triple quotes)
        if line.startswith('"""') or line.startswith("'''"):
            # Look for closing triple quote
            quote = line[:3]
            # If closing triple quote on same line and content inside quotes
            if len(line) > 3 and line.endswith(quote) and len(line) > 6:
                # One line docstring, accept
                return True
            else:
                # Multi-line docstring, check if .SYNOPSIS or any text inside
                idx += 1
                while idx < len(lines):
                    l = lines[idx].strip()
                    if l.lower().startswith('.synopsis'):
                        return True
                    if l.endswith(quote):
                        # End of docstring
                        break
                    idx += 1
                # If no .SYNOPSIS found inside, accept if non-empty docstring?
                # We'll accept any docstring as synopsis
                return True
        elif line.startswith('#'):
            # Leading comment line(s)
            # Accept any comment line as synopsis
            return True
        else:
            return False
    except Exception:
        return False

def check_script(path, stype):
    if stype == 'powershell':
        return check_powershell_synopsis(path)
    elif stype == 'bash':
        return check_bash_synopsis(path)
    elif stype == 'python':
        return check_python_synopsis(path)
    else:
        return True  # Unknown type, skip

def create_or_update_issue(missing_files):
    headers = {
        'Authorization': f'token {GITHUB_TOKEN}',
        'Accept': 'application/vnd.github+json',
    }
    api_base = f'https://api.github.com/repos/{GITHUB_REPOSITORY}'

    # Search for existing issue
    issues_url = f'{api_base}/issues'
    params = {
        'state': 'open',
        'labels': ','.join(ISSUE_LABELS),
        'per_page': 100,
    }
    response = requests.get(issues_url, headers=headers, params=params)
    if response.status_code != 200:
        print(f"Failed to get issues from GitHub: {response.status_code} {response.text}")
        return

    issues = response.json()
    issue = None
    for i in issues:
        if i.get('title') == ISSUE_TITLE:
            issue = i
            break

    body_lines = [
        "The following scripts are missing synopsis headers:",
        "",
    ]
    for fpath in missing_files:
        # Create link to file at commit SHA
        rel_path = os.path.relpath(fpath, REPO_ROOT).replace(os.sep, '/')
        url = f"{GITHUB_SERVER_URL}/{GITHUB_REPOSITORY}/blob/{GITHUB_SHA}/{rel_path}"
        body_lines.append(f"- [{rel_path}]({url})")
    body = '\n'.join(body_lines)

    if issue:
        # Update existing issue
        issue_url = f"{api_base}/issues/{issue['number']}"
        data = {
            'body': body,
            'labels': ISSUE_LABELS,
            'title': ISSUE_TITLE,
        }
        resp = requests.patch(issue_url, headers=headers, json=data)
        if resp.status_code not in [200, 201]:
            print(f"Failed to update GitHub issue: {resp.status_code} {resp.text}")
    else:
        # Create new issue
        data = {
            'title': ISSUE_TITLE,
            'body': body,
            'labels': ISSUE_LABELS,
        }
        resp = requests.post(issues_url, headers=headers, json=data)
        if resp.status_code not in [200, 201]:
            print(f"Failed to create GitHub issue: {resp.status_code} {resp.text}")

def main():
    missing = []
    for path, stype in find_scripts():
        if not check_script(path, stype):
            missing.append(path)

    if missing:
        print("Scripts missing synopsis headers:")
        for f in missing:
            print(f" - {os.path.relpath(f, REPO_ROOT)}")
        if GITHUB_TOKEN and GITHUB_REPOSITORY and GITHUB_SHA:
            create_or_update_issue(missing)
        sys.exit(1)
    else:
        print("All scripts have synopsis headers.")
        sys.exit(0)

if __name__ == '__main__':
    main()