#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./setup-pi-api.sh <root-domain>
  ./setup-pi-api.sh <public-hostname>
  ./setup-pi-api.sh <subdomain> <root-domain>

Examples:
  ./setup-pi-api.sh yourdomain.com
  ./setup-pi-api.sh api.yourdomain.com
  ./setup-pi-api.sh api yourdomain.com
  TUNNEL_TOKEN='eyJ...' ./setup-pi-api.sh api yourdomain.com

Environment overrides:
  PROJECT_DIR=/home/pi/my-api
  SERVICE_NAME=my-api
  PORT=3000
  HOST=127.0.0.1
  NODE_MAJOR=24
  TUNNEL_TOKEN=eyJ...
  API_KEY=change-this-long-random-string
  CORS_ORIGIN=https://yourdomain.com
USAGE
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARN: %s\n' "$*" >&2
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

domain_label_count() {
  local value="$1"
  local dots="${value//[^.]}"
  printf '%s' "$((${#dots} + 1))"
}

resolve_public_hostname() {
  if [[ "$#" -eq 1 ]]; then
    local value="${1%.}"
    if [[ "$(domain_label_count "$value")" -eq 2 ]]; then
      printf 'api.%s' "$value"
    else
      printf '%s' "$value"
    fi
  elif [[ "$#" -eq 2 ]]; then
    local subdomain="${1%.}"
    local root_domain="${2%.}"
    if [[ "$subdomain" == "@" ]]; then
      printf '%s' "$root_domain"
    else
      printf '%s.%s' "$subdomain" "$root_domain"
    fi
  else
    usage
    exit 2
  fi
}

