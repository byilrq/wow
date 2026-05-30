<?php

declare(strict_types=1);

require_once dirname(__DIR__) . '/src/WowApp.php';
$config = require dirname(__DIR__) . '/config.php';

try {
    (new WowApp($config))->run();
} catch (Throwable $e) {
    http_response_code(500);
    $debug = !empty($config['app']['debug']);
    echo '<!doctype html><meta charset="utf-8"><title>Server Error</title>';
    echo '<style>body{font-family:system-ui;background:#100f17;color:#fff;padding:48px}code{color:#ffcf70}</style>';
    echo '<h1>server is offline!</h1>';
    if ($debug) {
        echo '<p><code>' . htmlspecialchars($e->getMessage(), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') . '</code></p>';
    }
}
