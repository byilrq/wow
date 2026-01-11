#!/usr/bin/env bash
set -euo pipefail

#==========================================================
# wow.sh - WoW注册站一键部署 + 管理菜单（Debian/Ubuntu 兼容版）
#
# 特性：
# - 管理菜单：
#   1) 一键安装
#   2) 修改域名（自动改 Nginx + 自动改 config.php + 重新签证书）
#   3) 更新证书（certbot renew + reload nginx）
#
# - 启动时中文交互提示：域名回车默认 sharq.eu.org
# - 自动放行 80/443（尽量：ufw / firewalld / nftables / iptables）
#   * 优化：只放行 TCP（HTTP/HTTPS 不需要 UDP）
# - Debian：使用 Sury PHP 源安装 PHP 8.2
# - Ubuntu：使用 ondrej/php PPA 安装 PHP 8.2
# - 下载并解压 html.rar 到 /www/wow
# - 仅限制 PHP-FPM 的 open_basedir（不影响 CLI/composer）
# - certbot webroot 方式签证书，启用 HTTPS 443
# - 自动把 application/config/config.php 里的 https://sharq.eu.org 替换为新域名
# - 优化：Composer 允许 root 执行（减少提示），并保持非交互
#
# 默认：
# - 站点目录：/www/wow
# - 默认域名：sharq.eu.org
# - 保存当前域名到：/etc/wow_domain.conf
#==========================================================

#========================
# 全局默认配置
#========================
DEFAULT_DOMAIN="sharq.eu.org"
WEB_ROOT="${WEB_ROOT:-/www/wow}"
PHP_VER="${PHP_VER:-8.2}"

REPO_RAW_BASE="https://raw.githubusercontent.com/byilrq/wow/main"
ARCHIVE_URL="${REPO_RAW_BASE}/html.rar"
PHP_INI_URL="${REPO_RAW_BASE}/php.ini"

# config.php 默认基准域名（你已改为 https://sharq.eu.org）
DEFAULT_CONFIG_BASE="https://sharq.eu.org"

# certbot 注册邮箱（可运行前覆盖：EMAIL=xxx@xx.com sudo ./wow.sh）
EMAIL="${EMAIL:-byilrq@gmail.com}"

# 记录当前域名（用于“修改域名/更新证书”菜单）
DOMAIN_STATE_FILE="/etc/wow_domain.conf"

#==========================================================
# 工具函数：打印日志（中文）
# 作用：统一输出格式，方便排障
#==========================================================
log() { echo -e "\n==> $*"; }

#==========================================================
# 工具函数：必须 root 运行
# 作用：避免权限不足导致安装/写配置失败
#==========================================================
require_root() {
  if [[ ${EUID:-1000} -ne 0 ]]; then
    echo "❌ 请使用 root 运行：sudo -i 后执行 ./wow.sh（或 sudo bash wow.sh）"
    exit 1
  fi
}

#==========================================================
# 工具函数：读取系统信息（Debian/Ubuntu + 版本代号）
# 作用：根据系统选择正确的 PHP 仓库与安装方式
#==========================================================
get_os_info() {
  local id="" codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    codename="${VERSION_CODENAME:-}"
  fi
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -sc)"
  fi
  [[ -z "$codename" ]] && codename="bullseye"
  echo "${id}|${codename}"
}

#==========================================================
# 工具函数：备份文件
# 作用：修改系统配置前自动备份，便于回滚
#==========================================================
backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

#==========================================================
# 工具函数：读取/保存当前域名
# 作用：菜单模式下记住安装域名，后续“改域名/续期”无需猜
#==========================================================
get_saved_domain() {
  if [[ -f "$DOMAIN_STATE_FILE" ]]; then
    tr -d '\r\n' < "$DOMAIN_STATE_FILE" || true
  fi
}
save_domain() {
  local d="$1"
  echo "$d" > "$DOMAIN_STATE_FILE"
}

