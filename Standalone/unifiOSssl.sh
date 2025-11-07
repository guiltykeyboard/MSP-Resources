#!/usr/bin/env bash
# unifiOSssl.sh
# Purpose: Obtain Let's Encrypt cert (acme.sh or Certbot), renew automatically, and
#          import into UniFi OS Server via community importer on each renewal.
#
# Supports:
#  - acme.sh (recommended; has built-in Namecheap DNS support)
#  - Certbot  (fallback)
#
# Notes:
#  - Namecheap DNS (acme.sh): On first successful issuance, acme.sh persists
#    NAMECHEAP_USERNAME / NAMECHEAP_API_KEY / NAMECHEAP_SOURCEIP into
#    /root/.acme.sh/account.conf so renewals run unattended. You can verify with:
#      grep NAMECHEAP /root/.acme.sh/account.conf
#  - UniFi importer: we pull from my fork to avoid upstream changes breaking
#    behavior; adjust IMPORTER_URL below if you move it.
#  - Namecheap env file: this script stores API creds at /root/.secrets/namecheap.env
#    and sources it for acme.sh so renewals remain unattended.
#  - Rotation: run this script with --update-nc-creds to rotate Namecheap API
#    credentials in both the env file and acme.sh account.conf.

set -euo pipefail

# -----------------------------
# Utility
# -----------------------------
need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "[i] Elevating to root with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err()  { echo "[x] $*" >&2; exit 1; }

