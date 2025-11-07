#!/usr/bin/env bash
# unifiOSssl.sh
# Saved update: 2025-11-07T19:45Z (no logic changes; finalized DNS-01 reuse + wildcard symlink fixes)
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

# Create/refresh a symlink but do not fail if src==dest or if it already points correctly
safe_link() {
  local src="$1" dest="$2"
  # Ensure parent dir exists (handles non-symlink parent paths)
  mkdir -p "$(dirname -- "$dest")" 2>/dev/null || true
  # If dest exists and already resolves to src, do nothing
  if [[ -e "$dest" || -L "$dest" ]]; then
    local rsrc rdest
    rsrc="$(readlink -f -- "$src" 2>/dev/null || echo "$src")"
    rdest="$(readlink -f -- "$dest" 2>/dev/null || echo "")"
    if [[ -n "$rdest" && "$rsrc" == "$rdest" ]]; then
      return 0
    fi
  fi
  ln -sfn "$src" "$dest" 2>/dev/null || true
}

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
      log "DNS-01 selected."

      # ---- Ask domain scope first so we can reuse existing certs without prompting for DNS creds ----
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
          CERT_DIR_RUN="/root/.acme.sh/*.${BASE_DOMAIN}"
          ;;
        *)
          require_fqdn "${FQDN}"
          DOM_ARGS=( -d "${FQDN}" )
          ISSUED_DOMAINS="${FQDN}"
          CERT_DIR_RUN="/root/.acme.sh/${FQDN}"
          ;;
      esac

      # If a matching cert already exists, skip provider prompts & issuance. We'll symlink (for wildcard) and import later.
      if [[ -f "${CERT_DIR_RUN}/fullchain.cer" ]]; then
        warn "Existing certificate detected at ${CERT_DIR_RUN}. Skipping DNS provider prompts and issuance."
        # Wildcard compatibility links so importer can find the cert by common hostnames
        if [[ "${DNS_DOM_SEL}" == "2" ]]; then
          WILDCARD_DIR="/root/.acme.sh/*.${BASE_DOMAIN}"
          if [[ -d "${WILDCARD_DIR}" ]]; then
            [[ "${FQDN}" != "${BASE_DOMAIN}" ]] && safe_link "${WILDCARD_DIR}" "/root/.acme.sh/${FQDN}"; log "Linked /root/.acme.sh/${FQDN} -> ${WILDCARD_DIR}"
            for H in "unifi.${BASE_DOMAIN}" "uos.${BASE_DOMAIN}"; do
              [[ "${H}" != "${FQDN}" ]] && safe_link "${WILDCARD_DIR}" "/root/.acme.sh/${H}"; log "Linked /root/.acme.sh/${H} -> ${WILDCARD_DIR}"
            done
          fi
          WILDCARD_LINKS_DONE=1
        fi
      else
        # ---- No existing cert: prompt for DNS provider and perform issuance ----
        echo
        log "DNS-01 selected. Choose your DNS provider:"
        echo "  1) Namecheap"
        echo "  2) Cloudflare"
        echo "  3) GoDaddy"
        echo "  4) AWS Route53"
        echo "  5) Google Cloud DNS"
        echo "  6) DigitalOcean"
        echo "  7) Custom (enter acme.sh provider code, e.g., dns_gd)"
        echo "  8) Help: Open acme.sh DNS provider codes KB (then enter code)"
        echo "  9) Azure DNS"
        echo " 10) Hetzner DNS"
        echo " 11) Porkbun"
        echo " 12) Gandi"
        echo " 13) Linode"
        echo " 14) NameSilo"
        echo " 15) DNSPod (Tencent)"
        echo " 16) OVH"
        echo " 17) Vultr"
        echo " 18) DreamHost"
        echo " 19) Name.com"
        echo " 20) NS1"
        read -rp "Selection [1-20]: " DNS_PROV_SEL
        case "${DNS_PROV_SEL}" in
          1)
            DNS_PROVIDER="namecheap"; DNS_FLAG="dns_namecheap"
            read -rp "Namecheap USERNAME (login): " NC_USER
            read -srp "Namecheap API KEY (input hidden): " NC_KEY; echo
            read -rp "Namecheap SOURCE IP (exact IP you whitelisted in Namecheap): " NC_SRCIP
            [[ -n "${NC_USER}" && -n "${NC_KEY}" && -n "${NC_SRCIP}" ]] || err "All Namecheap fields are required."
            mkdir -p "/root/.secrets"; NAMECHEAP_ENV="/root/.secrets/namecheap.env"
            cat > "${NAMECHEAP_ENV}" <<ENVEOF
