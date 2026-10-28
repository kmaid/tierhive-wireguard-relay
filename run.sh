#!/bin/sh
# tierhive-wireguard-relay: reach a home WireGuard server from behind CGNAT via a tiny VPS.
#
# The VPS keeps a WireGuard tunnel open to your router (the router dials out, so CGNAT is fine)
# and forwards client UDP down it to the router's own WireGuard server. Client sessions stay
# end-to-end encrypted between device and router; the VPS never sees plaintext.
#
# Run as root on Alpine Linux. Idempotent: re-run with new settings to change them.
# Works directly from CLI or as a TierHive marketplace recipe startup script.
# See README.md for variables and router setup.

set -eu

SETTINGS="tunnel_port public_tunnel_port client_port router_port router_public_key egress_rate fair_use_guard
auto_update harden_ssh"

usage() {
    cat << 'EOF'
Usage: run.sh [--setting value | --setting=value | setting=value] ...

Settings (command line > TierHive recipe value > default):
  --tunnel-port         VPS-internal UDP port the router's tunnel connects to   (51820)
  --public-tunnel-port  public port TierHive forwards to tunnel_port, for the printed router config
  --client-port         VPS-internal UDP port devices connect to                (51821)
  --router-port         the router's WireGuard server port                      (51820)
  --router-public-key   router tunnel public key; generated and printed if empty
  --egress-rate         CAKE pacing rate such as 200mbit, or off                (off)
  --fair-use-guard      on/off: cap at 85mbit before TierHive's fair-use throttle (on)
  --auto-update         on/off: daily apk upgrades                              (on)
  --harden-ssh          on/off: key-only SSH if root has authorized_keys        (on)
EOF
}

# --- Command-line settings: --client-port 3977, --client-port=3977 or client_port=3977 ---
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --*=*) name=${1%%=*}; name=${name#--}; value=${1#*=} ;;
        --*)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 1; }
            name=${1#--}; value=$2; shift ;;
        *=*) name=${1%%=*}; value=${1#*=} ;;
        *) echo "ERROR: unexpected argument '$1' (see --help)" >&2; exit 1 ;;
    esac
    name=$(echo "$name" | tr - _)
    case " $(echo $SETTINGS) " in
        *" $name "*) eval "cli_$name=\$value" ;;
        *) echo "ERROR: unknown setting '$name' (see --help)" >&2; exit 1 ;;
    esac
    shift
done

# --- Settings & TierHive Recipe Tokens ----------------------------------------
# Each setting is the command-line value, otherwise its TierHive recipe token, which TierHive fills
# in when this script is deployed as a recipe. Anywhere else the token stays unfilled and counts as
# empty, so the default applies.
tunnel_port=${cli_tunnel_port:-'{{tunnel_port}}'}
public_tunnel_port=${cli_public_tunnel_port:-'{{public_tunnel_port}}'}
client_port=${cli_client_port:-'{{client_port}}'}
router_port=${cli_router_port:-'{{router_port}}'}
router_public_key=${cli_router_public_key:-'{{router_public_key}}'}
egress_rate=${cli_egress_rate:-'{{egress_rate}}'}
fair_use_guard=${cli_fair_use_guard:-'{{fair_use_guard}}'}
auto_update=${cli_auto_update:-'{{auto_update}}'}
harden_ssh=${cli_harden_ssh:-'{{harden_ssh}}'}

for name in $SETTINGS; do
    eval "value=\$$name"
    case "$value" in
        *"{{"*) eval "$name=''" ;;
    esac
done

: "${tunnel_port:=51820}"
: "${client_port:=51821}"
: "${router_port:=51820}"
: "${egress_rate:=off}"
: "${fair_use_guard:=on}"
: "${auto_update:=on}"
: "${harden_ssh:=on}"

for name in fair_use_guard auto_update harden_ssh; do
    eval "value=\$$name"
    case "$value" in
        on|ON|On|1|yes|true) eval "$name=on" ;;
        off|OFF|Off|0|no|false) eval "$name=off" ;;
        *) echo "ERROR: $name must be on or off, not '$value'" >&2; exit 1 ;;
    esac
done

# --- System requirements check ------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi
if [ ! -f /etc/alpine-release ] || [ ! -x /sbin/openrc-run ]; then
    echo "ERROR: This script is designed for Alpine Linux with OpenRC." >&2
    exit 1
