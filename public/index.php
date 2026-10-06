<?php

declare(strict_types=1);

require_once dirname(__DIR__) . '/src/WowApp.php';
$config = require dirname(__DIR__) . '/config.php';


// Presentation-only enhancement. The application, routes, sessions and configuration
// are still owned by WowApp. Never serialize the full configuration to the browser.
$wowPublicUi = json_encode([
    'realmlist' => (string)($config['realmlist'] ?? ''),
    'gameVersion' => (string)($config['game_version'] ?? ''),
    'cacheSeconds' => max(0, (int)($config['status_cache_seconds'] ?? 15)),
], JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_UNICODE);
ob_start(static function (string $html) use ($wowPublicUi): string {
    $assets = '<link rel="stylesheet" href="assets/console.css?v=20261006-2">'
        . '<script type="application/json" id="wow-public-ui">' . ($wowPublicUi ?: '{}') . '</script>'
        . '<script defer src="assets/console.js?v=20261006-2"></script>';
    return str_replace('</head>', $assets . '</head>', $html);
});

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

ob_end_flush();
