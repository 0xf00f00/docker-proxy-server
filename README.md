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

Pick one model:

- **Split-tunnel** *(recommended)* — only user traffic goes through WARP; the host stays on its WAN. Simpler, low lockout risk. Use this unless you have a reason not to.
- **Full-tunnel** — the whole box (including its own traffic) exits via WARP. Choose only if you also want the host's own outbound cloaked.

**Steps:**

1. Copy the generated config to `/etc/wireguard/wgcf.conf` and delete its `DNS =` line.
2. Paste the hooks for your model (below) into the `[Interface]` section.
3. Bring it up: `sudo systemctl enable --now wg-quick@wgcf`
   - To auto revert in 90s if you lock yourself out, run `sudo systemd-run --on-active=90 systemctl stop wg-quick@wgcf` beforehand.

Verify from a **client/container**: `curl https://www.cloudflare.com/cdn-cgi/trace` shows `warp=on`.

> Use **inline** hooks (not a `PostUp = /path/script.sh`). Ubuntu's AppArmor profile for wg-quick blocks executing external scripts but allows `ip`/`iptables`/`sysctl`.

#### Option A — Split-tunnel (recommended)

`Table = off` keeps the WAN as default route; the rules below send only user subnets through WARP. `172.16.0.0/12` covers all Docker networks; optionally uncomment the `10.x.x.0/24` line and set to your own subnet (e.g., WireGuard). Full file: [`wgcf.conf.hooks.split-tunnel.example`](system/wireguard-routes/wgcf.conf.hooks.split-tunnel.example).

```ini
Table = off
PostUp = ip route add default dev %i table 51820
PostUp = ip -6 route add default dev %i table 51820
PostUp = ip rule add from 172.16.0.0/12 table 51820 pref 100
# PostUp = ip rule add from 10.13.13.0/24 table 51820 pref 102
PostUp = iptables  -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = ip6tables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostDown = iptables  -t nat -D POSTROUTING -o %i -j MASQUERADE || true
PostDown = ip6tables -t nat -D POSTROUTING -o %i -j MASQUERADE || true
PostDown = ip rule del from 172.16.0.0/12 table 51820 pref 100 || true
# PostDown = ip rule del from 10.13.13.0/24 table 51820 pref 102 || true
PostDown = ip route flush table 51820 || true
PostDown = ip -6 route flush table 51820 || true
```

> If you serve IPv6 to clients, add matching `ip -6 rule add from <prefix>` lines for your v6 subnets, or clients leak via the server's real IPv6. If not, disable IPv6 on the host.

#### Option B — Full-tunnel

`AllowedIPs = 0.0.0.0/0, ::/0` makes WARP the default route; the hooks mark inbound replies back out the WAN so proxy clients aren't dropped. **Replace every `eth0` with your WAN interface** (`ip route show default`). Also ensure `rp_filter` is `2` (`sysctl net.ipv4.conf.all.rp_filter`; if `1`, set `net.ipv4.conf.<wan>.rp_filter=2` in `/etc/sysctl.d/`). Full file: [`wgcf.conf.hooks.full-tunnel.example`](system/wireguard-routes/wgcf.conf.hooks.full-tunnel.example).

```ini
PreUp = iptables  -t mangle -A PREROUTING -i eth0 -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x1/0x1
PreUp = iptables  -t mangle -A PREROUTING -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
PreUp = iptables  -t mangle -A OUTPUT     -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
PreUp = ip6tables -t mangle -A PREROUTING -i eth0 -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x1/0x1
PreUp = ip6tables -t mangle -A PREROUTING -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
PreUp = ip6tables -t mangle -A OUTPUT     -j CONNMARK --restore-mark --nfmask 0x1 --ctmask 0x1
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

#### If the server also runs Tailscale

Skip if you don't run Tailscale. The two models need opposite handling:

**Split-tunnel** — opt exit-node traffic *into* WARP. Add to Option A:

```ini
PostUp = ip rule add iif tailscale0 table 51820 pref 101
PostUp = ip -6 rule add iif tailscale0 table 51820 pref 101
PostDown = ip rule del iif tailscale0 table 51820 pref 101 || true
PostDown = ip -6 rule del iif tailscale0 table 51820 pref 101 || true
```

**Full-tunnel** — full-tunnel WARP otherwise swallows tailnet traffic + MagicDNS (and your SSH if it's over Tailscale). Carve it back *out* by adding to Option B (values are Tailscale's Linux defaults; confirm table `52` via `ip rule show`):

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