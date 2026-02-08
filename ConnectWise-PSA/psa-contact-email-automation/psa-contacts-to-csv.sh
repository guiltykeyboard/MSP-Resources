#!/usr/bin/env bash
set -euo pipefail

########################################
# Help / Usage
########################################
usage() {
  cat <<'EOF'
Usage: psa-contacts-to-csv.sh [options]

Options:
  -h, --help        Show this help message and exit
  -dump-json        Dump raw JSON API responses to a timestamped .json file
                    in the same directory as the CSV output

Environment Variables:
  BASE_URL          ConnectWise API base URL
                    (default: https://api-na.myconnectwise.net/v4_6_release/apis/3.0)
  COMPANY_ID        ConnectWise company ID (required)
  PUBLIC_KEY        ConnectWise API public key (required)
  PRIVATE_KEY       ConnectWise API private key (required)
  CLIENT_ID         ConnectWise ClientID GUID (required)

  OUTPUT_DIR        Directory where CSV/JSON output will be written
                    (default: current directory)
  OUTPUT_FILENAME   CSV filename
                    (default: contacts.csv)

  PAGE_SIZE         Page size for API calls (default: 1000)
  MAX_PAGES         Maximum pages to fetch (default: 10)
  PREFETCH_COMPANIES  Set to 0 to disable company prefetch (default: 1)
  KEEP_MAP_FILES     Set to 1 to keep company-map.json and company-type-map.json
                    after export completes (default: 0)

  EXCLUDE_COMPANY_IDS  Comma-separated company record IDs to exclude
                     (default: 19298)

  EXCLUDE_COMPANY_TYPE_LABELS  Comma-separated company type labels to exclude
                              (default: Former Client)
  EXCLUDE_CONTACT_TYPE_LABELS  Comma-separated contact type/status labels to exclude
                              (default: Gone, No Longer With Company)
  EXCLUDE_INACTIVE_CONTACTS    Set to 1 to exclude inactive contacts (default: 1)

  DEBUG             Set to 1 to enable verbose debug logging

Output columns include:
  - companyRecId: ConnectWise company record ID (numeric)
  - companyId: ConnectWise company identifier (string shown in UI)
  - contactRecId: ConnectWise contact record ID (numeric)
Examples:
  Export contacts to CSV:
    ./psa-contacts-to-csv.sh

  Export contacts with debug logging:
    DEBUG=1 ./psa-contacts-to-csv.sh

  Export contacts and dump raw JSON:
    ./psa-contacts-to-csv.sh -dump-json

  Export to a specific directory:
    OUTPUT_DIR=./output OUTPUT_FILENAME=contacts.csv ./psa-contacts-to-csv.sh
EOF
}

# Handle help flag early
if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  usage
  exit 0
fi

########################################
# Config (env vars or edit defaults)
########################################

# Example: https://api-na.myconnectwise.net/v4_6_release/apis/3.0
BASE_URL="${BASE_URL:-https://api-na.myconnectwise.net/v4_6_release/apis/3.0}"

# Your ConnectWise login company ID
: "${COMPANY_ID:?Set COMPANY_ID environment variable}"

# API member keys
: "${PUBLIC_KEY:?Set PUBLIC_KEY environment variable}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY environment variable}"

# Your ConnectWise ClientID GUID
: "${CLIENT_ID:?Set CLIENT_ID environment variable}"

# Pagination
PAGE_SIZE="${PAGE_SIZE:-1000}"   # CW max is 1000
MAX_PAGES="${MAX_PAGES:-10}"     # you can bump this if needed

# Exclusions
# Comma-separated list of company record IDs to exclude from the export.
# Example: EXCLUDE_COMPANY_IDS="19298,12345"
EXCLUDE_COMPANY_IDS="${EXCLUDE_COMPANY_IDS:-19298}"

# Exclude companies/contacts by type label (CSV-friendly, post-processing filter)
EXCLUDE_COMPANY_TYPE_LABELS="${EXCLUDE_COMPANY_TYPE_LABELS:-Former Client}"
EXCLUDE_CONTACT_TYPE_LABELS="${EXCLUDE_CONTACT_TYPE_LABELS:-Gone, No Longer With Company}"
EXCLUDE_INACTIVE_CONTACTS="${EXCLUDE_INACTIVE_CONTACTS:-1}"

# Output directory and filename
OUTPUT_DIR="${OUTPUT_DIR:-.}"
OUTPUT_FILENAME="${OUTPUT_FILENAME:-contacts.csv}"
OUTPUT_CSV="${OUTPUT_DIR%/}/${OUTPUT_FILENAME}"

# Company map cache (prefetch companies once to avoid per-contact lookups)
PREFETCH_COMPANIES="${PREFETCH_COMPANIES:-1}"   # set to 0 to disable prefetch
KEEP_MAP_FILES="${KEEP_MAP_FILES:-0}"  # set to 1 to keep map files after successful run
COMPANY_MAP_FILE="${OUTPUT_DIR%/}/company-map.json"
COMPANY_TYPE_MAP_FILE="${OUTPUT_DIR%/}/company-type-map.json"
export PREFETCH_COMPANIES
export COMPANY_MAP_FILE
export COMPANY_TYPE_MAP_FILE

# Auto-create output directory if it does not exist
if [ ! -d "${OUTPUT_DIR}" ]; then
  echo "Output directory does not exist. Creating: ${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}"
fi

# Python executable (override with PYTHON=/path/to/python)
PYTHON="${PYTHON:-python3}"

# Debug mode (set DEBUG=1 to enable verbose logging)
DEBUG="${DEBUG:-0}"

log_debug() {
  if [ "${DEBUG}" != "0" ]; then
    echo "[DEBUG] $*"
  fi
}

# Dump raw JSON responses to a timestamped file when enabled (safe defaults for set -u)
DUMP_JSON="${DUMP_JSON:-0}"
RAW_JSON_FILE="${RAW_JSON_FILE:-}"

# Optional CLI flag: -dump-json
if [ "${1-}" = "-dump-json" ]; then
  DUMP_JSON=1
  shift
fi

# Initialize raw JSON dump file path if dump-json is enabled
if [ "${DUMP_JSON}" != "0" ]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  RAW_JSON_FILE="${OUTPUT_DIR%/}/raw-json-${timestamp}.json"
  log_debug "Raw JSON output will be written to: ${RAW_JSON_FILE}"
fi

########################################
# Build Basic Auth header
########################################

AUTH_RAW="${COMPANY_ID}+${PUBLIC_KEY}:${PRIVATE_KEY}"
AUTH_B64="$(printf '%s' "$AUTH_RAW" | base64)"

# Export for embedded Python (fallback company lookups)
export CW_BASE_URL="${BASE_URL}"
export CW_AUTH_B64="${AUTH_B64}"
export CW_CLIENT_ID="${CLIENT_ID}"

# Export exclusion env vars for embedded Python filtering
export EXCLUDE_COMPANY_TYPE_LABELS
export EXCLUDE_CONTACT_TYPE_LABELS
export EXCLUDE_INACTIVE_CONTACTS

log_debug "BASE_URL=${BASE_URL}"
log_debug "COMPANY_ID=${COMPANY_ID}"
log_debug "PAGE_SIZE=${PAGE_SIZE}"
log_debug "MAX_PAGES=${MAX_PAGES}"
log_debug "OUTPUT_CSV=${OUTPUT_CSV}"
log_debug "PYTHON=${PYTHON}"

echo "Exporting contacts to: ${OUTPUT_CSV}"
rm -f "$OUTPUT_CSV"

########################################
# Prefetch Companies + CompanyTypes (fast company types/address)
########################################
if [ "${PREFETCH_COMPANIES}" != "0" ]; then
  echo "Prefetching companies (types/address) to: ${COMPANY_MAP_FILE}"
  rm -f "${COMPANY_MAP_FILE}"

  echo "Prefetching company types (id->label) to: ${COMPANY_TYPE_MAP_FILE}"
  rm -f "${COMPANY_TYPE_MAP_FILE}"

  # Prefetch companyTypes once so we can resolve type IDs to labels.
  # Many tenants only return ids in company.types[] except for Prospect.
  type_page=1
  while : ; do
    echo "  -> Fetching companyTypes page ${type_page}..."
    # Some tenants/security roles allow listing types but deny certain fields; request minimal fields.
    company_types_url="${BASE_URL}/company/companies/types?fields=id,name&pageSize=${PAGE_SIZE}&page=${type_page}"

    company_types_resp="$(
      curl -sS \
        -H "Authorization: Basic ${AUTH_B64}" \
        -H "clientId: ${CLIENT_ID}" \
        -H "Accept: application/json" \
        "$company_types_url"
    )"

    company_types_count="$(
      printf '%s' "$company_types_resp" | "$PYTHON" -c 'import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
