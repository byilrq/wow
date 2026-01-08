#!/usr/bin/env bash
set -euo pipefail

#==========================================================
# wow.sh - WoW注册站一键部署（Debian bullseye 适配版）
#
# 特性：
# - 启动时提示输入域名，回车默认 sharq.eu.org
# - 自动放行 80/443（尽量：ufw / firewalld / nftables / iptables）
# - Debian 使用 Sury PHP 源安装 PHP 8.2
# - 下载并解压 html.rar 到 /www/wow
# - 仅限制 PHP-FPM 的 open_basedir（不影响 CLI/composer）
# - certbot webroot 签证书，启用 HTTPS 443
# - 自动把 application/config/config.php 里的 https://sharq.eu.org 替换为新域名
#==========================================================

DEFAULT_DOMAIN="sharq.eu.org"
WEB_ROOT="${WEB_ROOT:-/www/wow}"
PHP_VER="${PHP_VER:-8.2}"

REPO_RAW_BASE="https://raw.githubusercontent.com/byilrq/wow/main"
ARCHIVE_URL="${REPO_RAW_BASE}/html.rar"
PHP_INI_URL="${REPO_RAW_BASE}/php.ini"

# 你现在 config.php 里默认写死的是这个域名（你已经改为 https://sharq.eu.org）
DEFAULT_CONFIG_BASE="https://sharq.eu.org"

# certbot 注册邮箱（可在运行前通过环境变量覆盖：EMAIL=xxx@xx.com sudo ./wow.sh）
EMAIL="${EMAIL:-byilrq@gmail.com}"

log() { echo -e "\n==> $*"; }

require_root() {
  if [[ ${EUID:-1000} -ne 0 ]]; then
    echo "❌ 请用 root 运行（sudo -i 后执行，或 sudo bash wow.sh）"
    exit 1
  fi
}

get_codename() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ -n "${VERSION_CODENAME:-}" ]]; then
      echo "$VERSION_CODENAME"
      return 0
    fi
  fi
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -sc
    return 0
  fi
  echo "bullseye"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

is_debian() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian" ]] && return 0
  fi
  return 1
}

enable_debian_nonfree() {
  local f="/etc/apt/sources.list"
  [[ -f "$f" ]] || return 0
  backup_file "$f"

  sed -ri '
    /^[[:space:]]*deb[[:space:]].* main([[:space:]]|$)/{
      / contrib /! s/ main([[:space:]]|$)/ main contrib\1/
      / non-free /! s/ main contrib([[:space:]]|$)/ main contrib non-free\1/
    }
  ' "$f"
}

add_sury_php_repo() {
  local codename="$1"
  log "接入 Sury PHP 仓库（${codename}）..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
  dpkg -i /tmp/debsuryorg-archive-keyring.deb
  rm -f /tmp/debsuryorg-archive-keyring.deb

  echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${codename} main" \
    > /etc/apt/sources.list.d/php-sury.list

  apt-get update -y
}

install_rar_tools() {
  log "安装解压工具（unrar 优先；不行就启用 non-free；再兜底 7z/libarchive）..."
  apt-get update -y
  apt-get install -y p7zip-full libarchive-tools >/dev/null 2>&1 || true

  if apt-get install -y unrar >/dev/null 2>&1; then
    echo "✅ 已安装 unrar"
    return 0
  fi

  if is_debian; then
    enable_debian_nonfree
    apt-get update -y
    if apt-get install -y unrar >/dev/null 2>&1; then
      echo "✅ 已安装 unrar（通过启用 contrib/non-free）"
      return 0
    fi
  fi

  apt-get install -y unrar-free >/dev/null 2>&1 || true
  echo "⚠️ unrar 可能不可用，将使用 7z/bsdtar 兜底解压（RAR5 可能不兼容）"
}

