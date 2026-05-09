# chromebook-server

Step-by-step setup for putting a small Node/Express API on a Raspberry Pi behind a Cloudflare Tunnel.

The clean path is:

```txt
your domain -> Cloudflare -> Cloudflare Tunnel -> Raspberry Pi -> localhost Node API
```

That avoids home IP address changes, static IP setup, and router port forwarding. `cloudflared` runs on the Pi and opens outbound-only connections to Cloudflare.

## Target Setup

These examples use:

```txt
public API hostname: https://api.yourdomain.com
Pi local API:        http://127.0.0.1:3000
project folder:      /home/pi/my-api
systemd service:     my-api
```

Replace `yourdomain.com` with your real domain.

## Fast Path: Use The Setup Script

Run this on the Raspberry Pi, not on your Mac.

```bash
chmod +x ./setup-pi-api.sh
./setup-pi-api.sh yourdomain.com
```

With one normal root domain argument, the script uses `api.yourdomain.com`.
For multi-part root domains such as `yourdomain.co.uk`, use the two-argument form.

You can also pass the subdomain explicitly:

```bash
./setup-pi-api.sh api yourdomain.com
```

Or pass a full hostname:

```bash
./setup-pi-api.sh api.yourdomain.com
```

The script does this:

1. Updates apt package metadata.
2. Installs base build tools.
3. Installs Node.js from NodeSource.
4. Creates a tiny Express API in `~/my-api`.
5. Installs `express`, `cors`, and `helmet`.
6. Creates and starts a `systemd` service named `my-api`.
7. Installs `cloudflared` from Cloudflare's apt repository.
8. Optionally installs the Cloudflare Tunnel connector service if `TUNNEL_TOKEN` is provided.
9. Tests `http://127.0.0.1:3000/health`.

### Script Options

You can override defaults with environment variables:

```bash
PROJECT_DIR=/home/pi/my-api \
SERVICE_NAME=my-api \
PORT=3000 \
HOST=127.0.0.1 \
NODE_MAJOR=24 \
./setup-pi-api.sh api yourdomain.com
```

Useful options:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PROJECT_DIR` | `$HOME/my-api` | Folder where the Node API is created |
| `SERVICE_NAME` | `my-api` | Name of the systemd service |
| `PORT` | `3000` | Local API port |
| `HOST` | `127.0.0.1` | Local bind address |
| `NODE_MAJOR` | `24` | NodeSource major version to install |
| `TUNNEL_TOKEN` | empty | Cloudflare remote tunnel token |
| `API_KEY` | empty | Optional API key value exposed to the service environment |
| `CORS_ORIGIN` | empty | Optional comma-separated CORS allow-list |

If you already created a Cloudflare Tunnel in the dashboard, get the tunnel token and run:

```bash
TUNNEL_TOKEN='eyJ...' ./setup-pi-api.sh api yourdomain.com
```

Cloudflare shows the token inside a command shaped like:

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
```

Use only the long `eyJ...` token string as `TUNNEL_TOKEN`.

## Full Manual Setup

Use this if you want to understand or perform every step manually.

## 1. SSH Into The Pi

From your Mac:

```bash
ssh pi@raspberrypi.local
```

Or use the Pi's LAN IP:

```bash
ssh pi@192.168.1.123
```

Update the Pi:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg git build-essential
```

## 2. Install Node.js

This guide defaults to Node 24, which is an Active LTS release in the current Node release schedule. Override `NODE_MAJOR` in the script if you need a different supported line.

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
```

Check it:

```bash
node -v
npm -v
```

## 3. Make A Tiny Node API

```bash
mkdir -p ~/my-api
cd ~/my-api
npm init -y
npm install express cors helmet
npm pkg set type="module"
```

Create `server.js`:

```bash
nano server.js
```

Paste:

```js
import express from "express";
import cors from "cors";
import helmet from "helmet";

const app = express();

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || "127.0.0.1";
const PUBLIC_HOSTNAME = process.env.PUBLIC_HOSTNAME || null;

app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));

app.get("/", (req, res) => {
  res.json({
    ok: true,
    service: "raspberry-pi-api",
    publicHostname: PUBLIC_HOSTNAME,
    message: "the little server is awake."
  });
});

app.get("/health", (req, res) => {
  res.json({
    ok: true,
    uptime: process.uptime()
  });
});

app.listen(PORT, HOST, () => {
  console.log(`api running at http://${HOST}:${PORT}`);
});
```

Add a start script:

```bash
npm pkg set scripts.start="node server.js"
```

Test it:

```bash
npm start
```

In another SSH session, or after stopping with `ctrl+c`, test:

```bash
curl http://127.0.0.1:3000/health
```

Expected shape:

```json
{
  "ok": true,
  "uptime": 123.456
}
```

## 4. Run The API As A System Service

This makes the API restart on crash and boot with the Pi.

```bash
sudo nano /etc/systemd/system/my-api.service
```

Paste:

```ini
[Unit]
Description=My Raspberry Pi Node API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/my-api
ExecStart=/usr/bin/node /home/pi/my-api/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOST=127.0.0.1
Environment=PUBLIC_HOSTNAME=api.yourdomain.com

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable my-api
sudo systemctl start my-api
sudo systemctl status my-api
```

View logs:

```bash
journalctl -u my-api -f
```

## 5. Install cloudflared

For Raspberry Pi OS or Debian:

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings

curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt-get update
sudo apt-get install -y cloudflared
```

