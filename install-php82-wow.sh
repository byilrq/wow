#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " 🚀 Nginx + PHP 8.2 + 扩展 + Composer 一键安装"
echo " 🚀 自动修复 vendor/autoload.php 缺失问题"
echo "=========================================="

#------------------------------------------
# 0. 基础检查
#------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 用户运行本脚本（sudo -i）"
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    echo "❌ 当前系统不支持本脚本（仅支持 Debian / Ubuntu 系 apt 系统）"
    exit 1
fi

#------------------------------------------
# 1. 检测项目路径（优先 wowweb，其次 wow）
#------------------------------------------
PROJECT_ROOT_DEFAULT="/www/wwwroot/wowweb"
ALT_ROOT="/www/wwwroot/wow"

if [[ -d "${PROJECT_ROOT_DEFAULT}/application" ]]; then
    PROJECT_ROOT="${PROJECT_ROOT_DEFAULT}"
elif [[ -d "${ALT_ROOT}/application" ]]; then
    PROJECT_ROOT="${ALT_ROOT}"
else
    echo "❌ 未找到项目目录。请确认以下任一路径存在："
    echo "   - ${PROJECT_ROOT_DEFAULT}/application"
    echo "   - ${ALT_ROOT}/application"
    echo "   然后再运行本脚本。"
    exit 1
fi

APP_PATH="${PROJECT_ROOT}/application"
echo "✅ 检测到项目路径：${PROJECT_ROOT}"
echo "✅ application 目录：${APP_PATH}"
echo

#------------------------------------------
# 2. 安装 Nginx
#------------------------------------------
echo "==> 安装 Nginx ..."
apt update -y
apt install -y nginx

systemctl enable nginx
systemctl restart nginx

echo "✅ Nginx 安装并已启动"
echo

#------------------------------------------
# 3. 安装 PHP 8.2 及扩展
#------------------------------------------
echo "==> 安装 PHP 8.2 及常用扩展 ..."

apt install -y software-properties-common curl unzip

# 添加 PPA：ondrej/php（如已存在则跳过）
if ! grep -Rqs "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    add-apt-repository -y ppa:ondrej/php
fi

apt update -y

apt install -y \
    php8.2 php8.2-cli php8.2-fpm php8.2-common \
    php8.2-mysql php8.2-gd php8.2-curl php8.2-mbstring \
    php8.2-xml php8.2-zip php8.2-gmp

# 确保 gmp 启用（有就跳过，没有就追加一行）
for INI in /etc/php/8.2/fpm/php.ini /etc/php/8.2/cli/php.ini; do
    if [[ -f "$INI" ]] && ! grep -q "^extension=gmp" "$INI"; then
        echo "extension=gmp" >> "$INI"
    fi
done

systemctl restart php8.2-fpm

echo "✅ PHP 8.2 及扩展安装完成"
php -v || true
echo

#------------------------------------------
# 4. 安装 Composer（如已存在则跳过）
#------------------------------------------
if ! command -v composer >/dev/null 2>&1; then
    echo "==> 安装 Composer ..."
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
else
    echo "✅ 检测到已安装 composer，跳过安装"
fi

echo "当前 Composer 版本："
composer -V || true
echo

#------------------------------------------
# 5. 在 application 目录执行 composer install
#------------------------------------------
if [[ ! -f "${APP_PATH}/composer.json" ]]; then
    echo "⚠️ 警告：未在 ${APP_PATH} 发现 composer.json"
    echo "   如果你的项目 composer.json 不在 application 目录，请手动调整脚本中的 APP_PATH。"
else
    echo "==> 在 ${APP_PATH} 中执行 composer install ..."
    cd "${APP_PATH}"
    composer install --no-interaction --prefer-dist
    echo "✅ composer install 完成，vendor 目录及 autoload.php 已生成（正常情况下）"
fi

#------------------------------------------
# 6. 设置权限
#------------------------------------------
echo "==> 设置项目文件权限（www-data:www-data，755） ..."
chown -R www-data:www-data "${PROJECT_ROOT}"
chmod -R 755 "${PROJECT_ROOT}"

#------------------------------------------
# 7. 完成信息
#------------------------------------------
echo
echo "=========================================="
echo "🎉 安装全部完成！"
echo "📁 项目目录：${PROJECT_ROOT}"
echo "📁 application 目录：${APP_PATH}"
echo "📁 vendor: ${APP_PATH}/vendor"
echo
echo "如果之前报错："
echo "  Failed opening required '${APP_PATH}/vendor/autoload.php'"
echo "现在应该已经修复（vendor/autoload.php 已生成）。"
echo
echo "你可以检查："
echo "  ls -l ${APP_PATH}/vendor/autoload.php"
echo
echo "服务状态查看："
echo "  systemctl status nginx"
echo "  systemctl status php8.2-fpm"
echo "=========================================="
