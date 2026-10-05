<?php
declare(strict_types=1);

/**
 * Демонстрация денежного пути биллинга: идемпотентность, транзакции, проводки, outbox.
 *
 * Запуск (внутри docker-лаборатории):
 *   docker compose exec php php /app/php/payment_flow_demo.php
 * или локально, если MySQL доступен на 127.0.0.1:3306:
 *   MYSQL_HOST=127.0.0.1 php 12-labs/php/payment_flow_demo.php
 *
 * Что показывает:
 *   1. Создание платежа с ключом идемпотентности + повторный вызов (тот же платёж).
 *   2. Обработку «вебхука» с защитой от дубля и с проверкой перехода состояния.
 *   3. Проводки с суммой 0 и запись события в outbox в ТОЙ ЖЕ транзакции.
 *   4. Таймаут внешнего вызова → статус unknown (а не failed).
 *   5. Печать денежных инвариантов после операций.
 */

// ---------------------------------------------------------------------------------------------
// Конфигурация подключения
//   Все параметры — через переменные окружения, чтобы скрипт работал и в docker-лаборатории,
//   и на локальном MySQL/MariaDB (например: MYSQL_HOST=127.0.0.1 MYSQL_PORT=3307 ...).
//   env(): getenv() возвращает false только если переменная НЕ задана, поэтому пустое
//   значение (пустой пароль root) уважается — иначе `?:` подставил бы 'billing'.
// ---------------------------------------------------------------------------------------------
function env(string $name, string $default): string
{
    $value = getenv($name);
    return $value === false ? $default : $value;
}

$host = env('MYSQL_HOST', 'mysql');
$port = env('MYSQL_PORT', '3306');
$db   = env('MYSQL_DATABASE', 'billing');
$user = env('MYSQL_USER', 'root');
$pass = env('MYSQL_PASSWORD', 'billing');

$pdo = new PDO(
    "mysql:host={$host};port={$port};dbname={$db};charset=utf8mb4",
    $user,
    $pass,
    [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,      // обязательна
        PDO::ATTR_EMULATE_PREPARES   => false,                       // настоящие prepared statements
        PDO::ATTR_STRINGIFY_FETCHES  => false,                       // BIGINT → int, DECIMAL → string
        PDO::MYSQL_ATTR_INIT_COMMAND => 'SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED',
        PDO::ATTR_TIMEOUT            => 5,
    ]
);

echo "== Подключение к MySQL ({$host}/{$db}) установлено\n\n";