#==========================================================
# 防火墙函数：放行 80/443（只放行 TCP）
# 作用：尽量自动开放端口（仍建议云厂商安全组也放行）
#==========================================================
open_firewall_ports() {
  log "尝试放行 80/443 端口（仅 TCP；若外网仍打不开，请检查云厂商安全组）..."

  # UFW（Ubuntu 常见 / 你机器也有）
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw status || true
    echo "✅ 已通过 ufw 尝试放行 80/443 (TCP)"
    return 0
  fi

  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true
    firewall-cmd --reload || true
    echo "✅ 已通过 firewalld 尝试放行 80/443"
    return 0
  fi

  # nftables
  if command -v nft >/dev/null 2>&1 && systemctl is-enabled nftables >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport 80 accept 2>/dev/null || true
    nft add rule inet filter input tcp dport 443 accept 2>/dev/null || true
    echo "✅ 已尝试通过 nftables runtime 规则放行 80/443 (TCP)（重启可能失效，需自行固化）"
    return 0
  fi

  # iptables
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT || true
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT || true

    # 尝试持久化（可选）
    if apt-get install -y iptables-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
      echo "✅ 已通过 iptables 放行并尝试持久化 80/443 (TCP)"
    else
      echo "✅ 已通过 iptables 放行 80/443 (TCP)（未持久化，重启可能失效）"
    fi
    return 0
  fi

  echo "⚠️ 未检测到可自动配置的防火墙工具（ufw/firewalld/nft/iptables），已跳过。"
}

#==========================================================
# 软件源函数：清理错误 PPA（防止 apt update 失败）
# 作用：避免 Debian 误加 Ubuntu PPA 导致 404 / Release file 错误
#==========================================================
cleanup_bad_repos() {
  log "清理可能导致 apt 更新失败的残留源（如 ondrej/php 在 Debian 上误加）..."
  rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*php*ppa* 2>/dev/null || true
}

#==========================================================
# 软件源函数：Debian 启用 contrib/non-free（用于安装 unrar）
# 作用：解决 Debian bullseye 下 unrar “无候选版本”问题
#==========================================================
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

#==========================================================
# 软件源函数：配置 PHP 仓库（Debian/Ubuntu 自动选择）
# 作用：确保能正确安装 PHP 8.2 及扩展
#==========================================================
setup_php_repo() {
  local os_id="$1" codename="$2"

  if [[ "$os_id" == "debian" ]]; then
    log "检测到 Debian：配置 Sury PHP 仓库（${codename}）..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i /tmp/debsuryorg-archive-keyring.deb
    rm -f /tmp/debsuryorg-archive-keyring.deb

    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${codename} main" \
      > /etc/apt/sources.list.d/php-sury.list

    apt-get update -y
    return 0
  fi

  if [[ "$os_id" == "ubuntu" ]]; then
    log "检测到 Ubuntu：使用 ondrej/php PPA 安装 PHP ${PHP_VER}..."
    apt-get update -y
    apt-get install -y software-properties-common ca-certificates curl gnupg lsb-release
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
    return 0
  fi

  log "未识别系统为 Debian/Ubuntu：将尝试直接安装 PHP（可能失败）"
}

#==========================================================
# 解压工具函数：安装 unrar + 7z 兜底
# 作用：确保 html.rar 能正常解压
#==========================================================
install_rar_tools() {
  log "安装解压工具（unrar 优先；失败则启用 non-free；并安装 7z/bsdtar 兜底）..."
  apt-get update -y
  apt-get install -y p7zip-full libarchive-tools >/dev/null 2>&1 || true

  if apt-get install -y unrar >/dev/null 2>&1; then
    echo "✅ 已安装 unrar"
    return 0
  fi

  local os_id codename
  IFS='|' read -r os_id codename <<<"$(get_os_info)"
  if [[ "$os_id" == "debian" ]]; then
    enable_debian_nonfree
    apt-get update -y
    if apt-get install -y unrar >/dev/null 2>&1; then
      echo "✅ 已安装 unrar（通过启用 contrib/non-free）"
      return 0
    fi
  fi

  apt-get install -y unrar-free >/dev/null 2>&1 || true
  echo "⚠️ unrar 仍不可用：将使用 7z/bsdtar 尝试解压（RAR5 可能不兼容）"
}

