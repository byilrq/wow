# WoW 新架构注册站

这是一个为 AzerothCore / TrinityCore 类 3.3.5a 私服准备的轻量注册与信息展示站。新版不再使用旧项目的多层 `application/include/template/vendor` 架构，而是采用：

```text
wow/
├── public/index.php          # 唯一 Web 入口
├── public/assets/style.css   # 前端样式
├── src/WowApp.php            # 注册、状态、公告、渲染核心
├── storage/announcements.json# 公告数据
├── config.php                # 集中配置
├── .env.example              # 环境变量模板
├── wow.py                    # 一键部署/改域名/续证书
├── nginx.conf.example        # Nginx 示例
└── php.ini                   # PHP 推荐配置
```

## 已实现功能

- 首页：服务器信息、Realmlist、在线人数摘要
- 注册页：账号名、邮箱、密码注册
- 状态页：认证库状态、总账号、角色总数、在线人数、分区列表
- 公告页：从 `storage/announcements.json` 读取公告
- 支持 AzerothCore / TrinityCore 常见 SRP6 注册字段：`salt` + `verifier`
- 可关闭 SRP6，改用旧式 `sha_pass_hash`
- 可选 hCaptcha
- Python 一键部署脚本：安装环境、从 GitHub 拉取源码、配置 Nginx、申请证书、修改域名、续证书

## 部署方式

先把本程序包内容上传到你的 GitHub 仓库，例如：

```bash
git init
git add .
git commit -m "new lightweight wow web"
git branch -M main
git remote add origin https://github.com/byilrq/wow.git
git push -u origin main
```

然后在服务器运行：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/byilrq/wow/main/wow.py
sudo python3 wow.py
```

默认部署到 `/www/wow`，Nginx 根目录是 `/www/wow/public`。

## 常用环境变量

一键安装前可以这样覆盖默认值：

```bash
export REPO_URL=https://github.com/byilrq/wow.git
export REPO_BRANCH=main
export DEFAULT_DOMAIN=sharq.eu.org
export EMAIL=byilrq@gmail.com
export DB_AUTH_HOST=127.0.0.1
export DB_AUTH_PORT=3306
export DB_AUTH_DATABASE=acore_auth
export DB_AUTH_USERNAME=admin
export DB_AUTH_PASSWORD='你的密码'
export REALM_1_DATABASE=acore_characters
sudo -E python3 wow.py
```

## 修改配置

安装后配置文件在：

```text
/www/wow/.env
```

修改数据库、站点标题、Realmlist、hCaptcha 等配置后，执行：

```bash
sudo systemctl restart php8.2-fpm
```

## 编辑公告

直接编辑：

```text
/www/wow/storage/announcements.json
```

格式：

```json
[
  {
    "title": "维护公告",
    "date": "2026-05-30",
    "level": "important",
    "content": "今晚 22:00 进行例行维护。"
  }
]
```

## 数据库要求

默认按 AzerothCore / TrinityCore 常见表结构读取：

- `acore_auth.account`
- `acore_auth.realmlist`
- `acore_characters.characters`

注册默认写入：

- `username`
- `salt`
- `verifier`
- `email`
- `expansion`

如果你的核心使用旧式密码字段，设置：

```env
SRP6_SUPPORT=false
```

## 菜单功能

```bash
sudo python3 wow.py
```

菜单包含：

1. 一键安装
2. 修改域名
3. 更新证书

## 注意事项

- 云服务器安全组仍需要放行 TCP 80/443。
- 使用 SRP6 时必须安装 `php-gmp`，部署脚本会自动安装。
- Nginx 的 Web 根目录必须指向 `public`，不要直接暴露项目根目录。

## 与 Hysteria 2 / 代理工具共存的本地反代模式

如果服务器上已经有 Hysteria 2、Xray、Caddy 或其他代理工具占用了公网 `443`，不要让 WoW 注册站的 Nginx 再监听公网 `443`，否则会冲突，或者浏览器看到的仍然是代理工具配置里的伪装站。

新版 `wow.py` 默认使用 `local_proxy` 模式：

- WoW 注册站 Nginx 只监听 `127.0.0.1:8080`。
- 公网 `443` 继续由你的代理工具监听。
- 脚本会尝试把 `/etc/hysteria/config.yaml` 的 `masquerade.proxy.url` 改成 `http://127.0.0.1:8080`。
- 浏览器访问 `https://你的域名/` 时，会由 Hysteria 的 masquerade 转发到本机 WoW 注册站。

安装：

```bash
sudo python3 wow.py
```

明确指定本地反代模式：

```bash
WOW_BIND_MODE=local_proxy sudo -E python3 wow.py
```

如本机 8080 已占用：

```bash
LOCAL_HTTP_PORT=8081 WOW_BIND_MODE=local_proxy sudo -E python3 wow.py
```

如果你不想让脚本自动改 Hysteria 配置：

```bash
UPDATE_HYSTERIA_MASQUERADE=0 WOW_BIND_MODE=local_proxy sudo -E python3 wow.py
```

然后手动修改 `/etc/hysteria/config.yaml`：

```yaml
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:8080
    rewriteHost: false
  listenHTTPS: :443
```

修改后重启：

```bash
systemctl restart hysteria-server || systemctl restart hysteria
systemctl reload nginx
```

如果你没有代理工具占用 443，才建议使用传统 HTTPS 模式：

```bash
WOW_BIND_MODE=public_https sudo -E python3 wow.py
```