NAMECHEAP_USERNAME=${NC_USER}
NAMECHEAP_API_KEY=${NC_KEY}
NAMECHEAP_SOURCEIP=${NC_SRCIP}
ENVEOF
            chmod 600 "${NAMECHEAP_ENV}"; set -a; source "${NAMECHEAP_ENV}"; set +a
            ;;
          2)
            DNS_PROVIDER="cloudflare"; DNS_FLAG="dns_cf"
            CF_ENV="/root/.secrets/cloudflare.env"
            read -srp "Cloudflare API Token (Zones:Read, DNS:Edit) (input hidden): " CF_TOKEN; echo
            read -rp "Cloudflare Account ID (optional; Enter to skip): " CF_ACCOUNT_ID
            mkdir -p "/root/.secrets"
            cat > "${CF_ENV}" <<ENVEOF
CF_Token=${CF_TOKEN}
CF_Account_ID=${CF_ACCOUNT_ID}
ENVEOF
            chmod 600 "${CF_ENV}"; set -a; source "${CF_ENV}"; set +a
            ;;
          3)
            DNS_PROVIDER="godaddy"; DNS_FLAG="dns_gd"
            GD_ENV="/root/.secrets/godaddy.env"
            read -rp "GoDaddy API Key: " GD_Key
            read -srp "GoDaddy API Secret (input hidden): " GD_Secret; echo
            [[ -n "${GD_Key}" && -n "${GD_Secret}" ]] || err "GoDaddy Key and Secret are required."
            mkdir -p "/root/.secrets"
            cat > "${GD_ENV}" <<ENVEOF
GD_Key=${GD_Key}
GD_Secret=${GD_Secret}
ENVEOF
            chmod 600 "${GD_ENV}"; set -a; source "${GD_ENV}"; set +a
            ;;
          4)
            DNS_PROVIDER="route53"; DNS_FLAG="dns_aws"
            AWS_ENV="/root/.secrets/aws-route53.env"
            read -rp "AWS Access Key ID: " AWS_ACCESS_KEY_ID
            read -srp "AWS Secret Access Key (input hidden): " AWS_SECRET_ACCESS_KEY; echo
            read -rp "AWS Region (optional, e.g., us-east-1; Enter to skip): " AWS_REGION
            [[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" ]] || err "AWS credentials are required."
            mkdir -p "/root/.secrets"
            cat > "${AWS_ENV}" <<ENVEOF
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_REGION=${AWS_REGION}
ENVEOF
            chmod 600 "${AWS_ENV}"; set -a; source "${AWS_ENV}"; set +a
            ;;
          5)
            DNS_PROVIDER="gcloud"; DNS_FLAG="dns_gcloud"
            GC_ENV="/root/.secrets/gcloud.env"
            read -rp "Path to Google service-account JSON (will be referenced): " GC_JSON
            [[ -f "${GC_JSON}" ]] || err "Service-account JSON not found at ${GC_JSON}"
            mkdir -p "/root/.secrets"
            cat > "${GC_ENV}" <<ENVEOF
GOOGLE_APPLICATION_CREDENTIALS=${GC_JSON}
ENVEOF
            chmod 600 "${GC_ENV}"; set -a; source "${GC_ENV}"; set +a
            ;;
          6)
            DNS_PROVIDER="digitalocean"; DNS_FLAG="dns_dgon"
            DO_ENV="/root/.secrets/digitalocean.env"
            read -srp "DigitalOcean API Token (input hidden): " DO_API_TOKEN; echo
            [[ -n "${DO_API_TOKEN}" ]] || err "DigitalOcean API token is required."
            mkdir -p "/root/.secrets"
            cat > "${DO_ENV}" <<ENVEOF
