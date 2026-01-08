#!/usr/bin/env bash
set -euo pipefail

#==========================================================
# wow.sh - WoW 注册站 一键安装（Nginx + PHP8.2 + 解压 html.rar + 替换配置）
# 默认:
#   站点目录: /www/wow
#   域名: sharq.eu.org
# 资源:
#   https://raw.githubusercontent.com/byilrq/wow/main/html.rar
#   https://raw.githubusercontent.com/byilrq/wow/main/php.ini
#   https://raw.githubusercontent.com/byilrq/wow/main/nginx.conf
#==========================================================

# -----------------------------
# 可调整参数（默认按你的要求）
# -----------------------------
DOMAIN="sharq.eu.org"
WEB_ROOT="/www/wow"
PHP_VER="8.2"

REPO_RAW_BASE="https://raw.githubusercontent.com/byilrq/wow/main"
ARCHIVE_URL="${REPO_RAW_BASE}/html.rar"
PHP_INI_URL="${REPO_RAW_BASE}/php.ini"
NGINX_CONF_URL="${REPO_RAW_BASE}/nginx.conf"

# 1=自动 composer install；0=不执行
RUN_COMPOSER="1"

# -----------------------------
# 工具函数
# -----------------------------
log() { echo -e "\n==> $*"; }

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ 请用 root 运行（例如：sudo -i 后再执行）"
    exit 1
  fi
}

# -----------------------------
# 开始
# -----------------------------
require_root

if ! command -v apt >/dev/null 2>&1; then
  echo "❌ 当前系统不支持本脚本（仅支持 Debian/Ubuntu + apt）"
  exit 1
fi

echo "=========================================="
echo " WoW 注册站 一键安装"
echo " DOMAIN   : ${DOMAIN}"
echo " WEB_ROOT : ${WEB_ROOT}"
echo "=========================================="

log "更新系统并安装基础工具..."
apt update -y
apt install -y ca-certificates curl unzip rsync software-properties-common

log "安装 Nginx..."
apt install -y nginx
systemctl enable nginx
systemctl restart nginx

log "安装 PHP ${PHP_VER}（使用 ondrej/php PPA）..."
# 仅在没添加过 PPA 时添加
if ! grep -Rqs "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  add-apt-repository -y ppa:ondrej/php
fi

apt update -y
apt install -y \
  "php${PHP_VER}" "php${PHP_VER}-cli" "php${PHP_VER}-fpm" "php${PHP_VER}-common" \
  "php${PHP_VER}-mysql" "php${PHP_VER}-pdo" \
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

log "安装 RAR 解压工具（unrar + 7z 作为兜底）..."
apt install -y unrar p7zip-full

log "下载 html.rar 并解压到 ${WEB_ROOT} ..."
TMP_DIR="/tmp/wow_install_$$"
mkdir -p "$TMP_DIR"
RAR_FILE="${TMP_DIR}/html.rar"
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"

# 下载（raw 可能偶发失败，这里简单重试）
for i in 1 2 3; do
  if curl -fL --connect-timeout 10 --max-time 300 -o "$RAR_FILE" "$ARCHIVE_URL"; then
    break
  fi
  echo "⚠️ 下载失败，重试第 $i 次..."
  sleep 2
done

if [[ ! -s "$RAR_FILE" ]]; then
  echo "❌ html.rar 下载失败或为空：$ARCHIVE_URL"
  exit 1
fi

# 解压：优先 unrar，失败则 7z
if unrar x -o+ "$RAR_FILE" "$EXTRACT_DIR/" >/dev/null 2>&1; then
  :
elif 7z x -y "-o$EXTRACT_DIR" "$RAR_FILE" >/dev/null 2>&1; then
  :
else
  echo "❌ 解压失败：unrar/7z 都无法解压该 rar"
  exit 1
fi

mkdir -p "$WEB_ROOT"

# 如果解压出来只有一个顶层目录（常见 html/），则把其内容同步到 WEB_ROOT
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
chmod -R 755 "$WEB_ROOT" || true

log "下载并替换 php.ini 与 nginx.conf ..."
PHP_FPM_INI="/etc/php/${PHP_VER}/fpm/php.ini"
PHP_CLI_INI="/etc/php/${PHP_VER}/cli/php.ini"
PHP_POOL="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
NGINX_MAIN="/etc/nginx/nginx.conf"
SITE_AVAIL="/etc/nginx/sites-available/wow"
SITE_ENABLE="/etc/nginx/sites-enabled/wow"

DL_PHP_INI="${TMP_DIR}/php.ini"
DL_NGINX_CONF="${TMP_DIR}/nginx.conf"

curl -fL -o "$DL_PHP_INI" "$PHP_INI_URL"
curl -fL -o "$DL_NGINX_CONF" "$NGINX_CONF_URL"

