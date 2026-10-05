# PHP и деньги: шпаргалка

## Деньги: правила, которые нельзя нарушать

```
1. НЕ float. Никогда. Ни в БД, ни в PHP, ни в JSON.
2. Минорные единицы (копейки) в int/BIGINT + код валюты.
3. «×100» — только через таблицу экспоненты валют (JPY = 0, KWD = 3).
4. DECIMAL приходит из PDO СТРОКОЙ — это защита, не баг. Во float не приводить.
5. BCMath с ЯВНЫМ scale. bcdiv('1','3') без scale вернёт '0'.
6. Округление — ОДИН раз на документ, режим зафиксирован в одном месте.
7. Пропорциональное деление — с распределением остатка, чтобы сумма частей = целому.
8. В JSON — минорные единицы или строка, никогда float.
```

```php
// Проверки «на пальцах»
php -r 'var_dump(0.1+0.2 === 0.3);'        // false
php -r 'var_dump((int)(0.29*100));'         // 28  ← потерянная копейка
php -r 'var_dump(bcdiv("1","3"));'          // '0' ← забыли scale
echo json_encode(['s' => 0.1+0.2]);         // 0.30000000000000004
```

## PDO: обязательная конфигурация

```php
$pdo = new PDO($dsn, $u, $p, [
    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_EMULATE_PREPARES   => false,      // настоящие prepared statements
    PDO::ATTR_STRINGIFY_FETCHES  => false,      // BIGINT → int, DECIMAL → string
    PDO::MYSQL_ATTR_INIT_COMMAND => "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
    PDO::ATTR_TIMEOUT            => 5,
]);
```

## Транзакция: правильный каркас

```php
$this->pdo->beginTransaction();
try {
    $payment = $repo->findForUpdate($id);     // SELECT ... FOR UPDATE
    // ... логика, проверки, проводки, outbox ...
    $this->pdo->commit();
} catch (Throwable $e) {
    if ($this->pdo->inTransaction()) $this->pdo->rollBack();
    throw $e;
}
```

**Правила:** транзакция = только БД · внешние вызовы вне транзакции · короткая транзакция ·
владение транзакцией — в прикладном слое (use case), а не в репозиториях.

## Дедлок-retry

```php
function withDeadlockRetry(PDO $pdo, callable $op, int $max = 5): mixed {
    for ($attempt = 1; ; $attempt++) {
        try { return $op(); }
        catch (PDOException $e) {
            $retryable = in_array($e->errorInfo[1] ?? 0, [1213, 1205], true)
                      || $e->getCode() === '40001';
            if (!$retryable || $attempt >= $max) throw $e;
            $cap = min(1000, 10 * (2 ** $attempt));
            usleep(random_int(1, $cap) * 1000);        // джиттер обязателен
            if ($pdo->inTransaction()) $pdo->rollBack(); // иначе следующий BEGIN упадёт
        }
    }
}
```

## Идемпотентность (4 уровня)

| Уровень | Механизм |
|---|---|
| 1. Запрос клиента | `idempotency_key` UNIQUE + тот же ответ при повторе |
| 2. Входящее событие | `UNIQUE(source, event_id)` + `ON DUPLICATE KEY` |
| 3. Переход состояния | машина состояний / `UPDATE ... WHERE status = :expected` + `rowCount()` |
| 4. Учёт | `UNIQUE(operation_id)` в проводках |

## Enum (PHP 8.1) для статусов

```php
enum PaymentStatus: string {
    case Created = 'created';  case Pending = 'pending';  case Paid = 'paid';
    case Unknown = 'unknown'; case Refunded = 'refunded'; case Failed = 'failed';

    public function canTransitionTo(self $n): bool {
        return match ($this) {
            self::Created => in_array($n, [self::Pending, self::Failed], true),
            self::Pending => in_array($n, [self::Paid, self::Unknown, self::Failed], true),
            self::Paid    => $n === self::Refunded,
            default       => false,
        };
    }
}
// Внешний статус — ТОЛЬКО через tryFrom (иначе новый статус ПС уронит обработку)
$status = PaymentStatus::tryFrom($external) ?? null;   // null → логируем, не падаем
```

