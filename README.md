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
1. Copy the generated config to `/etc/wireguard/wgcf.conf` on the server.
2. Install the routing helper:
```bash
sudo cp ./system/wireguard-routes/warp-routing.sh /usr/local/bin/warp-routing.sh
sudo chmod +x /usr/local/bin/warp-routing.sh
```
3. Add these two lines to the `[Interface]` section of `/etc/wireguard/wgcf.conf`:
```ini
PostUp   = /usr/local/bin/warp-routing.sh up   %i
PostDown = /usr/local/bin/warp-routing.sh down %i
```
4. Bring the tunnel up: `sudo systemctl enable --now wg-quick@wgcf`

The helper handles everything a full tunnel (`AllowedIPs = 0.0.0.0/0, ::/0`) needs — forwarding, NAT, and routing client replies back out the WAN so connected clients aren't dropped when the tunnel takes over the default route. The interface name is auto-detected, so there's nothing to hardcode.