# Validate FQDN (very basic)
require_fqdn() {
  local d="$1"
  [[ "$d" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || err "Domain must be a valid FQDN (e.g., unifi.example.com)."
}

# Validate apex/root domain (e.g., example.com)
require_apex() {
  local d="$1"
  [[ "$d" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || err "Domain must be a valid base domain (e.g., example.com)."
  [[ "$d" != *"*"* ]] || err "Do not include wildcards here; enter just the base domain (e.g., example.com)."
}

# -----------------------------
# Paths / constants
# -----------------------------
IMPORTER_PATH="/usr/local/bin/unifi-osserver-ssl-import.sh"
DEPLOY_HOOK_CERTBOT="/etc/letsencrypt/renewal-hooks/deploy/unifi-osserver-ssl-import"
CERTBOT_BIN="/usr/bin/certbot"
ACME_SH_BIN="/root/.acme.sh/acme.sh"
IMPORTER_URL="https://raw.githubusercontent.com/guiltykeyboard/UniFi-OS-Server-SSL-Import/refs/heads/main/unifi-osserver-ssl-import"
NAMECHEAP_ENV="/root/.secrets/namecheap.env"
ACCOUNT_CONF="/root/.acme.sh/account.conf"

update_nc_creds() {
  log "Update Namecheap API credentials"
  read -rp "Namecheap USERNAME (login): " NC_USER
  read -rp "Namecheap API KEY: " NC_KEY
  read -rp "Namecheap SOURCE IP (the IP you whitelist in Namecheap API access): " NC_SRCIP
  [[ -n "${NC_USER}" && -n "${NC_KEY}" && -n "${NC_SRCIP}" ]] || err "All Namecheap fields are required."

  # Ensure secrets dir
  mkdir -p "/root/.secrets"
  cat > "${NAMECHEAP_ENV}" <<ENVEOF
NAMECHEAP_USERNAME=${NC_USER}
NAMECHEAP_API_KEY=${NC_KEY}
NAMECHEAP_SOURCEIP=${NC_SRCIP}
ENVEOF
  chmod 600 "${NAMECHEAP_ENV}"

  # Source for current shell
  set -a
  # shellcheck disable=SC1090
  source "${NAMECHEAP_ENV}"
  set +a

  # Update acme.sh account.conf if present (used for unattended renewals)
  if [[ -f "${ACCOUNT_CONF}" ]]; then
    log "Updating ${ACCOUNT_CONF}"
    # Replace or append variables
    grep -q '^NAMECHEAP_USERNAME=' "${ACCOUNT_CONF}" && \
      sed -i -E "s|^NAMECHEAP_USERNAME=.*$|NAMECHEAP_USERNAME=${NC_USER}|" "${ACCOUNT_CONF}" || \
      echo "NAMECHEAP_USERNAME=${NC_USER}" >> "${ACCOUNT_CONF}"

    grep -q '^NAMECHEAP_API_KEY=' "${ACCOUNT_CONF}" && \
      sed -i -E "s|^NAMECHEAP_API_KEY=.*$|NAMECHEAP_API_KEY=${NC_KEY}|" "${ACCOUNT_CONF}" || \
      echo "NAMECHEAP_API_KEY=${NC_KEY}" >> "${ACCOUNT_CONF}"

    grep -q '^NAMECHEAP_SOURCEIP=' "${ACCOUNT_CONF}" && \
      sed -i -E "s|^NAMECHEAP_SOURCEIP=.*$|NAMECHEAP_SOURCEIP=${NC_SRCIP}|" "${ACCOUNT_CONF}" || \
      echo "NAMECHEAP_SOURCEIP=${NC_SRCIP}" >> "${ACCOUNT_CONF}"
  else
    warn "${ACCOUNT_CONF} not found yet. It will be created by acme.sh on first issuance."
  fi

  cat <<EONOTE
[OK] Namecheap credentials updated.
- Env file:        ${NAMECHEAP_ENV}
- acme.sh account: ${ACCOUNT_CONF} (updated if present)

Note: Existing certificates will use the new credentials on their next renewal.
If you rotated keys due to compromise, you can force a renewal now with:
  ${ACME_SH_BIN} --renew --force -d ${FQDN}
EONOTE
}

usage() {
  cat <<USAGE
Usage: sudo ./unifiOSssl.sh [--update-nc-creds]

Options:
  --update-nc-creds   Prompt for Namecheap API creds, update ${NAMECHEAP_ENV}
                      and ${ACCOUNT_CONF}, then exit.
USAGE
}

# Parse optional flag first
if [[ ${1-} == "--help" || ${1-} == "-h" ]]; then
  usage; exit 0
fi
if [[ ${1-} == "--update-nc-creds" ]]; then
  need_root "$@"
  update_nc_creds
  exit 0
fi

# -----------------------------
# Start
# -----------------------------
need_root "$@"

log "This helper will:"
log "  1) Ask for your domain and ACME client (acme.sh or Certbot)"
log "  2) Obtain a Let's Encrypt certificate (http-01 or dns-01)"
log "  3) Install/refresh the UniFi OS SSL importer"
log "  4) Import now and auto-import on future renewals"

# 1) Ask for FQDN
read -rp "Enter the fully-qualified domain name for UniFi (e.g., unifi.example.com): " FQDN
[[ -n "${FQDN}" ]] || err "Domain cannot be empty."
require_fqdn "${FQDN}"

# 2) Choose ACME client
cat <<EOF
Choose ACME client:
  1) acme.sh  (recommended; best for Namecheap DNS)
  2) Certbot  (fallback)
EOF
read -rp "Selection [1/2]: " CLIENT_SEL
case "${CLIENT_SEL}" in
  1|acme|acme.sh) CLIENT="acme" ;;
  2|certbot)      CLIENT="certbot" ;;
  *) err "Invalid selection." ;;
esac

# 3) Choose validation method
cat <<EOF
Choose validation method:
  1) http01  (standalone on port 80)
  2) dns01   (DNS provider API)
EOF
read -rp "Selection [1/2]: " VALIDATION_SEL
case "${VALIDATION_SEL}" in
  1|http|http01) METHOD="http01" ;;
  2|dns|dns01)   METHOD="dns01"  ;;
  *) err "Invalid selection." ;;
esac