## Money как Value Object

```php
final readonly class Money {                    // PHP 8.2 readonly class
    private function __construct(public string $currency, public int $amountMinor) {}
    public static function fromMinor(int $m, string $c): self { return new self($c, $m); }
    public static function of(string $dec, string $c, int $exp): self { /* строковый парсинг */ }
    public function add(self $o): self { $this->assertSame($o); return new self($this->currency, $this->amountMinor + $o->amountMinor); }
    public function multiply(string $f): self { return new self($this->currency, self::bcRoundToInt(bcmul((string)$this->amountMinor, $f, 6))); }
    public function allocate(array $weights): array { return allocate($this->amountMinor, $weights); }
}
// Наружу — ['currency' => 'RUB', 'amount_minor' => 15000], никогда float
```

## Распределение остатка (не потерять копейку)

```php
function allocate(int $total, array $weights): array {
    $sum = array_sum($weights);
    $out = []; $frac = []; $allocated = 0;
    foreach ($weights as $i => $w) {
        $out[$i] = intdiv($total * $w, $sum);
        $frac[$i] = ($total * $w) % $sum;
        $allocated += $out[$i];
    }
    arsort($frac);
    $left = $total - $allocated;
    foreach (array_keys($frac) as $i) { if ($left-- <= 0) break; $out[$i]++; }
    return $out;
}
allocate(100, [1,1,1]);   // [34,33,33]  сумма 100 ✔
```

## Генераторы: выгрузки без OOM

```php
$pdo->setAttribute(PDO::MYSQL_ATTR_USE_BUFFERED_QUERY, false);
// keyset-пагинация, не OFFSET:
SELECT ... WHERE id > :last ORDER BY id LIMIT 1000;
// отдаём через yield, пишем в CSV построчно
```

## Мапинг статусов ПС

```php
return match (strtolower($raw)) {
    'success','paid','captured' => PaymentStatus::Paid,
    'pending','processing'      => PaymentStatus::Pending,
    'declined','canceled'       => PaymentStatus::Failed,
    default                     => null,        // ← НЕ бросать: новый статус — норма
};
```

## Слои и швы

```
Controller (валидация, подпись) → Use case (транзакция, оркестрация)
   → Domain (правила, Money, статусы, политики) → Infrastructure (SQL, HTTP, MQ)
```
* Новый ПС = новый адаптер + контрактный тест, ядро не меняется.
* Новый вид услуги = запись в справочнике правил, ядро не меняется.
* Событийное — для следствий (чек, уведомление). Явное — для денег и лимитов.

## Мини-задачи на самопроверку

1. Почему `(int)(0.29 * 100) === 28`? → двоичное представление float.
2. Что вернёт `bcdiv('101','2')` и почему? → `'50'`, scale по умолчанию 0.
3. Как сделать, чтобы повторный HTTP-запрос вернул тот же платёж? → `idempotency_key` UNIQUE + `LAST_INSERT_ID(id)`.
4. Почему нельзя проверять `SELECT` + `INSERT`? → гонка.
5. Что делать при таймауте внешнего вызова? → статус `unknown`, затем `getStatus`.
6. Почему `DECIMAL` приходит строкой и это хорошо? → точность не теряется.
7. Как разделить 100 копеек на троих? → `allocate` → [34,33,33].
8. Что делать с новым неизвестным статусом от ПС? → `tryFrom → null`, лог, алерт, состояние не менять.
9. Где границы транзакции при внешнем вызове? → две короткие, вызов между ними.
10. Что писать в `outbox` и почему в той же транзакции? → событие для следствий, чтобы не было dual write.