Check it:

```bash
cloudflared --version
```

## 6. Create A Cloudflare Tunnel

In Cloudflare:

```txt
Cloudflare Dashboard
-> Zero Trust
-> Networks
-> Tunnels, or Connectors -> Cloudflare Tunnels
-> Create a tunnel
```

Choose `Cloudflared` as the connector type and name it something like:

```txt
home-pi-api
```

Cloudflare will show an install command for Linux. It looks like:

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
```

Run that command on the Pi, or use the script with `TUNNEL_TOKEN`.

## 7. Publish Your API Hostname

In the tunnel setup, add a public hostname:

```txt
subdomain:    api
domain:       yourdomain.com
service type: HTTP
service URL:  http://localhost:3000
```

That gives you:

```txt
https://api.yourdomain.com
```

Make sure the service URL points at the Pi-local API, not the public URL.

## 8. Make cloudflared Survive Reboot

If you used Cloudflare's remote tunnel token command:

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
sudo systemctl status cloudflared
```

If you created a locally managed tunnel with `/home/pi/.cloudflared/config.yml`, pass the config path explicitly:

```bash
sudo cloudflared --config /home/pi/.cloudflared/config.yml service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

Passing the config path matters because `sudo` may otherwise make `cloudflared` look under `/root/.cloudflared`.

## 9. Test Both Gates

First test on the Pi:

```bash
curl http://127.0.0.1:3000/health
```

Then test from your Mac or phone, outside the Pi SSH session:

```bash
curl https://api.yourdomain.com/health
```

Expected shape:

```json
{
  "ok": true,
  "uptime": 123.456
}
```

## 10. Recommended Security Settings

Keep the Node app bound to:

```txt
127.0.0.1
```

Do not bind it to `0.0.0.0` unless you intentionally want other LAN machines to reach it directly.

For anything beyond a toy API, add at least one of these:

```txt
API keys
JWT auth
Cloudflare Access
rate limiting
request size limits
strict CORS origins
```

Example request size limit:

```js
app.use(express.json({ limit: "1mb" }));
```

Example API key middleware:

```js
function requireApiKey(req, res, next) {
  const key = req.header("x-api-key");

  if (key !== process.env.API_KEY) {
    return res.status(401).json({ ok: false, error: "unauthorized" });
  }

  next();
}

app.use("/private", requireApiKey);
```

Then add this to the service:

```ini
Environment=API_KEY=change-this-long-random-string
```

Restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart my-api
```

## 11. Deploy Updates From Git

Inside the Pi:

```bash
cd ~/my-api
git pull
npm install
sudo systemctl restart my-api
```

Check:

```bash
systemctl status my-api
curl http://127.0.0.1:3000/health
curl https://api.yourdomain.com/health
```

## Troubleshooting

If `localhost:3000` works on the Pi but the domain does not:

```bash
sudo systemctl status cloudflared
journalctl -u cloudflared -f
```

If the domain gives a Cloudflare error, check the tunnel status in:

```txt
Cloudflare -> Zero Trust -> Networks -> Tunnels
```

If the API service is dead:

```bash
sudo systemctl status my-api
journalctl -u my-api -f
```

If the Pi rebooted and nothing works:

```bash
sudo systemctl enable my-api
sudo systemctl enable cloudflared
sudo systemctl restart my-api
sudo systemctl restart cloudflared
```

If port `3000` is already taken:

```bash
sudo ss -ltnp | grep ':3000'
```

Then rerun the script with a different port:

```bash
PORT=3001 ./setup-pi-api.sh api yourdomain.com
```

## Final Shape

```txt
internet
  |
  v
https://api.yourdomain.com
  |
  v
Cloudflare DNS + Tunnel
  |
  v
cloudflared on Raspberry Pi
  |
  v
http://127.0.0.1:3000
  |
  v
Node/Express API
```

The small gates are:

1. Get `curl http://127.0.0.1:3000/health` working on the Pi.
2. Get the Cloudflare Tunnel connector online.
3. Get `curl https://api.yourdomain.com/health` working from outside the Pi.

## References

- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare tunnel tokens](https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/)
- [Cloudflare tunnel service setup](https://developers.cloudflare.com/tunnel/setup/)
- [Cloudflare run as a service on Linux](https://developers.cloudflare.com/tunnel/advanced/local-management/as-a-service/linux/)
- [Node.js release schedule](https://github.com/nodejs/Release)
