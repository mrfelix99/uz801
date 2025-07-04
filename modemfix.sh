#!/bin/bash
# ================================================
#  File: /usr/local/bin/wwan_auto_o2.sh
#  One‑click O₂ LTE connection helper for Qualcomm WWAN modems
#  Installs as a systemd service to auto‑connect at boot.
#
#  ▸ Stops ModemManager (optional – it sometimes interferes)
#  ▸ Switches the modem to online/raw‑IP
#  ▸ Brings the interface up, starts a data‑session on APN web.o2.de (IPv4)
#  ▸ Retrieves runtime settings ➜ configures IP/route/DNS/MTU
#  ▸ Optional TTL tweak (set TTL_HACK=1) – skipped if module missing
#
#  Tested on Quectel EC25/EG25‑G and similar Qualcomm MDM9x WWAN devices.
# ================================================

set -euo pipefail

WWAN_DEV="/dev/wwan0qmi0"   # QMI control device
IFACE="wwan0"               # Network interface provided by kernel
APN="web.o2.de"             # O₂ (Telefónica Germany) APN
IPTYPE="4"                  # 4 = IPv4, 6 = IPv6, 0 = v4v6
TTL_HACK="0"                # 1 = apply TTL‑65 mangle rule (needs xt_TTL)

log(){ printf "[*] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*" >&2; }

log "Stopping ModemManager (if running) …"
systemctl stop ModemManager.service 2>/dev/null || true

log "Ensuring RAW‑IP + online …"
qmicli -d "$WWAN_DEV" --device-open-proxy \
        --dms-set-operating-mode=online    >/dev/null 2>&1 || true
qmicli -d "$WWAN_DEV" --device-open-proxy \
        --wda-set-data-format=raw-ip       >/dev/null

log "Resetting $IFACE …"
ip link set "$IFACE" down || true
sleep 1
ip link set "$IFACE" up || true

log "Starting data session on '$APN' …"
START_OUT=$(qmicli -d "$WWAN_DEV" --device-open-proxy \
            --wds-start-network="apn=$APN,ip-type=$IPTYPE" \
            --client-no-release-cid 2>/dev/null || true)
if ! echo "$START_OUT" | grep -q "Network started"; then
    warn "Modem did not report a successful connection!"
    echo "$START_OUT" >&2
    exit 1
fi
HANDLE=$(echo "$START_OUT" | awk -F"'" '/Packet data handle/ {print $2}')
log "Packet‑data handle: $HANDLE"

log "Querying runtime settings …"
SETTINGS=$(qmicli -d "$WWAN_DEV" --device-open-proxy \
           --wds-get-current-settings="ip-family=$IPTYPE" 2>/dev/null || true)
IP=$(echo "$SETTINGS" | awk '/IPv4 address/ {print $4}')
GW=$(echo "$SETTINGS" | awk '/Primary IPv4 gateway/ {print $5}')
DNS1=$(echo "$SETTINGS" | awk '/IPv4 primary DNS/ {print $5}')
DNS2=$(echo "$SETTINGS" | awk '/IPv4 secondary DNS/ {print $5}')

if [[ -z "$IP" || -z "$GW" ]]; then
    warn "Couldn’t retrieve IP or gateway – aborting."
    echo "$SETTINGS" >&2
    exit 1
fi

log "Configuring $IP/24 on $IFACE …"
ip addr flush dev "$IFACE" || true
ip addr add "$IP/24" dev "$IFACE"

log "Setting MTU 1452 …"
ip link set dev "$IFACE" mtu 1452

log "Adding default route via $GW …"
ip route replace default via "$GW" dev "$IFACE"

if [[ -n "$DNS1" ]]; then
  log "Writing DNS servers to /etc/resolv.conf …"
  printf "nameserver %s\n" "$DNS1" "$DNS2" > /etc/resolv.conf
fi

if [[ "$TTL_HACK" == "1" ]]; then
  log "Applying tether‑TTL hack …"
  if modprobe xt_TTL 2>/dev/null; then
      iptables -t mangle -C POSTROUTING -o "$IFACE" -j TTL --ttl-set 65 2>/dev/null || \
      iptables -t mangle -A POSTROUTING -o "$IFACE" -j TTL --ttl-set 65
  else
      warn "xt_TTL module missing – skipping TTL hack."
  fi
fi

log "✓ Connection up!\n"
ip -4 addr show dev "$IFACE" | grep -v qdisc || true

# ⚙️  END OF SCRIPT


################################################################################
#  Systemd service unit – save as /etc/systemd/system/wwan_auto_o2.service
################################################################################
#
#  [Unit]
#  Description=O2 LTE auto‑connect via WWAN modem
#  After=network.target
#  Wants=network-online.target
#
#  [Service]
#  Type=oneshot
#  RemainAfterExit=yes
#  ExecStart=/usr/local/bin/wwan_auto_o2.sh
#  # Optionally stop data session on shutdown:
#  ExecStop=/usr/bin/qmicli -d /dev/wwan0qmi0 --device-open-proxy --wds-stop-network=disable-autoconnect,ip-family=4 2>/dev/null || true
#  TimeoutSec=60
#
#  [Install]
#  WantedBy=multi-user.target
#
################################################################################
#  Installation quick‑steps (run once as root):
#     install -m 755 wwan_auto_o2.sh /usr/local/bin/
#     install -m 644 wwan_auto_o2.service /etc/systemd/system/
#     systemctl daemon-reload
#     systemctl enable --now wwan_auto_o2.service
################################################################################