'
    )"

    if [ "$company_types_count" -eq 0 ]; then
      echo "  -> No companyTypes returned (or response not an array). Stopping companyTypes prefetch."
      if [ "${DEBUG:-0}" != "0" ]; then
        echo "  -> [DEBUG] companyTypes URL: ${company_types_url}"
        echo "  -> [DEBUG] companyTypes response (first 300 chars): ${company_types_resp:0:300}"
      fi
      break
    fi

    # Merge this page into COMPANY_TYPE_MAP_FILE (id -> {id,label,name,identifier,description})
    printf '%s' "$company_types_resp" | "$PYTHON" -c 'import sys, json, os
path = os.environ.get("COMPANY_TYPE_MAP_FILE")
if not path:
    sys.exit(0)

try:
    page = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if not isinstance(page, list):
    sys.exit(0)

existing = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path, "r", encoding="utf-8") as f:
            existing = json.load(f)
            if not isinstance(existing, dict):
                existing = {}
    except Exception:
        existing = {}

for t in page:
    if not isinstance(t, dict):
        continue
    tid = t.get("id")
    if tid is None:
        continue
    label = t.get("name") or t.get("identifier") or t.get("description")
    existing[str(tid)] = {
        "id": tid,
        "label": label,
        "name": t.get("name"),
        "identifier": t.get("identifier"),
        "description": t.get("description"),
    }

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(existing, f)
os.replace(tmp, path)
'

    if [ "$company_types_count" -lt "$PAGE_SIZE" ]; then
      echo "  -> CompanyTypes prefetch complete (${company_types_count} types on last page)."
      break
    fi

    type_page=$((type_page + 1))
  done

  company_page=1
  while : ; do
    echo "  -> Fetching companies page ${company_page}..."
    companies_url="${BASE_URL}/company/companies?fields=id,identifier,name,type,type/name,types,types/name,types/identifier,types/description,address,addressLine1,addressLine2,city,state,zip,country&pageSize=${PAGE_SIZE}&page=${company_page}"

    companies_resp="$(
      curl -sS \
        -H "Authorization: Basic ${AUTH_B64}" \
        -H "clientId: ${CLIENT_ID}" \
        -H "Accept: application/json" \
        "$companies_url"
    )"

    companies_count="$(
      printf '%s' "$companies_resp" | "$PYTHON" -c 'import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
