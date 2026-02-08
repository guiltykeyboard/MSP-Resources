# Atomic8Ball PSA API Scripting

<!-- Badges -->
![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)&nbsp;&nbsp;![Python](https://img.shields.io/badge/Python-3.9+-3776AB?logo=python&logoColor=white)&nbsp;&nbsp;![Platform-macOS](https://img.shields.io/badge/Platform-macOS-000000?logo=apple&logoColor=white)&nbsp;&nbsp;![Platform-Linux](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black)&nbsp;&nbsp;![ConnectWise-PSA](https://img.shields.io/badge/ConnectWise-PSA-1A6DBB)&nbsp;&nbsp;![Repository](https://img.shields.io/badge/Repository-Internal-6E6E6E)&nbsp;&nbsp;![Version](https://img.shields.io/badge/Version-0.1.0-blue)&nbsp;&nbsp;![Commit Activity](https://img.shields.io/badge/Commit_Activity-Internal-grey)&nbsp;&nbsp;![Contributors](https://img.shields.io/badge/Contributors-iTech_&_Atomic8Ball-orange)&nbsp;&nbsp;![Code Size](badges/code-size.svg)

This repo has scripts for allowing Atomic 8 to interact with iTech's ConnectWise PSA

## Synopsis

Exports all ConnectWise PSA contacts to CSV via `psa-contacts-to-csv.sh`. Documentation is pending expansion for the broader PSA script set.

## Contact Export Script

This repository includes a Bash/Python hybrid script that exports all ConnectWise PSA contacts into a CSV file.  
The script supports pagination, email extraction, contact type, inactive flag, company type, and full company address broken into separate fields.

### Requirements

- macOS or Linux
- `bash`
- `python3`
- `curl`
- A ConnectWise **API Member** (public/private key pair)
- A ConnectWise **Client ID** (generated from the CW Developer Portal)

### Script File

The main script is:

```sh
psa-contacts-to-csv.sh
```

This script retrieves all contacts from the `/company/contacts` API endpoint and writes them to `contacts.csv` by default.

### Environment Variables

Before running the script, you must set the following environment variables:

| Variable | Description |
| -------- | ----------- |
| `BASE_URL` | The full ConnectWise Manage API URL (e.g., `https://api-na.myconnectwise.net/v4_6_release/apis/3.0`) |
| `COMPANY_ID` | Your ConnectWise login company ID |
| `PUBLIC_KEY` | CW API member public key |
| `PRIVATE_KEY` | CW API member private key |
| `CLIENT_ID` | Your ConnectWise Client ID GUID (required by CW APIs) |
| `OUTPUT_DIR` | *(Optional)* Directory where the CSV will be written (default: current directory `"."`) |
| `OUTPUT_FILENAME` | *(Optional)* Filename of the CSV (default: `contacts.csv`) |
| `PAGE_SIZE` | *(Optional)* Page size (default: `1000`, max CW allows) |
| `MAX_PAGES` | *(Optional)* Maximum number of pages to loop through (default: `10`) |
| `EXCLUDE_COMPANY_IDS` | *(Optional)* Comma-separated list of company record IDs to exclude from export (default: `19298`) |
| `KEEP_MAP_FILES` | *(Optional)* Set to `1` to keep `company-map.json` and `company-type-map.json` after the export completes (default: `0`, maps are removed) |

### Example of Setting Variables (macOS/Linux)

```bash
export BASE_URL="https://api-na.myconnectwise.net/v4_6_release/apis/3.0"
export COMPANY_ID="itechwv"
export PUBLIC_KEY="your_public_key_here"
export PRIVATE_KEY="your_private_key_here"
export CLIENT_ID="your_client_id_guid_here"
export OUTPUT_DIR="."
export OUTPUT_FILENAME="contacts.csv"
```

### Running the Script

> ⚠️ **Do NOT run this script with `sudo`**
>
> This script relies on environment variables for authentication.
> Running with `sudo` will discard those variables unless explicitly preserved,
> which will cause errors such as:
>
> ```text
> COMPANY_ID: Set COMPANY_ID environment variable
> ```
>
> Always run the script as your normal user:
>
> ```bash
> ./psa-contacts-to-csv.sh
> ```

```bash
chmod +x psa-contacts-to-csv.sh
./psa-contacts-to-csv.sh
```

#### Help / Usage

To view all supported options and environment variables:

```bash
./psa-contacts-to-csv.sh --help
```

After completion, the CSV file will contain the following fields:

- companyName  
- companyType  
- companyAddressLine1  
- companyAddressLine2  
- companyCity  
- companyState  
- companyZip  
- companyCountry  
- firstName  
- lastName  
- contactType  
- contactInactiveFlag  
- email  

### Additional Features

#### Output Directory & Filename

The script now supports setting both an output directory and filename:

- `OUTPUT_DIR` — directory where the CSV will be saved (default: `"."`)  
- `OUTPUT_FILENAME` — filename only (default: `contacts.csv`)  

These are combined at runtime into the full output path:

```bash
OUTPUT_CSV="${OUTPUT_DIR%/}/${OUTPUT_FILENAME}"
```

If the directory does not exist, the script will automatically create it.

#### Debug Mode

You can enable verbose logging by setting:

```bash
DEBUG=1 ./psa-contacts-to-csv.sh
```

This prints detailed internal state such as request URLs, pagination details, and configuration values.

#### Raw JSON Dump (`-dump-json`)

To capture the **raw API responses**, you may run:

```bash
./psa-contacts-to-csv.sh -dump-json
```

This will create a timestamped JSON file in the same output directory as the CSV:

```text
raw-json-YYYYMMDD-HHMMSS.json
```

The file includes **all pages of contacts**, stored as an array of page responses.  
This is useful for debugging, auditing, or building additional tooling.

#### Company Exclusion (`EXCLUDE_COMPANY_IDS`)

Contacts belonging to specific companies can be excluded from the export using company **record IDs**.

By default, the script excludes the internal **Catchall** company:

- Company Name: Catchall
- Company Record ID: `19298`

You can exclude additional companies by setting a comma-separated list of IDs:

```bash
EXCLUDE_COMPANY_IDS="19298,12345,67890" ./psa-contacts-to-csv.sh
```

To disable exclusions entirely:

```bash
EXCLUDE_COMPANY_IDS="" ./psa-contacts-to-csv.sh
```

Exclusions are applied using the ConnectWise API `conditions` query parameter (for example, `conditions=company/id!=19298`).

#### Map Cache Cleanup (`KEEP_MAP_FILES`)

For performance, the script may prefetch company and company type data into temporary JSON map files:

- `company-map.json`
- `company-type-map.json`

By default, these map files are **removed automatically** after a successful export so that only `contacts.csv` remains.

To keep the map files (useful for debugging or auditing), set:

```bash
KEEP_MAP_FILES=1 ./psa-contacts-to-csv.sh
```

### Notes

- The script uses a ConnectWise **API Member** (public/private key pair) and a **Client ID**; ensure the API Member’s security role has permission to read contacts, companies, and company types.
- If `contactType` is blank for all rows, confirm your tenant uses contact `types` and that the script is requesting `types/name` (run with `DEBUG=1` to inspect the first contact payload).
- If you change fields or extraction logic, delete any cached map files (or run without `KEEP_MAP_FILES=1`) so the export is regenerated from fresh data.
