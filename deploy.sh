#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 <Your Name>
#
# This script deploys Traefik (with Let's Encrypt), MariaDB, WordPress, and CiviCRM
# using Docker Compose. It interactively collects all required variables (robust prompts),
# shows a confirmation summary, and proceeds only after explicit approval.
#
# Usage:
#   Interactive:   sudo ./deploy.sh
#   Non-interactive (CI): export all required vars + NONINTERACTIVE=1, e.g.:
#     export DOMAIN="example.org" CRM_DOMAIN="crm.example.org" LE_EMAIL="admin@example.org"
#     export TZ="Europe/Berlin" WP_DB_USER="wpuser" CIVI_DB_USER="civiuser"
#     export WP_ADMIN_USER="wpadmin" CIVI_ADMIN_USER="civiadmin"
#     export BASE="/srv" NETWORK_NAME="web"
#     NONINTERACTIVE=1 sudo ./deploy.sh
#
set -euo pipefail

# Root check
[ "$(id -u)" -eq 0 ] || { echo "Please run as root (or via sudo)."; exit 1; }

#############################################
# 0) Interactive, robust prompts (no defaults)
#############################################

is_tty() { [[ -t 0 ]] && [[ -t 1 ]]; }
trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"   # ltrim
  s="${s%"${s##*[![:space:]]}"}"   # rtrim
  printf '%s' "$s"
}

# Practical regexes (not full RFC)
re_domain='^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
re_email='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
re_user='^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$'
re_dir='^/[^[:space:]]*$'
re_net='^[A-Za-z0-9][A-Za-z0-9_.-]{1,31}$'

