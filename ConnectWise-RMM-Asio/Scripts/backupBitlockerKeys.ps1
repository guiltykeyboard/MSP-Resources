# ------------------------------
# Global ignores for MSP-Resources
# ------------------------------

# macOS Finder metadata
.DS_Store
*/.DS_Store
.AppleDouble
.LSOverride
Icon?
._*
.Spotlight-V100
.Trashes
*.icloud

# Windows Explorer metadata
Thumbs.db
Thumbs.db:encryptable
ehthumbs.db
Desktop.ini
$RECYCLE.BIN/

# Editor/IDE configs
.vscode/
*.code-workspace
.idea/
*.swp
*.swo
*.tmp

# Logs / temp / local output
logs/
log/
*.log
*.tmp
tmp/
.temp/
.cache/

# Archives & bundles
*.zip
*.tar
*.tar.gz
*.tgz
*.7z

# Python
__pycache__/
*.py[cod]
*$py.class
.venv/
venv/
.env
.env.*
.python-version
.pytest_cache/
.coverage

# Node / package managers (just in case helpers get added later)
node_modules/
.pnpm-store/
.npm/
.yarn/

# Build output (generic)
dist/
build/
release/

# PowerShell artifacts (keep scripts, ignore transcripts/outputs)
*_Transcript.log
*.pshistory

# Repo-specific: keep scripts in source, ignore local output folders if created
output/
out/
artifacts/
reports/

# OS-specific junk in subfolders
**/.DS_Store
**/Thumbs.db
