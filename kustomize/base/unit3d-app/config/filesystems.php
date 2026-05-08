<?php

declare(strict_types=1);

/*
 * ratatoskr override for UNIT3D v9.2.0 config/filesystems.php.
 *
 * Mounted at /app/config/filesystems.php via ConfigMap volume mount in
 * the unit3d-app, unit3d-queue, unit3d-scheduler, and unit3d-migrate
 * workloads. The upstream image stays byte-identical — this file
 * replaces the in-image config at deploy time only, never modifies
 * the upstream artifact.
 *
 * Structural delta vs upstream HDInnovations/UNIT3D@v9.2.0:
 *
 *   - Three Storage-aware disks (`torrent-files`, `subtitle-files`,
 *     `attachment-files`) get their `driver` env-guarded so the prod
 *     overlay can flip them to `s3` via FILESYSTEM_<NAME> env vars
 *     without further patching. Each affected disk block carries the
 *     corresponding s3 connection keys defensively — Laravel ignores
 *     them while `driver` is `local`, consumes them when it flips to
 *     `s3`. Per ADR-0002.
 *
 *   - The other 14 disks keep `'driver' => 'local'` literal. Their
 *     controllers bypass Laravel Storage (Storage::disk(...)->path()
 *     plus Intervention Image::save() or UploadedFile::move()) and
 *     would break on an `s3` driver. Refactor tracked in
 *     docs/upstream-prs.md; v0.4 hard-depends on those PRs landing.
 *
 *   - Default disk, links, disk ordering, comments, and unrelated
 *     blocks are byte-equivalent to upstream. Refresh on each UNIT3D
 *     bump: diff this file against the corresponding upstream tag and
 *     port any structural changes (new disks, new connection keys)
 *     while preserving the three env guards above.
 *
 * Source: https://github.com/HDInnovations/UNIT3D/blob/v9.2.0/config/filesystems.php
 */