'
    )"

    if [ "$companies_count" -eq 0 ]; then
      echo "  -> No companies returned (or response not an array). Stopping company prefetch."
      break
    fi

    # Merge this page into COMPANY_MAP_FILE (id -> {name, identifier, types, address})
    printf '%s' "$companies_resp" | "$PYTHON" -c 'import sys, json, os
path = os.environ.get("COMPANY_MAP_FILE")
if not path:
    sys.exit(0)

try:
    page = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if not isinstance(page, list):
    sys.exit(0)

existing = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path, "r", encoding="utf-8") as f:
            existing = json.load(f)
            if not isinstance(existing, dict):
                existing = {}
    except Exception:
        existing = {}

for c in page:
    if not isinstance(c, dict):
        continue
    cid = c.get("id")
    if cid is None:
        continue
    existing[str(cid)] = {
        "id": cid,
        "identifier": c.get("identifier"),
        "name": c.get("name"),
        "type": c.get("type"),
        "types": c.get("types"),
        # Some CW payloads use a nested `address` object, others are flat fields.
        "address": c.get("address"),
        "addressLine1": c.get("addressLine1"),
        "addressLine2": c.get("addressLine2"),
        "city": c.get("city"),
        "state": c.get("state"),
        "zip": c.get("zip"),
        "country": c.get("country"),
    }

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(existing, f)
os.replace(tmp, path)
'

    if [ "$companies_count" -lt "$PAGE_SIZE" ]; then
      echo "  -> Prefetch complete (${companies_count} companies on last page)."
      break
    fi

    company_page=$((company_page + 1))
  done

  if [ "${DEBUG:-0}" != "0" ]; then
    echo "[DEBUG] Prefetch summary:"
    if [ -f "${COMPANY_MAP_FILE}" ]; then
      echo -n "[DEBUG]  company-map count: "
      "$PYTHON" -c 'import json,sys
