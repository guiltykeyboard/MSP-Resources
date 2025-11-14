#!/usr/bin/env bash
#
# test-snmp.sh — Cross‑platform (macOS/Linux) SNMPv2c + TCP check helper for printers/copiers
# Requirements:
#   - Net-SNMP tools: snmpget, snmpgetnext (macOS has them preinstalled; Linux: apt/yum install net-snmp)
#   - nc (netcat) or curl for TCP 443 probe
#
# Features:
#   - Prompts for target IP and community (default: public)
#   - Checks TCP 443 to the target
#   - SNMPv2c reachability test using sysDescr.0 (GET), with GET-NEXT fallbacks (1.3 / 1.3.6 / 1.3.6.1.2.1)
#   - Prints local endpoint IP in CIDR, gateway, and a summary line for ticket notes
#
set -euo pipefail

OS="$(uname -s)"
SYSDESCR_OID="1.3.6.1.2.1.1.1.0"
FALLBACK_START_OIDS=("1.3" "1.3.6" "1.3.6.1.2.1")

color() { # $1=color $2=msg
  local c="$1"; shift
  case "$c" in
    red)    printf "\033[31m%s\033[0m\n" "$*";;
    green)  printf "\033[32m%s\033[0m\n" "$*";;
    yellow) printf "\033[33m%s\033[0m\n" "$*";;
    gray)   printf "\033[90m%s\033[0m\n" "$*";;
    *)      printf "%s\n" "$*";;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
  local missing=()
  for t in snmpget snmpgetnext snmpwalk; do
    have "$t" || missing+=("$t")
  done
  if ((${#missing[@]})); then
    color yellow "Net-SNMP tools missing: ${missing[*]}"
    color yellow "macOS tip: they are usually preinstalled. Linux: sudo apt-get install -y snmp or sudo yum install -y net-snmp-utils"
    exit 1
  fi
}

prompt_input() {
  read -rp "Enter the IP address of the Xerox/device to test: " TARGET
  TARGET=${TARGET//[$'\t\r\n ']}
  if [[ -z "${TARGET:-}" ]]; then
    color red "Target IP is required."; exit 1
  fi
  read -rp "Enter SNMP community string (default = public): " COMMUNITY
  COMMUNITY=${COMMUNITY:-public}
}

# --- Local endpoint, CIDR, gateway (best-effort on macOS & Linux)
get_local_context() {
  LOCAL_IP=""; LOCAL_CIDR=""; GATEWAY=""; IFACE=""
  if [[ "$OS" == "Darwin" ]]; then
    IFACE=$(route -n get "$TARGET" 2>/dev/null | awk '/interface:/{print $2}')
    [[ -n "$IFACE" ]] && LOCAL_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || ifconfig "$IFACE" | awk '/inet /{print $2}' | head -1)
    # netmask (hex like 0xffffff00) -> prefix
    local NM_HEX; NM_HEX=$(ifconfig "$IFACE" 2>/dev/null | awk '/netmask/{print $4}' | head -1)
    if [[ "$NM_HEX" =~ ^0x ]]; then
      local NM_DEC=$((16#${NM_HEX#0x}))
      # count bits
      local p=0 n=$NM_DEC
      for _ in {1..32}; do
        (( (n & 0x80000000) != 0 )) && ((p++))
        n=$(( (n << 1) & 0xFFFFFFFF ))
      done
      [[ -n "$LOCAL_IP" ]] && LOCAL_CIDR="${LOCAL_IP}/${p}"
    fi
    GATEWAY=$(route -n get "$TARGET" 2>/dev/null | awk '/gateway:/{print $2}')
  else
    # Linux
    if have ip; then
      IFACE=$(ip -4 route get "$TARGET" 2>/dev/null | awk '/dev /{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1);break}}')
      LOCAL_IP=$(ip -4 route get "$TARGET" 2>/dev/null | awk '/src /{for(i=1;i<=NF;i++) if ($i=="src"){print $(i+1);break}}')
      # Try to grab prefix from the interface addresses
      if [[ -n "$IFACE" ]]; then
        LOCAL_CIDR=$(ip -o -f inet addr show dev "$IFACE" | awk '/scope global/{print $4; exit}')
      fi
      GATEWAY=$(ip route get "$TARGET" 2>/dev/null | awk '/via /{for(i=1;i<=NF;i++) if ($i=="via"){print $(i+1);break}}')
    fi
  fi
}

# --- TCP probe (port 443)
tcp_443_probe() {
  color yellow "Checking TCP port 443 (HTTPS)..."
  if have nc; then
    if [[ "$OS" == "Darwin" ]]; then
      if nc -z -G 3 "$TARGET" 443 2>/dev/null; then
        color green "[OK] TCP 443 reachable on $TARGET"
        TCP443="PASS"; return 0
      fi
    else
      if nc -z -w 3 "$TARGET" 443 2>/dev/null; then
        color green "[OK] TCP 443 reachable on $TARGET"
        TCP443="PASS"; return 0
      fi
    fi
  fi
  if have curl; then
    if curl -sSkI --connect-timeout 3 "https://$TARGET/" >/dev/null; then
      color green "[OK] TCP 443 reachable on $TARGET"
      TCP443="PASS"; return 0
    fi
  fi
  color red "[FAIL] TCP 443 not reachable on $TARGET"
  TCP443="FAIL"; return 1
}

# --- SNMP probes
snmp_probe() {
  local tmo=2 retries=1
  color yellow "Checking SNMP UDP/161 (sysDescr.0)..."
  if out=$(snmpget -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -Ovq "$TARGET" "$SYSDESCR_OID" 2>/dev/null); then
    color green "[OK] SNMP response from $TARGET"
    echo "sysDescr.0: $out"
    SNMP="PASS"; return 0
  fi
  # fallbacks like iReasoning does
  for start in "${FALLBACK_START_OIDS[@]}"; do
    color gray "[INFO] Trying SNMP GET-NEXT fallback starting at OID $start ..."
    if first=$(snmpgetnext -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -Onq "$TARGET" "$start" 2>/dev/null | head -1); then
      # first like: .1.3.6.1.2.1.1.1.0 = STRING: ...
      local oid="${first%% *=*}"
      local val="${first#*= }"
      if [[ "$oid" == ".1.3.6.1.2.1.1."* ]]; then
        color green "[OK] SNMP responded via GET-NEXT probe (start=$start)."
        [[ "$oid" == ".1.3.6.1.2.1.1.1.0" ]] && echo "sysDescr.0: ${val#*STRING: }"
        SNMP="PASS"; return 0
      else
        color gray "[INFO] SNMP responded to GET-NEXT (start=$start) with $oid, continuing..."
      fi
    else
      color gray "[INFO] No response to GET-NEXT (start=$start); trying next probe..."
    fi
  done
  SNMP="FAIL"
  return 1
}

# --- Detail fetch (sysName, serial, page count, supplies)
snmp_details() {
  color yellow "Quick device info (best-effort)..."
  local tmo=2 retries=1
  
  # OIDs
  local OID_sysName="1.3.6.1.2.1.1.5.0"
  # Printer-MIB: prtGeneralSerialNumber.1
  local OID_serial="1.3.6.1.2.1.43.5.1.1.17.1"
  # Printer-MIB: prtMarkerLifeCount.1.1 (total impressions, many Xerox map this)
  local OID_pages="1.3.6.1.2.1.43.10.2.1.4.1.1"
  
  # sysName
  if name=$(snmpget -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -Ovq "$TARGET" "$OID_sysName" 2>/dev/null); then
    echo "sysName.0 : $name"
  fi
  
  # Serial
  if serial=$(snmpget -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -Ovq "$TARGET" "$OID_serial" 2>/dev/null); then
    echo "Serial   : $serial"
  fi
  
  # Page count
  if pages=$(snmpget -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -Ovq "$TARGET" "$OID_pages" 2>/dev/null); then
    echo "Pages    : $pages"
  else
    # Xerox private (example seen in the field; may vary by model/firmware)
    if xp=$(snmpget -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -Ovq "$TARGET" "1.3.6.1.4.1.253.8.53.13.2.1.6.1.20.1" 2>/dev/null); then
      echo "Pages    : $xp  (Xerox private OID)"
    fi
  fi
  
  # Supplies via Printer-MIB prtMarkerSuppliesTable
  # descr: 1.3.6.1.2.1.43.11.1.1.6.1.X
  # max  : 1.3.6.1.2.1.43.11.1.1.8.1.X
  # level: 1.3.6.1.2.1.43.11.1.1.9.1.X
  echo
  color yellow "Printer-MIB supplies (best-effort)..."
  local walk_base="1.3.6.1.2.1.43.11.1.1"
  # Collect all three tables once
  local descrs maxes levels
  descrs=$(snmpwalk -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -On "$TARGET" "${walk_base}.6.1" 2>/dev/null || true)
  maxes=$(snmpwalk  -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -On "$TARGET" "${walk_base}.8.1" 2>/dev/null || true)
  levels=$(snmpwalk -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -On "$TARGET" "${walk_base}.9.1" 2>/dev/null || true)
  
  # Optional: fetch type (toner/waste/etc) and unit to aid interpretation
  types=$(snmpwalk -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -On "$TARGET" "1.3.6.1.2.1.43.11.1.1.5.1" 2>/dev/null || true)
  units=$(snmpwalk -v2c -c "$COMMUNITY" -t "$tmo" -r "$retries" -On "$TARGET" "1.3.6.1.2.1.43.11.1.1.7.1" 2>/dev/null || true)
  
  # If user wants raw, allow TEST_SNMP_RAW=1 env to print the raw tables
  if [[ "${TEST_SNMP_RAW:-0}" == "1" ]]; then
    echo "--- RAW Printer-MIB prtMarkerSupplies* ---"
    echo "[descr]";  printf "%s\n" "$descrs"
    echo "[type ]";  printf "%s\n" "$types"
    echo "[unit ]";  printf "%s\n" "$units"
    echo "[max  ]";  printf "%s\n" "$maxes"
    echo "[level]";  printf "%s\n" "$levels"
    echo "------------------------------------------"
  fi
  
  if [[ -z "$descrs$maxes$levels" ]]; then
    color gray "[INFO] No supplies entries returned (device may restrict Printer-MIB or use SNMPv3 only)."
    return 0
  fi
  
  # macOS ships Bash 3.2 (no associative arrays). Do a simple join by index using awk/loops.
  # Build pretty table by iterating over the description rows and looking up matching max/level entries.
  printf "%-28s %10s %10s %8s\n" "Supply" "Level" "Max" "Percent"
  printf "%-28s %10s %10s %8s\n" "------" "-----" "---" "-------"
  
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Example line from descrs:
    # .1.3.6.1.2.1.43.11.1.1.6.1.X = STRING: Cyan Toner
    oid="${line%% *=*}"
    idx="${oid##*.}"
    val="${line#*= }"
    desc="${val#STRING: }"
    # strip optional surrounding quotes
    desc="${desc%\"}"; desc="${desc#\"}"
    [[ -z "$desc" ]] && desc="$val"

    # Look up type and unit by same index
    typeRaw=$(printf "%s\n" "$types"  | awk -v i="$idx" -F'= ' '$1 ~ "\\."i"$" {gsub(/^INTEGER: /,"",$2); gsub(/^[ \t]+/,"",$2); print $2; exit}')
    unitRaw=$(printf "%s\n" "$units"  | awk -v i="$idx" -F'= ' '$1 ~ "\\."i"$" {gsub(/^INTEGER: /,"",$2); gsub(/^[ \t]+/,"",$2); print $2; exit}')

    # Find matching max (…8.1.X) and level (…9.1.X) by the same trailing index X
    max=$(printf "%s\n" "$maxes" | awk -v i="$idx" -F'= ' '$1 ~ "\\."i"$" {gsub(/^INTEGER: /,"",$2); gsub(/^[ \t]+/,"",$2); print $2; exit}')
    level=$(printf "%s\n" "$levels" | awk -v i="$idx" -F'= ' '$1 ~ "\\."i"$" {gsub(/^INTEGER: /,"",$2); gsub(/^[ \t]+/,"",$2); print $2; exit}')

    # Treat negative or non-numeric levels as unknown per RFC 3805 (-1/-2/-3)
    if [[ "$level" =~ ^- ]]; then
      level="0"
      max="0"
    fi

    # Defaults / normalization
    [[ -z "$max" ]] && max=0
    [[ -z "$level" ]] && level=0

    pct="NA"
    if [[ "$max" =~ ^[0-9]+$ && "$level" =~ ^-?[0-9]+$ && "$max" -gt 0 && "$level" -ge 0 ]]; then
      pct=$(( (100*level + max/2) / max ))
      [[ $pct -gt 100 ]] && pct=100
    fi

    # Map common types quickly for readability (best-effort)
    case "$typeRaw" in
      3) typeName="toner" ;; 4) typeName="wasteToner" ;; 9) typeName="opc" ;; 10) typeName="developer" ;; 11) typeName="fuserOil" ;; *) typeName="" ;; esac
    case "$unitRaw" in
      8) unitName="percent" ;; 9) unitName="tenthsOfGrams" ;; *) unitName="" ;; esac
    suffix=""
    [[ -n "$typeName$unitName" ]] && suffix=" (${typeName}${unitName:+/$unitName})"
    printf "%-28s %10s %10s %8s%s\n" "$desc" "$level" "$max" "${pct}%" "$suffix"
  done <<< "$descrs"

  # Heuristic: if every printed line had 0/0, let the user know this model reports 'unknown' for levels via v2c
  if ! printf "%s\n" "$levels" | grep -Eq ' = [1-9]'; then
    color gray "[INFO] Device reports unknown (-1/-2/-3) or zero for supplies levels in Printer-MIB. Some Xerox models only expose detailed supplies via private MIBs or SNMPv3."
  fi
}

