# docker-proxy-server

A self-hosted proxy server: **naive** (HTTPS/CONNECT) and **VLESS** (Xray, WebSocket + XHTTP) behind Caddy, with automatic TLS via the Cloudflare DNS challenge.

Pair it with [docker-proxy-client](https://github.com/0xf00f00/docker-proxy-client) — use the **same tag** on both for compatible versions.

## Requirements

- A Linux server (Ubuntu/Debian recommended).
- A domain on Cloudflare, plus an API token with **Zone:Read + DNS:Edit** (see the comments in [`.env.example`](.env.example) for exactly how to create it).

## Quick start

**1. Install Docker** (bundles Docker Compose):

```bash
apt-get update
apt-get install -y git curl ca-certificates
curl -fsSL https://get.docker.com | sh
```

**2. Configure** — copy the example env file and fill it in:

```bash
cp .env.example .env
```

**3. Start it:**

```bash
docker compose up -d
```

That's it. Point [docker-proxy-client](https://github.com/0xf00f00/docker-proxy-client) at your domain and connect.

---

## Egress through Cloudflare WARP

By default **naive** and **xray** egress through Cloudflare WARP.

**Disable it** (egress directly) by setting in `.env`:

```bash
WARP_EGRESS=false
```

**Verify** — proxied traffic should exit via WARP. From a client connected through naive or xray, load `https://www.cloudflare.com/cdn-cgi/trace`; it should report `warp=on` and a Cloudflare IP, not your server's.

> If WARP is requested but the profile is missing, naive/xray **refuse to start** rather than silently leaking your real IP — check the `warp-reg` and container logs.

## Alternative: host-level WARP (wgcf)

Instead of the per-service container WARP, route the whole host through a host-level WARP tunnel.

**1. Generate a WireGuard config** with the bundled script (add `-T <teams-JWT>` if you use a Zero Trust / Teams account):

```bash
./system/cloudflare-warp/warp.sh
```

> To get a Teams JWT: open `https://<teams-id>.cloudflareaccess.com/warp`, authenticate, then read it from the page console:
> `document.querySelector("meta[http-equiv='refresh']").content.split("=")[2]`

**2. Install it** to `/etc/wireguard/wgcf.conf`, **delete the `DNS =` line**, then paste the hooks for the model you want into the `[Interface]` section. Pick one:

- **Split-tunnel** *(recommended)* — only proxied traffic goes through WARP; the host keeps its normal WAN. → [`split-tunnel.example`](system/wireguard-routes/wgcf.conf.hooks.split-tunnel.example)
- **Full-tunnel** — the entire box exits via WARP. → [`full-tunnel.example`](system/wireguard-routes/wgcf.conf.hooks.full-tunnel.example)

Each example file documents every line, including the Tailscale carve-outs if this host is also a Tailscale exit node.

**3. Bring it up:**

```bash
# Optional safety net: auto-revert in 90s if you lock yourself out.
sudo systemd-run --on-active=90 systemctl stop wg-quick@wgcf

sudo systemctl enable --now wg-quick@wgcf
```

**4. Verify** from a client or container — it should show `warp=on`:

```bash
curl https://www.cloudflare.com/cdn-cgi/trace
```

> Use the **inline** hooks from the example files, not a `PostUp = /path/script.sh`. Ubuntu's AppArmor profile for wg-quick blocks external scripts but allows `ip`/`iptables`/`sysctl`. The hooks are written to be idempotent so cycling the link never stacks duplicate rules.

## Optional: WireGuard VPN server

Terminate remote clients (e.g. a MikroTik router) on a separate `wg0` interface and force all their traffic out through the host's WARP tunnel, with a kill-switch so nothing leaks to the raw WAN.

See [`wg0.conf.example`](system/wireguard-server/wg0.conf.example) — it documents the keys, ports, routing, and the MikroTik client setup end to end.