fi

# --- Logging setup ------------------------------------------------------------
LOG_FILE=/root/recipe.log
LOG_PIPE="/tmp/wg-relay-log.$$"

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a "$LOG_FILE" < "$LOG_PIPE" &
    LOG_PID=$!
    exec > "$LOG_PIPE" 2>&1
}

cleanup() {
    rc=$1
    set +e
    [ "$rc" -ne 0 ] && echo "ERROR: Recipe failed with exit code $rc"
    exec >/dev/null 2>&1
    wait "$LOG_PID" 2>/dev/null    # closing the pipe ends tee; let it flush everything
    rm -f "$LOG_PIPE"
}

start_logging
trap 'cleanup $?' EXIT

log() {
    echo "[wg-relay] $*"
}

RELAY_ADDRESS=10.88.0.1
ROUTER_ADDRESS=10.88.0.2
CONF=/etc/wireguard/wg0.conf

# Install a file from stdin, returning success only if it changed
install_stdin() {
    tmp=$(mktemp)
    cat > "$tmp"
    if cmp -s "$tmp" "$1"; then
        rm -f "$tmp"
        return 1
    fi
    install -D -m "$2" "$tmp" "$1"
    rm -f "$tmp"
    log "Updated $1"
}

echo '######################################'
echo '#      WireGuard CGNAT relay         #'
echo '######################################'

# --- Packages and kernel -----------------------------------------------------
log "Installing packages..."
apk add -q wireguard-tools iptables iproute2-tc

for module in wireguard nf_conntrack sch_cake ifb act_mirred; do
    grep -qx "$module" /etc/modules 2>/dev/null || echo "$module" >> /etc/modules
    modprobe "$module"
done

install_stdin /etc/sysctl.d/99-wg-relay.conf 644 << 'EOF' || true
net.ipv4.ip_forward = 1
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.netdev_max_backlog = 4096
net.netfilter.nf_conntrack_max = 8192
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
EOF
sysctl -q -p /etc/sysctl.d/99-wg-relay.conf

# --- SSH ----------------------------------------------------------------------
if [ "$harden_ssh" = on ]; then
    if [ -s /root/.ssh/authorized_keys ]; then
        # sshd uses the first value it reads, so sort ahead of cloud-init's drop-in
        printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' |
            install_stdin /etc/ssh/sshd_config.d/10-wg-relay-hardening.conf 644 &&
            sshd -t && rc-service sshd reload || true
    else
        log "Skipping SSH hardening: /root/.ssh/authorized_keys is empty (add a key, then re-run)"
    fi
fi

# --- Daily updates ------------------------------------------------------------
if [ "$auto_update" = on ]; then
    install_stdin /etc/periodic/daily/apk-upgrade 755 << 'EOF' || true
#!/bin/sh
# Daily patch-level upgrades within the pinned Alpine branch; reboot only for a new kernel
exec >> /var/log/apk-upgrade.log 2>&1
echo "== $(date)"
apk update -q && apk upgrade -q --available
apk cache clean -q 2>/dev/null || true
if [ ! -d "/lib/modules/$(uname -r)" ]; then
    echo "Kernel changed, rebooting"
    reboot
fi
EOF
else
    rm -f /etc/periodic/daily/apk-upgrade
fi

# --- Fair-use guard -------------------------------------------------------------
cron_changed=0
if [ "$fair_use_guard" = on ]; then
    install_stdin /usr/local/sbin/fup-governor 755 << 'EOF' || true
#!/bin/sh
# Keep the relay under TierHive's fair-use policy (100 Mbit/s hourly average -> stepped throttling).
# Runs from cron every 5 minutes: samples eth0 counters, computes the rolling 60-minute average
# per direction, and caps both directions with CAKE while the average is high.

[ -f /etc/conf.d/fup-governor ] && . /etc/conf.d/fup-governor

: "${FUP_IFACE:=eth0}"
: "${FUP_THROTTLE_AT:=75}"
: "${FUP_RELEASE_AT:=60}"
: "${FUP_CAP:=85mbit}"
: "${FUP_NORMAL:=250mbit}"
: "${FUP_WINDOW:=3600}"
STATE_DIR=/run/fup
SAMPLES="$STATE_DIR/samples"
LOG=/var/log/fup.log

