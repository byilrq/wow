# Azerother AI服务器 WoW 注册站

这是一个精简架构的 WoW 私服注册与信息展示站点，包含：

- 首页 + 在线玩家列表
- 注册页面
- 公告页面，可通过 PIN 添加/删除公告
- 登录器下载链接 `/downloads/WOWOL.bat`
- Nginx 本地网站配置
- Nginx stream 游戏流量转发：TCP 3724 / 8085

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
h.sh                      # Hysteria 安装脚本
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

## 登录器下载

把 `WOWOL.bat` 放在 GitHub 仓库根目录。安装时 `wow.sh` 会自动复制到：

```text
/www/wow/public/downloads/WOWOL.bat
```

网页首页会显示“登录器下载”，浏览器访问：

```text
/downloads/WOWOL.bat
```

## 游戏流量转发

保留旧版 Nginx stream 转发能力。默认配置：

```bash
GAME_PROXY_ENABLE=true
GAME_PROXY_TARGET_HOST=byilrq.iok.la
GAME_PROXY_AUTH_PORT=3724
GAME_PROXY_WORLD_PORT=8085
```

脚本会生成：

```text
/etc/nginx/stream-conf.d/wow-game-proxy.conf
```

效果：

```text
玩家 -> 本 VPS:3724 -> byilrq.iok.la:3724
玩家 -> 本 VPS:8085 -> byilrq.iok.la:8085
```

这对应旧版 `nginx.conf` 里的 `stream` 配置。

如需关闭游戏转发：

```bash
GAME_PROXY_ENABLE=false sudo -E bash wow.sh
```

## Hysteria 说明

`wow.sh` 不会修改 Hysteria 配置。Hysteria 安装和伪装站选择由 `h.sh` 管理。你可以选择外部伪装站，也可以选择本地 WoW 站：

```text
http://127.0.0.1:8080
```

## 配置

`.env` 可覆盖 `config.php` 中的参数，例如：

```env
APP_NAME=Azerother AI服务器
REALMLIST=你的域名
LAUNCHER_FILE=downloads/WOWOL.bat
LAUNCHER_LABEL=登录器下载
DB_AUTH_HOST=byilrq.iok.la
DB_AUTH_PORT=58006
GAME_PROXY_ENABLE=true
GAME_PROXY_TARGET_HOST=byilrq.iok.la
```

## 本版更新：在线玩家稳定显示

- 在线玩家列表保留稳定字段：角色、种族图标、职业图标、等级。
- 已取消公会、头衔、地图位置列，避免不同核心/数据库结构差异导致读取失败。
- 当没有在线玩家或角色库暂时不可读时，统一提示：服务器离线！


## 本版更新：首页视觉精简

- 站点标题默认改为 `Azerother AI服务器`。
- 首页主视觉从文字标题改为 WLK 图标。
- 首页去掉说明语、Realmlist 提示和大按钮区。
- `WOWOL.bat` 以文件名 + 下载图标形式展示。
- 在线玩家模块标题改为“服务器状态”，并隐藏人数/缓存提示。
