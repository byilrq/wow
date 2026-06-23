#!/usr/bin/env bash
set -euo pipefail

#==========================================================
# wow.sh - 黑石 WoW 注册站一键部署 + Nginx 游戏流量转发
#
# 职责：
# - 安装/更新网站依赖：Nginx、PHP 8.2、PHP 扩展、git、rsync。
# - 从 GitHub 仓库直接拉取新版网站源码到 /www/wow。
# - 写入 WoW 注册站 Nginx 配置。
# - 保留旧版通过 VPS 转发游戏流量的能力：TCP 3724 / 8085 -> 真实游戏服务器。
# - 如果系统已安装 Nginx/PHP，不重复破坏安装，只更新必要配置并 reload。
#
# 默认：
# - 站点目录：/www/wow
# - 默认域名：sharq.eu.org
# - 默认网站模式：local_proxy，Nginx 只监听 127.0.0.1:8080
# - 默认游戏转发：开启，目标 byilrq.iok.la:3724 / byilrq.iok.la:8085
#==========================================================

DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-sharq.eu.org}"
WEB_ROOT="${WEB_ROOT:-/www/wow}"
PHP_VER="${PHP_VER:-8.2}"
EMAIL="${EMAIL:-byilrq@gmail.com}"
REPO_URL="${REPO_URL:-https://github.com/byilrq/wow.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DOMAIN_STATE_FILE="/etc/wow_domain.conf"

# local_proxy：适合 443 被 Hysteria / Xray / Caddy 占用的机器。
# public_https：Nginx 直接监听 80/443 并申请证书。
WOW_BIND_MODE="${WOW_BIND_MODE:-local_proxy}"
LOCAL_BIND_HOST="${LOCAL_BIND_HOST:-127.0.0.1}"
LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-8080}"

# 游戏 TCP 转发。玩家 realmlist 指向这台 VPS，再由 Nginx stream 转发到真实游戏服务器。
GAME_PROXY_ENABLE="${GAME_PROXY_ENABLE:-true}"
GAME_PROXY_TARGET_HOST="${GAME_PROXY_TARGET_HOST:-byilrq.iok.la}"
GAME_PROXY_AUTH_PORT="${GAME_PROXY_AUTH_PORT:-3724}"
GAME_PROXY_WORLD_PORT="${GAME_PROXY_WORLD_PORT:-8085}"

