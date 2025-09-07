name: Build Script Catalog

on:
  push:
    branches: [ main ]
  workflow_dispatch: {}

permissions:
  contents: write          # needed for auto-merge and to let GH mark the PR as mergeable
  pull-requests: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.x'

      - name: Generate catalog
        run: |
          python3 tools/build_catalog.py

      - name: Create PR with updated catalog
        id: cpr
        uses: peter-evans/create-pull-request@v6
        with:
          commit-message: "chore: auto-update script catalog"
          title: "chore: auto-update script catalog"
          body: "Automated update of the README Generated index."
          branch: chore/auto-update-catalog
          delete-branch: true
          labels: |
            ci-catalog
            automation

      - name: Enable auto-merge (squash)
        if: ${{ steps.cpr.outputs.pull-request-number }}
        uses: peter-evans/enable-pull-request-automerge@v3
        with:
          pull-request-number: ${{ steps.cpr.outputs.pull-request-number }}
          merge-method: squash