ask_required() {
  # usage: ask_required VAR "Question (with example)" "regex" "Error message"
  local __var="$1"; shift
  local __question="$1"; shift
  local __regex="$1"; shift
  local __errmsg="$1"; shift

  local __ans=""
  if is_tty && [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    while true; do
      read -r -p "${__question}: " __ans || true
      __ans="$(trim "$__ans")"
      if [[ -z "$__ans" ]]; then
        echo "Input required. ${__errmsg}"
        continue
      fi
      if [[ -n "$__regex" && ! "$__ans" =~ $__regex ]]; then
        echo "Invalid value: '${__ans}'. ${__errmsg}"
        continue
      fi
      printf -v "$__var" '%s' "$__ans"
      break
    done
  else
    if [[ -z "${!__var:-}" ]]; then
      echo "Error: Variable '$__var' is not set in NONINTERACTIVE mode."
      echo "Set it via environment variable before running this script."
      exit 1
    fi
    local val
    val="$(trim "${!__var}")"
    if [[ -n "$__regex" && ! "$val" =~ $__regex ]]; then
      echo "Error: Variable '$__var' has invalid value '$val' in NONINTERACTIVE mode. ${__errmsg}"
      exit 1
    fi
    printf -v "$__var" '%s' "$val"
  fi
}

# 0.1 Ask for values
if is_tty && [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
  echo "Please provide the required values. Examples are only hints; fields are mandatory."

  ask_required DOMAIN           "Primary domain for WordPress (e.g. example.org)"        "$re_domain" "Provide a valid domain (e.g. example.org)."
  ask_required CRM_DOMAIN       "CiviCRM domain (e.g. crm.example.org)"                  "$re_domain" "Provide a valid subdomain (e.g. crm.example.org)."
  ask_required LE_EMAIL         "Email for Let's Encrypt / admin (e.g. admin@example.org)" "$re_email"  "Provide a valid email address."
  ask_required TZ               "Timezone (e.g. Europe/Berlin)"                          '.+'          "Provide a valid timezone string (e.g. Europe/Berlin)."

  ask_required WP_DB_USER       "WordPress DB user (e.g. wpuser)"                        "$re_user"    "3–32 chars: A–Z a–z 0–9 _ . -"
  ask_required CIVI_DB_USER     "CiviCRM DB user (e.g. civiuser)"                        "$re_user"    "3–32 chars: A–Z a–z 0–9 _ . -"
  ask_required WP_ADMIN_USER    "WordPress admin user (e.g. wpadmin)"                    "$re_user"    "3–32 chars: A–Z a–z 0–9 _ . -"
  ask_required CIVI_ADMIN_USER  "CiviCRM admin user (e.g. civiadmin)"                    "$re_user"    "3–32 chars: A–Z a–z 0–9 _ . -"

  ask_required BASE             "Base directory (absolute, e.g. /srv)"                   "$re_dir"     "Provide an absolute path starting with '/'."
  ask_required NETWORK_NAME     "Docker network name (e.g. web)"                         "$re_net"     "2–32 chars, letters/digits/._-, must not start with '.' or '-'."

  # Optional: sanity check timezone via timedatectl (warn only)
  if command -v timedatectl >/dev/null 2>&1; then
    if ! timedatectl list-timezones 2>/dev/null | grep -qxF "$TZ"; then
      echo "Warning: timezone '$TZ' not found by 'timedatectl list-timezones'. Will try to set it anyway."
    fi
  fi

  # 0.2 Review + edit loop
  while true; do
    echo
    echo "================= Review your values ================="
    printf "  1) DOMAIN            : %s\n" "$DOMAIN"
    printf "  2) CRM_DOMAIN        : %s\n" "$CRM_DOMAIN"
    printf "  3) LE_EMAIL          : %s\n" "$LE_EMAIL"
    printf "  4) TZ                : %s\n" "$TZ"
    printf "  5) WP_DB_USER        : %s\n" "$WP_DB_USER"
    printf "  6) CIVI_DB_USER      : %s\n" "$CIVI_DB_USER"
    printf "  7) WP_ADMIN_USER     : %s\n" "$WP_ADMIN_USER"
    printf "  8) CIVI_ADMIN_USER   : %s\n" "$CIVI_ADMIN_USER"
    printf "  9) BASE              : %s\n" "$BASE"
    printf " 10) NETWORK_NAME      : %s\n" "$NETWORK_NAME"
    echo "======================================================"
    echo "Confirm? [Y]es / [N]o / enter a number to edit (e.g. 3)"
    read -r -p "> " confirm || true
    confirm="$(trim "$confirm")"
    case "${confirm^^}" in
      Y|YES|"") break ;;
      N|NO)
        echo "Aborted by user."
        exit 1
        ;;
      1)  ask_required DOMAIN            "Primary domain (e.g. example.org)"           "$re_domain" "Provide a valid domain." ;;
      2)  ask_required CRM_DOMAIN        "CiviCRM domain (e.g. crm.example.org)"       "$re_domain" "Provide a valid subdomain." ;;
      3)  ask_required LE_EMAIL          "Email for Let's Encrypt/admin"               "$re_email"  "Provide a valid email address." ;;
      4)  ask_required TZ                "Timezone (e.g. Europe/Berlin)"               '.+'         "Provide a timezone string." ;;
      5)  ask_required WP_DB_USER        "WordPress DB user (e.g. wpuser)"             "$re_user"   "3–32 chars: A–Z a–z 0–9 _ . -" ;;
      6)  ask_required CIVI_DB_USER      "CiviCRM DB user (e.g. civiuser)"             "$re_user"   "3–32 chars: A–Z a–z 0–9 _ . -" ;;
      7)  ask_required WP_ADMIN_USER     "WordPress admin user (e.g. wpadmin)"         "$re_user"   "3–32 chars: A–Z a–z 0–9 _ . -" ;;
      8)  ask_required CIVI_ADMIN_USER   "CiviCRM admin user (e.g. civiadmin)"         "$re_user"   "3–32 chars: A–Z a–z 0–9 _ . -" ;;
      9)  ask_required BASE              "Base directory (absolute, e.g. /srv)"        "$re_dir"    "Provide an absolute path." ;;
      10) ask_required NETWORK_NAME      "Docker network name (e.g. web)"              "$re_net"    "2–32 chars; allowed: letters/digits/._-" ;;
      *)  echo "Please enter 'Y', 'N' or a number (1–10)." ;;
    esac
  done
fi

#############################################
# 1) Derived paths
#############################################
SECRETS_DIR="${BASE}/secrets"
SECRETS_FILE="${SECRETS_DIR}/verein.env"

TRAEFIK_DIR="${BASE}/traefik"
STACK_DIR="${BASE}/stack"