DO_API_TOKEN=${DO_API_TOKEN}
ENVEOF
            chmod 600 "${DO_ENV}"; set -a; source "${DO_ENV}"; set +a
            ;;
          7)
            read -rp "Enter full acme.sh DNS provider code (e.g., dns_gd, dns_ali, dns_azure): " DNS_FLAG
            [[ "${DNS_FLAG}" =~ ^dns_ ]] || err "Provider code must start with 'dns_'."
            DNS_PROVIDER="${DNS_FLAG#dns_}"
            read -rp "Path to env file to source for this provider (leave blank to skip): " CUSTOM_ENV
            if [[ -n "${CUSTOM_ENV}" ]]; then
              [[ -f "${CUSTOM_ENV}" ]] || err "Env file not found at ${CUSTOM_ENV}"
              set -a; source "${CUSTOM_ENV}"; set +a
            fi
            ;;
          8)
            echo "\nProvider codes reference: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
            echo "(Open the URL to find your provider's code and required env vars.)"
            read -rp "Enter provider code from the KB (e.g., dns_hetzner, dns_azure, dns_linode): " DNS_FLAG
            [[ "${DNS_FLAG}" =~ ^dns_ ]] || err "Provider code must start with 'dns_'."
            DNS_PROVIDER="${DNS_FLAG#dns_}"
            read -rp "Path to env file to source for this provider (leave blank to skip): " CUSTOM_ENV
            if [[ -n "${CUSTOM_ENV}" ]]; then
              [[ -f "${CUSTOM_ENV}" ]] || err "Env file not found at ${CUSTOM_ENV}"
              set -a; source "${CUSTOM_ENV}"; set +a
            fi
            ;;
          9)
            DNS_PROVIDER="azure"; DNS_FLAG="dns_azure"
            AZ_ENV="/root/.secrets/azure.env"
            read -rp "Azure Tenant ID: " AZUREDNS_TENANTID
            read -rp "Azure App (Client) ID: " AZUREDNS_APPID
            read -srp "Azure Client Secret (input hidden): " AZUREDNS_CLIENTSECRET; echo
            read -rp "Azure Subscription ID: " AZUREDNS_SUBSCRIPTIONID
            read -rp "Azure Resource Group (DNS zone RG): " AZUREDNS_RESOURCE_GROUP
            mkdir -p "/root/.secrets"
            cat > "${AZ_ENV}" <<ENVEOF
AZUREDNS_TENANTID=${AZUREDNS_TENANTID}
AZUREDNS_APPID=${AZUREDNS_APPID}
AZUREDNS_CLIENTSECRET=${AZUREDNS_CLIENTSECRET}
AZUREDNS_SUBSCRIPTIONID=${AZUREDNS_SUBSCRIPTIONID}
AZUREDNS_RESOURCE_GROUP=${AZUREDNS_RESOURCE_GROUP}
ENVEOF
            chmod 600 "${AZ_ENV}"; set -a; source "${AZ_ENV}"; set +a
            ;;
          10)
            DNS_PROVIDER="hetzner"; DNS_FLAG="dns_hetzner"
            HZ_ENV="/root/.secrets/hetzner.env"
            read -srp "Hetzner API Token (input hidden): " HETZNER_Token; echo
            mkdir -p "/root/.secrets"; cat > "${HZ_ENV}" <<ENVEOF
HETZNER_Token=${HETZNER_Token}
ENVEOF
            chmod 600 "${HZ_ENV}"; set -a; source "${HZ_ENV}"; set +a
            ;;
          11)
            DNS_PROVIDER="porkbun"; DNS_FLAG="dns_porkbun"
            PB_ENV="/root/.secrets/porkbun.env"
            read -rp "Porkbun API Key: " PORKBUN_API_KEY
            read -srp "Porkbun Secret Key (input hidden): " PORKBUN_SECRET_API_KEY; echo
            mkdir -p "/root/.secrets"; cat > "${PB_ENV}" <<ENVEOF
PORKBUN_API_KEY=${PORKBUN_API_KEY}
PORKBUN_SECRET_API_KEY=${PORKBUN_SECRET_API_KEY}
ENVEOF
            chmod 600 "${PB_ENV}"; set -a; source "${PB_ENV}"; set +a
            ;;
          12)
            DNS_PROVIDER="gandi"; DNS_FLAG="dns_gandi"
            GA_ENV="/root/.secrets/gandi.env"
            read -srp "Gandi Live API Key (input hidden): " GANDI_LIVE_API_KEY; echo
            mkdir -p "/root/.secrets"; cat > "${GA_ENV}" <<ENVEOF
GANDI_LIVE_API_KEY=${GANDI_LIVE_API_KEY}
ENVEOF
            chmod 600 "${GA_ENV}"; set -a; source "${GA_ENV}"; set +a
            ;;
          13)
            DNS_PROVIDER="linode"; DNS_FLAG="dns_linode"
            LI_ENV="/root/.secrets/linode.env"
            read -srp "Linode Personal Access Token (input hidden): " LINODE_V4_API_KEY; echo
            mkdir -p "/root/.secrets"; cat > "${LI_ENV}" <<ENVEOF
LINODE_V4_API_KEY=${LINODE_V4_API_KEY}
ENVEOF
            chmod 600 "${LI_ENV}"; set -a; source "${LI_ENV}"; set +a
            ;;
          14)
            DNS_PROVIDER="namesilo"; DNS_FLAG="dns_namesilo"
            NSL_ENV="/root/.secrets/namesilo.env"
            read -srp "NameSilo API Key (input hidden): " Namesilo_Key; echo
            mkdir -p "/root/.secrets"; cat > "${NSL_ENV}" <<ENVEOF