summary_line() {
  local scope="unknown"
  # best-effort same-subnet check using LOCAL_CIDR prefix if available
  if [[ -n "${LOCAL_CIDR:-}" ]]; then
    local lpfx="${LOCAL_CIDR#*/}"; local lip="${LOCAL_CIDR%/*}"
    # Use Python if available to compute network match; otherwise skip
    if command -v python3 >/dev/null 2>&1; then
      if python3 - "$lip" "$lpfx" "$TARGET" >/dev/null 2>&1 << 'PY'
import ipaddress, sys
lip, pfx, tip = sys.argv[1], int(sys.argv[2]), sys.argv[3]
net = ipaddress.IPv4Network(f"{lip}/{pfx}", strict=False)
print("same" if ipaddress.IPv4Address(tip) in net else "diff")
PY
      then scope="same-subnet"; else scope="different-subnet"; fi
    fi
  fi
  printf "\nSUMMARY: Target=%s | HTTPS(443)=%s | SNMP(161)=%s | From=%s" \
    "$TARGET" "${TCP443:-UNK}" "${SNMP:-UNK}" "${LOCAL_CIDR:-${LOCAL_IP:-?}}"
  [[ -n "$GATEWAY" ]] && printf " via %s" "$GATEWAY"
  [[ -n "$IFACE" ]] && printf " (%s)" "$IFACE"
  [[ "$scope" != "unknown" ]] && printf " | Scope=%s" "$scope"
  printf "\n"
}

main() {
  require_tools
  prompt_input
  get_local_context
  echo "Local endpoint for this test: ${LOCAL_CIDR:-${LOCAL_IP:-?}}"
  [[ -n "$GATEWAY" ]] && echo "Gateway: $GATEWAY${IFACE:+ (Interface: $IFACE)}"
  echo
  echo "=== Connectivity test to $TARGET ==="
  tcp_443_probe || true
  echo
  if snmp_probe; then
    snmp_details
  else
    color red "[FAIL] SNMP (UDP/161) did not respond from this host."
    echo "Action: If SNMP is enabled on the device (check https://$TARGET), confirm any 'SNMP Access Control/Managers' allows this host or subnet."
  fi
  summary_line
  echo -e "\n=== Test complete ==="
}

main "$@"
chmod +x /Users/mstoffel/Repositories/MSP-Resources/Standalone/test-snmp.sh
