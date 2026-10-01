#!/usr/bin/env bash
#
# unifi-vultr-firewall-group.sh
#
# Creates a new Vultr Cloud Firewall group with all required ports for a
# UniFi OS / UniFi Network Server, plus SSH, and optionally attaches it
# to an instance.
#
# Security model:
#   - ADMIN ports (SSH 22, web UI 443/8443) can be locked to a management
#     CIDR (your home/office IP) via -m. Strongly recommended.
#   - DEVICE ports (inform 8080, STUN 3478, portal, speedtest) default to
#     0.0.0.0/0 so remote-site devices can reach the controller, but can
#     be locked to a site CIDR via -d.
#
# Requirements:
#   - vultr-cli v3.x (https://github.com/vultr/vultr-cli)
#   - VULTR_API_KEY exported in your environment
#
# Usage:
#   export VULTR_API_KEY="your-api-key"
#   ./unifi-vultr-firewall-group.sh                          # everything open (warns)
#   ./unifi-vultr-firewall-group.sh -m 203.0.113.45/32       # lock admin ports to your IP
#   ./unifi-vultr-firewall-group.sh -m 203.0.113.45/32 -d 198.51.100.0/24 \
#       -a <INSTANCE_ID>                                     # + lock device ports, attach
#
# Options:
#   -m CIDR   Management CIDR for SSH + web UI (default 0.0.0.0/0 - open!)
#   -d CIDR   Device CIDR for inform/STUN/portal ports (default 0.0.0.0/0)
#   -a ID     Instance ID to attach the new firewall group to
#   -g NAME   Firewall group description (default "unifi-os-server")
#   -G ID     Reuse an EXISTING firewall group ID instead of creating one
#   -o        Include optional ports (10001, 1900, 5514 UDP)
#   -6        Also create equivalent IPv6 rules
#   -M CIDR   IPv6 management CIDR for SSH + web UI (default ::/0 - open!)
#   -D CIDR   IPv6 device CIDR for inform/STUN/portal (default ::/0)
#   -O        IPv6 rules ONLY - skip v4 (use with -G to add v6 to an
#             existing group without duplicate-rule errors)
#   -n        Dry run - print commands without executing
#
set -euo pipefail

MGMT_CIDR="0.0.0.0/0"
DEVICE_CIDR="0.0.0.0/0"
MGMT6_CIDR="::/0"
DEVICE6_CIDR="::/0"
INSTANCE_ID=""
GROUP_DESC="unifi-os-server"
EXISTING_FWG_ID=""
INCLUDE_OPTIONAL=false
INCLUDE_V6=false
V6_ONLY=false
DRY_RUN=false

while getopts "m:d:M:D:a:g:G:o6Onh" opt; do
  case "$opt" in
    m) MGMT_CIDR="$OPTARG" ;;
    d) DEVICE_CIDR="$OPTARG" ;;
    M) MGMT6_CIDR="$OPTARG" ;;
    D) DEVICE6_CIDR="$OPTARG" ;;
    a) INSTANCE_ID="$OPTARG" ;;
    g) GROUP_DESC="$OPTARG" ;;
    G) EXISTING_FWG_ID="$OPTARG" ;;
    o) INCLUDE_OPTIONAL=true ;;
    6) INCLUDE_V6=true ;;
    O) V6_ONLY=true; INCLUDE_V6=true ;;
    n) DRY_RUN=true ;;
    h) grep '^#' "$0" | head -40; exit 0 ;;
    *) echo "Unknown option"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v vultr-cli >/dev/null 2>&1 || {
  echo "ERROR: vultr-cli not found. Install: https://github.com/vultr/vultr-cli"
  exit 1
}
[[ -n "${VULTR_API_KEY:-}" ]] || {
  echo 'ERROR: VULTR_API_KEY not set. Run: export VULTR_API_KEY="your-key"'
  exit 1
}

if [[ "$MGMT_CIDR" == "0.0.0.0/0" ]] && ! $V6_ONLY; then
  echo "WARNING: no -m management CIDR given. SSH and the UniFi web UI"
  echo "         will be open to the ENTIRE internet. Consider:"
  echo "         ./$(basename "$0") -m \$(curl -s ifconfig.me)/32"
  echo
fi

if $INCLUDE_V6 && [[ "$MGMT6_CIDR" == "::/0" ]]; then
  echo "WARNING: no -M IPv6 management CIDR given. SSH and the UniFi web UI"
  echo "         will be open to the entire IPv6 internet. Consider:"
  echo "         -M <your-v6-prefix>/64  (or /128 for a single address)"
  echo
fi

# split "addr/nn" -> subnet + size (vultr-cli wants them separately)
# works for v4 and v6; bare addresses get /32 (v4) or /128 (v6)
split_cidr() {
  local cidr="$1"
  SUBNET="${cidr%/*}"
  SIZE="${cidr#*/}"
  if [[ "$SUBNET" == "$SIZE" ]]; then
    if [[ "$SUBNET" == *:* ]]; then SIZE=128; else SIZE=32; fi
  fi
}