# 4) Ensure UniFi importer exists/updated
if [[ ! -x "${IMPORTER_PATH}" ]]; then
  log "Installing UniFi OS SSL importer..."
else
  log "Refreshing UniFi OS SSL importer..."
fi
curl -fsSL "${IMPORTER_URL}" -o "${IMPORTER_PATH}"
chmod +x "${IMPORTER_PATH}"

# Set importer hostname to the FQDN you entered (if the importer exposes UNIFI_HOSTNAME)
if grep -q '^UNIFI_HOSTNAME=' "${IMPORTER_PATH}"; then
  sed -i -E "s|^UNIFI_HOSTNAME=.*$|UNIFI_HOSTNAME=\"${FQDN}\"|" "${IMPORTER_PATH}"
fi

# -----------------------------
# Path A: acme.sh (recommended)
# -----------------------------
if [[ "${CLIENT}" == "acme" ]]; then
  # Install acme.sh if missing
  if [[ ! -x "${ACME_SH_BIN}" ]]; then
    log "Installing acme.sh..."
    curl https://get.acme.sh | sh -s email=admin@"${FQDN#*.}"
    # shellcheck disable=SC1091
    if [[ -f /root/.bashrc ]]; then
      set +u
      source /root/.bashrc || true
      set -u
    fi
  else
    log "acme.sh already installed."
  fi

  if [[ ! -x "${ACME_SH_BIN}" ]]; then
    err "acme.sh not found at ${ACME_SH_BIN}"
  fi

  case "${METHOD}" in
    http01)
      warn "HTTP-01 (standalone): ensure TCP 80 is free during issuance."
      command -v socat >/dev/null 2>&1 || apt-get update -y && apt-get install -y socat
      unset SUDO_GID SUDO_UID SUDO_USER || true
      export HOME=/root
      "${ACME_SH_BIN}" --issue \
        --standalone \
        -d "${FQDN}" \
        --keylength 4096 \
        --reloadcmd "env UNIFI_HOSTNAME=${FQDN} ${IMPORTER_PATH} --provider=acme" || err "acme.sh HTTP-01 issuance failed."
      ;;

    dns01)
      echo
      log "DNS-01 selected. For Namecheap, set API credentials."
      read -rp "Namecheap USERNAME (login): " NC_USER
      read -srp "Namecheap API KEY (input hidden): " NC_KEY; echo
      read -rp "Namecheap SOURCE IP (exact IP you whitelisted in Namecheap): " NC_SRCIP
      [[ -n "${NC_USER}" && -n "${NC_KEY}" && -n "${NC_SRCIP}" ]] || err "All Namecheap fields are required."

      # Persist and source Namecheap credentials for unattended renewals
      mkdir -p "/root/.secrets"
      cat > "${NAMECHEAP_ENV}" <<ENVEOF