m=json.load(open(sys.argv[1]));
print(len(m) if isinstance(m, dict) else 0)
' "${COMPANY_MAP_FILE}" || true
    else
      echo "[DEBUG]  company-map missing"
    fi
    if [ -f "${COMPANY_TYPE_MAP_FILE}" ]; then
      echo -n "[DEBUG]  company-type-map count: "
      "$PYTHON" -c 'import json,sys
m=json.load(open(sys.argv[1]));
print(len(m) if isinstance(m, dict) else 0)
' "${COMPANY_TYPE_MAP_FILE}" || true
    else
      echo "[DEBUG]  company-type-map missing"
    fi
  fi
else
  echo "Company prefetch disabled (PREFETCH_COMPANIES=0). Company type/address may be blank."
fi

########################################
# Python CSV writer (temp file)
########################################
CSV_WRITER_PY="$(mktemp)"
trap 'rm -f "${CSV_WRITER_PY}"' EXIT

cat <<'PY' > "${CSV_WRITER_PY}"
import sys, json, os, csv

out_path = sys.argv[1] if len(sys.argv) > 1 else None
if not out_path:
    sys.exit(0)

CW_BASE_URL = os.environ.get("CW_BASE_URL")
CW_AUTH_B64 = os.environ.get("CW_AUTH_B64")
CW_CLIENT_ID = os.environ.get("CW_CLIENT_ID")

# Optional company map (prefetched): id -> {name, identifier, type, types, address}
company_map = {}
company_map_path = os.environ.get("COMPANY_MAP_FILE")
if company_map_path and os.path.exists(company_map_path):
    try:
        with open(company_map_path, "r", encoding="utf-8") as cf:
            obj = json.load(cf)
            if isinstance(obj, dict):
                company_map = obj
    except Exception:
        company_map = {}

# Optional company type map (prefetched): typeId -> {label,name,identifier,description}
company_type_map = {}
company_type_map_path = os.environ.get("COMPANY_TYPE_MAP_FILE")
if company_type_map_path and os.path.exists(company_type_map_path):
    try:
        with open(company_type_map_path, "r", encoding="utf-8") as tf:
            obj = json.load(tf)
            if isinstance(obj, dict):
                company_type_map = obj
    except Exception:
        company_type_map = {}

try:
    data = json.load(sys.stdin)
except Exception as e:
    print("Failed to parse JSON:", e, file=sys.stderr)
    sys.exit(0)

if not isinstance(data, list):
    # Unexpected response shape
    sys.exit(0)

fieldnames = [
    "companyName",
    "companyRecId",
    "companyId",
    "companyIdentifier",
    "companyType",
    "companyAddressLine1",
    "companyAddressLine2",
    "companyCity",
    "companyState",
    "companyZip",
    "companyCountry",
    "contactRecId",
    "firstName",
    "lastName",
    "contactType",
    "contactInactiveFlag",
    "email",
]

# Determine if we need to write the header
write_header = not os.path.exists(out_path) or os.path.getsize(out_path) == 0

EXCLUDE_COMPANY_TYPE_LABELS = os.environ.get("EXCLUDE_COMPANY_TYPE_LABELS", "Former Client")
EXCLUDE_CONTACT_TYPE_LABELS = os.environ.get("EXCLUDE_CONTACT_TYPE_LABELS", "Gone, No Longer With Company")
EXCLUDE_INACTIVE_CONTACTS = os.environ.get("EXCLUDE_INACTIVE_CONTACTS", "1")

exclude_company_types = {x.strip().lower() for x in EXCLUDE_COMPANY_TYPE_LABELS.split(",") if x.strip()}
exclude_contact_types = {x.strip().lower() for x in EXCLUDE_CONTACT_TYPE_LABELS.split(",") if x.strip()}
exclude_inactive = EXCLUDE_INACTIVE_CONTACTS not in ("0", "false", "False", "no", "No")

def _split_labels(s):
    if not isinstance(s, str) or not s.strip():
        return []
    return [p.strip().lower() for p in s.split(",") if p.strip()]