#==========================================================
# 解压函数：解压 RAR 到指定目录
# 作用：优先 unrar，其次 7z，再次 bsdtar
#==========================================================
extract_rar() {
  local rar_file="$1" out_dir="$2"
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

#==========================================================
# PHP 配置函数：仅限制 FPM open_basedir（不影响 CLI）
# 作用：避免 composer/phar 因 open_basedir 报错
#==========================================================
ensure_open_basedir_fpm_only() {
  local pool="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
  local allowed="${WEB_ROOT}/:/tmp/:/var/www/html/"

  backup_file "$pool"
  if grep -Eq '^\s*php_admin_value\[open_basedir\]\s*=' "$pool"; then
    sed -ri "s|^\s*php_admin_value\[open_basedir\]\s*=.*|php_admin_value[open_basedir] = ${allowed}|g" "$pool"
  else
    echo "" >> "$pool"
    echo "php_admin_value[open_basedir] = ${allowed}" >> "$pool"
  fi

  local cli_ini="/etc/php/${PHP_VER}/cli/php.ini"
  if [[ -f "$cli_ini" ]]; then
    sed -ri 's|^\s*open_basedir\s*=|;open_basedir =|g' "$cli_ini" || true
  fi

  systemctl restart "php${PHP_VER}-fpm"
}

#==========================================================
# PHP 配置函数：下载的 php.ini 只替换 FPM 版本
# 作用：避免 CLI 被限制导致 composer 失败
#==========================================================
apply_repo_php_ini_to_fpm_only() {
  local tmp_ini="$1"
  local fpm_ini="/etc/php/${PHP_VER}/fpm/php.ini"
  if [[ -s "$tmp_ini" ]]; then
    backup_file "$fpm_ini"
    cp -f "$tmp_ini" "$fpm_ini"
    systemctl restart "php${PHP_VER}-fpm"
  fi
}

#==========================================================
# Nginx 配置函数：写入 HTTP 站点（用于签证书前/或只用 HTTP）
# 作用：提供 80 访问 + ACME 验证目录
#==========================================================
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

#==========================================================
# Nginx 配置函数：写入 HTTPS 站点（80 -> 443 跳转）
# 作用：启用 443 SSL，并强制跳转 HTTPS
#==========================================================
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

#==========================================================
# 项目配置函数：根据域名更新 config.php
# 作用：解决模板里资源链接写死域名导致图片/CSS/JS 不显示
#==========================================================
fix_domain_in_config_php() {
  local domain="$1"
  local cfg="${WEB_ROOT}/application/config/config.php"
  [[ -f "$cfg" ]] || return 0

  log "更新 config.php 中站点域名：${DEFAULT_CONFIG_BASE} -> https://${domain}"
  backup_file "$cfg"

  sed -i \
    -e "s#https://sharq\.eu\.org#https://${domain}#g" \
    -e "s#http://sharq\.eu\.org#https://${domain}#g" \
    -e "s#sharq\.eu\.org#${domain}#g" \
    "$cfg" || true

  systemctl restart "php${PHP_VER}-fpm"
}

#==========================================================
# Composer 函数：可选执行 composer install
# 作用：生成 vendor/autoload.php（若项目需要）
#==========================================================
run_composer_install() {
  local dir=""
  if [[ -f "${WEB_ROOT}/application/composer.json" ]]; then
    dir="${WEB_ROOT}/application"
  elif [[ -f "${WEB_ROOT}/composer.json" ]]; then
    dir="${WEB_ROOT}"
  fi

  if [[ -n "$dir" ]]; then
    log "执行 composer install（非必需；若失败可忽略）：${dir}"
    mkdir -p "${dir}/vendor" || true
    export COMPOSER_ALLOW_SUPERUSER=1
    (cd "$dir" && php -d open_basedir= /usr/local/bin/composer install --no-interaction --prefer-dist --optimize-autoloader) || true
  fi
}

#==========================================================
# 证书函数：签发证书（webroot 模式）
# 作用：避开 nginx 插件 UTF-8 读取限制，适配你的环境
#==========================================================
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

  write_nginx_site_http_only "$domain"

  certbot certonly \
    --agree-tos \
    -m "${EMAIL}" \
    --webroot -w "${WEB_ROOT}" \
    -d "${domain}"
}