run() {
  if $DRY_RUN; then
    echo "-- DRY   $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Rule definitions:  protocol|port|scope|notes
#   scope: MGMT   -> restricted to $MGMT_CIDR
#          DEVICE -> restricted to $DEVICE_CIDR
# ---------------------------------------------------------------------------
RULES=(
  "tcp|22|MGMT|SSH server administration"
  "tcp|11443|MGMT|UniFi OS Server web UI"
  "tcp|443|MGMT|UniFi OS web UI"
  "tcp|8443|MGMT|UniFi Network app GUI-API"
  "tcp|8080|DEVICE|Device inform (adoption-management)"
  "udp|3478|DEVICE|STUN"
  "tcp|8880|DEVICE|Guest portal HTTP"
  "tcp|8843|DEVICE|Guest portal HTTPS"
  "tcp|6789|DEVICE|UniFi mobile speedtest"
)

OPTIONAL_RULES=(
  "udp|10001|DEVICE|Device discovery"
  "udp|1900|DEVICE|Make application discoverable (L2)"
  "udp|5514|DEVICE|Remote syslog"
)

$INCLUDE_OPTIONAL && RULES+=("${OPTIONAL_RULES[@]}")
# NOTE: TCP 27117 (MongoDB) intentionally excluded - local only, never expose.

# ---------------------------------------------------------------------------
# 1. Create the firewall group (or reuse an existing one via -G)
# ---------------------------------------------------------------------------
if [[ -n "$EXISTING_FWG_ID" ]]; then
  FWG_ID="$EXISTING_FWG_ID"
  echo "==> Using existing firewall group: $FWG_ID"
else
echo "==> Creating firewall group: $GROUP_DESC"
if $DRY_RUN; then
  echo "-- DRY   vultr-cli firewall group create --description \"$GROUP_DESC\""
  FWG_ID="DRY-RUN-GROUP-ID"
else
  CREATE_OUT="$(vultr-cli firewall group create --description "$GROUP_DESC")"
  echo "$CREATE_OUT"
  # Grab the UUID from the output (first UUID-looking token)
  FWG_ID="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<< "$CREATE_OUT" | head -1)"
  [[ -n "$FWG_ID" ]] || { echo "ERROR: could not parse firewall group ID."; exit 1; }
fi
fi
echo "==> Firewall group ID: $FWG_ID"
echo

# ---------------------------------------------------------------------------
# 2. Create the rules
# ---------------------------------------------------------------------------
for rule in "${RULES[@]}"; do
  IFS='|' read -r PROTO PORT SCOPE NOTES <<< "$rule"

  # ----- IPv4 rule -----
  if ! $V6_ONLY; then
    case "$SCOPE" in
      MGMT)   CIDR="$MGMT_CIDR" ;;
      DEVICE) CIDR="$DEVICE_CIDR" ;;
    esac
    split_cidr "$CIDR"

    echo "-- RULE  ${PROTO}/${PORT}  from ${SUBNET}/${SIZE}  (${NOTES})"
    run vultr-cli firewall rule create "$FWG_ID" \
        --ip-type=v4 \
        --protocol="$PROTO" \
        --subnet="$SUBNET" \
        --size="$SIZE" \
        --port="$PORT" \
        --notes="$NOTES" \
      || echo "   WARN: v4 rule ${PROTO}/${PORT} failed (may already exist) - continuing"
  fi

  # ----- IPv6 rule -----
  if $INCLUDE_V6; then
    case "$SCOPE" in
      MGMT)   CIDR="$MGMT6_CIDR" ;;
      DEVICE) CIDR="$DEVICE6_CIDR" ;;
    esac
    split_cidr "$CIDR"

    echo "-- RULE  ${PROTO}/${PORT}  from ${SUBNET}/${SIZE}  (${NOTES} v6)"
    run vultr-cli firewall rule create "$FWG_ID" \
        --ip-type=v6 \
        --protocol="$PROTO" \
        --subnet="$SUBNET" \
        --size="$SIZE" \
        --port="$PORT" \
        --notes="$NOTES v6" \
      || echo "   WARN: v6 rule ${PROTO}/${PORT} failed (may already exist) - continuing"
  fi
done

# ---------------------------------------------------------------------------
# 3. Optionally attach to an instance
# ---------------------------------------------------------------------------
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [[ -n "$INSTANCE_ID" && ! "$INSTANCE_ID" =~ $UUID_RE ]]; then
  # -a was given a label, not a UUID -> resolve it
  echo
  echo "==> '$INSTANCE_ID' is not a UUID; resolving label via instance list..."
  MATCHES="$(vultr-cli instance list | awk -v lbl="$INSTANCE_ID" '$0 ~ lbl {print $1}')"
  COUNT="$(grep -c . <<< "$MATCHES" || true)"
  if [[ "$COUNT" -eq 1 ]] && [[ "$MATCHES" =~ $UUID_RE ]]; then
    echo "==> Resolved '$INSTANCE_ID' -> $MATCHES"
    INSTANCE_ID="$MATCHES"
  else
    echo "ERROR: could not uniquely resolve label '$INSTANCE_ID' ($COUNT matches)."
    echo "Attach manually with:"
    echo "  vultr-cli instance update-firewall-group <INSTANCE_UUID> -f $FWG_ID"
    INSTANCE_ID=""
  fi
fi

if [[ -n "$INSTANCE_ID" ]]; then
  echo
  echo "==> Attaching firewall group to instance $INSTANCE_ID"
  run vultr-cli instance update-firewall-group "$INSTANCE_ID" \
      --firewall-group-id="$FWG_ID"
fi

# ---------------------------------------------------------------------------
# 4. Show final state
# ---------------------------------------------------------------------------
echo
if ! $DRY_RUN; then
  echo "==> Rules in group $FWG_ID:"
  vultr-cli firewall rule list "$FWG_ID"
fi

echo
echo "Done. Notes:"
echo "  * Vultr Cloud Firewalls apply to INSTANCES with public IPs."
echo "    If your UniFi server sits behind the managed NAT Gateway, the"
echo "    NAT gateway's port-forwarding rules are the exposure control -"
echo "    this group protects a directly-exposed instance instead."
echo "  * Vultr firewall is default-deny: anything not listed is blocked."
echo "  * To attach later: vultr-cli instance update-firewall-group <INSTANCE_ID> -f $FWG_ID"
