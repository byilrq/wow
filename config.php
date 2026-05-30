<?php
/**
 * WOW_Web 面板配置文件
 *
 * @author Amin Mahmoudi (MasterkinG)
 * @copyright Copyright (c) 2019 - 2024, MasterkinG32. (https://masterking32.com)
 * @link https://masterking32.com
 **/

// 基础配置 - 按你的网站信息进行调整。
// 必须填写一个有效 URL，否则可能导致图片/模板资源加载异常。
$config['baseurl'] = env('APP_URL', "https://sharq.eu.org"); // 有域名填域名，没有填服务器的IP
$config['page_title'] = env('APP_NAME', "黑石"); // 网站标题（浏览器标签页显示的标题）
$config['language'] = env('APP_LANGUAGE', "chinese-simplified"); // 网站默认语言
$config['supported_langs'] = [ // 支持的语言列表（不需要的语言可以删除）
    // 如需关闭语言切换，把它设置为：$config['supported_langs'] = false;
    'english' => 'English',
    'chinese-simplified' => 'Chinese Simplified',
]; 

// 调试模式 - 开启后可在排障时显示错误信息。
$config['debug_mode'] = env_bool('APP_DEBUG', true); // 如果遇到空白页或报错，可设置为 true 进行排查。
// **重要：问题解决后请务必关闭调试模式**。正式上线/生产环境建议设置为 `false`，以免带来安全与性能风险。

// 服务器信息 - 按你的服务器实际情况设置。
$config['realmlist'] = env('REALMLIST', 'sharq.eu.org'); // 服务器 Realmlist（玩家登录IP）
$config['patch_location'] = env('PATCH_LOCATION', 'http://mypatch.com/patch.mpq'); // 补丁地址（无 ?
$config['game_version'] = env('GAME_VERSION', '3.3.5a (12340)'); // 服务器运行的游戏版本

/* 资料片设置 - 通过数字选择你服务器的资料片版本：
0 = 经典旧世 (Classic)
1 = 燃烧的远征 (TBC)
2 = 巫妖王之怒 (WotLK)
3 = 大地的裂变 (Cataclysm)
4 = 熊猫人之谜 (MOP)
5 = 德拉诺之王 (WOD)
6 = 军团再临 (Legion)
7 = 争霸艾泽拉斯 (BFA)（此项作者也不完全确定）
 */
$config['expansion'] = env('EXPANSION', '2'); // '2' 对应 “巫妖王之怒” (WotLK)

/* 服务器核心类型 - 通过数字选择你的服务器核心：
核心类型：
0 = TrinityCore
1 = AzerothCore
2 = AshamaneCore
3 = Skyfire Project
4 = OregonCore
5 = CMangos
10 = 等等
 */
$config['server_core'] = (int) env('SERVER_CORE', 1); // '1' AzerothCore

// Battle.net 支持 - 如果你的核心支持 Battle.net（WoD/Legion/BFA 等）可启用。
$config['battlenet_support'] = env_bool('BATTLENET_SUPPORT', false);

// SRP6 密码加密 - 如果你的核心密码加密使用 SRP6，需启用（新版 TC/AC 通常需要）。
$config['srp6_support'] = env_bool('SRP6_SUPPORT', true); // 重要：请在 php.ini 启用 GMP 扩展。

/* 选择 SRP6 版本：
0 = SRP6 - auth 数据库 battlenet_accounts 表中没有 srp_version 字段
1 = SRP6v1
2 = SRP6v2
 */
$config['srp6_version'] = (int) env('SRP6_VERSION', 2);

// 功能开关 - 控制某些页面/功能是否禁用。
$config['disable_top_players'] = env_bool('DISABLE_TOP_PLAYERS', true); // 关闭 top players 页面
$config['disable_online_players'] = env_bool('DISABLE_ONLINE_PLAYERS', false); // 关闭在线玩家页面
$config['disable_changepassword'] = env_bool('DISABLE_CHANGEPASSWORD', true); // 设置为 true 禁用修改密码

// 是否允许同一邮箱创建多个账号
$config['multiple_email_use'] = env_bool('MULTIPLE_EMAIL_USE', false); // 一个邮箱一个账 ?

// 网站模板选择
$config['template'] = env('TEMPLATE', 'light'); // 可用模板：light, advance, icecrown, kaelthas, battleforazeroth

// SMTP 配置 - 用于发送邮件（例如找回密码）。
$config['smtp_host'] = env('SMTP_HOST', 'smtp1.example.com'); // SMTP 主机地址
$config['smtp_port'] = (int) env('SMTP_PORT', 587); // SMTP 端口
$config['smtp_auth'] = env_bool('SMTP_AUTH', true); // 是否启用 SMTP 认证
$config['smtp_user'] = env('SMTP_USER', 'user@example.com'); // SMTP 用户名
$config['smtp_pass'] = env('SMTP_PASS', 'SECRET'); // SMTP 密码
$config['smtp_secure'] = env('SMTP_SECURE', 'tls'); // 加密方式：'tls' 或 'ssl'
$config['smtp_mail'] = env('SMTP_MAIL', 'no-reply@example.com'); // 发件人邮箱（系统发信使用）