#==========================================================
# 证书函数：更新证书（renew）
# 作用：手动触发续期 + 自动 reload nginx
#==========================================================
renew_certs_and_reload() {
  log "开始执行证书续期（certbot renew）..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y certbot >/dev/null 2>&1 || true

  certbot renew --quiet --deploy-hook "systemctl reload nginx" || true
  echo "✅ 已执行续期命令（如果未到续期窗口，certbot 会自动跳过）"
}

#==========================================================
# 一键安装主流程
# 作用：安装 Nginx/PHP/依赖、部署站点、签证书、启用 HTTPS
#==========================================================
do_install() {
  local domain="$1"
  local os_id codename
  IFS='|' read -r os_id codename <<<"$(get_os_info)"

  echo "=========================================="
  echo " 一键安装开始"
  echo " 系统：${os_id:-unknown} / ${codename}"
  echo " 域名：${domain}"
  echo " 目录：${WEB_ROOT}"
  echo " PHP：${PHP_VER}"
  echo "=========================================="

  log "安装基础依赖..."
  apt-get update -y
  apt-get install -y ca-certificates curl unzip rsync gnupg lsb-release

  cleanup_bad_repos
  open_firewall_ports

  log "安装 Nginx..."
  apt-get install -y nginx
  systemctl enable nginx
  systemctl restart nginx

  log "配置 PHP 仓库并安装 PHP ${PHP_VER}..."
  setup_php_repo "${os_id}" "${codename}"
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
  local tmp_dir="/tmp/wow_install_$$"
  mkdir -p "$tmp_dir"
  local rar_file="${tmp_dir}/html.rar"
  local extract_dir="${tmp_dir}/extracted"
  mkdir -p "$extract_dir"

  curl -fL --connect-timeout 10 --max-time 300 -o "$rar_file" "$ARCHIVE_URL"
  if [[ ! -s "$rar_file" ]]; then
    echo "❌ html.rar 下载失败或为空：$ARCHIVE_URL"
    exit 1
  fi

  if ! extract_rar "$rar_file" "$extract_dir"; then
    echo "❌ 解压失败：请确保 unrar 可用后重试。"
    exit 1
  fi

  mkdir -p "$WEB_ROOT"
  local top_count
  top_count="$(find "$extract_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  if [[ "$top_count" == "1" ]]; then
    local only_item
    only_item="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -print -quit)"
    if [[ -d "$only_item" ]]; then
      rsync -a --delete "${only_item}/" "${WEB_ROOT}/"
    else
      rsync -a --delete "${extract_dir}/" "${WEB_ROOT}/"
    fi
  else
    rsync -a --delete "${extract_dir}/" "${WEB_ROOT}/"
  fi

  chown -R www-data:www-data "$WEB_ROOT" || true
  find "$WEB_ROOT" -type d -exec chmod 755 {} \; || true
  find "$WEB_ROOT" -type f -exec chmod 644 {} \; || true

  log "下载并应用 php.ini（仅替换 FPM）..."
  local dl_php_ini="${tmp_dir}/php.ini"
  curl -fL -o "$dl_php_ini" "$PHP_INI_URL"
  apply_repo_php_ini_to_fpm_only "$dl_php_ini"
  ensure_open_basedir_fpm_only

  log "写入 Nginx 站点（先启用 HTTP）..."
  write_nginx_site_http_only "$domain"

  log "根据域名更新 application/config/config.php ..."
  fix_domain_in_config_php "$domain"

  log "可选：执行 composer install（若失败不影响打开网站）..."
  run_composer_install

  log "申请证书并启用 HTTPS 443..."
  obtain_cert_webroot_if_needed "$domain"
  write_nginx_site_https "$domain"

  save_domain "$domain"

  log "验证本机 HTTP/HTTPS 状态..."
  echo "HTTP 状态码：  $(curl -s -o /dev/null -w '%{http_code}'  http://127.0.0.1/ -H "Host: ${domain}")"
  echo "HTTPS 状态码： $(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1/ -H "Host: ${domain}")"

  rm -rf "$tmp_dir" >/dev/null 2>&1 || true

  echo
  echo "=========================================="
  echo "✅ 安装完成"
  echo "访问地址： https://${domain}/"
  echo "日志：/var/log/nginx/wow_access.log  /var/log/nginx/wow_error.log"
  echo "提示：若外网仍打不开，请在云厂商安全组放行 TCP 80/443"
  echo "=========================================="
}

