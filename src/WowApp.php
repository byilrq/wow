<?php

declare(strict_types=1);

function env(string $key, mixed $default = null): mixed
{
    static $loaded = false;
    if (!$loaded) {
        $loaded = true;
        $envFile = dirname(__DIR__) . '/.env';
        if (is_file($envFile)) {
            foreach (file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
                $line = trim($line);
                if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
                    continue;
                }
                [$name, $value] = array_map('trim', explode('=', $line, 2));
                $value = trim($value, "\"'");
                $_ENV[$name] = $value;
                putenv($name . '=' . $value);
            }
        }
    }
    $value = getenv($key);
    if ($value === false || $value === '') {
        return $_ENV[$key] ?? $default;
    }
    return $value;
}

final class WowApp
{
    private array $config;
    private ?PDO $auth = null;
    private array $realmConnections = [];
    private array $flash = [];

    public function __construct(array $config)
    {
        $this->config = $config;
        date_default_timezone_set($this->config['app']['timezone'] ?? 'Asia/Shanghai');
        if (session_status() !== PHP_SESSION_ACTIVE) {
            session_start();
        }
        if (empty($_SESSION['csrf'])) {
            $_SESSION['csrf'] = bin2hex(random_bytes(32));
        }
    }

    public function run(): void
    {
        $page = $_GET['page'] ?? 'home';
        if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'register') {
            $this->handleRegister();
        }

