# tierhive-wireguard-relay

Reach your home WireGuard server from anywhere, even behind **CGNAT**, through a
[TierHive](https://tierhive.com/r/2926B31FDA30) VPS that costs a few cents a month.

```
phone / laptop ──► VPS relay ══════ tunnel ══════ your router ──► home LAN / internet
                    forwards UDP,    router dials out,  WireGuard server
                    can't decrypt    so CGNAT is fine    decrypts
```

- **Your router does the VPN**, so traffic leaves from your home IP, exactly as if you had a public one.
- **The VPS can't read your traffic.** It only forwards encrypted UDP down a tunnel the router keeps open.
- **Nothing else to run at home.** Fits TierHive's 128 MB Alpine plan.

Needs a router that can run a WireGuard server and client at the same time. Tested on stock Asuswrt 388
(ZenWiFi XT8).

## Why not frp, Tailscale or Cloudflare Tunnel?

- **frp** proxies every packet through daemons at both ends; here the kernel forwards them.
- **Tailscale** needs its app on every device and an account; here any stock WireGuard client works, with no
  third party involved.
- **Cloudflare Tunnel** is built for publishing web apps, not carrying a VPN for stock clients.

The trade-off: WireGuard inside WireGuard costs 160 bytes a packet, so throughput tops out around 87% of
line speed.

## Quick start

1. **Create a [TierHive](https://tierhive.com/r/2926B31FDA30) VPS** with Alpine Linux, near home, with your
   SSH key, and run the script on it as root:

   ```sh
   wget -qO- https://raw.githubusercontent.com/kmaid/tierhive-wireguard-relay/main/run.sh | sh
   ```

   Or deploy it in one step from the [TierHive Recipe Marketplace](https://control.tierhive.com/recipes):
   search for **CGNAT** and choose **WireGuard CGNAT Relay (AsusWRT / home router)**.

2. **Forward the ports**: in the VPS's port forwarding, add internal UDP ports `51820` (router tunnel) and
   `51821` (devices). TierHive assigns each a public port; note them.
3. **Set up your router** with the config the script printed, using the public port for `51820` as its
   endpoint port: [ASUS steps](#router-setup-asus).
4. **Point your devices at the relay**: Endpoint `<VPS IP>:<public port for 51821>`, MTU `1340`.

Re-run the script any time to change settings or upgrade.

## Router setup: ASUS

1. **Copy the config off the VPS**, and delete your copy once it's imported:
   `ssh -p <ssh port> root@<VPS IP> cat /root/router-tunnel.conf > router-tunnel.conf`
2. **WireGuard server**: *VPN → VPN Server → WireGuard VPN*. Enable it on port `51820` and add a client
   for each device.
3. **WireGuard client**: in *VPN → VPN Fusion*, add a WireGuard profile and upload `router-tunnel.conf` (fill
   in its Endpoint port first). Check it has **NAT: No**, **Address: `10.88.0.2/24`** and **Allowed IPs:
   `10.88.0.1/32`** (never `0.0.0.0/0`). Assign no devices, don't make it the default connection, and turn it
   on. Use VPN Fusion rather than the hidden client page: a client set up only on that page didn't restart
   after a reboot.
4. **Devices**: export each server client profile and, in the WireGuard app, set **Endpoint** to
   `<VPS IP>:<public port for 51821>` (ASUS fills in its own WAN address, which CGNAT makes unreachable)
   and **MTU** to `1340`.

On the VPS, `wg show wg0` should show a recent handshake from the router.

## Settings

Set them on the command line (`--public-tunnel-port 5355`, `--public-tunnel-port=5355` or `public_tunnel_port=5355`). As a
TierHive recipe, paste `run.sh` unchanged and add variables with the underscore names; TierHive fills in
the script's `{{tokens}}`. The command line wins over recipe values.

| Setting | Default | |
|---|---|---|
| `--tunnel-port` | `51820` | VPS UDP port the router's tunnel connects to |
| `--public-tunnel-port` | | Public port TierHive assigned to the tunnel port; fills in the printed router config |
| `--client-port` | `51821` | VPS UDP port devices connect to |
| `--router-port` | `51820` | Your router's WireGuard server port |
| `--router-public-key` | *generated* | Bring your own router tunnel key |

`sh run.sh --help` lists the rest: CAKE pacing, daily updates and SSH hardening.

## How it works

The router keeps a WireGuard tunnel to the VPS (`10.88.0.2` ↔ `10.88.0.1`) open with a 25 s keepalive.
The VPS forwards device packets arriving on `client_port` down that tunnel to the router's WireGuard server,
and connection tracking sends the replies back. It holds only the tunnel key, never device keys.

This is built for remote access, not sustained bandwidth: TierHive's unmetered traffic isn't unlimited, and it
caps accounts that run heavy traffic for long periods.

## Troubleshooting

- **No handshake in `wg show wg0`:** check the router client's endpoint uses the *public* tunnel port.
- **Tunnel up but devices can't connect:** check the client port forward and the device Endpoint.
  `iptables -t nat -L PREROUTING -v -n` shows whether packets arrive.
- **Handshake works but devices can't connect:** the router's tunnel Address must be `10.88.0.2/24`. With `/32`,
  VPN Fusion leaves the router with no main-table route back to the relay.
- **Pages hang, ping works:** the device profile needs an explicit `MTU = 1340`. "Auto" picks 1420, which
  doesn't fit inside the relay's own tunnel (each tunnel adds 80 bytes).
- **Moving VPS:** run the script on the new one with `--router-public-key`, then update the router's and
  devices' endpoints.

## Uninstall

```sh
wget -qO- https://raw.githubusercontent.com/kmaid/tierhive-wireguard-relay/main/uninstall.sh | sh
```

Then remove the WireGuard client from your router.

## License

MIT. TierHive links are referral links that support this project.