#==========================================================
# 菜单功能：修改域名
# 作用：自动更新 Nginx + config.php，并为新域名签证书
#==========================================================
do_change_domain() {
  local old_domain
  old_domain="$(get_saved_domain || true)"
  [[ -z "$old_domain" ]] && old_domain="$DEFAULT_DOMAIN"

  echo "当前记录域名：${old_domain}"
  read -rp "请输入新域名（回车取消）： " new_domain
  if [[ -z "${new_domain}" ]]; then
    echo "已取消。"
    return 0
  fi

  log "更新 Nginx（先切 HTTP 以便签证书）..."
  write_nginx_site_http_only "$new_domain"

  log "更新 config.php 域名..."
  fix_domain_in_config_php "$new_domain"

  log "为新域名签发证书并启用 HTTPS..."
  obtain_cert_webroot_if_needed "$new_domain"
  write_nginx_site_https "$new_domain"

  save_domain "$new_domain"

  echo "✅ 域名修改完成：${old_domain} -> ${new_domain}"
  echo "请访问： https://${new_domain}/"
}

#==========================================================
# 菜单功能：更新证书
# 作用：执行 certbot renew 并 reload nginx
#==========================================================
do_update_cert() {
  local d
  d="$(get_saved_domain || true)"
  [[ -z "$d" ]] && d="$DEFAULT_DOMAIN"

  echo "当前记录域名：${d}"
  renew_certs_and_reload

  if ss -lntp 2>/dev/null | grep -q ':443'; then
    echo "✅ 当前系统已监听 443"
  else
    echo "⚠️ 未检测到 443 监听（如果你未启用 HTTPS 可忽略）"
  fi

  echo "你也可以执行测试：certbot renew --dry-run"
}

#==========================================================
# 管理菜单
# 作用：提供安装/改域名/续期一体化入口
#==========================================================
menu() {
  local saved
  saved="$(get_saved_domain || true)"
  [[ -z "$saved" ]] && saved="（未记录）"

  echo "=========================================="
  echo " WoW 注册站管理菜单"
  echo " 当前记录域名：${saved}"
  echo " 站点目录：${WEB_ROOT}"
  echo "=========================================="
  echo "1) 一键安装"
  echo "2) 修改域名"
  echo "3) 更新证书"
  echo "0) 退出"
  echo "------------------------------------------"
  read -rp "请输入选项编号：" choice

  case "${choice}" in
    1)
      read -rp "请输入域名（回车默认 ${DEFAULT_DOMAIN}）：" input_domain
      local domain="${input_domain:-$DEFAULT_DOMAIN}"
      do_install "$domain"
      ;;
    2)
      do_change_domain
      ;;
    3)
      do_update_cert
      ;;
    0)
      echo "已退出。"
      exit 0
      ;;
    *)
      echo "❌ 无效选项，请重新运行脚本。"
      exit 1
      ;;
  esac
}

# ----------------------------- main -----------------------------
require_root
menu
