import os
import re
import sys
import subprocess
from github import Github

# Constants
REPO_NAME = os.getenv("GITHUB_REPOSITORY")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
ISSUE_TITLE = "Linting Issues Found in Scripts"
ISSUE_LABELS = ["lint", "automation"]

# Regex patterns
SYNOPSIS_PATTERN = re.compile(r'^\.SYNOPSIS', re.MULTILINE)
BASH_COMMENT_PATTERN = re.compile(r'^\s*#', re.MULTILINE)
PYTHON_DOCSTRING_PATTERN = re.compile(r'^\s*("""|\'\'\')', re.MULTILINE)

def find_scripts(base_dir):
    scripts = []
    for root, _, files in os.walk(base_dir):
        for file in files:
            if file.endswith(('.sh', '.bash', '.py')):
                scripts.append(os.path.join(root, file))
    return scripts

def check_synopsis(content):
    return bool(SYNOPSIS_PATTERN.search(content))

def check_bash_comments(content):
    return bool(BASH_COMMENT_PATTERN.search(content))

def check_python_docstrings(content):
    # Checks if the first statement in the file is a docstring
    lines = content.strip().splitlines()
    if not lines:
        return False
    first_line = lines[0].strip()
    return first_line.startswith('"""') or first_line.startswith("'''")

def lint_script(path):
    errors = []
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    if path.endswith(('.sh', '.bash')):
        if not check_synopsis(content):
            errors.append("Missing .SYNOPSIS block.")
        if not check_bash_comments(content):
            errors.append("Missing bash comments.")
    elif path.endswith('.py'):
        if not check_python_docstrings(content):
            errors.append("Missing Python docstring at the top of the file.")
    else:
        errors.append("Unsupported file type for linting.")

    return errors

def create_or_update_issue(gh, repo, errors_dict):
    existing_issues = repo.get_issues(state="open")
    issue = None
    for i in existing_issues:
        if i.title == ISSUE_TITLE:
            issue = i
            break

    body_lines = ["The following linting issues were found:\n"]
    for file_path, errors in errors_dict.items():
        body_lines.append(f"### {file_path}")
        for error in errors:
            # Create a link to the file in the repo at the main branch
            url = f"https://github.com/{REPO_NAME}/blob/main/{file_path}"
            body_lines.append(f"- {error} ([view file]({url}))")
        body_lines.append("")

    body = "\n".join(body_lines)

    if issue:
        issue.edit(body=body)
    else:
        repo.create_issue(title=ISSUE_TITLE, body=body, labels=ISSUE_LABELS)

def main():
    if not GITHUB_TOKEN or not REPO_NAME:
        print("GITHUB_TOKEN and GITHUB_REPOSITORY environment variables must be set.")
        sys.exit(1)

    gh = Github(GITHUB_TOKEN)
    repo = gh.get_repo(REPO_NAME)

    base_dir = "scripts"
    if not os.path.isdir(base_dir):
        print(f"Directory '{base_dir}' does not exist.")
        sys.exit(1)

    scripts = find_scripts(base_dir)
    errors_found = {}

    for script in scripts:
        errors = lint_script(script)
        if errors:
            errors_found[script] = errors

    if errors_found:
        create_or_update_issue(gh, repo, errors_found)
        print("Linting issues found and GitHub issue created/updated.")
        sys.exit(1)
    else:
        print("No linting issues found.")
        sys.exit(0)

if __name__ == "__main__":
    main()