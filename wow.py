#!/usr/bin/env python3
"""WoW 注册站新架构一键部署脚本。

功能：
1. 安装 Nginx / PHP-FPM / PHP 扩展 / git / certbot
2. 直接从 GitHub 仓库拉取源码，不再下载 rar/zip 包
3. 写入 .env、Nginx 站点、open_basedir
4. 支持菜单：一键安装 / 修改域名 / 更新证书
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from pathlib import Path

DEFAULT_DOMAIN = os.environ.get("DEFAULT_DOMAIN", "sharq.eu.org")
WEB_ROOT = Path(os.environ.get("WEB_ROOT", "/www/wow"))
PHP_VER = os.environ.get("PHP_VER", "8.2")
EMAIL = os.environ.get("EMAIL", "byilrq@gmail.com")
REPO_URL = os.environ.get("REPO_URL", "https://github.com/byilrq/wow.git")
REPO_BRANCH = os.environ.get("REPO_BRANCH", "main")
DOMAIN_STATE_FILE = Path("/etc/wow_domain.conf")


def run(cmd: list[str] | str, check: bool = True, cwd: Path | None = None) -> subprocess.CompletedProcess:
    print("\n==>", cmd if isinstance(cmd, str) else " ".join(cmd))
    return subprocess.run(cmd, shell=isinstance(cmd, str), check=check, cwd=cwd)


def require_root() -> None:
    if os.geteuid() != 0:
        raise SystemExit("请使用 root 运行：sudo python3 wow.py")


def read_os() -> tuple[str, str]:
    data = {}
    path = Path("/etc/os-release")
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v.strip('"')
    return data.get("ID", platform.system().lower()), data.get("VERSION_CODENAME", "bullseye")


def save_domain(domain: str) -> None:
    DOMAIN_STATE_FILE.write_text(domain)


def get_saved_domain() -> str:
    return DOMAIN_STATE_FILE.read_text().strip() if DOMAIN_STATE_FILE.exists() else DEFAULT_DOMAIN


def apt_install(packages: list[str]) -> None:
    run(["apt-get", "update", "-y"])
    run(["apt-get", "install", "-y", *packages])


def setup_php_repo() -> None:
    os_id, codename = read_os()
    run("rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*php*ppa*", check=False)
    if os_id == "debian":
        apt_install(["ca-certificates", "curl", "gnupg", "lsb-release"])
        run(["curl", "-fsSLo", "/tmp/debsuryorg-archive-keyring.deb", "https://packages.sury.org/debsuryorg-archive-keyring.deb"])
        run(["dpkg", "-i", "/tmp/debsuryorg-archive-keyring.deb"])
        Path("/etc/apt/sources.list.d/php-sury.list").write_text(
            f"deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ {codename} main\n"
        )
        run(["apt-get", "update", "-y"])
    elif os_id == "ubuntu":
        apt_install(["software-properties-common", "ca-certificates", "curl", "gnupg", "lsb-release"])
        run(["add-apt-repository", "-y", "ppa:ondrej/php"])
        run(["apt-get", "update", "-y"])


def open_firewall() -> None:
    if shutil.which("ufw"):
        run(["ufw", "allow", "80/tcp"], check=False)
        run(["ufw", "allow", "443/tcp"], check=False)
    elif shutil.which("firewall-cmd"):
        run(["firewall-cmd", "--permanent", "--add-service=http"], check=False)
        run(["firewall-cmd", "--permanent", "--add-service=https"], check=False)
        run(["firewall-cmd", "--reload"], check=False)
    elif shutil.which("iptables"):
        run("iptables -C INPUT -p tcp --dport 80 -j ACCEPT || iptables -I INPUT -p tcp --dport 80 -j ACCEPT", check=False)
        run("iptables -C INPUT -p tcp --dport 443 -j ACCEPT || iptables -I INPUT -p tcp --dport 443 -j ACCEPT", check=False)


def deploy_source() -> None:
    tmp = Path("/tmp/wow_repo_new")
    if tmp.exists():
        shutil.rmtree(tmp)
    run(["git", "clone", "--depth", "1", "--branch", REPO_BRANCH, REPO_URL, str(tmp)])
    WEB_ROOT.mkdir(parents=True, exist_ok=True)
    run(["rsync", "-a", "--delete", f"{tmp}/", f"{WEB_ROOT}/"])
    run(["chown", "-R", "www-data:www-data", str(WEB_ROOT)], check=False)


def ensure_env(domain: str) -> None:
    env_path = WEB_ROOT / ".env"
    if not env_path.exists():
        sample = WEB_ROOT / ".env.example"
        if sample.exists():
            shutil.copy(sample, env_path)
        else:
            env_path.write_text("")
    text = env_path.read_text()
    replacements = {
        "APP_URL": f"https://{domain}",
        "REALMLIST": domain,
        "APP_NAME": os.environ.get("APP_NAME", "BlackRock"),
        "DB_AUTH_HOST": os.environ.get("DB_AUTH_HOST", "127.0.0.1"),
        "DB_AUTH_PORT": os.environ.get("DB_AUTH_PORT", "3306"),
        "DB_AUTH_DATABASE": os.environ.get("DB_AUTH_DATABASE", "acore_auth"),
        "DB_AUTH_USERNAME": os.environ.get("DB_AUTH_USERNAME", "admin"),
        "DB_AUTH_PASSWORD": os.environ.get("DB_AUTH_PASSWORD", "change_me"),
        "REALM_1_DATABASE": os.environ.get("REALM_1_DATABASE", "acore_characters"),
    }
    lines = []
    seen = set()
    for line in text.splitlines():
        key = line.split("=", 1)[0] if "=" in line else ""
        if key in replacements:
            lines.append(f"{key}={replacements[key]}")
            seen.add(key)
        else:
            lines.append(line)
    for key, value in replacements.items():
        if key not in seen:
            lines.append(f"{key}={value}")
    env_path.write_text("\n".join(lines) + "\n")
    run(["chown", "www-data:www-data", str(env_path)], check=False)
    run(["chmod", "640", str(env_path)], check=False)


def configure_php() -> None:
    pool = Path(f"/etc/php/{PHP_VER}/fpm/pool.d/www.conf")
    allowed = f"{WEB_ROOT}/:/tmp/:/var/www/html/"
    if pool.exists():
        text = pool.read_text()
        line = f"php_admin_value[open_basedir] = {allowed}"
        if "php_admin_value[open_basedir]" in text:
            text = "\n".join(line if l.strip().startswith("php_admin_value[open_basedir]") else l for l in text.splitlines())
        else:
            text += "\n" + line + "\n"
        pool.write_text(text)
    run(["systemctl", "restart", f"php{PHP_VER}-fpm"], check=False)


def nginx_http(domain: str) -> None:
    Path("/etc/nginx/sites-available/wow").write_text(f"""