return [
    /*
    |--------------------------------------------------------------------------
    | Default Filesystem Disk
    |--------------------------------------------------------------------------
    |
    | Here you may specify the default filesystem disk that should be used
    | by the framework. The "local" disk, as well as a variety of cloud
    | based disks are available to your application. Just store away!
    |
    */

    'default' => env('FILESYSTEM_DISK', 'local'),

    /*
    |--------------------------------------------------------------------------
    | Filesystem Disks
    |--------------------------------------------------------------------------
    |
    | Here you may configure as many filesystem "disks" as you wish, and you
    | may even configure multiple disks of the same driver. Defaults have
    | been set up for each driver as an example of the required values.
    |
    | Supported Drivers: "local", "ftp", "sftp", "s3"
    |
    */

    'disks' => [
        'local' => [
            'driver' => 'local',
            'root'   => storage_path('app'),
            'throw'  => true,
        ],

        'public' => [
            'driver'     => 'local',
            'root'       => storage_path('app/public'),
            'url'        => env('APP_URL').'/storage',
            'visibility' => 'public',
            'throw'      => true,
        ],

        's3' => [
            'driver'                  => 's3',
            'key'                     => env('AWS_ACCESS_KEY_ID'),
            'secret'                  => env('AWS_SECRET_ACCESS_KEY'),
            'region'                  => env('AWS_DEFAULT_REGION'),
            'bucket'                  => env('AWS_BUCKET'),
            'url'                     => env('AWS_URL'),
            'endpoint'                => env('AWS_ENDPOINT'),
            'use_path_style_endpoint' => env('AWS_USE_PATH_STYLE_ENDPOINT', false),
            'throw'                   => false,
        ],

        'ftp' => [
            'driver'   => 'ftp',
            'host'     => 'ftp.example.com',
            'username' => 'your-username',
            'password' => 'your-password',

            // Optional FTP Settings...
            // 'port' => 21,
            // 'root' => '',
            // 'passive' => true,
            // 'ssl' => true,
            // 'timeout' => 30,
        ],

        'sftp' => [
            'driver'   => 'sftp',
            'host'     => 'example.com',
            'username' => 'your-username',
            'password' => 'your-password',

            // Settings for SSH key based authentication...
            'privateKey' => '/path/to/privateKey',
            'passphrase' => 'encryption-password',

            // Optional SFTP Settings...
            // 'port' => 22,
            // 'root' => '',
            // 'timeout' => 30,
        ],

        'backups' => [
            'driver' => 'local',
            'root'   => storage_path('backups'),
        ],

        // UNIT3D Custom Disks (Alphabetical Order)
        'article-images' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/articles/images'),
        ],

        // ratatoskr override per ADR-0002: env-guarded driver + s3 keys.
        // Storage-aware writes (AttachmentUpload Livewire ->storeAs at v9.2.0)
        // make this disk safe to flip to s3 without controller refactor.
        'attachment-files' => [
            'driver'                  => env('FILESYSTEM_ATTACHMENT_FILES', 'local'),
            'root'                    => storage_path('app/files/attachments/files'),
            'key'                     => env('FILESYSTEM_ATTACHMENT_FILES_KEY'),
            'secret'                  => env('FILESYSTEM_ATTACHMENT_FILES_SECRET'),
            'region'                  => env('FILESYSTEM_ATTACHMENT_FILES_REGION'),
            'bucket'                  => env('FILESYSTEM_ATTACHMENT_FILES_BUCKET'),
            'endpoint'                => env('FILESYSTEM_ATTACHMENT_FILES_ENDPOINT'),
            'use_path_style_endpoint' => env('FILESYSTEM_ATTACHMENT_FILES_USE_PATH_STYLE_ENDPOINT', false),
            'throw'                   => false,
        ],

        'user-avatars' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/users/avatars'),
        ],

        'user-icons' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/users/icons'),
        ],

        'category-images' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/categories/images'),
        ],

        'playlist-images' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/playlists/images'),
        ],

        // ratatoskr override per ADR-0002: env-guarded driver + s3 keys.
        // Storage-aware writes (SubtitleController:100 ->putFileAs at v9.2.0)
        // make this disk safe to flip to s3 without controller refactor.
        'subtitle-files' => [
            'driver'                  => env('FILESYSTEM_SUBTITLE_FILES', 'local'),
            'root'                    => storage_path('app/files/subtitles/files'),
            'key'                     => env('FILESYSTEM_SUBTITLE_FILES_KEY'),
            'secret'                  => env('FILESYSTEM_SUBTITLE_FILES_SECRET'),
            'region'                  => env('FILESYSTEM_SUBTITLE_FILES_REGION'),
            'bucket'                  => env('FILESYSTEM_SUBTITLE_FILES_BUCKET'),
            'endpoint'                => env('FILESYSTEM_SUBTITLE_FILES_ENDPOINT'),
            'use_path_style_endpoint' => env('FILESYSTEM_SUBTITLE_FILES_USE_PATH_STYLE_ENDPOINT', false),
            'throw'                   => false,
        ],

        'temporary-nfos' => [
            'driver' => 'local',
            'root'   => storage_path('app/tmp/nfos'),
        ],

        'torrent-banners' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/torrents/banners'),
        ],

        'torrent-covers' => [
            'driver' => 'local',
            'root'   => storage_path('app/images/torrents/covers'),
        ],

        // ratatoskr override per ADR-0002: env-guarded driver + s3 keys.
        // Storage-aware writes (TorrentController:347 ->put at v9.2.0)
        // make this disk safe to flip to s3 without controller refactor.
        // High-volume disk: .torrent files commonly tens to hundreds of MB
        // each on a populated tracker, so this is the dominant beneficiary
        // of the S3 swap (PVC sizing collapses dramatically per ADR-0002).
        'torrent-files' => [
            'driver'                  => env('FILESYSTEM_TORRENT_FILES', 'local'),
            'root'                    => storage_path('app/files/torrents/files'),
            'key'                     => env('FILESYSTEM_TORRENT_FILES_KEY'),
            'secret'                  => env('FILESYSTEM_TORRENT_FILES_SECRET'),
            'region'                  => env('FILESYSTEM_TORRENT_FILES_REGION'),
            'bucket'                  => env('FILESYSTEM_TORRENT_FILES_BUCKET'),
            'endpoint'                => env('FILESYSTEM_TORRENT_FILES_ENDPOINT'),
            'use_path_style_endpoint' => env('FILESYSTEM_TORRENT_FILES_USE_PATH_STYLE_ENDPOINT', false),
            'throw'                   => false,
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Symbolic Links
    |--------------------------------------------------------------------------
    |
    | Here you may configure the symbolic links that will be created when the
    | `storage:link` Artisan command is executed. The array keys should be
    | the locations of the links and the values should be their targets.
    |
    */

    'links' => [
        public_path('storage') => storage_path('app/public'),
    ],
];
