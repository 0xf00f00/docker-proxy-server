# docker-proxy-server

Works best with [docker-proxy-client](https://github.com/0xf00f00/docker-proxy-client). Use the same tags/releases to get compatible versions of server and client.

## How to setup

### Prerequisites

1. Install [docker](https://docs.docker.com/get-docker/)

```bash
apt-get update
apt-get install -y git curl ca-certificates
curl -fsSL https://get.docker.com | sh
```

2. Install Docker Compose

```bash
sudo apt-get install -y docker-compose
```

### Setup

1. Rename the `.env.example` file to `.env` (or copy: `cp .env.example .env`), and fill the values in the `.env` file.
2. Run the containers using `docker-compose`

```bash
docker-compose up -d
```

## Cloudflare setup

### Get the teams JWT token from Cloudflare

1. Visit https://<teams id>.cloudflareaccess.com/warp
2. Authenticate yourself as you would with the official client
3. Check the source code of the page for the JWT token or use the following code in the "Web Console" (Ctrl+Shift+K):
```javascript
console.log(document.querySelector("meta[http-equiv='refresh']").content.split("=")[2])
```
4. Copy the JWT token and use it in the next step as the `-T` argument.

### Generate the WireGuard configuration
```bash
git clone https://github.com/rany2/warp.sh
cd warp.sh
./warp.sh -T eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9... #teams JWT token (default no JWT token is sent)
```

### Add the WireGuard configuration to the server

A full tunnel (`AllowedIPs = 0.0.0.0/0, ::/0`) makes WARP the default route. The problem: once it is, replies to **inbound** connections (your proxy clients) would also try to go back through the tunnel, dropping them. We fix this with `iptables` connection marks + a policy-routing rule, all driven from the config's `PreUp`/`PostUp`/`PostDown` hooks.

> **Use inline hooks, not an external script.** Ubuntu ships an enforced AppArmor profile (`/etc/apparmor.d/wg-quick`) that blocks `wg-quick` from executing scripts in `/usr/local/bin` (you'll see `apparmor="DENIED" operation="exec"` in `dmesg`). It *does* allow `iptables`/`ip`/`sysctl`, so inline hook commands work fine. A `PostUp = /usr/local/bin/...sh` will fail and, mid-bringup, can lock you out.

1. Copy the generated config to `/etc/wireguard/wgcf.conf`.
2. Remove the `DNS =` line if present. On systemd-resolved boxes the AppArmor profile also blocks wg-quick's DNS *revert* (a denied dbus call), which aborts teardown and leaves the tunnel up — a lockout. Keep your host DNS managed separately.
3. Find your WAN interface: `ip route show default` → the `dev <name>` (e.g. `eth0`, `enp1s0`, `ens3`).
4. Add the block below to the `[Interface]` section, **replacing every `eth0` with your WAN interface** (leave `%i` — wg-quick fills it in). The full block is also in [`system/wireguard-routes/wgcf.conf.hooks.example`](system/wireguard-routes/wgcf.conf.hooks.example).

```ini
# Mark new inbound conns on the WAN so their replies route back out the WAN.
# ctstate NEW avoids marking WARP's own return flow (which would loop it).
PreUp = iptables  -t mangle -A PREROUTING -i eth0 -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x1/0x1
PreUp = iptables  -t mangle -A PREROUTING -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
PreUp = iptables  -t mangle -A OUTPUT     -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
PreUp = ip6tables -t mangle -A PREROUTING -i eth0 -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x1/0x1
PreUp = ip6tables -t mangle -A PREROUTING -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
PreUp = ip6tables -t mangle -A OUTPUT     -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
# Policy rule + NAT in PostUp. It MUST be PostUp, not PreUp: wg-quick auto-assigns
# its own rule to (lowest-existing-priority - 1), so a PreUp rule gets undercut.
# Adding ours after wg (with no ip rules in PreUp) lands wg high (~5209) and ours low.
PostUp = ip rule add fwmark 0x1/0x1 lookup main pref 100
PostUp = ip -6 rule add fwmark 0x1/0x1 lookup main pref 100
PostUp = iptables  -A FORWARD -i %i -j ACCEPT
PostUp = iptables  -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostUp = ip6tables -A FORWARD -i %i -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = ip rule del fwmark 0x1/0x1 lookup main pref 100 || true
PostDown = ip -6 rule del fwmark 0x1/0x1 lookup main pref 100 || true
PostDown = iptables  -t mangle -D PREROUTING -i eth0 -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x1/0x1 || true
PostDown = iptables  -t mangle -D PREROUTING -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1 || true
PostDown = iptables  -t mangle -D OUTPUT     -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1 || true
PostDown = iptables  -D FORWARD -i %i -j ACCEPT || true
PostDown = iptables  -t nat -D POSTROUTING -o eth0 -j MASQUERADE || true
PostDown = ip6tables -t mangle -D PREROUTING -i eth0 -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x1/0x1 || true
PostDown = ip6tables -t mangle -D PREROUTING -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1 || true
PostDown = ip6tables -t mangle -D OUTPUT     -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1 || true
PostDown = ip6tables -D FORWARD -i %i -j ACCEPT || true
PostDown = ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE || true
```

5. `rp_filter` must be loose (`2`) so inbound packets aren't dropped while the default route points at the tunnel. Most cloud images already ship `2`; verify with `sysctl net.ipv4.conf.all.rp_filter`, and if it's `1`, set `net.ipv4.conf.<wan>.rp_filter=2` in `/etc/sysctl.d/`.
6. Bring it up: `sudo systemctl enable --now wg-quick@wgcf`

**Verify** (don't assume): `ip route get 1.1.1.1` should show `dev wgcf`; `curl https://www.cloudflare.com/cdn-cgi/trace` should show `warp=on`. Test behind a safety net so a mistake can't lock you out — e.g. `sudo systemd-run --on-active=90 systemctl stop wg-quick@wgcf` first, which auto-reverts in 90s unless you cancel it.

#### If the server also runs Tailscale

Full-tunnel WARP will **break Tailscale** — and your SSH/DNS if you reach the box over it. WARP's rule preempts Tailscale's (which live at pref `5210+`), so tailnet traffic and MagicDNS get swallowed by WARP. Carve Tailscale out by adding these to **`PostUp`** (with matching `PostDown` deletes). The values below are Tailscale's Linux defaults — the same on every tailnet (fwmark `0x80000`, CGNAT `100.64.0.0/10`, the ULA `fd7a:115c:a1e0::/48`, table `52`); confirm the table with `ip rule show` (the `lookup <N>` near pref `5270`):

```ini
PostUp = ip rule add from all fwmark 0x80000/0xff0000 lookup main pref 80
PostUp = ip rule add to 100.64.0.0/10 lookup 52 pref 81
PostUp = ip -6 rule add from all fwmark 0x80000/0xff0000 lookup main pref 80
PostUp = ip -6 rule add to fd7a:115c:a1e0::/48 lookup 52 pref 81
PostDown = ip rule del from all fwmark 0x80000/0xff0000 lookup main pref 80 || true
PostDown = ip rule del to 100.64.0.0/10 lookup 52 pref 81 || true
PostDown = ip -6 rule del from all fwmark 0x80000/0xff0000 lookup main pref 80 || true
PostDown = ip -6 rule del to fd7a:115c:a1e0::/48 lookup 52 pref 81 || true
```