Namesilo_Key=${Namesilo_Key}
ENVEOF
            chmod 600 "${NSL_ENV}"; set -a; source "${NSL_ENV}"; set +a
            ;;
          15)
            DNS_PROVIDER="dnspod"; DNS_FLAG="dns_dp"
            DP_ENV="/root/.secrets/dnspod.env"
            read -rp "DNSPod (Tencent) ID: " DP_Id
            read -srp "DNSPod (Tencent) Key (input hidden): " DP_Key; echo
            mkdir -p "/root/.secrets"; cat > "${DP_ENV}" <<ENVEOF
DP_Id=${DP_Id}
DP_Key=${DP_Key}
ENVEOF
            chmod 600 "${DP_ENV}"; set -a; source "${DP_ENV}"; set +a
            ;;
          16)
            DNS_PROVIDER="ovh"; DNS_FLAG="dns_ovh"
            OVH_ENV="/root/.secrets/ovh.env"
            read -rp "OVH Application Key (AK): " OVH_AK
            read -srp "OVH Application Secret (AS) (input hidden): " OVH_AS; echo
            read -rp "OVH Consumer Key (CK): " OVH_CK
            read -rp "OVH Endpoint (optional, e.g., ovh-eu; Enter to skip): " OVH_END_POINT
            mkdir -p "/root/.secrets"; cat > "${OVH_ENV}" <<ENVEOF
OVH_AK=${OVH_AK}
OVH_AS=${OVH_AS}
OVH_CK=${OVH_CK}
OVH_END_POINT=${OVH_END_POINT}
ENVEOF
            chmod 600 "${OVH_ENV}"; set -a; source "${OVH_ENV}"; set +a
            ;;
          17)
            DNS_PROVIDER="vultr"; DNS_FLAG="dns_vultr"
            VU_ENV="/root/.secrets/vultr.env"
            read -srp "Vultr API Key (input hidden): " VULTR_API_KEY; echo
            mkdir -p "/root/.secrets"; cat > "${VU_ENV}" <<ENVEOF
VULTR_API_KEY=${VULTR_API_KEY}
ENVEOF
            chmod 600 "${VU_ENV}"; set -a; source "${VU_ENV}"; set +a
            ;;
          18)
            DNS_PROVIDER="dreamhost"; DNS_FLAG="dns_dreamhost"
            DH_ENV="/root/.secrets/dreamhost.env"
            read -srp "DreamHost API Key (input hidden): " DH_API_KEY; echo
            mkdir -p "/root/.secrets"; cat > "${DH_ENV}" <<ENVEOF
DH_API_KEY=${DH_API_KEY}
ENVEOF
            chmod 600 "${DH_ENV}"; set -a; source "${DH_ENV}"; set +a
            ;;
          19)
            DNS_PROVIDER="namecom"; DNS_FLAG="dns_namecom"
            NMC_ENV="/root/.secrets/namecom.env"
            read -rp "Name.com Username: " Namecom_Username
            read -srp "Name.com API Token (input hidden): " Namecom_Token; echo
            mkdir -p "/root/.secrets"; cat > "${NMC_ENV}" <<ENVEOF
Namecom_Username=${Namecom_Username}
Namecom_Token=${Namecom_Token}
ENVEOF
            chmod 600 "${NMC_ENV}"; set -a; source "${NMC_ENV}"; set +a
            ;;
          20)
            DNS_PROVIDER="nsone"; DNS_FLAG="dns_nsone"
            NS1_ENV="/root/.secrets/ns1.env"
            read -srp "NS1 API Key (input hidden): " NS1_Key; echo
            mkdir -p "/root/.secrets"; cat > "${NS1_ENV}" <<ENVEOF