def extract_email(communication_items):
    if not isinstance(communication_items, list):
        return None

    # Preferred: items explicitly marked as email
    for ci in communication_items:
        t = (ci.get("type") or ci.get("communicationType") or "")
        t = str(t).lower()
        if t in ("email", "e-mail"):
            return ci.get("value") or ci.get("address")

    # Fallback: any value that looks like an email
    for ci in communication_items:
        val = ci.get("value")
        if isinstance(val, str) and "@" in val:
            return val

    return None

def extract_contact_type(contact):
    # CW contacts may have a singular primary type (`type`) and/or multiple types (`types`).
    t = contact.get("type")
    if isinstance(t, dict):
        label = t.get("name") or t.get("identifier") or t.get("description") or t.get("value")
        if label:
            return str(label)
    elif isinstance(t, str) and t:
        return t

    tv = contact.get("types")
    if isinstance(tv, list):
        names = []
        for item in tv:
            if isinstance(item, dict):
                label = (
                    item.get("name")
                    or item.get("identifier")
                    or item.get("description")
                    or item.get("value")
                )
                if label:
                    names.append(str(label))
            elif isinstance(item, str) and item:
                names.append(item)
        return ", ".join(names) if names else None

    return None

def extract_company_type(company, company_id=None):
    """
    ConnectWise companies typically have a primary Company Type under `company.type`.
    Some payloads also include `company.types` (list). Return a comma-separated
    string of labels.
    """
    if not isinstance(company, dict):
        return None

    # 1) Prefer singular `type` (most tenants/UI)
    t_primary = company.get("type")
    if (not t_primary) and company_id:
        fetched = company_map.get(str(company_id), {})
        if isinstance(fetched, dict):
            t_primary = fetched.get("type")

    if isinstance(t_primary, dict):
        label = t_primary.get("name") or t_primary.get("identifier") or t_primary.get("description")
        if not label:
            tid = t_primary.get("id")
            if tid is not None:
                m = company_type_map.get(str(tid))
                if isinstance(m, dict):
                    label = m.get("label") or m.get("name") or m.get("identifier") or m.get("description")
        if label:
            return str(label)
    elif isinstance(t_primary, str) and t_primary:
        return t_primary

    # 2) Fallback to multi-type list `types`
    types_val = company.get("types")
    if (not types_val) and company_id:
        fetched = company_map.get(str(company_id), {})
        if isinstance(fetched, dict):
            types_val = fetched.get("types")

    if isinstance(types_val, list):
        names = []
        for t in types_val:
            if isinstance(t, dict):
                label = (
                    t.get("name")
                    or t.get("identifier")
                    or t.get("description")
                    or t.get("value")
                )
                if not label:
                    tid = t.get("id")
                    if tid is not None:
                        m = company_type_map.get(str(tid))
                        if isinstance(m, dict):
                            label = m.get("label") or m.get("name") or m.get("identifier") or m.get("description")
                if label:
                    names.append(str(label))
            elif isinstance(t, str):
                names.append(t)
        return ", ".join(names) if names else None

    return None

def extract_company_address_fields(company, company_id=None):
    """Returns tuple: (addressLine1, addressLine2, city, state, zip, country)."""
    if not isinstance(company, dict):
        return (None, None, None, None, None, None)

    addr = company.get("address")

    fetched = None
    if company_id is not None:
        fetched = company_map.get(str(company_id))
        if not isinstance(fetched, dict):
            fetched = None

    # Prefer nested address object when present
    if not isinstance(addr, dict) and fetched:
        addr = fetched.get("address")

    if isinstance(addr, dict):
        line1 = addr.get("addressLine1")
        line2 = addr.get("addressLine2")
        city = addr.get("city")
        state = addr.get("state")
        zipc = addr.get("zip")
        country = addr.get("country")
        if isinstance(country, dict):
            country = country.get("name") or country.get("identifier") or country.get("description")
        return (line1, line2, city, state, zipc, country)

    # Fallback: flat address fields on the company/company-map objects
    def _get_flat(key):
        v = company.get(key)
        if (v is None or v == "") and fetched:
            v = fetched.get(key)
        return v

    country = _get_flat("country")
    if isinstance(country, dict):
        country = country.get("name") or country.get("identifier") or country.get("description")

    return (
        _get_flat("addressLine1"),
        _get_flat("addressLine2"),
        _get_flat("city"),
        _get_flat("state"),
        _get_flat("zip"),
        country,
    )

