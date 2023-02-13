# docker-proxy-server

Works best with [docker-proxy-client](https://github.com/0xf00f00/docker-proxy-client). Use the same tags/releases to get compatible versions of server and client.

## How to setup

1. Rename the `.env.example` file to `.env` (or copy: `cp .env.example .env`), and fill the values in the `.env` file.
2. Run the containers using `docker-compose`

```bash
docker-compose up -d
```