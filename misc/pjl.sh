#!/usr/bin/env bash
set -euo pipefail

# Safe-ish single-printer audit
# Usage: ./printer_audit.sh 192.168.1.50

TARGET="${1:-}"
TIMEOUT_SECS=3

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <printer_ip_or_hostname>"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

need_cmd nc
need_cmd timeout

have_nmap=0
if command -v nmap >/dev/null 2>&1; then
  have_nmap=1
fi

have_snmpwalk=0
if command -v snmpwalk >/dev/null 2>&1; then
  have_snmpwalk=1
fi

divider() {
  printf '\n==== %s ====\n' "$1"
}

check_port() {
  local host="$1"
  local port="$2"
  if timeout "$TIMEOUT_SECS" nc -zvw1 "$host" "$port" >/dev/null 2>&1; then
    echo "open"
  else
    echo "closed"
  fi
}

try_http_head() {
  local proto="$1"
  local host="$2"
  local port="$3"

  printf "HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n" "$host" \
    | timeout "$TIMEOUT_SECS" nc "$host" "$port" 2>/dev/null \
    | sed -n '1,10p' || true
}

try_pjl_info_id() {
  local host="$1"
  printf '\033%%-12345X@PJL INFO ID\r\n' \
    | timeout "$TIMEOUT_SECS" nc "$host" 9100 2>/dev/null \
    | strings 2>/dev/null \
    | sed -n '1,20p' || true
}

try_pjl_info_status() {
  local host="$1"
  printf '\033%%-12345X@PJL INFO STATUS\r\n' \
    | timeout "$TIMEOUT_SECS" nc "$host" 9100 2>/dev/null \
    | strings 2>/dev/null \
    | sed -n '1,20p' || true
}

divider "Target"
echo "Host: $TARGET"

divider "Common printer ports"
for port in 80 443 515 631 9100 161; do
  state="$(check_port "$TARGET" "$port")"
  printf "Port %-5s %s\n" "$port" "$state"
done

if [[ "$have_nmap" -eq 1 ]]; then
  divider "nmap quick fingerprint"
  nmap -Pn -sT -sV -p 80,443,515,631,9100 "$TARGET" 2>/dev/null || true
else
  divider "nmap quick fingerprint"
  echo "nmap not installed, skipping"
fi

if [[ "$(check_port "$TARGET" 80)" == "open" ]]; then
  divider "HTTP response sample"
  try_http_head "http" "$TARGET" 80
fi

if [[ "$(check_port "$TARGET" 443)" == "open" ]]; then
  divider "HTTPS port note"
  echo "443 is open. Use a browser or curl -kI https://$TARGET for manual inspection."
fi

if [[ "$(check_port "$TARGET" 9100)" == "open" ]]; then
  divider "PJL INFO ID"
  out="$(try_pjl_info_id "$TARGET")"
  if [[ -n "$out" ]]; then
    echo "$out"
  else
    echo "No PJL INFO ID response received"
  fi

  divider "PJL INFO STATUS"
  out="$(try_pjl_info_status "$TARGET")"
  if [[ -n "$out" ]]; then
    echo "$out"
  else
    echo "No PJL INFO STATUS response received"
  fi
fi

if [[ "$have_snmpwalk" -eq 1 ]] && [[ "$(check_port "$TARGET" 161)" == "open" ]]; then
  divider "SNMP v2c public system info"
  snmpwalk -v2c -c public -t 1 -r 0 "$TARGET" 1.3.6.1.2.1.1 2>/dev/null | sed -n '1,20p' || \
    echo "No response to community 'public'"
else
  divider "SNMP"
  echo "snmpwalk not installed or UDP/161 not confirmed here"
fi

divider "Basic interpretation"
echo "9100 open  = raw printing exposed"
echo "631 open   = IPP exposed"
echo "515 open   = LPD exposed"
echo "80/443 open = web admin likely available"
echo "161 open   = SNMP may expose device metadata"

divider "Next steps"
echo "Review the web UI for auth, TLS, and admin exposure"
echo "Disable raw 9100 if not needed"
echo "Restrict management interfaces to admin VLANs"
echo "Disable SNMP v1/v2c or change default communities"