mkdir -p "$STATE_DIR"
s=/sys/class/net/$FUP_IFACE/statistics
now=$(date +%s); rx=$(cat "$s/rx_bytes"); tx=$(cat "$s/tx_bytes")

# Counter reset (reboot / interface recreated) invalidates the window
last_rx=$(tail -n 1 "$SAMPLES" 2>/dev/null | cut -d' ' -f2)
[ -n "$last_rx" ] && [ "$rx" -lt "$last_rx" ] && : > "$SAMPLES"

echo "$now $rx $tx" >> "$SAMPLES"
awk -v cutoff=$((now - FUP_WINDOW - 300)) '$1 >= cutoff' "$SAMPLES" > "$SAMPLES.tmp" && mv "$SAMPLES.tmp" "$SAMPLES"

# Rolling average against the oldest sample (a shorter window overestimates, which is the safe side)
set -- $(head -n 1 "$SAMPLES")
span=$((now - $1))
[ "$span" -lt 240 ] && exit 0
read -r rx_avg tx_avg << AVG
$(awk -v r0="$2" -v t0="$3" -v r1="$rx" -v t1="$tx" -v d="$span" 'BEGIN { printf "%.1f %.1f\n", (r1-r0)*8/d/1e6, (t1-t0)*8/d/1e6 }')
AVG

throttled=0; [ -f "$STATE_DIR/throttled" ] && throttled=1

cap_on() {
    tc qdisc replace dev "$FUP_IFACE" root cake bandwidth "$FUP_CAP"
    ip link set ifb0 up
    tc qdisc replace dev ifb0 root cake bandwidth "$FUP_CAP" ingress
    tc qdisc replace dev "$FUP_IFACE" handle ffff: ingress
    tc filter replace dev "$FUP_IFACE" parent ffff: prio 1 matchall action mirred egress redirect dev ifb0
    touch "$STATE_DIR/throttled"
}

cap_off() {
    tc qdisc del dev "$FUP_IFACE" ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set ifb0 down 2>/dev/null
    if [ "$FUP_NORMAL" = off ]; then
        tc qdisc del dev "$FUP_IFACE" root 2>/dev/null
    else
        tc qdisc replace dev "$FUP_IFACE" root cake bandwidth "$FUP_NORMAL"
    fi
    rm -f "$STATE_DIR/throttled"
}

action=""
if [ "$throttled" -eq 0 ] && awk -v a="$rx_avg" -v b="$tx_avg" -v t="$FUP_THROTTLE_AT" 'BEGIN { exit !(a >= t || b >= t) }'; then
    cap_on; action=" -> CAPPED at $FUP_CAP"
elif [ "$throttled" -eq 1 ] && awk -v a="$rx_avg" -v b="$tx_avg" -v t="$FUP_RELEASE_AT" 'BEGIN { exit !(a < t && b < t) }'; then
    cap_off; action=" -> released"
elif [ "$throttled" -eq 1 ]; then
    cap_on    # re-assert: a wg0 restart resets the egress qdisc
fi

state=normal; [ -f "$STATE_DIR/throttled" ] && state=capped
echo "$(date '+%Y-%m-%d %H:%M') in ${rx_avg} out ${tx_avg} Mbit/s (${span}s window) $state$action" >> "$LOG"
tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
EOF
    echo "FUP_NORMAL=$egress_rate" | install_stdin /etc/conf.d/fup-governor 644 || true
    if ! grep -q fup-governor /etc/crontabs/root; then
        printf '*/5\t*\t*\t*\t*\t/usr/local/sbin/fup-governor\n' >> /etc/crontabs/root
        cron_changed=1
    fi
elif grep -q fup-governor /etc/crontabs/root; then
    sed -i '/fup-governor/d' /etc/crontabs/root
    cron_changed=1
fi
rc-update add crond default >/dev/null 2>&1 || true
# BusyBox crond only rereads crontabs when the directory changes
if [ "$cron_changed" = 1 ]; then
    rc-service crond restart || true
else
    rc-service crond start >/dev/null 2>&1 || true
fi

# --- Router key ------------------------------------------------------------------
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
[ -s /etc/wireguard/relay.key ] || (umask 077 && wg genkey > /etc/wireguard/relay.key)
relay_public_key=$(wg pubkey < /etc/wireguard/relay.key)