log() { echo -e "\n==> $*"; }
require_root() { [[ ${EUID:-1000} -eq 0 ]] || { echo "请使用 root 运行：sudo bash wow.sh"; exit 1; }; }
backup_file() { [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" || true; }
get_saved_domain() { [[ -f "$DOMAIN_STATE_FILE" ]] && tr -d '\r\n' < "$DOMAIN_STATE_FILE" || echo "$DEFAULT_DOMAIN"; }
save_domain() { echo "$1" > "$DOMAIN_STATE_FILE"; }

get_os_info() {
  local id="" codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    codename="${VERSION_CODENAME:-}"
  fi
  [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1 && codename="$(lsb_release -sc)"
  [[ -z "$codename" ]] && codename="bullseye"
  echo "$id|$codename"
}

apt_install() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

cleanup_bad_repos() {
  rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*php*ppa* 2>/dev/null || true
}

setup_php_repo() {
  local os_id codename
  IFS='|' read -r os_id codename <<<"$(get_os_info)"
  cleanup_bad_repos

  if [[ "$os_id" == "debian" ]]; then
    log "配置 Debian Sury PHP 源：$codename"
    apt_install ca-certificates curl gnupg lsb-release
    curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i /tmp/debsuryorg-archive-keyring.deb
    rm -f /tmp/debsuryorg-archive-keyring.deb
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${codename} main" > /etc/apt/sources.list.d/php-sury.list
    apt-get update -y
  elif [[ "$os_id" == "ubuntu" ]]; then
    log "配置 Ubuntu ondrej/php PPA"
    apt_install software-properties-common ca-certificates curl gnupg lsb-release
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
  else
    log "未识别 Debian/Ubuntu，将尝试使用系统默认 PHP 包"
  fi
}

open_tcp_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" || true
    firewall-cmd --reload || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
  fi
}

open_firewall_ports() {
  [[ "$WOW_BIND_MODE" == "public_https" ]] && { open_tcp_port 80; open_tcp_port 443; }
  if [[ "$GAME_PROXY_ENABLE" == "true" ]]; then
    open_tcp_port "$GAME_PROXY_AUTH_PORT"
    open_tcp_port "$GAME_PROXY_WORLD_PORT"
  fi
}

deploy_source() {
  log "从 GitHub 拉取网站源码：$REPO_URL ($REPO_BRANCH)"
  local tmp="/tmp/wow_repo_new"
  rm -rf "$tmp"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$tmp"

  mkdir -p "$WEB_ROOT"
  rsync -a --delete "$tmp/" "$WEB_ROOT/"

  if [[ ! -f "$WEB_ROOT/public/index.php" ]]; then
    echo "部署失败：仓库中没有 public/index.php，请确认 GitHub 仓库已上传新版程序包。"
    exit 1
  fi

  mkdir -p "$WEB_ROOT/storage" "$WEB_ROOT/public/downloads"
  [[ -f "$WEB_ROOT/storage/announcements.json" ]] || echo '[]' > "$WEB_ROOT/storage/announcements.json"

  # 登录器下载：GitHub 仓库根目录若存在 WOWOL.bat，则复制到 public/downloads 供 Web 下载。
  if [[ -f "$WEB_ROOT/WOWOL.bat" ]]; then
    cp -f "$WEB_ROOT/WOWOL.bat" "$WEB_ROOT/public/downloads/WOWOL.bat"
  elif [[ -f "$WEB_ROOT/public/WOWOL.bat" ]]; then
    cp -f "$WEB_ROOT/public/WOWOL.bat" "$WEB_ROOT/public/downloads/WOWOL.bat"
  fi

  chown -R www-data:www-data "$WEB_ROOT" || true
  find "$WEB_ROOT" -type d -exec chmod 755 {} \; || true
  find "$WEB_ROOT" -type f -exec chmod 644 {} \; || true
}

ensure_env() {
  local domain="$1"
  local env_file="$WEB_ROOT/.env"
  [[ -f "$env_file" ]] || cp "$WEB_ROOT/.env.example" "$env_file" 2>/dev/null || touch "$env_file"

  upsert_env "$env_file" APP_URL "${APP_URL:-https://$domain}"
  upsert_env "$env_file" APP_NAME "${APP_NAME:-黑石}"
  upsert_env "$env_file" REALMLIST "${REALMLIST:-$domain}"
  upsert_env "$env_file" PATCH_LOCATION "${PATCH_LOCATION:-/downloads/WOWOL.bat}"
  upsert_env "$env_file" LAUNCHER_FILE "${LAUNCHER_FILE:-downloads/WOWOL.bat}"
  upsert_env "$env_file" LAUNCHER_LABEL "${LAUNCHER_LABEL:-登录器下载}"
  upsert_env "$env_file" DB_AUTH_HOST "${DB_AUTH_HOST:-byilrq.iok.la}"
  upsert_env "$env_file" DB_AUTH_PORT "${DB_AUTH_PORT:-58006}"
  upsert_env "$env_file" DB_AUTH_DATABASE "${DB_AUTH_DATABASE:-acore_auth}"
  upsert_env "$env_file" DB_AUTH_USERNAME "${DB_AUTH_USERNAME:-admin}"
  upsert_env "$env_file" DB_AUTH_PASSWORD "${DB_AUTH_PASSWORD:-Plex0819$}"
  upsert_env "$env_file" REALM_1_NAME "${REALM_1_NAME:-黑石}"
  upsert_env "$env_file" REALM_1_HOST "${REALM_1_HOST:-${DB_AUTH_HOST:-byilrq.iok.la}}"
  upsert_env "$env_file" REALM_1_PORT "${REALM_1_PORT:-${DB_AUTH_PORT:-58006}}"
  upsert_env "$env_file" REALM_1_DATABASE "${REALM_1_DATABASE:-acore_characters}"
  upsert_env "$env_file" REALM_1_USERNAME "${REALM_1_USERNAME:-${DB_AUTH_USERNAME:-admin}}"
  upsert_env "$env_file" REALM_1_PASSWORD "${REALM_1_PASSWORD:-${DB_AUTH_PASSWORD:-Plex0819$}}"
  upsert_env "$env_file" CAPTCHA_TYPE "${CAPTCHA_TYPE:-1}"
  upsert_env "$env_file" CAPTCHA_KEY "${CAPTCHA_KEY:-10b6462c-973a-458c-84f4-6c60794e2a78}"
  upsert_env "$env_file" CAPTCHA_SECRET "${CAPTCHA_SECRET:-ES_9278a8805838434c9fa776e49af64355}"
  upsert_env "$env_file" CAPTCHA_LANGUAGE "${CAPTCHA_LANGUAGE:-en}"
  upsert_env "$env_file" ANNOUNCEMENT_PIN "${ANNOUNCEMENT_PIN:-0819}"
  upsert_env "$env_file" GAME_PROXY_ENABLE "$GAME_PROXY_ENABLE"
  upsert_env "$env_file" GAME_PROXY_TARGET_HOST "$GAME_PROXY_TARGET_HOST"
  upsert_env "$env_file" GAME_PROXY_AUTH_PORT "$GAME_PROXY_AUTH_PORT"
  upsert_env "$env_file" GAME_PROXY_WORLD_PORT "$GAME_PROXY_WORLD_PORT"

  chown www-data:www-data "$env_file" || true
  chmod 640 "$env_file" || true
}

upsert_env() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

configure_php() {
  local pool="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
  local allowed="${WEB_ROOT}/:/tmp/:/var/www/html/"
  if [[ -f "$pool" ]]; then
    backup_file "$pool"
    if grep -Eq '^\s*php_admin_value\[open_basedir\]\s*=' "$pool"; then
      sed -ri "s|^\s*php_admin_value\[open_basedir\]\s*=.*|php_admin_value[open_basedir] = ${allowed}|g" "$pool"
    else
      echo "php_admin_value[open_basedir] = ${allowed}" >> "$pool"
    fi
  fi
  systemctl restart "php${PHP_VER}-fpm" || true
}

enable_nginx_site() {
  ln -sf /etc/nginx/sites-available/wow /etc/nginx/sites-enabled/wow
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl reload nginx || true
}

write_nginx_site_local() {
  local domain="$1"
  cat > /etc/nginx/sites-available/wow <<EOF_SITE
server {
    listen ${LOCAL_BIND_HOST}:${LOCAL_HTTP_PORT};
    server_name ${domain} localhost 127.0.0.1 _;

    root ${WEB_ROOT}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location ~ /\. { deny all; }
    access_log /var/log/nginx/wow_access.log;
    error_log  /var/log/nginx/wow_error.log;
}
EOF_SITE
  enable_nginx_site
}

write_nginx_site_http() {
  local domain="$1"
  cat > /etc/nginx/sites-available/wow <<EOF_SITE
server {
    listen 80;
    server_name ${domain};
    root ${WEB_ROOT}/public;
    index index.php index.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT}/public;
        default_type "text/plain";
        allow all;
    }

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock; }
    location ~ /\. { deny all; }
    access_log /var/log/nginx/wow_access.log;
    error_log  /var/log/nginx/wow_error.log;
}
EOF_SITE
  enable_nginx_site
}

