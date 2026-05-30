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

function env_bool(string $key, bool $default = false): bool
{
    $value = env($key, $default ? '1' : '0');
    return filter_var($value, FILTER_VALIDATE_BOOL);
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
        date_default_timezone_set('Asia/Shanghai');
        if (!empty($this->config['debug_mode'])) {
            ini_set('display_errors', '1');
            error_reporting(E_ALL);
        }
        // 所有外部请求默认短超时，避免验证码/远程数据库异常时拖慢页面切换。
        ini_set('default_socket_timeout', (string)(int)$this->cfg('network_timeout', 3));
        set_time_limit((int)$this->cfg('php_request_timeout', 12));
        if (session_status() !== PHP_SESSION_ACTIVE) {
            session_start();
        }
        if (empty($_SESSION['csrf'])) {
            $_SESSION['csrf'] = bin2hex(random_bytes(32));
        }
        $this->ensureStorage();
    }

    public function run(): void
    {
        $page = (string)($_GET['page'] ?? 'home');
        if ($_SERVER['REQUEST_METHOD'] === 'POST') {
            $action = (string)($_POST['action'] ?? '');
            if ($action === 'register') {
                $this->handleRegister();
                $page = 'register';
            } elseif ($action === 'add_announcement') {
                $this->handleAddAnnouncement();
                $page = 'announcements';
            } elseif ($action === 'delete_announcement') {
                $this->handleDeleteAnnouncement();
                $page = 'announcements';
            }
        }

        $normalizedPage = $page === 'status' ? 'home' : $page;
        if ($normalizedPage !== 'register') {
            // 首页/公告页不需要继续写 session，提前释放锁，切换页面更顺畅。
            $this->closeSession();
        }

        $this->render(match ($page) {
            'register' => $this->pageRegister(),
            'status' => $this->pageHome(),
            'announcements', 'news' => $this->pageAnnouncements(),
            default => $this->pageHome(),
        }, $normalizedPage);
    }

    private function cfg(string $key, mixed $default = null): mixed
    {
        return array_key_exists($key, $this->config) ? $this->config[$key] : $default;
    }

    private function csrf(): string
    {
        return $_SESSION['csrf'] ?? '';
    }

    private function closeSession(): void
    {
        if (session_status() === PHP_SESSION_ACTIVE) {
            session_write_close();
        }
    }

    private function h(mixed $value): string
    {
        return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    }


    private function launcherUrl(): string
    {
        $file = trim((string)$this->cfg('launcher_file', 'downloads/WOWOL.bat'));
        if ($file === '') {
            $file = trim((string)$this->cfg('patch_location', '/downloads/WOWOL.bat'));
        }
        if (preg_match('#^https?://#i', $file) || str_starts_with($file, '/')) {
            return $file;
        }
        return '/' . ltrim($file, '/');
    }

    private function storagePath(): string
    {
        return dirname(__DIR__) . '/storage/announcements.json';
    }

    private function ensureStorage(): void
    {
        $dir = dirname($this->storagePath());
        if (!is_dir($dir)) {
            mkdir($dir, 0775, true);
        }
        if (!is_file($this->storagePath())) {
            file_put_contents($this->storagePath(), json_encode([], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
        }
    }

    private function addFlash(string $type, string $message): void
    {
        $this->flash[] = ['type' => $type, 'message' => $message];
    }

    private function db(array $cfg): PDO
    {
        $timeout = max(1, (int)$this->cfg('db_timeout', 2));
        $dsn = sprintf(
            'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4;connect_timeout=%d',
            $cfg['host'],
            (int)$cfg['port'],
            $cfg['database'],
            $timeout
        );
        $options = [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
            PDO::ATTR_TIMEOUT => $timeout,
        ];
        if (defined('PDO::MYSQL_ATTR_INIT_COMMAND')) {
            $options[PDO::MYSQL_ATTR_INIT_COMMAND] = 'SET SESSION wait_timeout=5';
        }
        return new PDO($dsn, $cfg['username'], $cfg['password'], $options);
    }

    private function authCfg(): array
    {
        return [
            'host' => $this->cfg('db_auth_host', '127.0.0.1'),
            'port' => (int)$this->cfg('db_auth_port', 3306),
            'database' => $this->cfg('db_auth_dbname', 'acore_auth'),
            'username' => $this->cfg('db_auth_user', 'admin'),
            'password' => $this->cfg('db_auth_pass', ''),
        ];
    }

    private function realmCfg(int|string $realmId): array
    {
        $realm = $this->cfg('realmlists', [])[(string)$realmId] ?? [];
        return [
            'id' => (int)($realm['realmid'] ?? $realmId),
            'name' => $realm['realmname'] ?? '黑石',
            'host' => $realm['db_host'] ?? $this->cfg('db_auth_host', '127.0.0.1'),
            'port' => (int)($realm['db_port'] ?? $this->cfg('db_auth_port', 3306)),
            'database' => $realm['db_name'] ?? 'acore_characters',
            'username' => $realm['db_user'] ?? $this->cfg('db_auth_user', 'admin'),
            'password' => $realm['db_pass'] ?? $this->cfg('db_auth_pass', ''),
        ];
    }

    private function auth(): PDO
    {
        return $this->auth ??= $this->db($this->authCfg());
    }

    private function realmDb(int|string $realmId): PDO
    {
        $key = (string)$realmId;
        if (!isset($this->realmConnections[$key])) {
            $this->realmConnections[$key] = $this->db($this->realmCfg($realmId));
        }
        return $this->realmConnections[$key];
    }

    private function handleRegister(): void
    {
        try {
            $this->verifyCsrf();
            $this->verifyCaptcha();

            $username = strtoupper(trim((string)($_POST['username'] ?? '')));
            $email = strtoupper(trim((string)($_POST['email'] ?? '')));
            $password = (string)($_POST['password'] ?? '');
            $repassword = (string)($_POST['repassword'] ?? '');

            $this->validateRegistration($username, $email, $password, $repassword);

            // 注册写库/ SOAP 可能访问远程服务。提前释放 PHP session 锁，避免用户马上切首页/公告时排队卡住。
            $this->closeSession();

            if (!empty($this->config['soap_for_register'])) {
                $this->registerViaSoap($username, $password);
                $this->addFlash('success', '账号创建成功，请使用客户端登录游戏。');
                return;
            }

            $auth = $this->auth();
            $auth->beginTransaction();
            if (!$this->cfg('multiple_email_use', false) && $this->exists('account', 'email', $email)) {
                throw new RuntimeException('这个邮箱已经注册过账号。');
            }
            if ($this->exists('account', 'username', $username)) {
                throw new RuntimeException('这个账号名已经存在。');
            }

            if (!empty($this->config['srp6_support'])) {
                [$salt, $verifier] = $this->srp6($username, $password);
                $columns = ['username', 'salt', 'verifier', 'email', 'expansion'];
                $values = [':username', ':salt', ':verifier', ':email', ':expansion'];
                if ((int)$this->cfg('srp6_version', 2) > 0 && $this->columnExists('account', 'srp_version')) {
                    $columns[] = 'srp_version';
                    $values[] = ':srp_version';
                }
                $sql = 'INSERT INTO account (' . implode(',', $columns) . ') VALUES (' . implode(',', $values) . ')';
                $stmt = $auth->prepare($sql);
                $stmt->bindValue(':username', $username);
                $stmt->bindValue(':salt', $salt, PDO::PARAM_LOB);
                $stmt->bindValue(':verifier', $verifier, PDO::PARAM_LOB);
                $stmt->bindValue(':email', $email);
                $stmt->bindValue(':expansion', (int)$this->cfg('expansion', 2), PDO::PARAM_INT);
                if (in_array(':srp_version', $values, true)) {
                    $stmt->bindValue(':srp_version', (int)$this->cfg('srp6_version', 2), PDO::PARAM_INT);
                }
                $stmt->execute();
            } else {
                $hash = strtoupper(sha1(strtoupper($username . ':' . $password)));
                $stmt = $auth->prepare('INSERT INTO account (username, sha_pass_hash, email, expansion) VALUES (:username, :hash, :email, :expansion)');
                $stmt->execute([
                    ':username' => $username,
                    ':hash' => $hash,
                    ':email' => $email,
                    ':expansion' => (int)$this->cfg('expansion', 2),
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

    private function verifyCsrf(): void
    {
        if (!hash_equals($this->csrf(), (string)($_POST['csrf'] ?? ''))) {
            throw new RuntimeException('页面已过期，请刷新后重试。');
        }
    }

    private function validateRegistration(string $username, string $email, string $password, string $repassword): void
    {
        if (!preg_match('/^[0-9A-Z_-]{2,16}$/', $username)) {
            throw new RuntimeException('账号名只能使用 2-16 位字母、数字、下划线和中横线。');
        }
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            throw new RuntimeException('请输入有效邮箱。');
        }
        if ($password !== $repassword) {
            throw new RuntimeException('两次输入的密码不一致。');
        }
        if (strlen($password) < 4 || strlen($password) > 16) {
            throw new RuntimeException('密码长度必须为 4-16 位。');
        }
    }

    private function verifyCaptcha(): void
    {
        $type = (int)$this->cfg('captcha_type', 3);
        if ($type > 2) {
            return;
        }

        // 本地图形验证码；同时作为 HCaptcha/ReCaptcha 外部脚本加载失败时的兜底。
        // 这样注册页不会因为 js.hcaptcha.com / google.com 访问慢或不可达而“卡死”。
        $localAnswer = strtolower(trim((string)($_POST['image_captcha'] ?? '')));
        if ($localAnswer !== '') {
            if ($localAnswer !== strtolower((string)($_SESSION['image_captcha'] ?? ''))) {
                throw new RuntimeException('图形验证码错误。');
            }
            unset($_SESSION['image_captcha']);
            return;
        }

        if ($type === 0) {
            throw new RuntimeException('请输入图形验证码。');
        }

        $secret = (string)$this->cfg('captcha_secret', '');
        if ($secret === '') {
            return;
        }

        $tokenField = $type === 1 ? 'h-captcha-response' : 'g-recaptcha-response';
        $verifyUrl = $type === 1 ? 'https://hcaptcha.com/siteverify' : 'https://www.google.com/recaptcha/api/siteverify';
        $token = (string)($_POST[$tokenField] ?? '');
        if ($token === '') {
            throw new RuntimeException('请先完成人机验证；如果外部验证码加载失败，请使用下方图形验证码。');
        }

        $context = stream_context_create([
            'http' => [
                'method' => 'POST',
                'header' => "Content-Type: application/x-www-form-urlencoded\r\n",
                'content' => http_build_query(['secret' => $secret, 'response' => $token]),
                'timeout' => 3,
                'ignore_errors' => true,
            ],
        ]);
        $raw = @file_get_contents($verifyUrl, false, $context);
        if ($raw === false || $raw === '') {
            throw new RuntimeException('外部人机验证服务暂时不可用，请刷新页面后使用图形验证码兜底。');
        }
        $json = json_decode($raw, true);
        if (!is_array($json) || empty($json['success'])) {
            throw new RuntimeException('人机验证失败，请重试。');
        }
    }

    private function registerViaSoap(string $username, string $password): void
    {
        if (!class_exists('SoapClient')) {
            throw new RuntimeException('PHP SOAP 扩展未安装，无法使用 SOAP 注册。');
        }
        $command = str_replace(['{USERNAME}', '{PASSWORD}'], [$username, $password], (string)$this->cfg('soap_ca_command'));
        $client = new SoapClient(null, [
            'location' => sprintf('http://%s:%s/', $this->cfg('soap_host'), $this->cfg('soap_port')),
            'uri' => $this->cfg('soap_uri', 'urn:MaNGOS'),
            'style' => constant($this->cfg('soap_style', 'SOAP_RPC')),
            'login' => $this->cfg('soap_username'),
            'password' => $this->cfg('soap_password'),
        ]);
        $client->executeCommand(new SoapParam($command, 'command'));
    }

    private function exists(string $table, string $column, string $value): bool
    {
        $sql = sprintf('SELECT 1 FROM %s WHERE %s = :value LIMIT 1', $this->safeName($table), $this->safeName($column));
        $stmt = $this->auth()->prepare($sql);
        $stmt->execute([':value' => $value]);
        return (bool)$stmt->fetchColumn();
    }

    private function columnExists(string $table, string $column): bool
    {
        $stmt = $this->auth()->prepare('SHOW COLUMNS FROM ' . $this->safeName($table) . ' LIKE :column');
        $stmt->execute([':column' => $column]);
        return (bool)$stmt->fetch();
    }

    private function safeName(string $name): string
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
        $cacheTtl = max(0, (int)$this->cfg('status_cache_seconds', 15));
        if ($cacheTtl > 0 && ($cached = $this->readStatusCache($cacheTtl)) !== null) {
            return $cached;
        }

        $result = [
            'auth_online' => null,
            'realms' => [],
            'total_accounts' => null,
            'total_online' => 0,
            'online_players' => [],
            'online_limit' => 49,
            'cached' => false,
        ];

        try {
            // 首页只展示在线玩家，因此不再每次访问都连接 auth 库读取账号数/realmlist，减少远程库慢导致的卡顿。
            foreach ($this->cfg('realmlists', []) as $id => $realmRaw) {
                $realmCfg = $this->realmCfg($id);
                $realm = [
                    'id' => (int)$realmCfg['id'],
                    'name' => $realmCfg['name'],
                    'address' => $this->cfg('realmlist', ''),
                    'port' => 8085,
                    'population' => null,
                    'online' => null,
                    'characters' => null,
                    'ok' => false,
                ];
                try {
                    $db = $this->realmDb($id);
                    $realm['online'] = (int)$db->query('SELECT COUNT(*) FROM characters WHERE online = 1')->fetchColumn();
                    $realm['ok'] = true;
                    $result['total_online'] += $realm['online'];
                    $result['online_players'] = array_merge(
                        $result['online_players'],
                        $this->onlinePlayers($db, (string)$realm['name'], (int)$result['online_limit'])
                    );
                } catch (Throwable $e) {
                    $realm['error'] = $e->getMessage();
                }
                $result['realms'][] = $realm;
            }
            usort($result['online_players'], fn($a, $b) => [$b['level'], $a['name']] <=> [$a['level'], $b['name']]);
            $result['online_players'] = array_slice($result['online_players'], 0, (int)$result['online_limit']);
            $this->writeStatusCache($result);
        } catch (Throwable $e) {
            $result['error'] = $e->getMessage();
            if (($cached = $this->readStatusCache(86400)) !== null) {
                $cached['cached'] = true;
                $cached['error'] = $e->getMessage();
                return $cached;
            }
        }
        return $result;
    }

    private function statusCachePath(): string
    {
        return dirname(__DIR__) . '/storage/status-cache.json';
    }

    private function readStatusCache(int $ttl): ?array
    {
        $path = $this->statusCachePath();
        if (!is_file($path)) {
            return null;
        }
        $raw = @file_get_contents($path);
        $data = is_string($raw) ? json_decode($raw, true) : null;
        if (!is_array($data) || !isset($data['saved_at'], $data['status'])) {
            return null;
        }
        if ((time() - (int)$data['saved_at']) > $ttl) {
            return null;
        }
        if (!is_array($data['status'])) {
            return null;
        }
        $data['status']['cached'] = true;
        $data['status']['cache_age'] = time() - (int)$data['saved_at'];
        return $data['status'];
    }

    private function writeStatusCache(array $status): void
    {
        $path = $this->statusCachePath();
        $status['cached'] = false;
        @file_put_contents($path, json_encode([
            'saved_at' => time(),
            'status' => $status,
        ], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), LOCK_EX);
    }

    private function onlinePlayers(PDO $db, string $realmName, int $limit): array
    {
        $limit = max(1, min(49, $limit));
        $hasGender = $this->columnExistsIn($db, 'characters', 'gender');
        $hasMap = $this->columnExistsIn($db, 'characters', 'map');
        $hasZone = $this->columnExistsIn($db, 'characters', 'zone');

        $columns = ['name', 'race', 'class', 'level'];
        if ($hasGender) {
            $columns[] = 'gender';
        }
        if ($hasMap) {
            $columns[] = 'map';
        }
        if ($hasZone) {
            $columns[] = 'zone';
        }

        $sql = 'SELECT ' . implode(', ', $columns) . " FROM characters WHERE online = 1 ORDER BY level DESC, name ASC LIMIT {$limit}";
        $players = [];
        foreach ($db->query($sql) as $row) {
            $race = (int)($row['race'] ?? 0);
            $class = (int)($row['class'] ?? 0);
            $gender = (int)($row['gender'] ?? 0);
            $map = isset($row['map']) ? (int)$row['map'] : null;
            $zone = isset($row['zone']) ? (int)$row['zone'] : null;

            $players[] = [
                'name' => (string)($row['name'] ?? ''),
                'race_id' => $race,
                'race' => $this->raceName($race),
                'race_icon' => $this->raceIconUrl($race, $gender),
                'class_id' => $class,
                'class' => $this->className($class),
                'class_icon' => $this->classIconUrl($class),
                'level' => (int)($row['level'] ?? 0),
                'map' => $map,
                'zone' => $zone,
                'location' => $this->locationName($map, $zone),
                'realm' => $realmName,
            ];
        }
        return $players;
    }

    private function columnExistsIn(PDO $db, string $table, string $column): bool
    {
        static $cache = [];
        $key = spl_object_id($db) . ':' . $table . ':' . $column;
        if (array_key_exists($key, $cache)) {
            return $cache[$key];
        }
        try {
            $stmt = $db->prepare('SHOW COLUMNS FROM ' . $this->safeName($table) . ' LIKE :column');
            $stmt->execute([':column' => $column]);
            return $cache[$key] = (bool)$stmt->fetch();
        } catch (Throwable) {
            return $cache[$key] = false;
        }
    }

    private function iconUrl(string $type, string $file): ?string
    {
        $relative = 'assets/icons/' . trim($type, '/') . '/' . ltrim($file, '/');
        $absolute = dirname(__DIR__) . '/public/' . $relative;
        return is_file($absolute) ? '/' . $relative : null;
    }

    private function raceIconUrl(int $race, int $gender = 0): ?string
    {
        foreach (["{$race}-{$gender}.gif", "{$race}-{$gender}-0.gif", "{$race}-0.gif", "{$race}-0-0.gif"] as $file) {
            $url = $this->iconUrl('race', $file);
            if ($url !== null) {
                return $url;
            }
        }
        return null;
    }

    private function classIconUrl(int $class): ?string
    {
        return $this->iconUrl('class', $class . '.gif');
    }

    private function iconImg(?string $url, string $alt): string
    {
        if ($url === null) {
            return '<span class="icon-fallback">' . $this->h($alt) . '</span>';
        }
        return '<img class="wow-icon" src="' . $this->h($url) . '" alt="' . $this->h($alt) . '" title="' . $this->h($alt) . '" loading="lazy">';
    }

    private function raceName(int $race): string
    {
        return [
            1 => '人类',
            2 => '兽人',
            3 => '矮人',
            4 => '暗夜精灵',
            5 => '亡灵',
            6 => '牛头人',
            7 => '侏儒',
            8 => '巨魔',
            10 => '血精灵',
            11 => '德莱尼',
        ][$race] ?? '未知';
    }

    private function className(int $class): string
    {
        return [
            1 => '战士',
            2 => '圣骑士',
            3 => '猎人',
            4 => '潜行者',
            5 => '牧师',
            6 => '死亡骑士',
            7 => '萨满祭司',
            8 => '法师',
            9 => '术士',
            11 => '德鲁伊',
        ][$class] ?? '未知';
    }

    private function locationName(?int $map, ?int $zone = null): string
    {
        $zones = [
            1 => '丹莫罗', 3 => '荒芜之地', 4 => '诅咒之地', 8 => '悲伤沼泽', 10 => '暮色森林', 11 => '湿地',
            12 => '艾尔文森林', 14 => '杜隆塔尔', 15 => '尘泥沼泽', 16 => '艾萨拉', 17 => '贫瘠之地', 28 => '西瘟疫之地',
            33 => '荆棘谷', 36 => '奥特兰克山脉', 38 => '洛克莫丹', 40 => '西部荒野', 41 => '逆风小径', 44 => '赤脊山',
            45 => '阿拉希高地', 46 => '燃烧平原', 47 => '辛特兰', 51 => '灼热峡谷', 85 => '提瑞斯法林地', 130 => '银松森林',
            139 => '东瘟疫之地', 141 => '泰达希尔', 148 => '黑海岸', 215 => '莫高雷', 267 => '希尔斯布莱德丘陵', 331 => '灰谷',
            357 => '菲拉斯', 361 => '费伍德森林', 400 => '千针石林', 405 => '凄凉之地', 406 => '石爪山脉', 440 => '塔纳利斯',
            490 => '安戈洛环形山', 493 => '月光林地', 618 => '冬泉谷', 1377 => '希利苏斯', 1497 => '幽暗城', 1519 => '暴风城',
            1537 => '铁炉堡', 1637 => '奥格瑞玛', 1638 => '雷霆崖', 1657 => '达纳苏斯', 3430 => '永歌森林', 3433 => '幽魂之地',
            3483 => '地狱火半岛', 3487 => '银月城', 3518 => '纳格兰', 3519 => '泰罗卡森林', 3520 => '影月谷', 3521 => '赞加沼泽',
            3522 => '刀锋山', 3523 => '虚空风暴', 3524 => '秘蓝岛', 3525 => '秘血岛', 3537 => '北风苔原', 3557 => '埃索达',
            3703 => '沙塔斯城', 3711 => '索拉查盆地', 4080 => '奎尔丹纳斯岛', 4197 => '冬拥湖', 4298 => '血色领地',
            4395 => '达拉然', 65 => '龙骨荒野', 66 => '祖达克', 67 => '风暴峭壁', 210 => '冰冠冰川', 394 => '灰熊丘陵',
            495 => '嚎风峡湾', 2817 => '晶歌森林', 4100 => '净化斯坦索姆', 4264 => '岩石大厅', 4265 => '闪电大厅', 4273 => '奥杜尔',
            4494 => '安卡赫特：古代王国', 4722 => '十字军的试炼', 4812 => '冰冠堡垒',
        ];
        if ($zone !== null && isset($zones[$zone])) {
            return $zones[$zone];
        }

        $maps = [
            0 => '东部王国', 1 => '卡利姆多', 30 => '奥特兰克山谷', 33 => '影牙城堡', 34 => '暴风城监狱', 36 => '死亡矿井',
            43 => '哀嚎洞穴', 47 => '剃刀沼泽', 48 => '黑暗深渊', 70 => '奥达曼', 90 => '诺莫瑞根', 109 => '沉没的神庙',
            129 => '剃刀高地', 189 => '血色修道院', 209 => '祖尔法拉克', 229 => '黑石塔', 230 => '黑石深渊', 249 => '奥妮克希亚的巢穴',
            269 => '开启黑暗之门', 289 => '通灵学院', 309 => '祖尔格拉布', 329 => '斯坦索姆', 349 => '玛拉顿', 369 => '矿道地铁',
            409 => '熔火之心', 429 => '厄运之槌', 469 => '黑翼之巢', 489 => '战歌峡谷', 529 => '阿拉希盆地', 530 => '外域',
            531 => '安其拉神殿', 532 => '卡拉赞', 533 => '纳克萨玛斯', 534 => '海加尔山之战', 540 => '地狱火城墙', 542 => '鲜血熔炉',
            543 => '破碎大厅', 544 => '玛瑟里顿的巢穴', 545 => '蒸汽地窟', 546 => '幽暗沼泽', 547 => '奴隶围栏', 548 => '毒蛇神殿',
            550 => '风暴要塞', 552 => '禁魔监狱', 553 => '生态船', 554 => '能源舰', 555 => '暗影迷宫', 556 => '塞泰克大厅',
            557 => '法力陵墓', 558 => '奥金尼地穴', 560 => '旧希尔斯布莱德丘陵', 562 => '刀锋山竞技场', 564 => '黑暗神殿', 565 => '格鲁尔的巢穴',
            566 => '风暴之眼', 568 => '祖阿曼', 571 => '诺森德', 572 => '洛丹伦废墟', 574 => '乌特加德城堡', 575 => '乌特加德之巅',
            576 => '魔枢', 578 => '魔环', 580 => '太阳之井高地', 585 => '魔导师平台', 595 => '净化斯坦索姆', 598 => '太阳之井高地',
            599 => '岩石大厅', 600 => '达克萨隆要塞', 601 => '艾卓-尼鲁布', 602 => '闪电大厅', 603 => '奥杜尔', 604 => '古达克',
            608 => '紫罗兰监狱', 615 => '黑曜石圣殿', 616 => '永恒之眼', 617 => '达拉然下水道', 618 => '勇气竞技场', 619 => '安卡赫特：古代王国',
            624 => '阿尔卡冯的宝库', 628 => '征服之岛', 631 => '冰冠堡垒', 632 => '灵魂洪炉', 649 => '十字军的试炼', 650 => '冠军的试炼',
            658 => '萨隆矿坑', 668 => '映像大厅', 724 => '红玉圣殿',
        ];
        if ($map !== null && isset($maps[$map])) {
            return $maps[$map];
        }
        if ($zone !== null && $zone > 0) {
            return '区域ID: ' . $zone;
        }
        if ($map !== null && $map >= 0) {
            return '地图ID: ' . $map;
        }
        return '未知位置';
    }

    private function announcements(): array
    {
        $items = json_decode(is_file($this->storagePath()) ? file_get_contents($this->storagePath()) : '[]', true);
        return is_array($items) ? $items : [];
    }

    private function saveAnnouncements(array $items): void
    {
        file_put_contents($this->storagePath(), json_encode(array_values($items), JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    }

    private function verifyAnnouncementPin(): void
    {
        $pin = (string)($_POST['pin'] ?? '');
        if (!hash_equals((string)$this->cfg('announcement_pin', '0819'), $pin)) {
            throw new RuntimeException('PIN 码不正确。');
        }
    }

    private function handleAddAnnouncement(): void
    {
        try {
            $this->verifyCsrf();
            $this->verifyAnnouncementPin();
            $title = trim((string)($_POST['title'] ?? ''));
            $content = trim((string)($_POST['content'] ?? ''));
            $level = trim((string)($_POST['level'] ?? 'normal'));
            if ($title === '' || $content === '') {
                throw new RuntimeException('公告标题和内容不能为空。');
            }
            if (!in_array($level, ['normal', 'important', 'maintenance'], true)) {
                $level = 'normal';
            }
            $items = $this->announcements();
            $items[] = [
                'id' => bin2hex(random_bytes(8)),
                'title' => $title,
                'content' => $content,
                'level' => $level,
                'date' => date('Y-m-d H:i'),
            ];
            $this->saveAnnouncements($items);
            $this->addFlash('success', '公告已添加。');
        } catch (Throwable $e) {
            $this->addFlash('error', $e->getMessage());
        }
    }

    private function handleDeleteAnnouncement(): void
    {
        try {
            $this->verifyCsrf();
            $this->verifyAnnouncementPin();
            $id = (string)($_POST['id'] ?? '');
            $items = array_values(array_filter($this->announcements(), fn($item) => (string)($item['id'] ?? '') !== $id));
            $this->saveAnnouncements($items);
            $this->addFlash('success', '公告已删除。');
        } catch (Throwable $e) {
            $this->addFlash('error', $e->getMessage());
        }
    }

    private function pageHome(): string
    {
        $status = $this->status();
        $realmName = $this->firstRealmName();
        ob_start(); ?>
        <section class="hero">
            <div>
                <p class="eyebrow">黑石 · 私服注册站</p>
                <h1><?= $this->h($realmName) ?></h1>
                <p>注册账号、查看在线玩家、阅读最新公告。客户端 Realmlist：<code>set realmlist <?= $this->h($this->cfg('realmlist')) ?></code></p>
                <p class="launcher-line"><a class="download-link" href="<?= $this->h($this->launcherUrl()) ?>" download><?= $this->h($this->cfg('launcher_label', '登录器下载')) ?></a></p>
                <div class="actions">
                    <a class="btn primary" href="?page=register">立即注册</a>
                    <a class="btn" href="#online-players">在线玩家</a>
                </div>
            </div>
            <div class="panel metric">
                <span>当前在线玩家</span>
                <strong><?= (int)$status['total_online'] ?></strong>
                <small><?= $this->h($this->cfg('game_version')) ?></small>
            </div>
        </section>
        <section class="grid two">
            <div class="card"><h2>服务器信息</h2><p>服务器：<?= $this->h($realmName) ?></p><p>版本：<?= $this->h($this->cfg('game_version')) ?></p><p>Realmlist：<?= $this->h($this->cfg('realmlist')) ?></p><p><?= $this->h($this->cfg('launcher_label', '登录器下载')) ?>：<a href="<?= $this->h($this->launcherUrl()) ?>" download><?= $this->h(basename((string)$this->cfg('launcher_file', 'downloads/WOWOL.bat'))) ?></a></p></div>
            <div class="card"><h2>最新公告</h2><?= $this->announcementList(2, false) ?></div>
        </section>
        <?= $this->onlinePlayersTable($status) ?>
        <?php return (string)ob_get_clean();
    }

    private function onlinePlayersTable(array $status): string
    {
        $players = $status['online_players'] ?? [];
        $limit = (int)($status['online_limit'] ?? 49);
        $totalOnline = (int)($status['total_online'] ?? 0);
        ob_start(); ?>
        <section id="online-players" class="card online-players">
            <div class="section-title">
                <div>
                    <h2>在线玩家</h2>
                    <p>最多显示<?= $limit ?>个在线玩家 - 当前在线玩家: <?= $totalOnline ?><?php if (!empty($status['cached'])): ?> <span class="muted">（缓存<?= isset($status['cache_age']) ? ' ' . (int)$status['cache_age'] . ' 秒' : '' ?>）</span><?php endif; ?></p>
                </div>
                <span class="badge ok">实时状态</span>
            </div>
            <div class="table-wrap">
                <table>
                    <thead><tr><th>角色</th><th>种族</th><th>职业</th><th>等级</th><th>地图位置</th></tr></thead>
                    <tbody>
                    <?php if (!$players): ?>
                        <tr><td colspan="5" class="empty-row">当前没有在线玩家，或角色数据库暂时无法读取。</td></tr>
                    <?php endif; ?>
                    <?php foreach ($players as $player): ?>
                        <tr>
                            <td><?= $this->h($player['name'] ?? '') ?></td>
                            <td class="icon-cell"><?= $this->iconImg($player['race_icon'] ?? null, (string)($player['race'] ?? '未知种族')) ?></td>
                            <td class="icon-cell"><?= $this->iconImg($player['class_icon'] ?? null, (string)($player['class'] ?? '未知职业')) ?></td>
                            <td><?= (int)($player['level'] ?? 0) ?></td>
                            <td><?= $this->h($player['location'] ?? '未知位置') ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </section>
        <?php return (string)ob_get_clean();
    }

    private function pageRegister(): string
    {
        ob_start(); ?>
        <section class="page-head"><h1>账号注册</h1><p>创建黑石游戏账号后，请在客户端使用账号名和密码登录。</p></section>
        <section class="card form-card">
            <form method="post" action="?page=register" autocomplete="off">
                <input type="hidden" name="csrf" value="<?= $this->h($this->csrf()) ?>">
                <input type="hidden" name="action" value="register">
                <label>邮箱<input name="email" type="email" required placeholder="you@example.com"></label>
                <label>账号名<input name="username" required minlength="2" maxlength="16" pattern="[A-Za-z0-9_-]+" placeholder="USERNAME"></label>
                <label>密码<input name="password" type="password" required minlength="4" maxlength="16"></label>
                <label>重复密码<input name="repassword" type="password" required minlength="4" maxlength="16"></label>
                <?= $this->captchaWidget() ?>
                <button class="btn primary" type="submit">创建账号</button>
            </form>
        </section>
        <?php
        $html = (string)ob_get_clean();
        // 图形验证码已写入 session，随后立即释放锁，防止用户点首页/公告时等待注册页请求结束。
        $this->closeSession();
        return $html;
    }

    private function captchaWidget(): string
    {
        $type = (int)$this->cfg('captcha_type', 3);
        $key = (string)$this->cfg('captcha_key', '');
        $lang = (string)$this->cfg('captcha_language', 'en');
        if ($type > 2) {
            return '';
        }

        $a = random_int(1, 9);
        $b = random_int(1, 9);
        $_SESSION['image_captcha'] = (string)($a + $b);
        $localCaptcha = '<label class="local-captcha">图形验证码：' . $a . ' + ' . $b . ' = <input name="image_captcha" inputmode="numeric" autocomplete="off"></label>';

        if ($type === 0 || $key === '') {
            return str_replace('<input ', '<input required ', $localCaptcha);
        }

        if ($type === 1) {
            $api = 'https://js.hcaptcha.com/1/api.js?hl=' . rawurlencode($lang) . '&render=explicit&onload=wowCaptchaLoaded';
            $widgetClass = 'h-captcha';
            $tokenName = 'h-captcha-response';
            $label = 'HCaptcha';
        } else {
            $api = 'https://www.google.com/recaptcha/api.js?hl=' . rawurlencode($lang) . '&render=explicit&onload=wowCaptchaLoaded';
            $widgetClass = 'g-recaptcha';
            $tokenName = 'g-recaptcha-response';
            $label = 'ReCaptcha';
        }

        $html = '<div class="captcha-box" data-captcha-provider="' . $this->h((string)$type) . '">';
        $html .= '<div class="captcha-status">正在加载' . $label . '，如果长时间无响应会自动切换为图形验证码。</div>';
        $html .= '<div id="wow-captcha-widget" class="' . $widgetClass . '" data-sitekey="' . $this->h($key) . '"></div>';
        $html .= '<noscript>' . str_replace('<input ', '<input required ', $localCaptcha) . '</noscript>';
        $html .= '<div class="captcha-fallback" hidden><p>外部验证码加载失败，请使用图形验证码：</p>' . str_replace('<input ', '<input required ', $localCaptcha) . '</div>';
        $html .= '<input type="hidden" name="' . $tokenName . '" value="">';
        $html .= '</div>';
        $html .= '<script>
(function(){
  var fallbackTimer;
  var box = document.currentScript.previousElementSibling;
  var fallback = box ? box.querySelector(".captcha-fallback") : null;
  var status = box ? box.querySelector(".captcha-status") : null;
  var tokenInput = box ? box.querySelector("input[type=hidden]") : null;
  var widget = document.getElementById("wow-captcha-widget");
  function showFallback(){
    if (fallback) fallback.hidden = false;
    if (status) status.textContent = "外部验证码未加载，已切换为图形验证码。";
    if (widget) widget.style.display = "none";
  }
  window.wowCaptchaLoaded = function(){
    clearTimeout(fallbackTimer);
    try {
      if (!widget) return showFallback();
      if (window.hcaptcha) {
        window.hcaptcha.render(widget, {sitekey: widget.getAttribute("data-sitekey"), callback: function(t){ if(tokenInput) tokenInput.value = t || ""; }});
      } else if (window.grecaptcha) {
        window.grecaptcha.render(widget, {sitekey: widget.getAttribute("data-sitekey"), callback: function(t){ if(tokenInput) tokenInput.value = t || ""; }});
      } else {
        showFallback();
        return;
      }
      if (status) status.textContent = "请完成人机验证。";
    } catch(e) {
      showFallback();
    }
  };
  fallbackTimer = setTimeout(showFallback, 3500);
  var script = document.createElement("script");
  script.src = ' . json_encode($api, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . ';
  script.async = true;
  script.defer = true;
  script.onerror = showFallback;
  document.body.appendChild(script);
})();
</script>';
        return $html;
    }

    private function pageStatus(): string
    {
        return $this->pageHome();
    }

    private function pageAnnouncements(): string
    {
        ob_start(); ?>
        <section class="page-head"><h1>公告</h1><p>服务器维护、活动、版本说明都会显示在这里。</p></section>
        <section class="card form-card">
            <h2>发布公告</h2>
            <form method="post" action="?page=announcements" onsubmit="return fillPin(this)">
                <input type="hidden" name="csrf" value="<?= $this->h($this->csrf()) ?>">
                <input type="hidden" name="action" value="add_announcement">
                <input type="hidden" name="pin" value="">
                <label>标题<input name="title" required maxlength="80" placeholder="例如：周末活动开启"></label>
                <label>类型<select name="level"><option value="normal">普通</option><option value="important">重要</option><option value="maintenance">维护</option></select></label>
                <label>内容<textarea name="content" required rows="4" placeholder="请输入公告内容"></textarea></label>
                <button class="btn primary" type="submit">添加公告</button>
            </form>
        </section>
        <section class="card announcements"><h2>公告列表</h2><?= $this->announcementList(null, true) ?></section>
        <script>
        function fillPin(form){
            var pin = prompt('请输入公告管理 PIN 码');
            if (pin === null) return false;
            form.querySelector('input[name="pin"]').value = pin;
            return true;
        }
        </script>
        <?php return (string)ob_get_clean();
    }

    private function announcementList(?int $limit = null, bool $withDelete = false): string
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
                <div class="announcement-head"><div><h3><?= $this->h($item['title'] ?? '未命名公告') ?></h3><time><?= $this->h($item['date'] ?? '') ?></time></div>
                <?php if ($withDelete): ?>
                    <form method="post" action="?page=announcements" onsubmit="return fillPin(this)">
                        <input type="hidden" name="csrf" value="<?= $this->h($this->csrf()) ?>">
                        <input type="hidden" name="action" value="delete_announcement">
                        <input type="hidden" name="id" value="<?= $this->h($item['id'] ?? '') ?>">
                        <input type="hidden" name="pin" value="">
                        <button class="btn danger" type="submit">删除</button>
                    </form>
                <?php endif; ?></div>
                <p><?= nl2br($this->h($item['content'] ?? '')) ?></p>
            </article>
        <?php endforeach;
        return (string)ob_get_clean();
    }

    private function firstRealmName(): string
    {
        $realms = $this->cfg('realmlists', []);
        $first = is_array($realms) ? reset($realms) : [];
        return (string)($first['realmname'] ?? $this->cfg('page_title', '黑石'));
    }

    private function render(string $content, string $page): void
    {
        $title = $this->h($this->cfg('page_title', '黑石'));
        $nav = ['home' => '首页', 'register' => '注册', 'announcements' => '公告'];
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
        <footer>© <?= date('Y') ?> <?= $title ?> · Realmlist: <?= $this->h($this->cfg('realmlist')) ?></footer>
        </body></html>
        <?php
    }
}
