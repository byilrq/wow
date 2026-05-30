# 黑石 WoW 注册站


## 目录结构

```text
public/index.php          # Web 入口
public/assets/style.css   # 样式
public/downloads/         # 登录器下载目录，安装时自动放入 WOWOL.bat
src/WowApp.php            # 核心逻辑
storage/announcements.json# 公告数据
config.php                # 配置文件，保留中文注释
wow.sh                    # 主安装/更新脚本
wow.py                    # 兼容入口，调用 wow.sh
```

## 部署

上传到 GitHub 后，在 VPS 上运行：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/byilrq/wow/main/wow.sh
sudo bash wow.sh
```

新版要求：网站安装、依赖安装、Nginx 网站配置、Nginx 游戏流量转发配置，都由 `wow.sh` 统一实现。如果系统已安装 Nginx/PHP，脚本会继续更新配置并 reload。

## 网站监听模式

默认模式是：

```bash
WOW_BIND_MODE=local_proxy
LOCAL_BIND_HOST=127.0.0.1
LOCAL_HTTP_PORT=8080
```

适合 Hysteria / Xray / Caddy 已占用公网 443 的服务器。此时网站只监听本机：

```text
http://127.0.0.1:8080
```

然后由你的代理工具手动反代到这个地址。

如果你希望 Nginx 直接管理公网 80/443：

```bash
WOW_BIND_MODE=public_https sudo -E bash wow.sh
```

## 游戏流量转发

保留旧版 Nginx stream 转发能力。默认配置：

```bash
GAME_PROXY_ENABLE=true
GAME_PROXY_TARGET_HOST=byilrq.iok.la
GAME_PROXY_AUTH_PORT=3724
GAME_PROXY_WORLD_PORT=8085
```