write_nginx_site_https() {
  local domain="$1"
  mkdir -p /etc/nginx/snippets
  cat > "/etc/nginx/snippets/ssl-${domain}.conf" <<EOF_SSL
ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
EOF_SSL
  cat > /etc/nginx/sites-available/wow <<EOF_SITE
server {
    listen 80;
    server_name ${domain};
    root ${WEB_ROOT}/public;
    location ^~ /.well-known/acme-challenge/ { root ${WEB_ROOT}/public; default_type "text/plain"; allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name ${domain};
    include /etc/nginx/snippets/ssl-${domain}.conf;
    root ${WEB_ROOT}/public;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock; }
    location ~ /\. { deny all; }
    access_log /var/log/nginx/wow_access.log;
    error_log  /var/log/nginx/wow_error.log;
}
EOF_SITE
  enable_nginx_site
}

ensure_nginx_stream_include() {
  local nginx_conf="/etc/nginx/nginx.conf"
  mkdir -p /etc/nginx/stream-conf.d
  [[ -f "$nginx_conf" ]] || return 0

  # 如果主配置还没有 stream 块，则追加一个专门 include 目录。
  if ! grep -qE '^\s*stream\s*\{' "$nginx_conf"; then
    backup_file "$nginx_conf"
    cat >> "$nginx_conf" <<'EOF_STREAM'

# WoW 游戏 TCP 转发配置入口，由 wow.sh 管理。
stream {
    include /etc/nginx/stream-conf.d/*.conf;
}
EOF_STREAM
  elif ! grep -q '/etc/nginx/stream-conf.d/\*.conf' "$nginx_conf"; then
    echo "⚠️ 检测到 nginx.conf 已有 stream 块，但未包含 /etc/nginx/stream-conf.d/*.conf。"
    echo "   请确认你的 stream 块中包含：include /etc/nginx/stream-conf.d/*.conf;"
  fi
}

write_game_proxy_config() {
  if [[ "$GAME_PROXY_ENABLE" != "true" ]]; then
    rm -f /etc/nginx/stream-conf.d/wow-game-proxy.conf || true
    return 0
  fi

  ensure_nginx_stream_include
  cat > /etc/nginx/stream-conf.d/wow-game-proxy.conf <<EOF_STREAM_CONF
# WoW 游戏流量转发：玩家连接本 VPS，Nginx 转发到真实游戏服务器。
# 来源：旧版 nginx.conf 中的 stream 转发功能，保留 3724 / 8085。
server {
    listen ${GAME_PROXY_AUTH_PORT};
    proxy_pass ${GAME_PROXY_TARGET_HOST}:${GAME_PROXY_AUTH_PORT};
    proxy_timeout 300s;
    proxy_connect_timeout 10s;
}

server {
    listen ${GAME_PROXY_WORLD_PORT};
    proxy_pass ${GAME_PROXY_TARGET_HOST}:${GAME_PROXY_WORLD_PORT};
    proxy_timeout 300s;
    proxy_connect_timeout 10s;
}
EOF_STREAM_CONF
}

obtain_cert() {
  local domain="$1"
  # 检查本地已有 Let's Encrypt 证书（与 x.sh/h.sh 共用）
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    green "检测到已有 Let's Encrypt 证书：/etc/letsencrypt/live/${domain}/，跳过申请直接复用"
    return 0
  fi
  apt_install certbot
  mkdir -p "$WEB_ROOT/public/.well-known/acme-challenge"
  if [[ "$WOW_BIND_MODE" == "public_https" ]]; then
    write_nginx_site_http "$domain"
  fi
  certbot certonly --agree-tos -m "$EMAIL" --webroot -w "$WEB_ROOT/public" -d "$domain"
}

install_or_update() {
  local domain="$1"
  [[ "$WOW_BIND_MODE" == "local_proxy" || "$WOW_BIND_MODE" == "public_https" ]] || { echo "WOW_BIND_MODE 只能是 local_proxy 或 public_https"; exit 1; }

  log "检查系统 Nginx/PHP 状态"
  local need_nginx="n"
  local need_php="n"
  if ! command -v nginx >/dev/null 2>&1; then
    need_nginx="y"
  else
    log "检测到系统已有 nginx，跳过安装"
  fi
  if ! command -v "php${PHP_VER}-fpm" >/dev/null 2>&1 && ! systemctl list-unit-files 2>/dev/null | grep -q "php${PHP_VER}-fpm"; then
    need_php="y"
  else
    log "检测到系统已有 PHP ${PHP_VER}，跳过安装"
  fi

  if [[ "$need_nginx" == "y" || "$need_php" == "y" ]]; then
    log "安装基础依赖与 Nginx"
    apt_install ca-certificates curl rsync git gnupg lsb-release
    [[ "$need_nginx" == "y" ]] && apt_install nginx
    apt_install libnginx-mod-stream || true

    if [[ "$need_php" == "y" ]]; then
      setup_php_repo
      apt_install "php${PHP_VER}" "php${PHP_VER}-cli" "php${PHP_VER}-fpm" "php${PHP_VER}-mysql" "php${PHP_VER}-gmp" "php${PHP_VER}-curl" "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" "php${PHP_VER}-zip" "php${PHP_VER}-soap"
    fi

    systemctl enable nginx "php${PHP_VER}-fpm" || true
  fi
  open_firewall_ports
  deploy_source
  ensure_env "$domain"
  configure_php
  write_game_proxy_config

  if [[ "$WOW_BIND_MODE" == "local_proxy" ]]; then
    write_nginx_site_local "$domain"
    echo "✅ 网站安装/更新完成：本机 http://${LOCAL_BIND_HOST}:${LOCAL_HTTP_PORT}/"
    echo "✅ 游戏转发：${GAME_PROXY_ENABLE}，${GAME_PROXY_AUTH_PORT}/${GAME_PROXY_WORLD_PORT} -> ${GAME_PROXY_TARGET_HOST}"
    echo "公网 HTTPS 如由 Hysteria 接管，请在 Hysteria 里把本地伪装站指向 http://${LOCAL_BIND_HOST}:${LOCAL_HTTP_PORT}"
  else
    write_nginx_site_http "$domain"
    obtain_cert "$domain"
    write_nginx_site_https "$domain"
    echo "✅ 网站安装/更新完成：https://${domain}/"
    echo "✅ 游戏转发：${GAME_PROXY_ENABLE}，${GAME_PROXY_AUTH_PORT}/${GAME_PROXY_WORLD_PORT} -> ${GAME_PROXY_TARGET_HOST}"
  fi
  save_domain "$domain"
}

change_domain() {
  local old new
  old="$(get_saved_domain)"
  read -rp "当前域名 ${old}，请输入新域名（回车取消）：" new
  [[ -z "$new" ]] && return 0
  ensure_env "$new"
  if [[ "$WOW_BIND_MODE" == "local_proxy" ]]; then
    write_nginx_site_local "$new"
  else
    write_nginx_site_http "$new"
    obtain_cert "$new"
    write_nginx_site_https "$new"
  fi
  save_domain "$new"
  echo "✅ 域名已修改：${old} -> ${new}"
}

renew_cert() {
  if [[ "$WOW_BIND_MODE" == "local_proxy" ]]; then
    echo "local_proxy 模式下公网 HTTPS 通常由 Hysteria/其他代理管理，本脚本不续签代理证书。"
    return 0
  fi
  apt_install certbot
  certbot renew --quiet --deploy-hook "systemctl reload nginx" || true
  echo "✅ 已执行 certbot renew。"
}

menu() {
  require_root
  local saved
  saved="$(get_saved_domain)"
  echo "=========================================="
  echo " 黑石 WoW 注册站管理菜单"
  echo " 当前记录域名：${saved}"
  echo " 站点目录：${WEB_ROOT}"
  echo " GitHub：${REPO_URL}"
  echo " 网站模式：${WOW_BIND_MODE}"
  echo " 本地监听：${LOCAL_BIND_HOST}:${LOCAL_HTTP_PORT}"
  echo " 游戏转发：${GAME_PROXY_ENABLE} -> ${GAME_PROXY_TARGET_HOST}:${GAME_PROXY_AUTH_PORT}/${GAME_PROXY_WORLD_PORT}"
  echo "=========================================="
  echo "1) 一键安装 / 更新网站"
  echo "2) 修改域名"
  echo "3) 更新证书（仅 public_https 模式）"
  echo "0) 退出"
  echo "------------------------------------------"
  read -rp "请输入选项编号：" choice
  case "$choice" in
    1)
      echo ""
      echo "请选择网站监听模式："
      echo " 1) 本机监听（默认）: http://127.0.0.1:8080"
      echo "    适合 Hysteria / Xray / Caddy 已占用公网 443 的服务器。"
      echo "    公网 HTTPS 由其他代理软件管理，Nginx 只监听本机 8080。"
      echo ""
      echo " 2) 公网 80/443: Nginx 直接管理 HTTPS"
      echo "    适合没有其他代理软件占用 443 的服务器。"
      echo "    脚本将自动申请 Let's Encrypt 证书并配置 HTTPS。"
      echo ""
      read -rp "请选择 [1/2]（回车默认 1）: " mode_choice
      if [[ "$mode_choice" == "2" ]]; then
        WOW_BIND_MODE="public_https"
      else
        WOW_BIND_MODE="local_proxy"
      fi
      read -rp "请输入域名（回车默认 ${DEFAULT_DOMAIN}）：" input_domain
      install_or_update "${input_domain:-$DEFAULT_DOMAIN}"
      ;;
    2) change_domain ;;
    3) renew_cert ;;
    0) echo "已退出。" ;;
    *) echo "无效选项。"; exit 1 ;;
  esac
}

menu
