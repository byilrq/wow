# 黑石 WoW 注册站

这是一个面向私服魔兽世界的轻量注册站，采用新架构实现注册页、首页在线状态、公告页，文件数量少，部署边界清晰。

## 结构

```text
public/index.php          # 唯一 Web 入口
public/assets/style.css   # 页面样式
src/WowApp.php            # 注册、首页在线玩家、公告、验证码、公告管理核心
config.php                # 保留原 WOW_Web 配置参数与中文注释
storage/announcements.json# 公告数据
wow.py                    # 只负责注册站安装和 Nginx 配置
h.sh                      # Hysteria 2 安装/管理脚本，可选择外部伪装站或本机 WoW 注册站
```

## 重要边界

`wow.py` 只负责：

- 安装 PHP 8.2 / PHP-FPM / Nginx / Git / rsync。
- 从 GitHub 仓库拉取本程序。
- 写入 `/www/wow`。
- 生成 `.env`。
- 配置 Nginx。

`wow.py` 不会修改 Hysteria、Xray、Caddy 等代理工具配置，也不会重启这些服务。

如果公网 443 已经被 Hysteria 占用，请使用默认的 `local_proxy` 模式。此时 Nginx 只监听：

```text
http://127.0.0.1:8080
```

然后在 Hysteria 中选择“本机 WoW 注册站”作为伪装站。

## 安装 WoW 注册站

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/byilrq/wow/main/wow.py
sudo python3 wow.py
```

默认模式：

```bash
WOW_BIND_MODE=local_proxy sudo -E python3 wow.py
```

公网直连 HTTPS 模式：

```bash
WOW_BIND_MODE=public_https sudo -E python3 wow.py
```

## 安装 Hysteria 并选择伪装站

```bash
sudo bash h.sh
```

安装或修改伪装站时会出现：

```text
1. 外部伪装站
2. 本机 WoW 注册站
```

选择本机 WoW 注册站时，脚本会写入：

```yaml
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:8080
    rewriteHost: false
  listenHTTPS: :443
```

## 配置

配置文件是 `config.php`，保留原配置参数和中文注释。也支持 `.env` 覆盖常用参数。

验证码参数：

```php
$config['captcha_type'] = 1; // 0(图形验证码), 1(HCaptcha), 2(ReCaptcha v2), >2(禁用验证码)
$config['captcha_key'] = '...';
$config['captcha_secret'] = '...';
$config['captcha_language'] = 'en';
```

公告管理 PIN：

```php
$config['announcement_pin'] = '0819';
```

## 公告管理

进入公告页后可以手动输入公告。添加或删除公告时，页面会弹出 PIN 输入框，默认 PIN：

```text
0819
```

## 测试

本机模式下测试：

```bash
curl -I http://127.0.0.1:8080
```

使用 Hysteria 反代时，用浏览器访问：

```text
https://你的域名/
```

## 流畅度修复说明

本版优化了注册页切回首页/公告页时的卡顿问题：

- 注册写库或 SOAP 前会提前释放 PHP session 锁，避免后续页面请求排队。
- 首页在线玩家状态增加短缓存，默认 15 秒，避免每次切页都实时访问远程角色库。
- 数据库连接默认短超时，远程数据库异常时不会长时间拖住页面。
- 首页不再为了显示在线玩家而每次访问 auth 库读取账号数/realmlist。

可在 `.env` 中调整：

```env
DB_TIMEOUT=2
NETWORK_TIMEOUT=3
PHP_REQUEST_TIMEOUT=12
STATUS_CACHE_SECONDS=15
```
