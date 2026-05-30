#!/usr/bin/env python3
"""黑石 WoW 注册站一键部署脚本。

职责边界：
- 本脚本只负责 WoW 注册站自身安装、源码更新、PHP-FPM、Nginx 配置。
- 本脚本不会读取、修改或重启 Hysteria / Xray / Caddy 等代理工具。
- 如果公网 443 已经由代理工具占用，请使用默认 local_proxy 模式，代理工具手动反代到 http://127.0.0.1:8080。

部署模式：
1. local_proxy（默认）：Nginx 只监听 127.0.0.1:8080，适合已有 Hysteria/代理工具占用公网 443。
2. public_https：Nginx 监听公网 80/443，并由本脚本用 certbot 申请证书。

常用：
  sudo python3 wow.py
  WOW_BIND_MODE=local_proxy sudo -E python3 wow.py
  WOW_BIND_MODE=public_https sudo -E python3 wow.py
"""
from __future__ import annotations

import os
import platform
import shutil
import socket
import subprocess
from pathlib import Path

DEFAULT_DOMAIN = os.environ.get("DEFAULT_DOMAIN", "sharq.eu.org")
WEB_ROOT = Path(os.environ.get("WEB_ROOT", "/www/wow"))
PHP_VER = os.environ.get("PHP_VER", "8.2")
EMAIL = os.environ.get("EMAIL", "byilrq@gmail.com")
REPO_URL = os.environ.get("REPO_URL", "https://github.com/byilrq/wow.git")
REPO_BRANCH = os.environ.get("REPO_BRANCH", "main")
DOMAIN_STATE_FILE = Path("/etc/wow_domain.conf")

WOW_BIND_MODE = os.environ.get("WOW_BIND_MODE", "local_proxy").strip().lower()
LOCAL_BIND_HOST = os.environ.get("LOCAL_BIND_HOST", "127.0.0.1")
LOCAL_HTTP_PORT = int(os.environ.get("LOCAL_HTTP_PORT", "8080"))


def run(cmd: list[str] | str, check: bool = True, cwd: Path | None = None) -> subprocess.CompletedProcess:
    print("\n==>", cmd if isinstance(cmd, str) else " ".join(cmd))
    return subprocess.run(cmd, shell=isinstance(cmd, str), check=check, cwd=cwd)


def require_root() -> None:
    if os.geteuid() != 0:
        raise SystemExit("请使用 root 运行：sudo python3 wow.py")


def read_os() -> tuple[str, str]:
    data: dict[str, str] = {}
    path = Path("/etc/os-release")
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v.strip('"')
    return data.get("ID", platform.system().lower()), data.get("VERSION_CODENAME", "bullseye")


def save_domain(domain: str) -> None:
    DOMAIN_STATE_FILE.write_text(domain + "\n")


def get_saved_domain() -> str:
    return DOMAIN_STATE_FILE.read_text().strip() if DOMAIN_STATE_FILE.exists() else DEFAULT_DOMAIN