NAMECHEAP_USERNAME=${NC_USER}
NAMECHEAP_API_KEY=${NC_KEY}
NAMECHEAP_SOURCEIP=${NC_SRCIP}
ENVEOF
      chmod 600 "${NAMECHEAP_ENV}"
      set -a
      # shellcheck disable=SC1090
      source "${NAMECHEAP_ENV}"
      set +a

      echo
      log "Choose domains for issuance:"
      echo "  1) Single host: ${FQDN}"
      echo "  2) Wildcard + apex: *.base-domain and base-domain (dns-01 only)"
      read -rp "Selection [1/2]: " DNS_DOM_SEL
      case "${DNS_DOM_SEL}" in
        2)
          read -rp "Enter base domain for wildcard (e.g., example.com): " BASE_DOMAIN
          require_apex "${BASE_DOMAIN}"
          DOM_ARGS=( -d "*.${BASE_DOMAIN}" -d "${BASE_DOMAIN}" )
          ISSUED_DOMAINS="*.${BASE_DOMAIN}, ${BASE_DOMAIN}"
          ;;
        *)
          # Single host uses the FQDN provided at the start
          require_fqdn "${FQDN}"
          DOM_ARGS=( -d "${FQDN}" )
          ISSUED_DOMAINS="${FQDN}"
          ;;
      esac

      unset SUDO_GID SUDO_UID SUDO_USER || true
      export HOME=/root
      "${ACME_SH_BIN}" --issue \
        --dns dns_namecheap \
        "${DOM_ARGS[@]}" \
        --keylength 4096 \
        --dnssleep 180 \
        --debug 2 \
        --reloadcmd "env UNIFI_HOSTNAME=${FQDN} ${IMPORTER_PATH} --provider=acme --dns=namecheap" || err "acme.sh DNS-01 issuance failed."

  # If we issued a wildcard (*.BASE_DOMAIN), acme.sh stores files under /root/.acme.sh/*.BASE_DOMAIN
  # Some importer scripts look for /root/.acme.sh/<FQDN>. Create a symlink so both paths work.
  if [[ "${METHOD}" == "dns01" && "${DNS_DOM_SEL-}" == "2" ]]; then
    WILDCARD_DIR="/root/.acme.sh/*.${BASE_DOMAIN}"
    if [[ -d "${WILDCARD_DIR}" ]]; then
      # Always link the chosen FQDN
      if [[ "${FQDN}" != "${BASE_DOMAIN}" ]]; then
        ln -sfn "${WILDCARD_DIR}" "/root/.acme.sh/${FQDN}"
        log "Linked /root/.acme.sh/${FQDN} -> ${WILDCARD_DIR}"
      fi
      # Also link common hostnames that may point here
      for H in "unifi.${BASE_DOMAIN}" "uos.${BASE_DOMAIN}"; do
        if [[ "${H}" != "${FQDN}" ]]; then
          ln -sfn "${WILDCARD_DIR}" "/root/.acme.sh/${H}"
          log "Linked /root/.acme.sh/${H} -> ${WILDCARD_DIR}"
        fi
      done
    fi
  fi
      ;;
  esac

  # Run an immediate import to avoid waiting for the first renew hook
  [[ -n "${ISSUED_DOMAINS-}" ]] && log "Issued domains: ${ISSUED_DOMAINS}"
  log "Importing certificate into UniFi OS Server (acme.sh provider)..."
  if [[ "${METHOD}" == "dns01" ]]; then
    UNIFI_HOSTNAME="${FQDN}" "${IMPORTER_PATH}" --provider=acme --dns=namecheap --verbose || err "Importer failed."
  else
    UNIFI_HOSTNAME="${FQDN}" "${IMPORTER_PATH}" --provider=acme --verbose || err "Importer failed."
  fi

  # acme.sh installs a cron automatically; the --reloadcmd will run on renewals
  CERT_DIR="/root/.acme.sh/${FQDN}"
  RENEW_NOTE="(acme.sh cron handles renewal; importer runs via --reloadcmd)"