        $this->render(match ($page) {
            'register' => $this->pageRegister(),
            'status' => $this->pageStatus(),
            'announcements', 'news' => $this->pageAnnouncements(),
            default => $this->pageHome(),
        }, $page);
    }

    private function config(string $path, mixed $default = null): mixed
    {
        $value = $this->config;
        foreach (explode('.', $path) as $part) {
            if (!is_array($value) || !array_key_exists($part, $value)) {
                return $default;
            }
            $value = $value[$part];
        }
        return $value;
    }

    private function csrf(): string
    {
        return $_SESSION['csrf'] ?? '';
    }

    private function h(string $value): string
    {
        return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    }

    private function db(array $cfg): PDO
    {
        $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=%s', $cfg['host'], $cfg['port'], $cfg['database'], $cfg['charset'] ?? 'utf8mb4');
        return new PDO($dsn, $cfg['username'], $cfg['password'], [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    }

    private function auth(): PDO
    {
        return $this->auth ??= $this->db($this->config('database.auth'));
    }

    private function realmDb(int $realmId): PDO
    {
        if (!isset($this->realmConnections[$realmId])) {
            $realm = $this->config("database.realms.$realmId");
            $this->realmConnections[$realmId] = $this->db($realm);
        }
        return $this->realmConnections[$realmId];
    }

    private function addFlash(string $type, string $message): void
    {
        $this->flash[] = ['type' => $type, 'message' => $message];
    }

    private function handleRegister(): void
    {
        try {
            if (!hash_equals($this->csrf(), $_POST['csrf'] ?? '')) {
                throw new RuntimeException('页面已过期，请刷新后重试。');
            }
            $this->verifyCaptcha();

            $username = strtoupper(trim((string)($_POST['username'] ?? '')));
            $email = strtoupper(trim((string)($_POST['email'] ?? '')));
            $password = (string)($_POST['password'] ?? '');
            $repassword = (string)($_POST['repassword'] ?? '');

            $this->validateRegistration($username, $email, $password, $repassword);

            $auth = $this->auth();
            $auth->beginTransaction();
            if (!$this->config('account.multiple_email_use') && $this->exists('account', 'email', $email)) {
                throw new RuntimeException('这个邮箱已经注册过账号。');
            }
            if ($this->exists('account', 'username', $username)) {
                throw new RuntimeException('这个账号名已经存在。');
            }

            if ($this->config('account.srp6_support')) {
                [$salt, $verifier] = $this->srp6($username, $password);
                $sql = sprintf(
                    'INSERT INTO account (username, %s, %s, email, expansion) VALUES (:username, :salt, :verifier, :email, :expansion)',
                    $this->safeColumn($this->config('account.salt_field', 'salt')),
                    $this->safeColumn($this->config('account.verifier_field', 'verifier'))
                );
                $stmt = $auth->prepare($sql);
                $stmt->bindValue(':username', $username);
                $stmt->bindValue(':salt', $salt, PDO::PARAM_LOB);
                $stmt->bindValue(':verifier', $verifier, PDO::PARAM_LOB);
                $stmt->bindValue(':email', $email);
                $stmt->bindValue(':expansion', (int)$this->config('app.expansion'), PDO::PARAM_INT);
                $stmt->execute();
            } else {
                $hash = strtoupper(sha1(strtoupper($username . ':' . $password)));
                $stmt = $auth->prepare('INSERT INTO account (username, sha_pass_hash, email, expansion) VALUES (:username, :hash, :email, :expansion)');
                $stmt->execute([
                    ':username' => $username,
                    ':hash' => $hash,
                    ':email' => $email,
                    ':expansion' => (int)$this->config('app.expansion'),
                ]);
            }
            $auth->commit();
            $this->addFlash('success', '账号创建成功，请使用客户端登录游戏。');
        } catch (Throwable $e) {
            if ($this->auth instanceof PDO && $this->auth->inTransaction()) {
                $this->auth->rollBack();
            }
            $this->addFlash('error', $e->getMessage());
        }
    }

    private function validateRegistration(string $username, string $email, string $password, string $repassword): void
    {
        if (!preg_match('/^[0-9A-Z_-]+$/', $username)) {
            throw new RuntimeException('账号名只能使用字母、数字、下划线和中横线。');
        }
        $ulen = strlen($username);
        if ($ulen < $this->config('account.username_min') || $ulen > $this->config('account.username_max')) {
            throw new RuntimeException('账号名长度不正确。');
        }
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            throw new RuntimeException('请输入有效邮箱。');
        }
        if ($password !== $repassword) {
            throw new RuntimeException('两次输入的密码不一致。');
        }
        $plen = strlen($password);
        if ($plen < $this->config('account.password_min') || $plen > $this->config('account.password_max')) {
            throw new RuntimeException('密码长度不正确。');
        }
    }

    private function verifyCaptcha(): void
    {
        $secret = (string)$this->config('captcha.hcaptcha_secret', '');
        if ($secret === '') {
            return;
        }
        $token = $_POST['h-captcha-response'] ?? '';
        if ($token === '') {
            throw new RuntimeException('请先完成人机验证。');
        }
        $context = stream_context_create([
            'http' => [
                'method' => 'POST',
                'header' => "Content-Type: application/x-www-form-urlencoded\r\n",
                'content' => http_build_query(['secret' => $secret, 'response' => $token]),
                'timeout' => 8,
            ],
        ]);
        $raw = file_get_contents('https://hcaptcha.com/siteverify', false, $context);
        $json = json_decode($raw ?: '{}', true);
        if (empty($json['success'])) {
            throw new RuntimeException('人机验证失败，请重试。');
        }
    }

    private function exists(string $table, string $column, string $value): bool
    {
        $sql = sprintf('SELECT 1 FROM %s WHERE %s = :value LIMIT 1', $this->safeColumn($table), $this->safeColumn($column));
        $stmt = $this->auth()->prepare($sql);
        $stmt->execute([':value' => $value]);
        return (bool)$stmt->fetchColumn();
    }

    private function safeColumn(string $name): string
    {
        if (!preg_match('/^[a-zA-Z0-9_]+$/', $name)) {
            throw new RuntimeException('配置中的数据库字段名不安全。');
        }
        return $name;
    }

    private function srp6(string $username, string $password): array
    {
        if (!function_exists('gmp_init')) {
            throw new RuntimeException('服务器未安装 php-gmp，无法生成 SRP6 密码数据。');
        }
        $salt = random_bytes(32);
        $g = gmp_init(7);
        $N = gmp_init('894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7', 16);
        $identityHash = sha1(strtoupper($username . ':' . $password), true);
        $x = gmp_import(sha1($salt . $identityHash, true), 1, GMP_LSW_FIRST);
        $verifier = gmp_export(gmp_powm($g, $x, $N), 1, GMP_LSW_FIRST);
        $verifier = str_pad($verifier, 32, chr(0), STR_PAD_RIGHT);
        return [$salt, $verifier];
    }

    private function status(): array
    {
        $result = ['auth_online' => false, 'realms' => [], 'total_accounts' => null, 'total_online' => 0];
        try {
            $auth = $this->auth();
            $result['auth_online'] = true;
            $result['total_accounts'] = (int)$auth->query('SELECT COUNT(*) FROM account')->fetchColumn();
            $realmlist = [];
            try {
                foreach ($auth->query('SELECT id, name, address, port, population FROM realmlist') as $row) {
                    $realmlist[(int)$row['id']] = $row;
                }
            } catch (Throwable) {
                $realmlist = [];
            }
            foreach ($this->config('database.realms', []) as $id => $realmCfg) {
                $realmId = (int)$id;
                $realm = [
                    'id' => $realmId,
                    'name' => $realmlist[$realmId]['name'] ?? $realmCfg['name'] ?? ('Realm ' . $realmId),
                    'address' => $realmlist[$realmId]['address'] ?? $this->config('app.realmlist'),
                    'port' => $realmlist[$realmId]['port'] ?? 8085,
                    'population' => $realmlist[$realmId]['population'] ?? null,
                    'online' => null,
                    'characters' => null,
                    'ok' => false,
                ];
                try {
                    $db = $this->realmDb($realmId);
                    $realm['characters'] = (int)$db->query('SELECT COUNT(*) FROM characters')->fetchColumn();
                    $realm['online'] = (int)$db->query('SELECT COUNT(*) FROM characters WHERE online = 1')->fetchColumn();
                    $realm['ok'] = true;
                    $result['total_online'] += $realm['online'];
                } catch (Throwable $e) {
                    $realm['error'] = $e->getMessage();
                }
                $result['realms'][] = $realm;
            }
        } catch (Throwable $e) {
            $result['error'] = $e->getMessage();
        }
        return $result;
    }

    private function announcements(): array
    {
        $file = dirname(__DIR__) . '/storage/announcements.json';
        $items = json_decode(is_file($file) ? file_get_contents($file) : '[]', true);
        return is_array($items) ? $items : [];
    }

    private function pageHome(): string
    {
        $status = $this->status();
        ob_start(); ?>
        <section class="hero">
            <div>
                <p class="eyebrow">Wrath of the Lich King · 私服注册站</p>
                <h1><?= $this->h($this->config('app.name')) ?></h1>
                <p>注册账号、查看服务器状态、阅读最新公告。客户端 Realmlist：<code>set realmlist <?= $this->h($this->config('app.realmlist')) ?></code></p>
                <div class="actions">
                    <a class="btn primary" href="?page=register">立即注册</a>
                    <a class="btn" href="?page=status">查看状态</a>
                </div>
            </div>
            <div class="panel metric">
                <span>在线人数</span>
                <strong><?= (int)$status['total_online'] ?></strong>
                <small><?= $this->h($this->config('app.game_version')) ?></small>
            </div>
        </section>
        <section class="grid two">
            <div class="card"><h2>服务器信息</h2><p>版本：<?= $this->h($this->config('app.game_version')) ?></p><p>Realmlist：<?= $this->h($this->config('app.realmlist')) ?></p></div>
            <div class="card"><h2>最新公告</h2><?= $this->announcementList(2) ?></div>
        </section>
        <?php return (string)ob_get_clean();
    }

    private function pageRegister(): string
    {
        $siteKey = (string)$this->config('captcha.hcaptcha_site_key', '');
        ob_start(); ?>
        <section class="page-head"><h1>账号注册</h1><p>创建游戏账号后，请在客户端使用账号名和密码登录。</p></section>
        <section class="card form-card">
            <form method="post" action="?page=register" autocomplete="off">
                <input type="hidden" name="csrf" value="<?= $this->h($this->csrf()) ?>">
                <input type="hidden" name="action" value="register">
                <label>邮箱<input name="email" type="email" required placeholder="you@example.com"></label>
                <label>账号名<input name="username" required minlength="2" maxlength="16" pattern="[A-Za-z0-9_-]+" placeholder="USERNAME"></label>
                <label>密码<input name="password" type="password" required minlength="4" maxlength="16"></label>
                <label>重复密码<input name="repassword" type="password" required minlength="4" maxlength="16"></label>
                <?php if ($siteKey !== ''): ?>
                    <script src="https://js.hcaptcha.com/1/api.js" async defer></script>
                    <div class="h-captcha" data-sitekey="<?= $this->h($siteKey) ?>"></div>
                <?php endif; ?>
                <button class="btn primary" type="submit">创建账号</button>
            </form>
        </section>
        <?php return (string)ob_get_clean();
    }

    private function pageStatus(): string
    {
        $status = $this->status();
        ob_start(); ?>
        <section class="page-head"><h1>服务器状态</h1><p>数据库、分区、在线人数和角色统计。</p></section>
        <section class="grid three">
            <div class="card metric"><span>认证库</span><strong><?= $status['auth_online'] ? '在线' : '离线' ?></strong></div>
            <div class="card metric"><span>总账号</span><strong><?= $status['total_accounts'] ?? '-' ?></strong></div>
            <div class="card metric"><span>在线角色</span><strong><?= (int)$status['total_online'] ?></strong></div>
        </section>
        <section class="card"><h2>分区列表</h2><div class="table-wrap"><table><thead><tr><th>分区</th><th>地址</th><th>在线</th><th>角色数</th><th>状态</th></tr></thead><tbody>
        <?php foreach ($status['realms'] as $realm): ?>
            <tr><td><?= $this->h($realm['name']) ?></td><td><?= $this->h($realm['address'] . ':' . $realm['port']) ?></td><td><?= $realm['online'] ?? '-' ?></td><td><?= $realm['characters'] ?? '-' ?></td><td><span class="badge <?= $realm['ok'] ? 'ok' : 'bad' ?>"><?= $realm['ok'] ? '正常' : '异常' ?></span></td></tr>
        <?php endforeach; ?>
        </tbody></table></div></section>
        <?php return (string)ob_get_clean();
    }

    private function pageAnnouncements(): string
    {
        ob_start(); ?>
        <section class="page-head"><h1>公告</h1><p>服务器维护、活动、版本说明都会显示在这里。</p></section>
        <section class="card announcements"><?= $this->announcementList() ?></section>
        <?php return (string)ob_get_clean();
    }

    private function announcementList(?int $limit = null): string
    {
        $items = $this->announcements();
        usort($items, fn($a, $b) => strcmp($b['date'] ?? '', $a['date'] ?? ''));
        if ($limit !== null) {
            $items = array_slice($items, 0, $limit);
        }
        ob_start();
        if (!$items) {
            echo '<p>暂无公告。</p>';
        }
        foreach ($items as $item): ?>
            <article class="announcement <?= $this->h($item['level'] ?? 'normal') ?>">
                <div><h3><?= $this->h($item['title'] ?? '未命名公告') ?></h3><time><?= $this->h($item['date'] ?? '') ?></time></div>
                <p><?= nl2br($this->h($item['content'] ?? '')) ?></p>
            </article>
        <?php endforeach;
        return (string)ob_get_clean();
    }

    private function render(string $content, string $page): void
    {
        $title = $this->h($this->config('app.name'));
        $nav = [
            'home' => '首页',
            'register' => '注册',
            'status' => '状态',
            'announcements' => '公告',
        ];
        ?>
        <!doctype html><html lang="zh-CN"><head>
            <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title><?= $title ?></title><link rel="stylesheet" href="assets/style.css">
        </head><body>
        <header class="topbar"><a class="brand" href="?page=home"><?= $title ?></a><nav>
            <?php foreach ($nav as $key => $label): ?><a class="<?= $page === $key ? 'active' : '' ?>" href="?page=<?= $key ?>"><?= $label ?></a><?php endforeach; ?>
        </nav></header>
        <main>
            <?php foreach ($this->flash as $message): ?><div class="flash <?= $this->h($message['type']) ?>"><?= $this->h($message['message']) ?></div><?php endforeach; ?>
            <?= $content ?>
        </main>
        <footer>© <?= date('Y') ?> <?= $title ?> · Realmlist: <?= $this->h($this->config('app.realmlist')) ?></footer>
        </body></html>
        <?php
    }
}