def tcp_port_is_busy(host: str, port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        return s.connect_ex((host, port)) == 0
    finally:
        s.close()


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
    # local_proxy 模式只监听 127.0.0.1，不需要开放 8080；public_https 需要 80/443。
    if WOW_BIND_MODE != "public_https":
        return
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
    if not (WEB_ROOT / "public/index.php").exists():
        raise SystemExit("部署失败：仓库中没有 public/index.php，请确认 GitHub 仓库已上传新版程序包。")
    (WEB_ROOT / "storage").mkdir(parents=True, exist_ok=True)
    if not (WEB_ROOT / "storage/announcements.json").exists():
        (WEB_ROOT / "storage/announcements.json").write_text("[]\n")
    run(["chown", "-R", "www-data:www-data", str(WEB_ROOT)], check=False)


def ensure_env(domain: str) -> None:
    env_path = WEB_ROOT / ".env"
    if not env_path.exists():
        sample = WEB_ROOT / ".env.example"
        shutil.copy(sample, env_path) if sample.exists() else env_path.write_text("")

    replacements = {
        "APP_URL": os.environ.get("APP_URL", f"https://{domain}"),
        "APP_NAME": os.environ.get("APP_NAME", "黑石"),
        "REALMLIST": os.environ.get("REALMLIST", domain),
        "DB_AUTH_HOST": os.environ.get("DB_AUTH_HOST", "byilrq.iok.la"),
        "DB_AUTH_PORT": os.environ.get("DB_AUTH_PORT", "58006"),
        "DB_AUTH_DATABASE": os.environ.get("DB_AUTH_DATABASE", "acore_auth"),
        "DB_AUTH_USERNAME": os.environ.get("DB_AUTH_USERNAME", "admin"),
        "DB_AUTH_PASSWORD": os.environ.get("DB_AUTH_PASSWORD", "Plex0819$"),
        "REALM_1_NAME": os.environ.get("REALM_1_NAME", "黑石"),
        "REALM_1_HOST": os.environ.get("REALM_1_HOST", os.environ.get("DB_AUTH_HOST", "byilrq.iok.la")),
        "REALM_1_PORT": os.environ.get("REALM_1_PORT", os.environ.get("DB_AUTH_PORT", "58006")),
        "REALM_1_DATABASE": os.environ.get("REALM_1_DATABASE", "acore_characters"),
        "REALM_1_USERNAME": os.environ.get("REALM_1_USERNAME", os.environ.get("DB_AUTH_USERNAME", "admin")),
        "REALM_1_PASSWORD": os.environ.get("REALM_1_PASSWORD", os.environ.get("DB_AUTH_PASSWORD", "Plex0819$")),
        "CAPTCHA_TYPE": os.environ.get("CAPTCHA_TYPE", "1"),
        "CAPTCHA_KEY": os.environ.get("CAPTCHA_KEY", "10b6462c-973a-458c-84f4-6c60794e2a78"),
        "CAPTCHA_SECRET": os.environ.get("CAPTCHA_SECRET", "ES_9278a8805838434c9fa776e49af64355"),
        "CAPTCHA_LANGUAGE": os.environ.get("CAPTCHA_LANGUAGE", "en"),
        "ANNOUNCEMENT_PIN": os.environ.get("ANNOUNCEMENT_PIN", "0819"),
    }

    text = env_path.read_text()
    lines: list[str] = []
    seen: set[str] = set()
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


def enable_nginx_site() -> None:
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


def write_nginx_site_local(domain: str) -> None:
    Path("/etc/nginx/sites-available/wow").write_text(f"""
server {{
    listen {LOCAL_BIND_HOST}:{LOCAL_HTTP_PORT};
    server_name {domain} localhost 127.0.0.1 _;

    root {WEB_ROOT}/public;
    index index.php index.html;

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
    enable_nginx_site()


def write_nginx_site_http(domain: str) -> None:
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

    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{ include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php{PHP_VER}-fpm.sock; }}
    location ~ /\\. {{ deny all; }}
    access_log /var/log/nginx/wow_access.log;
    error_log /var/log/nginx/wow_error.log;
}}
""")
    enable_nginx_site()


def write_nginx_site_https(domain: str) -> None:
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
    enable_nginx_site()


def obtain_cert(domain: str) -> None:
    live = Path(f"/etc/letsencrypt/live/{domain}/fullchain.pem")
    if live.exists():
        return
    if tcp_port_is_busy("127.0.0.1", 443):
        raise SystemExit("检测到本机 TCP 443 已被占用，不能使用 public_https 模式。请改用 WOW_BIND_MODE=local_proxy。")
    apt_install(["certbot"])
    (WEB_ROOT / "public/.well-known/acme-challenge").mkdir(parents=True, exist_ok=True)
    write_nginx_site_http(domain)
    run(["certbot", "certonly", "--agree-tos", "-m", EMAIL, "--webroot", "-w", str(WEB_ROOT / "public"), "-d", domain])


def install(domain: str) -> None:
    mode = WOW_BIND_MODE
    if mode not in {"local_proxy", "public_https"}:
        raise SystemExit("WOW_BIND_MODE 只能是 local_proxy 或 public_https")

    apt_install(["ca-certificates", "curl", "rsync", "git", "gnupg", "lsb-release", "nginx"])
    setup_php_repo()
    apt_install([
        f"php{PHP_VER}", f"php{PHP_VER}-cli", f"php{PHP_VER}-fpm", f"php{PHP_VER}-mysql",
        f"php{PHP_VER}-gmp", f"php{PHP_VER}-curl", f"php{PHP_VER}-mbstring", f"php{PHP_VER}-xml", f"php{PHP_VER}-zip", f"php{PHP_VER}-soap",
    ])
    run(["systemctl", "enable", "nginx", f"php{PHP_VER}-fpm"], check=False)
    open_firewall()
    deploy_source()
    ensure_env(domain)
    configure_php()

    if mode == "local_proxy":
        if tcp_port_is_busy(LOCAL_BIND_HOST, LOCAL_HTTP_PORT):
            print(f"\n⚠️ {LOCAL_BIND_HOST}:{LOCAL_HTTP_PORT} 已有服务监听，Nginx reload 可能失败。可用 LOCAL_HTTP_PORT=8081 改端口。")
        write_nginx_site_local(domain)
        print("\n✅ 安装完成：local_proxy 模式")
        print(f"本机测试地址：http://{LOCAL_BIND_HOST}:{LOCAL_HTTP_PORT}/")
        print(f"公网访问地址通常由你的代理工具提供：https://{domain}/")
        print(f"如果使用 Hysteria/Xray/Caddy 伪装站，请手动把反代目标设置为：http://{LOCAL_BIND_HOST}:{LOCAL_HTTP_PORT}")
    else:
        write_nginx_site_http(domain)
        obtain_cert(domain)
        write_nginx_site_https(domain)
        print(f"\n✅ 安装完成：https://{domain}/")

    save_domain(domain)


def change_domain() -> None:
    old = get_saved_domain()
    new = input(f"当前域名 {old}，请输入新域名（回车取消）：").strip()
    if not new:
        return
    ensure_env(new)
    if WOW_BIND_MODE == "local_proxy":
        write_nginx_site_local(new)
        print(f"✅ 域名已修改：{old} -> {new}")
        print(f"提醒：本脚本不会修改代理工具配置，请手动把伪装站/反代目标保持为 http://{LOCAL_BIND_HOST}:{LOCAL_HTTP_PORT}")
    else:
        write_nginx_site_http(new)
        obtain_cert(new)
        write_nginx_site_https(new)
        print(f"✅ 域名已修改：{old} -> {new}")
    save_domain(new)


def renew_cert() -> None:
    if WOW_BIND_MODE == "local_proxy":
        print("local_proxy 模式下 WoW 站点不直接管理公网 HTTPS 证书。")
        print("请在你的代理工具/Hysteria 脚本中续签证书，或执行它自己的证书更新菜单。")
        return
    apt_install(["certbot"])
    run(["certbot", "renew", "--quiet", "--deploy-hook", "systemctl reload nginx"], check=False)
    print("✅ 已执行证书续期。")


def menu() -> None:
    require_root()
    print(f"""
==========================================
 黑石 WoW 注册站管理菜单
 当前记录域名：{get_saved_domain()}
 站点目录：{WEB_ROOT}
 GitHub：{REPO_URL}
 模式：{WOW_BIND_MODE}
 本地监听：{LOCAL_BIND_HOST}:{LOCAL_HTTP_PORT}
==========================================
1) 一键安装 / 更新
2) 修改域名
3) 更新证书（仅 public_https 模式）
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