# 强制 open_basedir 按新目录写入
OPEN_BASEDIR="${WEB_ROOT}/:/tmp/:/var/www/html/"
if grep -Eq '^\s*;?\s*open_basedir\s*=' "$DL_PHP_INI"; then
  sed -ri "s|^\s*;?\s*open_basedir\s*=.*|open_basedir = ${OPEN_BASEDIR}|g" "$DL_PHP_INI"
else
  echo "open_basedir = ${OPEN_BASEDIR}" >> "$DL_PHP_INI"
fi

backup_file "$PHP_FPM_INI"
backup_file "$PHP_CLI_INI"
cp -f "$DL_PHP_INI" "$PHP_FPM_INI"
cp -f "$DL_PHP_INI" "$PHP_CLI_INI"

# 同步 PHP-FPM 池 open_basedir
backup_file "$PHP_POOL"
if grep -Eq '^\s*php_admin_value\[open_basedir\]\s*=' "$PHP_POOL"; then
  sed -ri "s|^\s*php_admin_value\[open_basedir\]\s*=.*|php_admin_value[open_basedir] = ${OPEN_BASEDIR}|g" "$PHP_POOL"
else
  echo "" >> "$PHP_POOL"
  echo "php_admin_value[open_basedir] = ${OPEN_BASEDIR}" >> "$PHP_POOL"
fi

# 确保常用扩展启用（以防 php.ini/环境差异）
if command -v phpenmod >/dev/null 2>&1; then
  for mod in gmp gd curl mbstring xml zip intl bcmath mysqli pdo_mysql; do
    phpenmod -v "${PHP_VER}" "$mod" >/dev/null 2>&1 || true
  done
fi

systemctl restart "php${PHP_VER}-fpm"

# 部署 Nginx 配置：判断是主配置还是站点配置
if grep -Eq '^\s*(worker_processes|events\s*\{|http\s*\{|pid\s+)' "$DL_NGINX_CONF"; then
  log "检测到 nginx.conf 为【主配置】，替换 ${NGINX_MAIN} ..."
  backup_file "$NGINX_MAIN"
  cp -f "$DL_NGINX_CONF" "$NGINX_MAIN"
else
  log "检测到 nginx.conf 为【站点配置】，部署到 ${SITE_AVAIL} 并启用..."

  # 尽力替换 server_name / root / fastcgi_pass（如果文件里有对应行）
  if grep -Eq '^\s*server_name\s+' "$DL_NGINX_CONF"; then
    sed -ri "s|^\s*server_name\s+.*;|    server_name ${DOMAIN} www.${DOMAIN};|g" "$DL_NGINX_CONF"
  fi
  if grep -Eq '^\s*root\s+' "$DL_NGINX_CONF"; then
    sed -ri "s|^\s*root\s+.*;|    root ${WEB_ROOT};|g" "$DL_NGINX_CONF"
  fi
  if grep -Eq '^\s*fastcgi_pass\s+' "$DL_NGINX_CONF"; then
    sed -ri "s|^\s*fastcgi_pass\s+.*;|        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;|g" "$DL_NGINX_CONF"
  fi

  backup_file "$SITE_AVAIL"
  cp -f "$DL_NGINX_CONF" "$SITE_AVAIL"
  rm -f "$SITE_ENABLE" || true
  ln -s "$SITE_AVAIL" "$SITE_ENABLE"

  # 关闭默认站点避免冲突
  rm -f /etc/nginx/sites-enabled/default || true
fi

nginx -t
systemctl restart nginx

log "可选：执行 composer install（生成 vendor/autoload.php）..."
if [[ "$RUN_COMPOSER" == "1" ]]; then
  COMPOSER_DIR=""
  if [[ -f "${WEB_ROOT}/application/composer.json" ]]; then
    COMPOSER_DIR="${WEB_ROOT}/application"
  elif [[ -f "${WEB_ROOT}/composer.json" ]]; then
    COMPOSER_DIR="${WEB_ROOT}"
  fi

  if [[ -n "$COMPOSER_DIR" ]]; then
    mkdir -p "${COMPOSER_DIR}/vendor" || true
    (cd "$COMPOSER_DIR" && composer install --no-interaction --prefer-dist --optimize-autoloader)
  else
    echo "⚠️ 未找到 composer.json，跳过 composer install（如仍缺 autoload.php 请手动执行）"
  fi
fi

# 最后权限再统一一次
chown -R www-data:www-data "$WEB_ROOT" || true
chmod -R 755 "$WEB_ROOT" || true

echo
echo "=========================================="
echo "✅ 一键安装完成"
echo "站点目录: ${WEB_ROOT}"
echo "域名    : ${DOMAIN}"
echo "PHP-FPM : php${PHP_VER}-fpm"
echo
echo "常用排错："
echo "  Nginx 错误日志: /var/log/nginx/error.log"
echo "  站点日志(若配置有): /var/log/nginx/*.log"
echo "  PHP-FPM 日志: journalctl -u php${PHP_VER}-fpm -n 200 --no-pager"
echo
echo "如果仍报 vendor/autoload.php 缺失："
echo "  cd ${WEB_ROOT}/application && composer install"
echo "=========================================="

rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
