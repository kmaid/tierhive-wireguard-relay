#!/bin/sh
# Remove everything run.sh installed. Packages and kernel modules are left in place.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

rc-service wg-quick.wg0 stop 2>/dev/null || wg-quick down wg0 2>/dev/null || true
rc-update del wg-quick.wg0 default >/dev/null 2>&1 || true
rm -f /etc/init.d/wg-quick.wg0

rm -f /etc/wireguard/wg0.conf /etc/wireguard/relay.key /etc/wireguard/router.key \
    /root/router-tunnel.conf \
    /etc/periodic/daily/apk-upgrade \
    /etc/sysctl.d/99-wg-relay.conf

if [ -f /etc/ssh/sshd_config.d/10-wg-relay-hardening.conf ]; then
    rm -f /etc/ssh/sshd_config.d/10-wg-relay-hardening.conf
    rc-service sshd reload || true
fi

echo "WireGuard relay removed. Reboot to reset kernel settings."