rows = []
for c in data:
    company = c.get("company") or {}
    company_rec_id = company.get("id")

    # Resolve company identifier (Company ID) via payload or prefetched map
    company_identifier = None
    if isinstance(company, dict):
        company_identifier = company.get("identifier")
    if (not company_identifier) and company_rec_id is not None:
        fetched = company_map.get(str(company_rec_id))
        if isinstance(fetched, dict):
            company_identifier = fetched.get("identifier")

    # Defensive: drop inactive contacts if requested (API also filters via conditions)
    inactive_flag = c.get("inactiveFlag")
    if exclude_inactive and inactive_flag is True:
        continue

    contact_type_label = extract_contact_type(c)
    company_type_label = extract_company_type(company, company_id=company_rec_id)

    # Exclude contacts with certain type/status labels (e.g., Gone / No Longer With Company)
    if exclude_contact_types and any(lbl in exclude_contact_types for lbl in _split_labels(contact_type_label or "")):
        continue

    # Exclude companies with certain type labels (e.g., Former Client)
    if exclude_company_types and any(lbl in exclude_company_types for lbl in _split_labels(company_type_label or "")):
        continue

    addr1, addr2, city, state, zipc, country = extract_company_address_fields(company, company_id=company_rec_id)

    rows.append({
        "companyName": company.get("name"),
        "companyRecId": company_rec_id,
        "companyId": company_identifier,
        "companyIdentifier": company_identifier,
        "companyType": company_type_label,
        "companyAddressLine1": addr1,
        "companyAddressLine2": addr2,
        "companyCity": city,
        "companyState": state,
        "companyZip": zipc,
        "companyCountry": country,
        "contactRecId": c.get("id"),
        "firstName": c.get("firstName"),
        "lastName": c.get("lastName"),
        "contactType": contact_type_label,
        "contactInactiveFlag": inactive_flag,
        "email": extract_email(c.get("communicationItems")),
    })

with open(out_path, "a", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    if write_header:
        writer.writeheader()
    for r in rows:
        writer.writerow(r)
PY

########################################
# Loop pages and stream to Python
########################################

page=1
while [ "$page" -le "$MAX_PAGES" ]; do
  echo "Fetching page ${page}..."

  # Build URL: contacts, sorted by company name, with selected fields
  # We request:
  # - id, firstName, lastName
  # - company (for name, identifier, type, address)
  # - communicationItems (for email)
  # - type/types (for contactType)
  # - inactiveFlag (for contactInactiveFlag)
  url="${BASE_URL}/company/contacts?fields=id,firstName,lastName,company/id,company/identifier,company/name,company/type,company/type/name,company/types,company/types/name,company/types/identifier,company/types/description,company/address,communicationItems,type,type/name,types,types/name,types/identifier,types/description,inactiveFlag&orderBy=company/name&pageSize=${PAGE_SIZE}&page=${page}"

  # Apply exclusions via conditions
  conditions=""

  # Exclude inactive contacts by default
  if [ "${EXCLUDE_INACTIVE_CONTACTS}" != "0" ]; then
    conditions="inactiveFlag=false"
  fi

  # Exclude company record IDs
  if [ -n "${EXCLUDE_COMPANY_IDS}" ]; then
    IFS=',' read -r -a _exclude_ids <<< "${EXCLUDE_COMPANY_IDS}"
    for _id in "${_exclude_ids[@]}"; do
      # Trim whitespace
      _id="${_id#"${_id%%[![:space:]]*}"}"
      _id="${_id%"${_id##*[![:space:]]}"}"
      [ -z "${_id}" ] && continue
      if [ -n "${conditions}" ]; then
        conditions="${conditions} AND "
      fi
      conditions="${conditions}company/id!=${_id}"
    done
  fi

  if [ -n "${conditions}" ]; then
    # URL-encode spaces in the conditions string
    url="${url}&conditions=${conditions// /%20}"
  fi

  log_debug "Request URL: ${url}"

  # Call API
  response="$(
    curl -sS \
      -H "Authorization: Basic ${AUTH_B64}" \
      -H "clientId: ${CLIENT_ID}" \
      -H "Accept: application/json" \
      "$url"
  )"

  # Optionally dump raw JSON response for this page
  if [ "${DUMP_JSON}" != "0" ] && [ -n "${RAW_JSON_FILE}" ]; then
    if [ "$page" -eq 1 ]; then
      # Start an outer array of page responses
      echo "[" > "${RAW_JSON_FILE}"
      printf '%s' "${response}" >> "${RAW_JSON_FILE}"
    else
      echo "," >> "${RAW_JSON_FILE}"
      printf '%s' "${response}" >> "${RAW_JSON_FILE}"
    fi
  fi

  # Count items in this page using Python quickly
  items_in_page="$(
    printf '%s' "$response" | "$PYTHON" -c 'import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
'
  )"

  log_debug "items_in_page=${items_in_page}"

  # If we got 0 items or some error, stop
  if [ "$items_in_page" -eq 0 ]; then
    log_debug "Stopping because items_in_page is 0 (or response not an array)"
    echo "No contacts on page ${page} (or response not an array). Stopping."
    break
  fi

  if [ "${DEBUG:-0}" != "0" ] && [ "$page" -eq 1 ]; then
    echo "[DEBUG] Sample contact/company from page 1:"
    printf '%s' "$response" | "$PYTHON" -c 'import json,sys,os