# Helpers
randpw () { openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#%^+=-_.' | head -c 24; }
header () { echo -e "\n\033[1;32m==> $*\033[0m"; }
ensure_line () { local line="$1" file="$2"; grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"; }
get_or_set () { local key="$1"; grep -q "^${key}=" "$SECRETS_FILE" 2>/dev/null || echo "${key}=$(randpw)" >> "$SECRETS_FILE"; }
wait_http () {
  local svc="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    if docker run --rm --network "${NETWORK_NAME}" curlimages/curl:8.8.0 -sSf "http://${svc}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

#############################################
# 2) System preparation
#############################################
header "Update system & install base tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw jq

header "Set timezone"
timedatectl set-timezone "$TZ" || echo "Warning: could not set timezone."

#############################################
# 3) Secrets
#############################################
header "Generate / load secrets"
mkdir -p "$SECRETS_DIR"
touch "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

get_or_set "MYSQL_ROOT_PASSWORD"
get_or_set "WP_DB_PASSWORD"
get_or_set "CIVI_DB_PASSWORD"
get_or_set "WP_ADMIN_PASSWORD"
get_or_set "CIVI_ADMIN_PASSWORD"

ensure_line "LE_EMAIL=${LE_EMAIL}" "$SECRETS_FILE"
ensure_line "DOMAIN=${DOMAIN}" "$SECRETS_FILE"
ensure_line "CRM_DOMAIN=${CRM_DOMAIN}" "$SECRETS_FILE"
ensure_line "TZ=${TZ}" "$SECRETS_FILE"
ensure_line "WP_DB_USER=${WP_DB_USER}" "$SECRETS_FILE"
ensure_line "CIVI_DB_USER=${CIVI_DB_USER}" "$SECRETS_FILE"
ensure_line "WP_ADMIN_USER=${WP_ADMIN_USER}" "$SECRETS_FILE"
ensure_line "CIVI_ADMIN_USER=${CIVI_ADMIN_USER}" "$SECRETS_FILE"

# shellcheck disable=SC1090
source "$SECRETS_FILE"

#############################################
# 4) Docker
#############################################
header "Install Docker & Compose (if missing)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi
docker version >/dev/null
docker compose version >/dev/null

#############################################
# 5) Firewall
#############################################
header "Configure UFW (allow 22, 80, 443)"
ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
yes | ufw enable || true

#############################################
# 6) Docker network
#############################################
header "Create Docker network '${NETWORK_NAME}' (if missing)"
docker network create "${NETWORK_NAME}" >/dev/null 2>&1 || true

#############################################
# 7) Traefik
#############################################
header "Deploy Traefik (force HTTPS, no dashboard)"
mkdir -p "${TRAEFIK_DIR}/letsencrypt"
chmod 700 "${TRAEFIK_DIR}/letsencrypt"
touch "${TRAEFIK_DIR}/letsencrypt/acme.json"
chmod 600 "${TRAEFIK_DIR}/letsencrypt/acme.json"

cat > "${TRAEFIK_DIR}/traefik.yml" <<EOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

api:
  dashboard: false

providers:
  docker:
    exposedByDefault: false

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${LE_EMAIL}"
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
EOF

cat > "${TRAEFIK_DIR}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    command:
      - "--configFile=/traefik.yml"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
      - ./traefik.yml:/traefik.yml:ro
    networks:
      - web
networks:
  web:
    external: true
EOF

docker compose -f "${TRAEFIK_DIR}/docker-compose.yml" up -d

#############################################
# 8) App stack (MariaDB + WordPress + CiviCRM)
#############################################
header "Deploy app stack (MariaDB, WordPress, CiviCRM)"
mkdir -p "${STACK_DIR}"

# Stack .env
cat > "${STACK_DIR}/.env" <<EOF
DOMAIN=${DOMAIN}
CRM_DOMAIN=${CRM_DOMAIN}
TZ=${TZ}

# DB root & users
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}

# WordPress DB
WP_DB_NAME=wordpress
WP_DB_USER=${WP_DB_USER}
WP_DB_PASSWORD=${WP_DB_PASSWORD}

# CiviCRM DB
CIVI_DB_NAME=civicrm
CIVI_DB_USER=${CIVI_DB_USER}
CIVI_DB_PASSWORD=${CIVI_DB_PASSWORD}

# WordPress admin
WP_ADMIN_USER=${WP_ADMIN_USER}
WP_ADMIN_PASSWORD=${WP_ADMIN_PASSWORD}
WP_ADMIN_EMAIL=${LE_EMAIL}

# CiviCRM admin (used in the web installer)
CIVI_ADMIN_USER=${CIVI_ADMIN_USER}
CIVI_ADMIN_PASSWORD=${CIVI_ADMIN_PASSWORD}
CIVI_ADMIN_EMAIL=${LE_EMAIL}
EOF
chmod 600 "${STACK_DIR}/.env"

# Compose file
cat > "${STACK_DIR}/docker-compose.yml" <<'EOF'
services:
  db:
    image: mariadb:10.11
    container_name: db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    command: ["mysqld","--character-set-server=utf8mb4","--collation-server=utf8mb4_unicode_ci"]
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 5s
      timeout: 3s
      retries: 30
    volumes:
      - db_data:/var/lib/mysql
      - ./initdb:/docker-entrypoint-initdb.d:ro
    networks:
      - web

  wordpress:
    image: wordpress:latest
    container_name: wp
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: ${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WP_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${WP_DB_NAME}
      WORDPRESS_TABLE_PREFIX: wp_
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_HOME','https://${DOMAIN}');
        define('WP_SITEURL','https://${DOMAIN}');
        define('FORCE_SSL_ADMIN', true);
        if (strpos($$_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '', 'https') !== false) {
          $$_SERVER['HTTPS']='on';
        }
    volumes:
      - wp_data:/var/www/html
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wp.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.wp.entrypoints=websecure"
      - "traefik.http.routers.wp.tls.certresolver=letsencrypt"
      - "traefik.http.services.wp.loadbalancer.server.port=80"
    networks:
      - web

  civicrm:
    image: civicrm/civicrm:latest
    container_name: civicrm
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      TZ: ${TZ}
    volumes:
      - civicrm_public:/var/www/html/public
      - civicrm_private:/var/www/html/private
      - civicrm_ext:/var/www/html/ext
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.civi.rule=Host(`${CRM_DOMAIN}`)"
      - "traefik.http.routers.civi.entrypoints=websecure"
      - "traefik.http.routers.civi.tls.certresolver=letsencrypt"
      - "traefik.http.services.civi.loadbalancer.server.port=80"
    networks:
      - web

volumes:
  db_data:
  wp_data:
  civicrm_public:
  civicrm_private:
  civicrm_ext:

networks:
  web:
    external: true
EOF

# DB init SQL
mkdir -p "${STACK_DIR}/initdb"
cat > "${STACK_DIR}/initdb/00-init.sql" <<EOF
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME:-wordpress}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`${CIVI_DB_NAME:-civicrm}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'%' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME:-wordpress}\`.* TO '${WP_DB_USER}'@'%';

CREATE USER IF NOT EXISTS '${CIVI_DB_USER}'@'%' IDENTIFIED BY '${CIVI_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${CIVI_DB_NAME:-civicrm}\`.* TO '${CIVI_DB_USER}'@'%';

FLUSH PRIVILEGES;
EOF

docker compose -f "${STACK_DIR}/docker-compose.yml" --env-file "${STACK_DIR}/.env" pull
docker compose -f "${STACK_DIR}/docker-compose.yml" --env-file "${STACK_DIR}/.env" up -d

#############################################
# 9) WordPress initial install via wp-cli
#############################################
header "Initial WordPress install via wp-cli"
set -a
# shellcheck disable=SC1091
. "${STACK_DIR}/.env"
set +a

echo "Waiting for WordPress/DB..."
wait_http "wp" 60 || echo "Warning: could not reach 'wp' via HTTP, attempting installation anyway."

docker run --rm \
  --network "${NETWORK_NAME}" \
  -v wp_data:/var/www/html \
  -e WORDPRESS_DB_HOST=db \
  -e WORDPRESS_DB_USER="${WP_DB_USER}" \
  -e WORDPRESS_DB_PASSWORD="${WP_DB_PASSWORD}" \
  -e WORDPRESS_DB_NAME="${WP_DB_NAME}" \
  wordpress:cli php -d memory_limit=256M /usr/local/bin/wp core install \
    --url="https://${DOMAIN}" \
    --title="Organisation ID" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${LE_EMAIL}" \
    --skip-email || true

# Ensure SSL options in WP
docker run --rm --network "${NETWORK_NAME}" -v wp_data:/var/www/html wordpress:cli \
  /usr/local/bin/wp option update home "https://${DOMAIN}" || true
docker run --rm --network "${NETWORK_NAME}" -v wp_data:/var/www/html wordpress:cli \
  /usr/local/bin/wp option update siteurl "https://${DOMAIN}" || true

#############################################
# 10) Final info
#############################################
header "Done! Credentials & installer hints"
echo "Secrets file: ${SECRETS_FILE} (chmod 600)"
echo
echo "== WordPress =="
echo "URL:   https://${DOMAIN}"
echo "User:  ${WP_ADMIN_USER}"
echo "Pass:  ${WP_ADMIN_PASSWORD}"
echo
echo "== CiviCRM (Web installer) =="
echo "URL:   https://${CRM_DOMAIN}"
echo
echo "Use in installer:"
echo "  Server (Host): db"
echo "  Database (Name): civicrm"
echo "  Username: ${CIVI_DB_USER}"
echo "  Password: ${CIVI_DB_PASSWORD}"
echo "  Base URL: https://${CRM_DOMAIN}"
echo "  Public files:  /var/www/html/public"
echo "  Private files: /var/www/html/private"
echo "  Extensions:    /var/www/html/ext"
echo
echo "Civi admin account:"
echo "  User:  ${CIVI_ADMIN_USER}"
echo "  Pass:  ${CIVI_ADMIN_PASSWORD}"
echo "  Email: ${LE_EMAIL}"
echo
echo "== MariaDB root =="
echo "Root password: ${MYSQL_ROOT_PASSWORD}"
echo
echo "Troubleshooting:"
echo "- Traefik (ACME):     docker logs traefik --since 3m | egrep -i 'acme|certificate|challenge'"
echo "- Network check:      docker network inspect ${NETWORK_NAME} | grep Name"
echo "- DB health:          docker ps   (db should be 'healthy')"