// 投票系统配置 - 是否启用投票系统用于服务器推广。
$config['vote_system'] = env_bool('VOTE_SYSTEM', true); // 设置为 true 启用投票系统
$config['vote_sites'] = array(
    // 在此定义投票站点及其对应图片
    // array(
    //     'image' => 'http://www.top100arena.com/hit.asp?id=93137&c=WoW&t=2',
    //     'site_url' => 'http://www.top100arena.com/in.asp?id=93137'
    // ),
    // array(
    //     'image' => 'https://topg.org/topg.gif',
    //     'site_url' => 'https://topg.org/wow-private-servers/in-479394'
    // ),
    // array(
    //     'image' => 'http://www.xtremeTop100.com/votenew.jpg',
    //     'site_url' => 'http://www.xtremetop100.com/in.php?site=1132364316'
    // )
);

// 验证码配置 - 选择验证码方式。
$config['captcha_type'] = (int) env('CAPTCHA_TYPE', 1); // 选项：0(图形验证码), 1(HCaptcha), 2(ReCaptcha v2), >2(禁用验证码)
$config['captcha_key'] = env('CAPTCHA_KEY', '10b6462c-973a-458c-84f4-6c60794e2a78'); // HCaptcha/Recaptcha 的 key；使用图片验证码则留空
$config['captcha_secret'] = env('CAPTCHA_SECRET', 'ES_9278a8805838434c9fa776e49af64355'); // HCaptcha/Recaptcha 的 secret；使用图片验证码则留空
$config['captcha_language'] = env('CAPTCHA_LANGUAGE', 'en'); // 验证码语言（原注释里给了文档链接）

// 通过 SOAP 接口注册账号 - 如果你想用 SOAP 来处理账号创建，可在此配置。
// 如果你使用默认创建方式或新版核心，一般不需要启用。
$config['soap_for_register'] = env_bool('SOAP_FOR_REGISTER', false); // 只有在确认 SOAP 配置正确时才建议启用
$config['soap_host'] = env('SOAP_HOST', '127.0.0.1'); // SOAP 服务地址
$config['soap_port'] = env('SOAP_PORT', '7878'); // SOAP 服务端口
$config['soap_uri'] = env('SOAP_URI', 'urn:MaNGOS'); // SOAP URI（按你的核心实现调整）
$config['soap_style'] = env('SOAP_STYLE', 'SOAP_RPC'); // SOAP 风格
$config['soap_username'] = env('SOAP_USERNAME', 'admin_soap'); // SOAP 认证用户名
$config['soap_password'] = env('SOAP_PASSWORD', 'admin_soap'); // SOAP 认证密码
$config['soap_ca_command'] = env('SOAP_CA_COMMAND', 'account create {USERNAME} {PASSWORD}'); // SOAP 创建账号命令

// 双因素认证 (2FA) - 如果你的核心支持 2FA，可在此配置。
// 虽然某些操作需要 SOAP，但启用 2FA 并不一定要求开启 soap_for_register。
// 若要支持基于邮箱验证的 2FA，请确保 SMTP 配置正确。
$config['2fa_support'] = env_bool('TWO_FA_SUPPORT', false); // 是否启用 2FA
$config['soap_2d_command'] = env('SOAP_2D_COMMAND', 'account set 2fa {USERNAME} off'); // SOAP：关闭 2FA 命令
$config['soap_2e_command'] = env('SOAP_2E_COMMAND', 'account set 2fa {USERNAME} {SECRET}'); // SOAP：开启 2FA 命令

// 数据库信息 - 数据库配置
$config['db_auth_host'] = env('DB_AUTH_HOST', 'byilrq.iok.la'); // 数据库主机地址
$config['db_auth_port'] = env('DB_AUTH_PORT', '58006'); // 数据库端口
$config['db_auth_user'] = env('DB_AUTH_USERNAME', 'admin'); // 数据库用户名
$config['db_auth_pass'] = env('DB_AUTH_PASSWORD', 'Plex0819$'); // 数据库密码
$config['db_auth_dbname'] = env('DB_AUTH_DATABASE', 'acore_auth'); // auth/realmd 数据库名

// 分区(Realm)列表配置 -
$config['realmlists'] = array(
    "1" => array(
        'realmid' => (int) env('REALM_1_ID', 1), // 分区 ID
        'realmname' => env('REALM_1_NAME', "黑石"), // 分区名称
        'db_host' => env('REALM_1_HOST', env('DB_AUTH_HOST', "byilrq.iok.la")), // MySQL 主机地址
        'db_port' => env('REALM_1_PORT', env('DB_AUTH_PORT', "58006")), // MySQL 端口
        'db_user' => env('REALM_1_USERNAME', env('DB_AUTH_USERNAME', "admin")), // MySQL 用户名
        'db_pass' => env('REALM_1_PASSWORD', env('DB_AUTH_PASSWORD', 'Plex0819$')), // MySQL 密码
        'db_name' => env('REALM_1_DATABASE', "acore_characters"), // 角色库数据库名
    ),
);

// 公告管理配置 - 用于公告页面新增/删除公告时校验。
$config['announcement_pin'] = env('ANNOUNCEMENT_PIN', '0819'); // 公告新增/删除 PIN 码

// 脚本版本 - 用于标识当前配置脚本的版本号
$config['script_version'] = '2.0.2';

return $config;