server {{
    listen 80;
    server_name {domain};
    root {WEB_ROOT}/public;
    index index.php index.html;

    location ^~ /.well-known/acme-challenge/ {{
        root {WEB_ROOT}/public;
        default_type "text/plain";
        allow all;
    }}

    location / {{
        try_files $uri $uri/ /index.php?$query_string;
    }}

    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php{PHP_VER}-fpm.sock;
    }}

    location ~ /\\. {{ deny all; }}
    access_log /var/log/nginx/wow_access.log;
    error_log /var/log/nginx/wow_error.log;
}}
""")
    sites_enabled = Path("/etc/nginx/sites-enabled")
    sites_enabled.mkdir(exist_ok=True)
    link = sites_enabled / "wow"
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to("/etc/nginx/sites-available/wow")
    default = sites_enabled / "default"
    if default.exists() or default.is_symlink():
        default.unlink()
    run(["nginx", "-t"])
    run(["systemctl", "reload", "nginx"], check=False)


def nginx_https(domain: str) -> None:
    Path("/etc/nginx/snippets").mkdir(exist_ok=True)
    Path(f"/etc/nginx/snippets/ssl-{domain}.conf").write_text(f"""
ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
""")
    Path("/etc/nginx/sites-available/wow").write_text(f"""
server {{
    listen 80;
    server_name {domain};
    root {WEB_ROOT}/public;
    location ^~ /.well-known/acme-challenge/ {{ root {WEB_ROOT}/public; default_type "text/plain"; allow all; }}
    location / {{ return 301 https://$host$request_uri; }}
}}
server {{
    listen 443 ssl http2;
    server_name {domain};
    include /etc/nginx/snippets/ssl-{domain}.conf;
    root {WEB_ROOT}/public;
    index index.php index.html;
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{ include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php{PHP_VER}-fpm.sock; }}
    location ~ /\\. {{ deny all; }}
    access_log /var/log/nginx/wow_access.log;
    error_log /var/log/nginx/wow_error.log;
}}
""")
    run(["nginx", "-t"])
    run(["systemctl", "reload", "nginx"], check=False)


def obtain_cert(domain: str) -> None:
    live = Path(f"/etc/letsencrypt/live/{domain}/fullchain.pem")
    if live.exists():
        return
    apt_install(["certbot"])
    (WEB_ROOT / "public/.well-known/acme-challenge").mkdir(parents=True, exist_ok=True)
    nginx_http(domain)
    run(["certbot", "certonly", "--agree-tos", "-m", EMAIL, "--webroot", "-w", str(WEB_ROOT / "public"), "-d", domain])


def install(domain: str) -> None:
    apt_install(["ca-certificates", "curl", "rsync", "git", "gnupg", "lsb-release", "nginx"])
    setup_php_repo()
    apt_install([f"php{PHP_VER}", f"php{PHP_VER}-cli", f"php{PHP_VER}-fpm", f"php{PHP_VER}-mysql", f"php{PHP_VER}-gmp", f"php{PHP_VER}-curl", f"php{PHP_VER}-mbstring", f"php{PHP_VER}-xml", f"php{PHP_VER}-zip"])
    run(["systemctl", "enable", "nginx", f"php{PHP_VER}-fpm"], check=False)
    open_firewall()
    deploy_source()
    ensure_env(domain)
    configure_php()
    nginx_http(domain)
    obtain_cert(domain)
    nginx_https(domain)
    save_domain(domain)
    print(f"\n✅ 安装完成：https://{domain}/")


def change_domain() -> None:
    old = get_saved_domain()
    new = input(f"当前域名 {old}，请输入新域名（回车取消）：").strip()
    if not new:
        return
    ensure_env(new)
    nginx_http(new)
    obtain_cert(new)
    nginx_https(new)
    save_domain(new)
    print(f"✅ 域名已修改：{old} -> {new}")


def renew_cert() -> None:
    apt_install(["certbot"])
    run(["certbot", "renew", "--quiet", "--deploy-hook", "systemctl reload nginx"], check=False)
    print("✅ 已执行证书续期。")


def menu() -> None:
    require_root()
    print(f"""
==========================================
 WoW 新架构注册站管理菜单
 当前记录域名：{get_saved_domain()}
 站点目录：{WEB_ROOT}
 GitHub：{REPO_URL}
==========================================
1) 一键安装
2) 修改域名
3) 更新证书
0) 退出
""")
    choice = input("请输入选项编号：").strip()
    if choice == "1":
        domain = input(f"请输入域名（回车默认 {DEFAULT_DOMAIN}）：").strip() or DEFAULT_DOMAIN
        install(domain)
    elif choice == "2":
        change_domain()
    elif choice == "3":
        renew_cert()
    else:
        print("已退出。")


if __name__ == "__main__":
    menu()