try:
    data=json.load(sys.stdin)
except Exception as e:
    print("[DEBUG]  failed to parse response:", e)
    raise SystemExit

if not isinstance(data, list) or not data:
    print("[DEBUG]  response is not a non-empty list")
    raise SystemExit

c=data[0]
comp=c.get("company")
print("[DEBUG]  company field type:", type(comp).__name__)
print("[DEBUG]  company keys:", list(comp.keys()) if isinstance(comp, dict) else comp)
company_id = comp.get("id") if isinstance(comp, dict) else None
print("[DEBUG]  company.id:", company_id)
print("[DEBUG]  company.identifier:", (comp.get("identifier") if isinstance(comp, dict) else None))

# Try lookup in company-map
cm_path=os.environ.get("COMPANY_MAP_FILE")
if cm_path and os.path.exists(cm_path) and company_id is not None:
    try:
        cm=json.load(open(cm_path))
    except Exception as e:
        print("[DEBUG]  failed to load company-map:", e)
        raise SystemExit
    hit = cm.get(str(company_id))
    print("[DEBUG]  company-map hit:", bool(hit))
    if isinstance(hit, dict):
        print("[DEBUG]  company-map.identifier:", hit.get("identifier"))
        print("[DEBUG]  company-map.type:", hit.get("type"))
        print("[DEBUG]  company-map.types:", hit.get("types"))
else:
    print("[DEBUG]  company-map lookup skipped (missing map or company_id)")
'
  fi

  echo "  -> ${items_in_page} contacts on this page"

  # Append this page's data into CSV via Python
  printf '%s' "$response" | "$PYTHON" "${CSV_WRITER_PY}" "${OUTPUT_CSV}"

  # If this page had fewer than PAGE_SIZE results, we've hit the end
  if [ "$items_in_page" -lt "$PAGE_SIZE" ]; then
    log_debug "Stopping because items_in_page (${items_in_page}) < PAGE_SIZE (${PAGE_SIZE})"
    echo "Last page (only ${items_in_page} contacts). Stopping."
    break
  fi

  page=$((page + 1))
done

# Close raw JSON dump array if enabled
if [ "${DUMP_JSON}" != "0" ] && [ -n "${RAW_JSON_FILE}" ]; then
  echo "]" >> "${RAW_JSON_FILE}"
  log_debug "Finished writing raw JSON to: ${RAW_JSON_FILE}"
fi

echo "Done. CSV written to: ${OUTPUT_CSV}"

# Cleanup map cache files by default (leave only the CSV) unless KEEP_MAP_FILES=1
if [ "${PREFETCH_COMPANIES}" != "0" ] && [ "${KEEP_MAP_FILES}" = "0" ]; then
  log_debug "Removing map cache files: ${COMPANY_MAP_FILE}, ${COMPANY_TYPE_MAP_FILE}"
  rm -f "${COMPANY_MAP_FILE}" "${COMPANY_TYPE_MAP_FILE}" || true
fi