validate_public_hostname() {
  local hostname="$1"
  [[ "${#hostname}" -le 253 ]] || die "Hostname is too long: $hostname"
  [[ "$hostname" == *.* ]] || die "Hostname must contain at least one dot: $hostname"
  [[ "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || die "Invalid hostname: $hostname"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "PORT must be a number: $port"
  ((port > 0 && port < 65536)) || die "PORT must be between 1 and 65535: $port"
}

validate_service_name() {
  local service_name="$1"
  [[ "$service_name" =~ ^[A-Za-z0-9_.@-]+$ ]] \
    || die "SERVICE_NAME can only contain letters, numbers, dot, underscore, dash, and @"
}

systemd_env_line() {
  local key="$1"
  local value="$2"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf 'Environment="%s=%s"\n' "$key" "$value"
}

write_if_changed() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"

  if [[ -f "$target_file" ]] && ! cmp -s "$source_file" "$target_file"; then
    local backup_file="${target_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$target_file" "$backup_file"
    log "Backed up existing $target_file to $backup_file"
  fi

  install -m "$mode" "$source_file" "$target_file"
}

install_base_packages() {
  log "Installing base packages"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg git build-essential
}

install_node() {
  local current_major=""

  if command -v node >/dev/null 2>&1; then
    current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  fi

  if [[ "$current_major" == "$NODE_MAJOR" ]]; then
    log "Node.js $NODE_MAJOR is already installed"
    return
  fi

  log "Installing Node.js $NODE_MAJOR from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs
}

write_server_file() {
  local tmp_file
  tmp_file="$(mktemp)"

  cat >"$tmp_file" <<'SERVER_JS'
import express from "express";
import cors from "cors";
import helmet from "helmet";

const app = express();

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || "127.0.0.1";
const PUBLIC_HOSTNAME = process.env.PUBLIC_HOSTNAME || null;
const CORS_ORIGIN = process.env.CORS_ORIGIN || "";

const corsOptions = CORS_ORIGIN
  ? { origin: CORS_ORIGIN.split(",").map((origin) => origin.trim()) }
  : {};

app.use(helmet());
app.use(cors(corsOptions));
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
SERVER_JS

  write_if_changed "$tmp_file" "$PROJECT_DIR/server.js" "0644"
  rm -f "$tmp_file"
}

setup_node_api() {
  log "Creating Node API in $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
  cd "$PROJECT_DIR"

  if [[ ! -f package.json ]]; then
    npm init -y
  fi

  npm pkg set type="module"
  npm pkg set scripts.start="node server.js"
  npm install express cors helmet
  write_server_file
}

install_api_service() {
  local node_bin
  local tmp_file
  local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

  node_bin="$(command -v node)"
  tmp_file="$(mktemp)"

  log "Writing systemd service $SERVICE_NAME"

  {
    printf '[Unit]\n'
    printf 'Description=Raspberry Pi Node API\n'
    printf 'After=network-online.target\n'
    printf 'Wants=network-online.target\n\n'
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'User=%s\n' "$APP_USER"
    printf 'WorkingDirectory=%s\n' "$PROJECT_DIR"
    printf 'ExecStart=%s %s/server.js\n' "$node_bin" "$PROJECT_DIR"
    printf 'Restart=always\n'
    printf 'RestartSec=5\n'
    systemd_env_line "NODE_ENV" "production"
    systemd_env_line "PORT" "$PORT"
    systemd_env_line "HOST" "$HOST"
    systemd_env_line "PUBLIC_HOSTNAME" "$PUBLIC_HOSTNAME"
    [[ -n "${API_KEY:-}" ]] && systemd_env_line "API_KEY" "$API_KEY"
    [[ -n "${CORS_ORIGIN:-}" ]] && systemd_env_line "CORS_ORIGIN" "$CORS_ORIGIN"
    printf '\n[Install]\n'
    printf 'WantedBy=multi-user.target\n'
  } >"$tmp_file"

  sudo install -m 0644 "$tmp_file" "$service_file"
  rm -f "$tmp_file"

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared is already installed"
    return
  fi

  log "Installing cloudflared from Cloudflare's apt repository"
  sudo mkdir -p --mode=0755 /usr/share/keyrings

  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y cloudflared
}

install_cloudflared_service_from_token() {
  if [[ -z "${TUNNEL_TOKEN:-}" ]]; then
    warn "TUNNEL_TOKEN was not provided, so the Cloudflare connector service was not installed."
    return
  fi

  log "Installing Cloudflare Tunnel connector service from TUNNEL_TOKEN"

  if systemctl cat cloudflared.service >/dev/null 2>&1; then
    warn "cloudflared.service already exists. Leaving the existing service installed."
    sudo systemctl enable cloudflared
    sudo systemctl restart cloudflared
    return
  fi

  sudo cloudflared service install "$TUNNEL_TOKEN"
  sudo systemctl enable cloudflared
  sudo systemctl start cloudflared
}

test_local_api() {
  local check_host="$HOST"
  [[ "$check_host" == "0.0.0.0" ]] && check_host="127.0.0.1"

  log "Testing local API health endpoint"
  sleep 2

  if curl -fsS "http://${check_host}:${PORT}/health"; then
    printf '\n'
  else
    warn "Local health check failed. Check logs with: journalctl -u ${SERVICE_NAME} -f"
  fi
}

print_next_steps() {
  cat <<NEXT_STEPS

Setup finished.

Local API:
  http://${HOST}:${PORT}
  http://${HOST}:${PORT}/health

Public API target:
  https://${PUBLIC_HOSTNAME}
  https://${PUBLIC_HOSTNAME}/health

Cloudflare public hostname settings:
  Hostname:     ${PUBLIC_HOSTNAME}
  Service type: HTTP
  Service URL:  http://localhost:${PORT}

Useful commands:
  sudo systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  sudo systemctl status cloudflared
  journalctl -u cloudflared -f

NEXT_STEPS

  if [[ -z "${TUNNEL_TOKEN:-}" ]]; then
    cat <<'TOKEN_STEPS'
Next Cloudflare step:
  1. Open Cloudflare Dashboard -> Zero Trust -> Networks -> Tunnels.
  2. Create or open a Cloudflared tunnel.
  3. Add the public hostname shown above.
  4. Copy the Linux connector token command.
  5. Rerun this script with TUNNEL_TOKEN set, or run Cloudflare's command directly.

Example:
  TUNNEL_TOKEN='eyJ...' ./setup-pi-api.sh api yourdomain.com

TOKEN_STEPS
  else
    cat <<TOKEN_DONE
Cloudflare connector:
  TUNNEL_TOKEN was provided, so the script attempted to install/start cloudflared.service.
  Confirm the connector is online in Cloudflare, then test:
    curl https://${PUBLIC_HOSTNAME}/health

TOKEN_DONE
  fi
}

main() {
  PUBLIC_HOSTNAME="$(resolve_public_hostname "$@")"
  PROJECT_DIR="${PROJECT_DIR:-$HOME/my-api}"
  SERVICE_NAME="${SERVICE_NAME:-my-api}"
  PORT="${PORT:-3000}"
  HOST="${HOST:-127.0.0.1}"
  NODE_MAJOR="${NODE_MAJOR:-24}"
  APP_USER="${APP_USER:-$(id -un)}"

  validate_public_hostname "$PUBLIC_HOSTNAME"
  validate_port "$PORT"
  validate_service_name "$SERVICE_NAME"

  [[ "$EUID" -ne 0 ]] || die "Run this as a normal user with sudo access, not as root."
  [[ -d /etc/apt ]] || die "This script expects Raspberry Pi OS, Debian, or Ubuntu with apt."
  [[ "$PROJECT_DIR" != *" "* ]] || die "PROJECT_DIR must not contain spaces: $PROJECT_DIR"

  require_command sudo
  require_command apt-get
  id "$APP_USER" >/dev/null 2>&1 || die "APP_USER does not exist: $APP_USER"

  sudo -v

  install_base_packages
  require_command curl
  install_node
  require_command npm
  setup_node_api
  install_api_service
  install_cloudflared
  install_cloudflared_service_from_token
  test_local_api
  print_next_steps
}

main "$@"