NS1_Key=${NS1_Key}
ENVEOF
            chmod 600 "${NS1_ENV}"; set -a; source "${NS1_ENV}"; set +a
            ;;
          *) err "Invalid DNS provider selection." ;;
        esac

        unset SUDO_GID SUDO_UID SUDO_USER || true
        export HOME=/root
        set +e
        "${ACME_SH_BIN}" --issue \
          --dns ${DNS_FLAG} \
          "${DOM_ARGS[@]}" \
          --keylength 4096 \
          --dnssleep 180 \
          --debug 2 \
          --reloadcmd "env UNIFI_HOSTNAME=${FQDN} ${IMPORTER_PATH} --provider=acme ${DNS_PROVIDER:+--dns=${DNS_PROVIDER}}"
        RC=$?
        set -e
        if [[ $RC -ne 0 ]]; then
          if [[ -f "${CERT_DIR_RUN}/fullchain.cer" ]]; then
            warn "acme.sh returned non-zero, but an existing cert was found at ${CERT_DIR_RUN}. Proceeding with import."
          else
            err "acme.sh DNS-01 issuance failed."
          fi
        fi
      fi

      # Common wildcard symlink step (safe to run even if links already exist)
      if [[ "${DNS_DOM_SEL-}" == "2" && -z "${WILDCARD_LINKS_DONE-}" ]]; then
        WILDCARD_DOM="*.${BASE_DOMAIN}"
        WILDCARD_DIR="/root/.acme.sh/${WILDCARD_DOM}"
        if [[ -d "${WILDCARD_DIR}" ]]; then
          set +e
          # Ensure directory links for common hostnames
          for H in "${FQDN}" "unifi.${BASE_DOMAIN}" "uos.${BASE_DOMAIN}"; do
            if [[ "${H}" != "${BASE_DOMAIN}" ]]; then
              safe_link "${WILDCARD_DIR}" "/root/.acme.sh/${H}"
              log "Linked /root/.acme.sh/${H} -> ${WILDCARD_DIR}"

              # Resolve source files from the wildcard directory (avoid quoting the glob so it expands)
              KEY_SRC=$(ls -1 ${WILDCARD_DIR}/*.${BASE_DOMAIN}.key 2>/dev/null | head -n1)
              CER_SRC=$(ls -1 ${WILDCARD_DIR}/*.${BASE_DOMAIN}.cer 2>/dev/null | head -n1)
              CHAIN_SRC="${WILDCARD_DIR}/fullchain.cer"

              if [[ -n "${KEY_SRC}" && -f "${KEY_SRC}" ]]; then
                safe_link "${KEY_SRC}" "/root/.acme.sh/${H}/private.key"
                safe_link "${KEY_SRC}" "/root/.acme.sh/${H}/${H}.key"
                log "Linked key files for ${H}"
              else
                warn "Wildcard key not found in ${WILDCARD_DIR} (*.${BASE_DOMAIN}.key)"
              fi

              if [[ -f "${CHAIN_SRC}" ]]; then
                safe_link "${CHAIN_SRC}" "/root/.acme.sh/${H}/fullchain.cer"
                log "Linked fullchain for ${H}"
              else
                warn "Expected chain not found: ${CHAIN_SRC}"
              fi

              if [[ -n "${CER_SRC}" && -f "${CER_SRC}" ]]; then
                safe_link "${CER_SRC}" "/root/.acme.sh/${H}/${H}.cer"
                log "Linked leaf cert for ${H}"
              fi
            fi
          done
          set -e
        else
          warn "Wildcard directory not found at ${WILDCARD_DIR}"
        fi
      fi
      ;;
  esac

  # Run an immediate import to avoid waiting for the first renew hook
  [[ -n "${ISSUED_DOMAINS-}" ]] && log "Issued domains: ${ISSUED_DOMAINS}"
  log "Importing certificate into UniFi OS Server (acme.sh provider)..."
  if [[ "${METHOD}" == "dns01" ]]; then
    if [[ -n "${DNS_PROVIDER-}" ]]; then DNS_ARG=(--dns="${DNS_PROVIDER}"); else DNS_ARG=(); fi
    UNIFI_HOSTNAME="${FQDN}" "${IMPORTER_PATH}" --provider=acme "${DNS_ARG[@]}" --verbose || err "Importer failed."
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
DNS Provider: ${DNS_PROVIDER:-n/a}
Cert dir used: ${CERT_DIR_RUN:-${CERT_DIR}}
Symlink:      ${DNS_DOM_SEL:+$([[ "${DNS_DOM_SEL}" == "2" ]] && echo "/root/.acme.sh/${FQDN} -> /root/.acme.sh/*.${BASE_DOMAIN}" )}
Links made:   ${DNS_DOM_SEL:+$([[ "${DNS_DOM_SEL}" == "2" ]] && echo "${FQDN}, unifi.${BASE_DOMAIN}, uos.${BASE_DOMAIN}")}
Cert path:    ${CERT_DIR}
Importer:     ${IMPORTER_PATH}
Renewals:     ${RENEW_NOTE}
Notes:        $([[ -n "${WILDCARD_LINKS_DONE-}" ]] && echo "Existing cert detected; DNS prompts and issuance skipped.")

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