extract_rar() {
  local rar_file="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"

  if command -v unrar >/dev/null 2>&1; then
    if unrar x -o+ "$rar_file" "$out_dir/" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v 7z >/dev/null 2>&1; then
    if 7z x -y "-o$out_dir" "$rar_file" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v bsdtar >/dev/null 2>&1; then
    if bsdtar -xf "$rar_file" -C "$out_dir" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

ensure_open_basedir_fpm_only() {
  # 只在 FPM 池里限制 open_basedir，避免 CLI/composer 出问题
  local pool="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
  local allowed="${WEB_ROOT}/:/tmp/:/var/www/html/"

  backup_file "$pool"
  if grep -Eq '^\s*php_admin_value\[open_basedir\]\s*=' "$pool"; then
    sed -ri "s|^\s*php_admin_value\[open_basedir\]\s*=.*|php_admin_value[open_basedir] = ${allowed}|g" "$pool"
  else
    echo "" >> "$pool"
    echo "php_admin_value[open_basedir] = ${allowed}" >> "$pool"
  fi

  # CLI 不限制 open_basedir（防止 composer/phar 出错）
  local cli_ini="/etc/php/${PHP_VER}/cli/php.ini"
  if [[ -f "$cli_ini" ]]; then
    sed -ri 's|^\s*open_basedir\s*=|;open_basedir =|g' "$cli_ini" || true
  fi

  systemctl restart "php${PHP_VER}-fpm"
}

apply_repo_php_ini_to_fpm_only() {
  # 只替换 FPM php.ini，避免 CLI 受影响
  local tmp_ini="$1"
  local fpm_ini="/etc/php/${PHP_VER}/fpm/php.ini"
  if [[ -s "$tmp_ini" ]]; then
    backup_file "$fpm_ini"
    cp -f "$tmp_ini" "$fpm_ini"
    systemctl restart "php${PHP_VER}-fpm"
  fi
}

write_nginx_site_http_only() {
  local domain="$1"
  cat > /etc/nginx/sites-available/wow <<EOF
server {
    listen 80;
    server_name ${domain};

    root ${WEB_ROOT};
    index index.php index.html index.htm;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        allow all;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    access_log /var/log/nginx/wow_access.log;
    error_log  /var/log/nginx/wow_error.log;
}
EOF

  ln -sf /etc/nginx/sites-available/wow /etc/nginx/sites-enabled/wow
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl reload nginx
}

write_nginx_site_https() {
  local domain="$1"
  mkdir -p /etc/nginx/snippets

  cat > /etc/nginx/snippets/ssl-${domain}.conf <<EOF
ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
EOF

  cat > /etc/nginx/sites-available/wow <<EOF
server {
    listen 80;
    server_name ${domain};

    root ${WEB_ROOT};
    index index.php index.html index.htm;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    include /etc/nginx/snippets/ssl-${domain}.conf;

    root ${WEB_ROOT};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    access_log /var/log/nginx/wow_access.log;
    error_log  /var/log/nginx/wow_error.log;
}
EOF

  ln -sf /etc/nginx/sites-available/wow /etc/nginx/sites-enabled/wow
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl reload nginx
}

open_firewall_ports() {
  # 尽最大可能放行 80/443（不同系统防火墙不同）
  log "尝试放行 80/443 端口（若云安全组拦截仍需在控制台放行）..."

  # UFW
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw status || true
    echo "✅ 已通过 ufw 放行 80/443"
    return 0
  fi

  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true
    firewall-cmd --reload || true
    echo "✅ 已通过 firewalld 放行 80/443"
    return 0
  fi

  # nftables
  if command -v nft >/dev/null 2>&1 && systemctl is-enabled nftables >/dev/null 2>&1; then
    # 尝试直接添加 runtime 规则（持久化依赖 nftables.conf，复杂度较高，这里尽力而为）
    nft add rule inet filter input tcp dport 80 accept 2>/dev/null || true
    nft add rule inet filter input tcp dport 443 accept 2>/dev/null || true
    echo "✅ 已尝试通过 nftables runtime 规则放行 80/443（若重启失效请手动固化）"
    return 0
  fi

  # iptables
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT || true
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT || true

    # 尝试安装持久化（可选）
    if apt-get install -y iptables-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
      echo "✅ 已通过 iptables 放行并尝试持久化 80/443"
    else
      echo "✅ 已通过 iptables 放行 80/443（未持久化，重启可能失效）"
    fi
    return 0
  fi

  echo "⚠️ 未检测到可自动配置的防火墙工具（ufw/firewalld/nft/iptables），跳过。若外网仍无法访问请检查云安全组。"
}

fix_domain_in_config_php() {
  local domain="$1"
  local cfg="${WEB_ROOT}/application/config/config.php"
  [[ -f "$cfg" ]] || return 0

  log "更新 config.php 中站点域名：${DEFAULT_CONFIG_BASE} -> https://${domain}"
  backup_file "$cfg"

  # 把默认的 https://sharq.eu.org（以及可能的 http://sharq.eu.org）替换为新域名
  sed -i \
    -e "s#https://sharq\.eu\.org#https://${domain}#g" \
    -e "s#http://sharq\.eu\.org#https://${domain}#g" \
    -e "s#sharq\.eu\.org#${domain}#g" \
    "$cfg" || true

  systemctl restart "php${PHP_VER}-fpm"
}

run_composer_install() {
  local dir=""
  if [[ -f "${WEB_ROOT}/application/composer.json" ]]; then
    dir="${WEB_ROOT}/application"
  elif [[ -f "${WEB_ROOT}/composer.json" ]]; then
    dir="${WEB_ROOT}"
  fi

  if [[ -n "$dir" ]]; then
    log "执行 composer install（强制解除 open_basedir 影响）: ${dir}"
    mkdir -p "${dir}/vendor" || true
    (cd "$dir" && php -d open_basedir= /usr/local/bin/composer install --no-interaction --prefer-dist --optimize-autoloader) || true
  fi
}

obtain_cert_webroot_if_needed() {
  local domain="$1"
  local live="/etc/letsencrypt/live/${domain}/fullchain.pem"

  if [[ -f "$live" ]]; then
    log "证书已存在，跳过签发：${live}"
    return 0
  fi

  log "使用 certbot webroot 申请证书：${domain}"
  apt-get update -y
  apt-get install -y certbot

  mkdir -p "${WEB_ROOT}/.well-known/acme-challenge"
  chown -R www-data:www-data "${WEB_ROOT}/.well-known" || true

  # 证书签发依赖 80 可访问，所以先确保 HTTP 站点启用
  write_nginx_site_http_only "$domain"

  certbot certonly \
    --agree-tos \
    -m "${EMAIL}" \
    --webroot -w "${WEB_ROOT}" \
    -d "${domain}"
}

# ----------------------------- main -----------------------------
require_root

read -rp "请输入域名（回车默认 ${DEFAULT_DOMAIN}）: " INPUT_DOMAIN
DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"

CODENAME="$(get_codename)"

echo "=========================================="
echo " WoW 注册站 一键安装"
echo " DOMAIN   : ${DOMAIN}"
echo " WEB_ROOT : ${WEB_ROOT}"
echo " CODENAME : ${CODENAME}"
echo "=========================================="

log "基础依赖..."
apt-get update -y
apt-get install -y ca-certificates curl unzip rsync gnupg lsb-release

log "清理可能残留的 ondrej/php PPA（避免 apt update 失败）..."
rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*php*ppa* 2>/dev/null || true

open_firewall_ports

log "安装 Nginx..."
apt-get install -y nginx
systemctl enable nginx
systemctl restart nginx

log "接入 PHP 源并安装 PHP ${PHP_VER}..."
add_sury_php_repo "$CODENAME"
apt-get install -y \
  "php${PHP_VER}" "php${PHP_VER}-cli" "php${PHP_VER}-fpm" "php${PHP_VER}-common" \
  "php${PHP_VER}-mysql" \
  "php${PHP_VER}-gd" "php${PHP_VER}-gmp" "php${PHP_VER}-mbstring" \
  "php${PHP_VER}-curl" "php${PHP_VER}-xml" "php${PHP_VER}-zip" \
  "php${PHP_VER}-intl" "php${PHP_VER}-bcmath"

systemctl enable "php${PHP_VER}-fpm"
systemctl restart "php${PHP_VER}-fpm"

log "安装 Composer..."
if ! command -v composer >/dev/null 2>&1; then
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi

install_rar_tools

log "下载 html.rar 并解压到 ${WEB_ROOT}..."
TMP_DIR="/tmp/wow_install_$$"
mkdir -p "$TMP_DIR"
RAR_FILE="${TMP_DIR}/html.rar"
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"

curl -fL --connect-timeout 10 --max-time 300 -o "$RAR_FILE" "$ARCHIVE_URL"
if [[ ! -s "$RAR_FILE" ]]; then
  echo "❌ html.rar 下载失败或为空：$ARCHIVE_URL"
  exit 1
fi

if ! extract_rar "$RAR_FILE" "$EXTRACT_DIR"; then
  echo "❌ 解压失败：请确保 unrar 可用后重试。"
  exit 1
fi

mkdir -p "$WEB_ROOT"
TOP_COUNT="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [[ "$TOP_COUNT" == "1" ]]; then
  ONLY_ITEM="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
  if [[ -d "$ONLY_ITEM" ]]; then
    rsync -a --delete "${ONLY_ITEM}/" "${WEB_ROOT}/"
  else
    rsync -a --delete "${EXTRACT_DIR}/" "${WEB_ROOT}/"
  fi
else
  rsync -a --delete "${EXTRACT_DIR}/" "${WEB_ROOT}/"
fi

chown -R www-data:www-data "$WEB_ROOT" || true
find "$WEB_ROOT" -type d -exec chmod 755 {} \; || true
find "$WEB_ROOT" -type f -exec chmod 644 {} \; || true

log "下载 php.ini（只替换 FPM，避免 CLI/composer 出错）..."
DL_PHP_INI="${TMP_DIR}/php.ini"
curl -fL -o "$DL_PHP_INI" "$PHP_INI_URL"
apply_repo_php_ini_to_fpm_only "$DL_PHP_INI"
ensure_open_basedir_fpm_only

log "写入 Nginx 站点（先启用 HTTP）..."
write_nginx_site_http_only "$DOMAIN"

log "根据输入域名更新 application/config/config.php ..."
fix_domain_in_config_php "$DOMAIN"

log "执行 composer install（如存在 composer.json）..."
run_composer_install

log "申请证书并启用 HTTPS 443..."
obtain_cert_webroot_if_needed "$DOMAIN"
write_nginx_site_https "$DOMAIN"

log "验证..."
echo "HTTP:  $(curl -s -o /dev/null -w '%{http_code}'  http://127.0.0.1/ -H "Host: ${DOMAIN}")"
echo "HTTPS: $(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1/ -H "Host: ${DOMAIN}")"

echo
echo "=========================================="
echo "✅ 部署完成"
echo "访问： https://${DOMAIN}/"
echo
echo "如果外网仍打不开：请检查云厂商【安全组】是否放行 TCP 80/443"
echo "证书续期测试： sudo certbot renew --dry-run"
echo "=========================================="

rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