# -----------------------------
# Path B: Certbot (fallback)
# -----------------------------
else
  log "Installing Certbot..."
  apt-get update -y
  apt-get install -y certbot

  DNS_AUTH_FLAG=""
  DNS_CREDS_FILE=""
  if [[ "${METHOD}" == "dns01" ]]; then
    echo
    log "DNS-01 selected. Install your DNS plugin (e.g., python3-certbot-dns-cloudflare)."
    read -rp "Enter the apt package name for your DNS plugin: " DNS_PLUGIN_PKG
    [[ -n "${DNS_PLUGIN_PKG}" ]] || err "DNS plugin package cannot be empty."
    apt-get install -y "${DNS_PLUGIN_PKG}"

    read -rp "Enter the exact Certbot authenticator flag (e.g., --dns-cloudflare): " DNS_AUTH_FLAG
    [[ "${DNS_AUTH_FLAG}" =~ ^--dns- ]] || err "Authenticator flag must start with --dns-"

    read -rp "Path to DNS credentials file (or blank if not required): " DNS_CREDS_FILE || true
    if [[ -n "${DNS_CREDS_FILE}" && ! -f "${DNS_CREDS_FILE}" ]]; then
      err "Credentials file not found at ${DNS_CREDS_FILE}"
    fi
  fi

  CERT_DIR="/etc/letsencrypt/live/${FQDN}"
  if [[ -d "${CERT_DIR}" ]]; then
    log "Certificate directory already exists. Attempting renewal..."
  else
    log "No existing certificate found. Requesting a new one..."
  fi

  if [[ "${METHOD}" == "http01" ]]; then
    warn "HTTP-01 uses Certbot standalone. Ensure port 80 is free during issuance."
    "${CERTBOT_BIN}" certonly \
      --non-interactive --agree-tos --email admin@"${FQDN#*.}" \
      --key-type rsa --rsa-key-size 4096 \
      --standalone -d "${FQDN}" || err "Certbot HTTP-01 issuance failed."
  else
    if [[ -n "${DNS_CREDS_FILE}" ]]; then CREDS_OPT=("${DNS_AUTH_FLAG}-credentials" "${DNS_CREDS_FILE}"); else CREDS_OPT=(); fi
    "${CERTBOT_BIN}" certonly \
      --non-interactive --agree-tos --email admin@"${FQDN#*.}" \
      --key-type rsa --rsa-key-size 4096 \
      ${DNS_AUTH_FLAG} "${CREDS_OPT[@]}" -d "${FQDN}" || err "Certbot DNS-01 issuance failed."
  fi

  log "Importing certificate into UniFi OS Server (certbot provider)..."
  UNIFI_HOSTNAME="${FQDN}" "${IMPORTER_PATH}" --provider=certbot --verbose || err "Importer failed."

  # Create Certbot deploy hook for future renewals
  log "Creating Certbot deploy hook at ${DEPLOY_HOOK_CERTBOT} ..."
  mkdir -p "$(dirname "${DEPLOY_HOOK_CERTBOT}")"
  cat > "${DEPLOY_HOOK_CERTBOT}" <<HOOK
#!/usr/bin/env bash
# Trigger UniFi OS SSL import after successful renewal
"${IMPORTER_PATH}" --provider=certbot >> /var/log/unifi-ssl-import.log 2>&1
HOOK
  chmod +x "${DEPLOY_HOOK_CERTBOT}"

  RENEW_NOTE="(Certbot systemd timer handles renewal; deploy hook re-imports)"
fi

# -------------
# Summary
# -------------
cat <<EOT

========================================
Success!
Domain:       ${FQDN}
Client:       ${CLIENT}
Validation:   ${METHOD}
Domains:      ${ISSUED_DOMAINS:-${FQDN}}
Symlink:      ${DNS_DOM_SEL:+$([[ "${DNS_DOM_SEL}" == "2" ]] && echo "/root/.acme.sh/${FQDN} -> /root/.acme.sh/*.${BASE_DOMAIN}" )}
Links made:   ${DNS_DOM_SEL:+$([[ "${DNS_DOM_SEL}" == "2" ]] && echo "${FQDN}, unifi.${BASE_DOMAIN}, uos.${BASE_DOMAIN}")}
Cert path:    ${CERT_DIR}
Importer:     ${IMPORTER_PATH}
Renewals:     ${RENEW_NOTE}

Namecheap creds: stored in /root/.acme.sh/account.conf (persisted by acme.sh)
Env file:        ${NAMECHEAP_ENV}
• Your certificate is installed into UniFi OS Server now.
• Future renewals will re-import automatically.
• Logs: /var/log/unifi-ssl-import.log (importer)

Rotate creds later with: ./unifiOSssl.sh --update-nc-creds

If UniFi still shows the old certificate, allow ~30–60s for services to recycle,
then reload your browser (clear HSTS if needed).
========================================
EOT