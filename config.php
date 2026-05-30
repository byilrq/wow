<?php
// WoW 注册站集中配置。优先读取环境变量/.env，未设置时使用这里的默认值。
return [
    'app' => [
        'name' => env('APP_NAME', 'BlackRock'),
        'url' => rtrim(env('APP_URL', 'https://sharq.eu.org'), '/'),
        'realmlist' => env('REALMLIST', 'sharq.eu.org'),
        'game_version' => env('GAME_VERSION', '3.3.5a (12340)'),
        'expansion' => (int) env('EXPANSION', 2),
        'timezone' => env('APP_TIMEZONE', 'Asia/Shanghai'),
        'debug' => filter_var(env('APP_DEBUG', false), FILTER_VALIDATE_BOOL),
    ],
    'database' => [
        'auth' => [
            'host' => env('DB_AUTH_HOST', '127.0.0.1'),
            'port' => (int) env('DB_AUTH_PORT', 3306),
            'database' => env('DB_AUTH_DATABASE', 'acore_auth'),
            'username' => env('DB_AUTH_USERNAME', 'admin'),
            'password' => env('DB_AUTH_PASSWORD', 'change_me'),
            'charset' => env('DB_AUTH_CHARSET', 'utf8mb4'),
        ],
        'realms' => [
            1 => [
                'id' => (int) env('REALM_1_ID', 1),
                'name' => env('REALM_1_NAME', '黑石'),
                'host' => env('REALM_1_HOST', env('DB_AUTH_HOST', '127.0.0.1')),
                'port' => (int) env('REALM_1_PORT', env('DB_AUTH_PORT', 3306)),
                'database' => env('REALM_1_DATABASE', 'acore_characters'),
                'username' => env('REALM_1_USERNAME', env('DB_AUTH_USERNAME', 'admin')),
                'password' => env('REALM_1_PASSWORD', env('DB_AUTH_PASSWORD', 'change_me')),
                'charset' => env('REALM_1_CHARSET', 'utf8mb4'),
            ],
        ],
    ],
    'account' => [
        'srp6_support' => filter_var(env('SRP6_SUPPORT', true), FILTER_VALIDATE_BOOL),
        'salt_field' => env('ACCOUNT_SALT_FIELD', 'salt'),
        'verifier_field' => env('ACCOUNT_VERIFIER_FIELD', 'verifier'),
        'multiple_email_use' => filter_var(env('MULTIPLE_EMAIL_USE', false), FILTER_VALIDATE_BOOL),
        'username_min' => 2,
        'username_max' => 16,
        'password_min' => 4,
        'password_max' => 16,
    ],
    'captcha' => [
        'hcaptcha_site_key' => env('HCAPTCHA_SITE_KEY', ''),
        'hcaptcha_secret' => env('HCAPTCHA_SECRET', ''),
    ],
];
