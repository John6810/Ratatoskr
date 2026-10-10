<?php

declare(strict_types=1);

// Runs without booting Laravel: a fresh PVC has no framework directories yet.
$storage = getenv('RATATOSKR_STORAGE_PATH') ?: '/app/storage';
foreach (['app/public', 'framework/cache/data', 'framework/sessions', 'framework/views', 'logs'] as $directory) {
    $path = $storage.'/'.$directory;
    if (!is_dir($path) && !@mkdir($path, 0775, true) && !is_dir($path)) {
        fwrite(STDERR, "Cannot initialize writable storage: $path\n");
        exit(1);
    }
}

$mode = $argv[1] ?? 'storage';
// PHP is PID 1 in init containers. Handle cancellation explicitly instead of
// waiting for a worker Pod's long termination grace period to send SIGKILL.
if (in_array($mode, ['prepare', 'wait'], true)) {
    pcntl_async_signals(true);
    pcntl_signal(SIGTERM, static function (): void { exit(143); });
    pcntl_signal(SIGINT, static function (): void { exit(130); });
}
if ($mode === 'storage') {
    exit(0);
}
if ($mode === 'migrate') {
    // Serialize deployment jobs even if two delivery tools target one database.
    $db = new PDO(
        'mysql:host='.getenv('DB_HOST').';port='.(getenv('DB_PORT') ?: '3306').';dbname='.getenv('DB_DATABASE'),
        getenv('DB_USERNAME'), getenv('DB_PASSWORD'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
    );
    $lock = $db->prepare('SELECT GET_LOCK(?, 60)');
    $lock->execute(['ratatoskr:'.substr(hash('sha256', getenv('DB_DATABASE')), 0, 40)]);
    if ((int) $lock->fetchColumn() !== 1) {
        fwrite(STDERR, "Another migration owns the database lock\n");
        exit(1);
    }
    $hasTable = function (string $name) use ($db): bool {
        $query = $db->prepare('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?');
        $query->execute([$name]);
        return (int) $query->fetchColumn() > 0;
    };
    $state = $hasTable('_ratatoskr_bootstrap')
        ? $db->query('SELECT completed FROM _ratatoskr_bootstrap WHERE id = 1')->fetchColumn() : false;
    if ($state !== false && (int) $state !== 1) {
        fwrite(STDERR, "A previous seed was interrupted. Inspect and repair the seed data before marking _ratatoskr_bootstrap completed; refusing to seed twice.\n");
        exit(1);
    }
    $established = $state !== false || ($hasTable('users') && (int) $db->query('SELECT COUNT(*) FROM users')->fetchColumn() > 0);
    $run = function (array $arguments): void {
        $command = escapeshellarg(PHP_BINARY).' /app/artisan '.implode(' ', array_map('escapeshellarg', $arguments));
        passthru($command, $result);
        if ($result !== 0) {
            exit($result);
        }
    };
    $run(['migrate', '--force']);
    if (!$established) {
        // Upstream seeders insert fixed primary keys and cannot be repeated.
        $db->exec('CREATE TABLE IF NOT EXISTS _ratatoskr_bootstrap (id TINYINT PRIMARY KEY, completed TINYINT NOT NULL)');
        $db->exec('INSERT INTO _ratatoskr_bootstrap (id, completed) VALUES (1, 0)');
        $run(['db:seed', '--force']);
        $db->exec('UPDATE _ratatoskr_bootstrap SET completed = 1 WHERE id = 1');
    } else {
        fwrite(STDOUT, "Existing database: skipping first-install seeders\n");
    }
    $run(['scout:sync-index-settings']);
    exit(0);
}
if (!in_array($mode, ['prepare', 'wait'], true)) {
    fwrite(STDERR, "Unknown lifecycle mode\n");
    exit(1);
}
$deadline = time() + (int) (getenv('RATATOSKR_WAIT_SECONDS') ?: 900);
do {
    if ($mode === 'prepare') {
        try {
            $db = new PDO(
                'mysql:host='.getenv('DB_HOST').';port='.getenv('DB_PORT').';dbname='.getenv('DB_DATABASE'),
                getenv('DB_USERNAME'),
                getenv('DB_PASSWORD'),
                [PDO::ATTR_TIMEOUT => 5, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
            );
            $db->query('SELECT 1');
            $redis = new Redis();
            $redis->connect(getenv('REDIS_HOST'), (int) getenv('REDIS_PORT'), 5);
            if (getenv('REDIS_PASSWORD') !== false && getenv('REDIS_PASSWORD') !== '') {
                $redis->auth(getenv('REDIS_PASSWORD'));
            }
            $redis->ping();
            $health = @file_get_contents(rtrim(getenv('MEILISEARCH_HOST'), '/').'/health', false,
                stream_context_create(['http' => ['timeout' => 5]]));
            if ($health !== false && (json_decode($health, true)['status'] ?? null) === 'available') {
                fwrite(STDOUT, "Database, Redis and MeiliSearch are ready\n");
                exit(0);
            }
        } catch (Throwable $error) {
            // Never print connection exceptions: they can contain credentials.
        }
    } else {
        $directory = '/var/run/secrets/ratatoskr';
        $token = @file_get_contents($directory.'/token');
        $namespace = @file_get_contents($directory.'/namespace');
        if ($token === false || $namespace === false) {
            fwrite(STDERR, "Missing projected Kubernetes API credentials\n");
            exit(1);
        }
        $host = getenv('KUBERNETES_SERVICE_HOST');
        if (str_contains($host, ':')) {
            $host = '['.$host.']';
        }
        $url = 'https://'.$host.':'.(getenv('KUBERNETES_SERVICE_PORT_HTTPS') ?: '443')
            .'/apis/batch/v1/namespaces/'.rawurlencode(trim($namespace)).'/jobs/'.rawurlencode(getenv('MIGRATION_JOB'));
        $context = stream_context_create([
            'http' => ['timeout' => 5, 'ignore_errors' => true, 'header' => 'Authorization: Bearer '.trim($token)],
            'ssl' => ['cafile' => $directory.'/ca.crt', 'verify_peer' => true, 'verify_peer_name' => true],
        ]);
        $body = @file_get_contents($url, false, $context);
        $status = $http_response_header[0] ?? '';
        if (preg_match('/\s(401|403)\s/', $status)) {
            fwrite(STDERR, "Kubernetes API denied access to the migration Job\n");
            exit(1);
        }
        $job = $body === false ? [] : (json_decode($body, true) ?? []);
        foreach ($job['status']['conditions'] ?? [] as $condition) {
            if ($condition['type'] === 'Failed' && $condition['status'] === 'True') {
                fwrite(STDERR, "Migration Job failed; refusing to start the application\n");
                exit(1);
            }
        }
        if (($job['status']['succeeded'] ?? 0) >= 1) {
            fwrite(STDOUT, "Migration Job completed\n");
            exit(0);
        }
    }
    fwrite(STDOUT, "Waiting for ".($mode === 'prepare' ? 'dependencies' : 'migration completion')."\n");
    sleep(3);
} while (time() < $deadline);
fwrite(STDERR, "Lifecycle wait timed out\n");
exit(1);