router_conf=/root/router-tunnel.conf
if [ -z "$router_public_key" ]; then
    if [ ! -s /etc/wireguard/router.key ]; then
        log "Generating the router's tunnel key"
        (umask 077 && wg genkey > /etc/wireguard/router.key)
    fi
    router_public_key=$(wg pubkey < /etc/wireguard/router.key)
else
    rm -f /etc/wireguard/router.key
fi

# --- Tunnel + client forwarding ----------------------------------------------------
dnat="PREROUTING -i eth0 -p udp --dport $client_port -j DNAT --to-destination $ROUTER_ADDRESS:$router_port"
snat="POSTROUTING -o %i -d $ROUTER_ADDRESS -p udp --dport $router_port -j SNAT --to-source $RELAY_ADDRESS"
{
    echo "# Managed by tierhive-wireguard-relay run.sh; re-run it instead of editing."
    echo "# Tunnel to the router; client UDP on $client_port is forwarded down it, still encrypted."
    echo "[Interface]"
    echo "Address = $RELAY_ADDRESS/24"
    echo "ListenPort = $tunnel_port"
    echo "PrivateKey = $(cat /etc/wireguard/relay.key)"
    echo "MTU = 1420"
    echo "Table = off"
    if [ "$egress_rate" != off ]; then
        echo "# Pace egress just under the provider's rate limit so TCP sees queueing, not drops"
        echo "PostUp = tc qdisc replace dev eth0 root cake bandwidth $egress_rate"
        echo "PostDown = tc qdisc del dev eth0 root"
    fi
    echo "PostUp = iptables -t nat -A $dnat"
    echo "PostUp = iptables -t nat -A $snat"
    echo "PostDown = iptables -t nat -D $dnat"
    echo "PostDown = iptables -t nat -D $snat"
    echo
    echo "[Peer]"
    echo "# Router"
    echo "PublicKey = $router_public_key"
    echo "AllowedIPs = $ROUTER_ADDRESS/32"
} > /tmp/wg0.conf

ln -sf /etc/init.d/wg-quick /etc/init.d/wg-quick.wg0
rc-update add wg-quick.wg0 default >/dev/null 2>&1 || true
if ! cmp -s /tmp/wg0.conf "$CONF" || ! wg show wg0 >/dev/null 2>&1; then
    # Stop with the old config so its PostDown removes the old rules before they change
    rc-service wg-quick.wg0 stop 2>/dev/null || wg-quick down wg0 2>/dev/null || true
    install -m 600 /tmp/wg0.conf "$CONF"
    log "Updated $CONF"
    rc-service wg-quick.wg0 start
fi
rm -f /tmp/wg0.conf

# --- Router config -------------------------------------------------------------------
public_ip=$(wget -qO- -T 5 https://api.ipify.org 2>/dev/null || echo "<VPS public IP>")

echo
echo '######################################'
echo '#              Done                  #'
echo '######################################'
echo
{
    echo "[Interface]"
    if [ -s /etc/wireguard/router.key ]; then
        echo "PrivateKey = $(cat /etc/wireguard/router.key)"
    else
        echo "PrivateKey = <your router's tunnel private key>"
    fi
    echo "Address = $ROUTER_ADDRESS/32"
    echo "MTU = 1420"
    echo
    echo "[Peer]"
    echo "PublicKey = $relay_public_key"
    echo "Endpoint = $public_ip:${public_tunnel_port:-<public port forwarded to $tunnel_port>}"
    echo "AllowedIPs = $RELAY_ADDRESS/32"
    echo "PersistentKeepalive = 25"
} > "$router_conf"
chmod 600 "$router_conf"
echo "In your VPS's port forwarding, forward UDP $tunnel_port (router tunnel) and $client_port (devices)"
echo "and note the public ports you get back."
echo
echo "Import this on your router as a WireGuard *client* (saved to $router_conf)."
echo "Route no devices through it; it only lets the relay reach the router:"
echo
cat "$router_conf"
echo
echo "Then point each device's profile (from your router's WireGuard server) at:"
echo "  Endpoint = $public_ip:<public port forwarded to $client_port>"
echo "  MTU      = 1340"