// ---------------------------------------------------------------------------------------------
// Деньги: только минорные единицы (int) + валюта. Никаких float.
// ---------------------------------------------------------------------------------------------
final readonly class Money
{
    private function __construct(
        public string $currency,
        public int $amountMinor,
    ) {}

    public static function ofMinor(int $minor, string $currency = 'RUB'): self
    {
        return new self($currency, $minor);
    }

    public function add(self $other): self
    {
        $this->assertSameCurrency($other);
        return new self($this->currency, $this->amountMinor + $other->amountMinor);
    }

    public function subtract(self $other): self
    {
        $this->assertSameCurrency($other);
        return new self($this->currency, $this->amountMinor - $other->amountMinor);
    }

    /** НДС: точная арифметика через BCMath, округление ОДИН раз и в явном режиме. */
    public function vatPart(string $ratePercent): array
    {
        $gross = $this->amountMinor;
        // НДС "в том числе": vat = round(gross * rate / (100 + rate))
        $numerator   = bcmul((string) $gross, $ratePercent, 6);
        $denominator = bcadd('100', $ratePercent, 6);
        $raw         = bcdiv($numerator, $denominator, 6);      // максимальная точность

        $vat = self::bcRoundHalfUpToInt($raw);                  // округляем один раз, в конце
        return ['base' => $gross - $vat, 'vat' => $vat];
    }

    /** Округление строкового decimal до целого (half-up) — без float внутри. */
    private static function bcRoundHalfUpToInt(string $value): int
    {
        $negative = str_starts_with($value, '-');
        if ($negative) {
            $value = substr($value, 1);
        }
        [$int, $frac] = array_pad(explode('.', $value, 2), 2, '0');
        $bump = (int) ($frac[0] ?? '0') >= 5 ? 1 : 0;
        $result = (int) $int + $bump;
        return $negative ? -$result : $result;
    }

    /** Пропорциональное распределение без потери копейки. */
    public function allocate(array $weights): array
    {
        $total = array_sum($weights);
        $out = $frac = [];
        $allocated = 0;
        foreach ($weights as $i => $w) {
            $out[$i]  = intdiv($this->amountMinor * $w, $total);
            $frac[$i] = ($this->amountMinor * $w) % $total;
            $allocated += $out[$i];
        }
        arsort($frac);
        $left = $this->amountMinor - $allocated;
        foreach (array_keys($frac) as $i) {
            if ($left <= 0) break;
            $out[$i]++;
            $left--;
        }
        return array_map(fn (int $m) => new self($this->currency, $m), $out);
    }

    public function format(): string
    {
        $sign = $this->amountMinor < 0 ? '-' : '';
        $abs  = str_pad((string) abs($this->amountMinor), 3, '0', STR_PAD_LEFT);
        return $sign . substr($abs, 0, -2) . '.' . substr($abs, -2) . ' ' . $this->currency;
    }

    private function assertSameCurrency(self $other): void
    {
        if ($this->currency !== $other->currency) {
            throw new InvalidArgumentException("Currency mismatch: {$this->currency} vs {$other->currency}");
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Утилиты
// ---------------------------------------------------------------------------------------------
function uuid4(): string
{
    $d = random_bytes(16);
    $d[6] = chr((ord($d[6]) & 0x0f) | 0x40);
    $d[8] = chr((ord($d[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($d), 4));
}

/**
 * Повтор денежной операции при временных ошибках InnoDB.
 * ВАЖНО: переигрывать можно только идемпотентную операцию.
 */
function withDeadlockRetry(PDO $pdo, callable $operation, int $maxAttempts = 5): mixed
{
    for ($attempt = 1; ; $attempt++) {
        try {
            return $operation();
        } catch (PDOException $e) {
            $errno = $e->errorInfo[1] ?? 0;
            $retryable = in_array($errno, [1213, 1205], true) || $e->getCode() === '40001';
            if (!$retryable || $attempt >= $maxAttempts) {
                throw $e;
            }
            $cap = min(1000, 10 * (2 ** $attempt));
            usleep(random_int(1, $cap) * 1000);      // backoff + джиттер (без джиттера — "стадо")
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
        }
    }
}

/** Переходы состояний платежа: единственный источник правды о том, что допустимо. */
function canTransition(string $from, string $to): bool
{
    return in_array($to, match ($from) {
        'created'  => ['pending', 'unknown', 'failed'],
        'pending'  => ['paid', 'unknown', 'failed', 'expired'],
        'unknown'  => ['paid', 'failed'],
        'paid'     => ['refunded', 'partially_refunded'],
        default    => [],
    }, true);
}

// ---------------------------------------------------------------------------------------------
// 1. Создание платежа (идемпотентно) и повторный вызов
// ---------------------------------------------------------------------------------------------
echo "== 1. Создание платежа с идемпотентным ключом\n";

$idempotencyKey = 'demo-idem-' . bin2hex(random_bytes(8));
$amount = Money::ofMinor(15000);
$vat = $amount->vatPart('20.00');

$createPayment = function () use ($pdo, $idempotencyKey, $amount, $vat): array {
    // Вставка с UNIQUE(idempotency_key). При повторе ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)
    // возвращает id СУЩЕСТВУЮЩЕЙ строки → повторный запрос получит тот же платёж и тот же ответ.
    $stmt = $pdo->prepare(
        "INSERT INTO payment
           (public_id, user_id, legal_entity_id, service_code, amount_minor, currency, status,
            idempotency_key, provider_code, provider_payment_id,
            vat_rate, vat_base_minor, vat_amount_minor, fiscal_rule_id,
            refunded_minor, operation_day, created_at)
         VALUES
           (:public_id, 42, 1, 'contact_access', :amount, :cur, 'created',
            :idem, 'sbp', NULL,
            '20.00', :vat_base, :vat_amount, 1,
            0, CURDATE(), NOW(6)) AS new
         ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)"
    );
    $stmt->execute([
        'public_id'  => str_pad(bin2hex(random_bytes(16)), 32, '0'),
        'amount'     => $amount->amountMinor,
        'cur'        => $amount->currency,
        'idem'       => $idempotencyKey,
        'vat_base'   => $vat['base'],
        'vat_amount' => $vat['vat'],
    ]);
    $id = (int) $pdo->lastInsertId();

    $sel = $pdo->prepare('SELECT id, status, amount_minor, idempotency_key FROM payment WHERE id = :id');
    $sel->execute(['id' => $id]);
    return $sel->fetch(PDO::FETCH_ASSOC);
};

$first = $createPayment();
echo "   первый вызов : payment_id={$first['id']}, status={$first['status']} (строка создана)\n";
$second = $createPayment();
echo "   повторный    : payment_id={$second['id']}, status={$second['status']}  ← тот же платёж, не второй!\n";
$paymentId = (int) $first['id'];

// 1b. ПС принял запрос на оплату → переводим created → pending (это отдельная короткая
//     транзакция: сюда, в реальном коде, встаёт ответ createPayment от ПС).
$pdo->prepare(
    "UPDATE payment SET status = 'pending', provider_payment_id = :ppid WHERE id = :id AND status = 'created'"
)->execute(['ppid' => 'SBP-DEMO-' . $paymentId, 'id' => $paymentId]);
echo "   ПС принял    : created → pending (короткая транзакция)\n\n";

// ---------------------------------------------------------------------------------------------
// 2. Обработка вебхука (идемпотентно, атомарно, с проводками и outbox)
// ---------------------------------------------------------------------------------------------
echo "== 2. Обработка вебхука ПС (с защитой от дубля)\n";

$processedEventId = 'evt-demo-' . bin2hex(random_bytes(6));

/** Обработчик вебхука: тот же путь и для вебхука, и для опроса статуса. */
$handleWebhook = function (PDO $pdo, int $paymentId, string $eventId, string $newStatus) use ($vat, $amount): string {
    return withDeadlockRetry($pdo, function () use ($pdo, $paymentId, $eventId, $newStatus, $vat, $amount): string {
        $pdo->beginTransaction();
        try {
            // (1) Идемпотентность события: UNIQUE(source, event_id)
            $ins = $pdo->prepare(
                "INSERT INTO processed_event (source, event_id, payload_hash, seen_count, processed_at)
                 VALUES ('psp', :eid, SHA2(:payload, 256), 1, NOW(6)) AS new
                 ON DUPLICATE KEY UPDATE seen_count = seen_count + 1, payload_hash = new.payload_hash"
            );
            $ins->execute(['eid' => $eventId, 'payload' => json_encode(['p' => $paymentId, 's' => $newStatus])]);
            // ⚠️ ЛОВУШКА, на которой легко ошибиться: rowCount() здесь возвращает
            //      1 — строка вставлена (событие первое),
            //      2 — строка БЫЛА и мы её обновили (seen_count + 1) → это дубль,
            //      0 — строка была, но ничего не изменилось (если UPDATE был бы `id = id`).
            //    Поэтому проверять надо `!== 1`, а не `=== 0`: иначе дубль при наличии
            //    реального UPDATE (seen_count + 1) пройдёт как «новое событие».
            $isDuplicate = $ins->rowCount() !== 1;
            if ($isDuplicate) {
                $pdo->commit();
                return 'duplicate: событие уже обрабатывалось';
            }

            // (2) Блокируем строку платежа: два параллельных обработчика не решат одновременно
            $sel = $pdo->prepare('SELECT id, status, amount_minor FROM payment WHERE id = :id FOR UPDATE');
            $sel->execute(['id' => $paymentId]);
            $payment = $sel->fetch(PDO::FETCH_ASSOC);
            if ($payment === false) {
                $pdo->commit();
                return 'unknown payment: событие сохранено, деньги не тронуты';
            }

            // (3) Проверка допустимости перехода (устаревшее событие игнорируем)
            if (!canTransition($payment['status'], $newStatus)) {
                $pdo->commit();
                return "ignored: переход {$payment['status']} → {$newStatus} недопустим (устаревшее событие)";
            }

            // (4) Изменяем состояние + проводки + outbox В ОДНОЙ ТРАНЗАКЦИИ
            $pdo->prepare(
                "UPDATE payment SET status = :s, paid_at = NOW(6), provider_payment_id = :ppid WHERE id = :id"
            )->execute(['s' => $newStatus, 'ppid' => 'SBP-DEMO-' . $paymentId, 'id' => $paymentId]);

            $operationId = uuid4();
            $entries = [
                // [account_id, amount_minor]
                [1, $amount->amountMinor],           // + транзит: эквайринг
                [4, -$amount->amountMinor],          // − авансы полученные (для услуги — выручка+НДС)
            ];
            $le = $pdo->prepare(
                'INSERT INTO ledger_entry
                   (created_day, created_at, operation_id, operation_type, account_id, amount_minor, currency, payment_id, comment)
                 VALUES (CURDATE(), NOW(6), :op, :otype, :acc, :amt, :cur, :pid, :comment)'
            );
            foreach ($entries as [$accountId, $amt]) {
                $le->execute([
                    'op' => $operationId, 'otype' => 'payment', 'acc' => $accountId,
                    'amt' => $amt, 'cur' => 'RUB', 'pid' => $paymentId,
                    'comment' => $accountId === 1 ? 'поступило от ПС' : 'аванс полученный',
                ]);
            }

            // Проверяем инвариант ПРЯМО ЗДЕСЬ: сумма проводок по операции обязана быть 0
            $chk = $pdo->prepare('SELECT SUM(amount_minor) FROM ledger_entry WHERE operation_id = :op');
            $chk->execute(['op' => $operationId]);
            if ((int) $chk->fetchColumn() !== 0) {
                throw new RuntimeException('Нарушен инвариант двойной записи: сумма проводок != 0');
            }

            // (5) Событие для следствий — в ТОЙ ЖЕ транзакции (outbox, не брокер!)
            $pdo->prepare(
                "INSERT INTO outbox (event_type, aggregate_id, payload, created_at, published_at, attempts)
                 VALUES ('receipt.requested', :pid, :payload, NOW(6), NULL, 0)"
            )->execute([
                'pid' => $paymentId,
                'payload' => json_encode([
                    'payment_id' => $paymentId,
                    'amount_minor' => $amount->amountMinor,
                    'vat_amount_minor' => $vat['vat'],
                    'operation_id' => $operationId,
                ], JSON_UNESCAPED_UNICODE),
            ]);

            $pdo->commit();
            return "applied: {$payment['status']} → {$newStatus}, проводки + outbox записаны";
        } catch (Throwable $e) {
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
            throw $e;
        }
    });
};

echo '   первый вебхук : ' . $handleWebhook($pdo, $paymentId, $processedEventId, 'paid') . "\n";
echo '   тот же вебхук : ' . $handleWebhook($pdo, $paymentId, $processedEventId, 'paid') . "\n";
echo '   устаревшее    : ' . $handleWebhook($pdo, $paymentId, 'evt-demo-old', 'pending') . "\n\n";

// ---------------------------------------------------------------------------------------------
// 3. Таймаут внешнего вызова → unknown, а не failed
// ---------------------------------------------------------------------------------------------
echo "== 3. Таймаут внешнего вызова: unknown ≠ failed\n";

$timeoutPaymentKey = 'demo-timeout-' . bin2hex(random_bytes(6));
$pdo->prepare(
    "INSERT INTO payment
       (public_id, user_id, legal_entity_id, service_code, amount_minor, currency, status,
        idempotency_key, provider_code, vat_rate, vat_base_minor, vat_amount_minor, fiscal_rule_id,
        refunded_minor, operation_day, created_at)
     VALUES (:pid, 43, 1, 'contact_access', 15000, 'RUB', 'unknown', :idem, 'sbp',
             '20.00', 12500, 2500, 1, 0, CURDATE(), NOW(6))"
)->execute(['pid' => str_pad(bin2hex(random_bytes(16)), 32, '0'), 'idem' => $timeoutPaymentKey]);
echo "   внешний вызов завершился таймаутом → status='unknown'\n";
echo "   правильно: опросить getStatus по нашему order_id; НЕЛЬЗЯ писать failed и НЕЛЬЗЯ\n";
echo "   слепо повторять (второе списание).\n\n";

// ---------------------------------------------------------------------------------------------
// 4. Распределение остатка: 100 копеек на троих
// ---------------------------------------------------------------------------------------------
echo "== 4. Пропорциональное распределение без потери копейки\n";
$split = Money::ofMinor(100)->allocate([1, 1, 1]);
$sum = 0;
foreach ($split as $i => $m) {
    echo "   часть #{$i}: {$m->format()}\n";
    $sum += $m->amountMinor;
}
echo '   сумма частей: ' . $sum . " коп. (должно быть ровно 100)\n\n";

// ---------------------------------------------------------------------------------------------
// 5. Денежные инварианты после всех операций
// ---------------------------------------------------------------------------------------------
echo "== 5. Проверка денежных инвариантов\n";

$invariants = [
    'И1. Сумма проводок по операции = 0' => "
        SELECT COUNT(*) FROM (
            SELECT operation_id FROM ledger_entry GROUP BY operation_id HAVING SUM(amount_minor) <> 0
        ) x",
    'И2. Сальдо счёта = сумма проводок' => "
        SELECT COUNT(*) FROM (
            SELECT a.id FROM account a LEFT JOIN ledger_entry l ON l.account_id = a.id
             GROUP BY a.id, a.balance_minor HAVING COALESCE(SUM(l.amount_minor),0) <> a.balance_minor
        ) x",
    'И3. Оплачено, но чека нет' => "
        SELECT COUNT(*) FROM payment p
          LEFT JOIN receipt r ON r.payment_id = p.id AND r.receipt_type = 'income'
         WHERE p.status IN ('paid','partially_refunded','refunded')
           AND (r.id IS NULL OR r.status <> 'printed')",
    'И4. Возвраты не больше платежа' => "
        SELECT COUNT(*) FROM (
            SELECT p.id FROM payment p JOIN refund r ON r.payment_id = p.id AND r.status = 'completed'
             GROUP BY p.id, p.amount_minor HAVING SUM(r.amount_minor) > p.amount_minor
        ) x",
    'И5. Платежи в pending/unknown старше 10 минут' => "
        SELECT COUNT(*) FROM payment
         WHERE status IN ('pending','unknown') AND created_at < NOW() - INTERVAL 10 MINUTE",
    'И6. Чек без состоявшейся оплаты' => "
        SELECT COUNT(*) FROM receipt r LEFT JOIN payment p ON p.id = r.payment_id
         WHERE r.receipt_type = 'income'
           AND (r.payment_id IS NULL OR p.status NOT IN ('paid','partially_refunded','refunded'))",
];

foreach ($invariants as $name => $sql) {
    $count = (int) $pdo->query($sql)->fetchColumn();
    $mark  = $count === 0 ? '✅' : '⚠️ ';
    printf("   %s %-52s нарушений: %d\n", $mark, $name, $count);
}

echo "\n   (И3/И5 в демо-данных специально нарушены — это те самые 'грязные' кейсы,\n";
echo "    которые находят sql/03-queries.sql и разбирают в 05-billing-domain/07-reconciliation.md)\n\n";

// ---------------------------------------------------------------------------------------------
// 6. Что накопилось в outbox (в проде это читает отдельный publisher)
// ---------------------------------------------------------------------------------------------
echo "== 6. Очередь событий в outbox (публикует отдельный процесс, через SKIP LOCKED)\n";
$rows = $pdo->query(
    "SELECT id, event_type, aggregate_id, attempts, published_at IS NULL AS unpublished
       FROM outbox ORDER BY id DESC LIMIT 5"
)->fetchAll(PDO::FETCH_ASSOC);
foreach ($rows as $r) {
    printf("   #%d %-20s aggregate=%d attempts=%d %s\n",
        $r['id'], $r['event_type'], $r['aggregate_id'], $r['attempts'],
        ((int) $r['unpublished'] === 1 ? 'НЕ опубликовано' : 'опубликовано'));
}

echo "\n== Готово. Обрати внимание: в одной транзакции записаны и деньги, и событие —\n";
echo "   поэтому состояние 'деньги есть, события нет' невозможно by design.\n";
