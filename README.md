# docker-proxy-server

Works best with [docker-proxy-client](https://github.com/0xf00f00/docker-proxy-client). Use the same tags/releases to get compatible versions of server and client.

## How to setup

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
2. Add the following to the `[Interface]` section of the config:
```ini
PreUp = /usr/local/bin/update_routes.sh
PostUp = iptables -A FORWARD -i wgcf -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostUp = ip6tables -A FORWARD -i wgcf -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -D FORWARD -i wgcf -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
PostDown = ip6tables -D FORWARD -i wgcf -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
```


### Set up routing for client IPs
This prevents them from being disconnected from the server after the VPN connection is established.

1. Copy `./system/wireguard-routes/update_routes.sh` to your server (e.g., `/usr/local/bin/update_routes.sh`).
2. Add the following to your crontab (`sudo crontab -e`):
```bash
*/5 * * * * /usr/local/bin/update_routes.sh >> /var/log/update_routes.log 2>&1
```