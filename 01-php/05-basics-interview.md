# 05. Базовый PHP: что спрашивают на собесах

> Материалы `01-php/` уже покрывают деньги, транзакции, PHP 8-специфику и SOLID.
> Здесь — **база**, которую спросят в начале, до того как перейти к биллингу:
> типы, nul, массивы, функции, исключения, match, атрибуты, идиомы и подводные камни.
> Если на эти вопросы ответить неуверенно — интервьюер усомнится в остальном.

---

## Оглавление

1. [Типы и strict_types](#1-типы-и-strict_types)
2. [Null: null, ??, ?:, isset, empty](#2-null)
3. [Массивы и списки](#3-массивы-и-списки)
4. [Функции: именованные аргументы, variadic, замыкания](#4-функции)
5. [Строки и интерполяция](#5-строки)
6. [Исключения и обработка ошибок](#6-исключения)
7. [match: замена switch](#7-match)
8. [Атрибуты (#[...])](#8-атрибуты)
9. [Конструктор promotion](#9-конструктор-promotion)
10. [Идиомы биллинга на PHP](#10-идиомы-биллинга)
11. [Подводные камни и их ловят](#11-подводные-камни)
12. [Вопросы и ответы](#12-вопросы-и-ответы)

---

## 1. Типы и `strict_types`

### Что спросят

> «Какие типы есть в PHP? Чем отличается `int` от `float`? Что даёт `strict_types`?»

### Ответ

В PHP 8.x типы строгие (кроме границы с внешним миром). Основные:

```php
// Скалярные
int $count = 42;           // целое (BigInt, без переполнения)
float $rate = 20.0;        // число с плавающей точкой (но для денег — Money VO!)
string $name = 'Profiru';  // строка
bool $active = true;       // буль

// Составные
array<int> $ids = [1, 2, 3];            // гомогенный массив
array<int|string> $mixed = [1, 'two'];  // union в массиве
Hash<int> $map = ['key' => 42];         // HashMap
set<string> $tags = {'foo', 'bar'};     // множество

// Объектные
?string $maybe = null;          // optional (nullable)
readonly Money $price;         // readonly-тип (VO)

// Nullable: T | null
?int $val = null;               // int или null
string|null $name = null;       // то же, явный union

// Union-типы (8.0+)
int|string $id;                 // может быть int или string
```

### `declare(strict_types=1)`

```php
declare(strict_types=1);  // обязательно в каждом денежном файле!

function add(int $a, int $b): int {
    return $a + $b;
}

add(5, 3);      // ✅ 8
add('5', 3);    // ❌ TypeError: ожидал int, получил string
```

**Без `strict_types`** PHP попытается привести `'5'` к `5` молча — фатально для денег.

### Приведение на границе

```php
// JSON снаружи — всегда string
$rawAmount = '1500';               // из JSON всё string
$amount = int($rawAmount);         // явное приведение
// НО: float('1500.7') → 1500 — тихая потеря! → Money VO обязателен
```

---

## 2. Null

### Что спросят

> «Чем отличается `??` от `?:`, `isset()` от `array_key_exists()`, `null` от `undefined`?»

### Ответ

```php
declare(strict_types=1);

// null — единственное нулевое значение
?string $name = null;

// ?? — null-коалесценция: берёт ПЕРВОЕ НЕ-null
$displayName = $name ?? 'гость';         // 'гость'

// ?: — null-safe access (optional chaining) — PHP 8.0+
$config = null;
// $config?->timeout  → null, не TypeError

// Пример из биллинга:
?Payment $payment = $this->payments->findByProviderId($id);
$status = $payment?->status()?->value() ?? 'unknown';
//   ↑ если payment null — не падает, а даёт null → берётся 'unknown'

// isset — проверяет, что ключ СУЩЕСТВУЕТ и НЕ null
$arr = ['a' => 1, 'b' => null];
isset($arr['a']);  // true
isset($arr['b']);  // false — потому что null!
isset($arr['c']);  // false — нет ключа

// array_key_exists — проверяет только СУЩЕСТВОВАНИЕ ключа
array_key_exists($arr, 'a');  // true
array_key_exists($arr, 'b');  // true — b существует, хоть и null
array_key_exists($arr, 'c');  // false

// ПРАВИЛО: если null в массиве валиден — array_key_exists, а не isset
```

### Когда что использовать

| Ситуация | Что писать |
|---|---|
| «значение не задано — взять по умолчанию» | `$val ?? 'default'` |
| «безопасно разыменовать цепочку» | `$obj?->field?->method()` |
| «проверить, есть ли ключ в массиве» | `array_key_exists($arr, 'key')` или `'key' in $arr` |
| «только если не null и не false/0/empty» | `empty($val)` — проверяет null, false, 0, '' |

---

## 3. Массивы и списки

### Что спросят

> «Чем `array` отличается от `list`? Как работает `foreach`? Что такое `Hash`?»

### Ответ

```php
declare(strict_types=1);

// array — фиксированный тип элемента, может быть и списком, и HashMap
array<int> $list = [1, 2, 3];
array<int> $empty: [];              // пустой

// Hash — явная HashMap (ключ-значение)
Hash<string> $map = ['key1' => 'val1', 'key2' => 'val2'];

// foreach — обход
foreach ($list as $i => $val) {           // с индексом
    // $i — int $val — int
}

foreach ($map as $key => $val) {          // ключ → значение
    // $key — string
}

foreach ($list as $val) {                 // только значения
    // ...
}

// Встроенные функции
array_map($list, fn ($x) => $x * 2);
array_filter($list, fn ($x) => $x > 0);
array_reduce($list, fn ($acc, $x) => $acc + $x, 0);
in_array($value, $list, true);   // строгое сравнение — всегда true!
array_sum($list);                 // сумма int
array_sort($list);
array_unique($list);
array_join($list, ', ');

// Array spread
$merged = [...$list, 4, 5];

// Hash spread
$mergedMap = [...$map, 'new' => 'value'];
```

### Важно: `in_array` всегда с `true`

```php
in_array(0, [null, false, '0'], true);  // false — строгий поиск
in_array(0, [null, false, '0']);        // true — loose сравнение → опасно!
// ПРАВИЛО: всегда третий аргумент true в денежном коде
```

---

## 4. Функции

### Что спросят

> «Какие виды функций есть? Что такое closure? Именованные аргументы? Variadic?»

### Ответ

```php
declare(strict_types=1);

// Обычная функция
function calcTotal(array<int> $items): int {
    return array_sum($items);
}

// Стрелочная (closure)
$multiply = fn (int $a, int $b): int => $a * $b;

// Closure захватывает область видимости:
function makeCounter(): fn (): int {
    int $count = 0;
    return fn (): int => ++$count;
}
$counter = makeCounter();
$counter();  // 1
$counter();  // 2

// Variadic
function sumAll(int ...$numbers): int {
    return array_sum($numbers);
}
sumAll(1, 2, 3);  // 6

// Именованные аргументы (8.0+)
function createPayment(
    int $userId,
    string $serviceCode,
    int $amount,
    string $currency = 'RUB',
): Payment { ... }

createPayment(
    userId: 42,
    serviceCode: 'contact_access',
    amount: 1500,
    // currency опущен — берётся 'RUB'
);

// Типизированный callback
function processPayment(
    int $paymentId,
    callable(string): void $onSuccess,
    callable(string): void $onFail,
): void {
    // ...
}

// Default values
function fetch(int $id, int $ttlSeconds = 300): ?Payment { ... }
fetch(42);           // ttl=300
fetch(42, ttlSeconds: 600);  // явно
```

---

## 5. Строки

### Что спросят

> «Интерполяция, heredoc, мультилайны, строковые функции»

### Ответ

```php
declare(strict_types=1);

int $amount = 1500;
string $service = 'contact_access';

// Интерполяция
string $msg = "Платёж {$amount} ₽ за {$service}";  // двойные кавычки
// ВАЖНО: в одинарных — нет!

// Heredoc (8.0+)
string $sql = <<<'SQL'
    SELECT id, amount_minor
    FROM payment
    WHERE status = 'paid' AND paid_at >= ?day
SQL;

// String builder (8.0+)
string $url = "https://api.profiru.ru/v2/{$service}/{$paymentId}";

// Основные функции
string $s = '  hello, world  ';
$s->trim();                // 'hello, world'
$s->upper();               // 'HELLO, WORLD'
$s->replace('world', 'php'); // 'hello, php'
$s->split(', ');           // ['hello', 'world']
$s->contains('hello');     // true
$s->startsWith('  hel');   // true
$s->length();              // 15
```

---

## 6. Исключения

### Что спросят

> «Как работает try/catch? Что нельзя ловить? Когда использовать throw?»

### Ответ

```php
declare(strict_types=1);

function loadPayment(int $id): Payment {
    $payment = $this->payments->find($id);
    if ($payment === null) {
        throw new PaymentNotFound($id);  // доменное исключение
    }
    if ($payment->status() === PaymentStatus::Failed) {
        throw new PaymentFailedException($payment);  // бизнес-правило
    }
    return $payment;
}

// Обработка
try {
    $payment = loadPayment($id);
    process($payment);
} catch (PaymentNotFound $e) {
    // 404 — не ошибка, а состояние
    return response(status: 404, body: ['error' => 'not_found']);
} catch (PaymentFailedException $e) {
    // логика восстановления
    $this->logger->warning('Попытка обработать failed-платёж', $e);
    throw;  // переброс — да, это нормально!
} catch (\Throwable $e) {
    // неожиданное: падение БД, таймаут сети
    $this->alerts->critical('Unhandled in payment flow', $e);
    throw;
} finally {
    $this->pdo?->close();  // очистка всегда
}

// ПРАВИЛА биллинга:
// 1. Не ловить TypeError/ValueError — они означают баг, а не состояние
// 2. Доменные исключения наследовать от Exception
// 3. На границе с внешним миром (вебхук) — свой иерархия:
//    PaymentNotFound → 404, RefundExceedsPaid → 422, UnauthorizedWebhook → 401
```

---

## 7. `match` — замена `switch`

### Что спросят

> «Расскажи про match в PHP 8. Чем лучше switch? Обязателен ли default?»

### Ответ

```php
declare(strict_types=1);

enum PaymentStatus: string {
    case Created  = 'created';
    case Pending  = 'pending';
    case Paid     = 'paid';
    case Refunded = 'refunded';
    case Failed   = 'failed';
}

// match — выражение (возвращает значение)
public function isFinal(): bool {
    return match ($this) {
        self::Paid, self::Refunded, self::Failed => true,
        self::Created, self::Pending             => false,
    };
}

// match с null
function transitionFor(?PaymentStatus $status): ?string {
    return match ($status) {
        PaymentStatus::Pending => 'pending',
        PaymentStatus::Paid    => 'paid',
        null                   => null,   // явно
        default                => null,   // всё, что не перечислили
    };
}

// ⚠️ Без default — бросит UnhandledMatchError!
match ($x) {
    1 => 'one',
    2 => 'two',
    // нет default — если $x=3, упадёт!
}

// В биллинге:
// match с default, возвращающим null — безопасный маппинг статусов ПС
```

### Чем лучше `switch`

| | `switch` | `match` |
|---|---|---|
| Возвращает значение | ❌ (только через `break` + переменная) | ✅ |
| Exhaustive check | ❌ | ✅ (без `default` — ошибка компиляции на пропущенный case) |
| Fallthrough по умолчанию | ✅ — случайно | ❌ |
| `match` с `default => null` | ❌ | ✅ — «неизвестный статус не ломает обработчик» |

---

## 8. Атрибуты (`#[...]`)

### Что спросят

> «Что такое атрибуты в PHP 8? Для чего используются?»

### Ответ

```php
declare(strict_types=1);

// Встроенные
#[Override]
public function __invoke(CreateRefund $cmd): RefundId { ... }

#[Deprecated(reason: 'use PaymentService::refund() instead')]
public function oldMethod(): void { ... }

// Контракт для тестов (Contract Test)
abstract class PaymentProviderContractTest extends TestCase {
    #[Test]
    public function testRefundReturnsRefundId(): void { ... }
}

// Пользовательские — через атрибуты-классы
<<Retry(maxAttempts: 3, backoffMs: 100)>>
function withRetry(callable(): void $fn): void {
    // ...
}

// Пример из биллинга: маркер «идемпотентный метод»
<<Idempotent(ttl: '24h')>>
function processRefund(Refund $refund): void { ... }
```

---

## 9. Конструктор promotion

### Что спросят

> «Что такое promoted constructor? Как объявить readonly-свойство?»

### Ответ

```php
declare(strict_types=1);

// Вместо:
class OldPayment {
    private readonly int $id;
    private readonly string $status;
    public function __construct(int $id, string $status) {
        $this->id = $id;
        $this->status = $status;
    }
}

// ➡️ ОДНОЙ СТРОКОЙ:
class Payment {
    public function __construct(
        private readonly int $id,
        private readonly string $status,
        public readonly DateTime $createdAt,       // публичное readonly
        private ?string $providerId = null,         // с дефолтом
    ) {}
}

// clone with — мутация с созданием копии (VO):
$updated = $payment->clone with {
    status: 'paid',
    paidAt: new DateTime(),
};
// $payment остался неизменным
```

---

## 10. Идиомы биллинга на PHP

Что ожидают услышать от кандидата, не дожидаясь прямого вопроса.

```php
declare(strict_types=1);

// 1. Value Object для денег — не int, не float
readonly class Money {
    public function __construct(
        private readonly int $amountMinor,
        private readonly string $currency,
    ) {}
    public function add(Money $other): Money { ... }
    public function allocate(array<int> $weights): array<Money> { ... }
}

// 2. Идемпотентность через UNIQUE в БД — не через проверку в коде
// ❌ if ($exists) return;
// ✅ UNIQUE(idempotency_key) — INSERT сам защищает

// 3. SELECT ... FOR UPDATE под транзакцией
$payment = $this->payments->findForUpdate($id);  // ждёт, если заблокировано

// 4. withDeadlockRetry — обязательная обёртка
function withDeadlockRetry(PDO $pdo, callable(): void $fn): void {
    int $attempts = 0;
    while (true) {
        try {
            $fn();
            return;
        } catch (DeadlockException $e) {
            if (++$attempts >= 3) throw;
            usleep(50_000 * $attempts);  // exponential backoff
        }
    }
}

// 5. Default в match — не бросать на незнакомом значении извне
match ($pspStatus) {
    'succeeded'  => PaymentStatus::Paid,
    'pending'    => PaymentStatus::Pending,
    'failed'     => PaymentStatus::Failed,
    default      => null,   // [psp] status unknown — логируем, не ломаем
}

// 6. declare(strict_types=1) — в каждом файле с деньгами
```

---

## 11. Подводные камни

То, на чём валятся на собесах (copypaste из `03-php8-for-billing.md §Подводные камни`).

| Ловушка | Правильно |
|---|---|
| `in_array($x, $list)` без `true` | `in_array($x, $list, true)` — иначе `0 == 'foo'` |
| `from()` для внешнего статуса | `tryFrom()` → `null` → log, не падать |
| `match` без `default` | `default => null` для запасного статуса |
| `isset()` для проверки ключа | `array_key_exists()` если `null` — валидное значение |
| `switch` с fallthrough | `match` — осознанное перечисление case-ов |
| Публичные мутаторы у Value Object | `readonly class` + `clone with` — неизменяемость |
| Сравнение строк через `==` | `===` (strict) или `.equals()` для доменных объектов |
| `empty($x)` для проверки на null | `$x === null` — `empty()` вернёт true для `0`, `''`, `false` |

---

## 12. Вопросы и ответы

### Q1. «Какая разница между `array<int>` и `Hash<int>`?»

**A:** `array<int>` — индексированный список (0, 1, 2…). `Hash<int>` — произвольные строковые ключи. Оба гомогенные (тип элемента фиксирован). Если нужен список — `array`, если карта — `Hash`.

### Q2. «Что такое strict_types и зачем он в биллинге?»

**A:** Запрещает неявное приведение типов. Без него `add('5', 3)` приведёт `'5'` к `5` молча. В денежном коде тихая потеря точности или неверный тип — потеря денег. `declare(strict_types=1)` в начале каждого файла — требование, не рекомендация.

### Q3. «Чем `??` отличается от `?:`?»

**A:** `$a ?? $b` — берёт `$a`, если оно не null, иначе `$b`. Это оператор значения по умолчанию. `$obj?->field` — безопасный доступ: если `$obj === null`, выражение не падает, а возвращает null. Разные задачи: `??` для дефолта, `?:` для разыменования цепочки.

### Q4. «Что делает `match` и чем он лучше `switch`?»

**A:** `match` — выражение (возвращает значение), exhaustive (без `default` — ошибка компиляции на пропущенные варианты), нет случайного fallthrough. `switch` — только оператор с проваливанием по умолчанию.

### Q5. «Как сделать неизменяемый объект в PHP 8?»

**A:** `readonly class` — все свойства readonly по умолчанию. Конструктор promotion: `public function __construct(private readonly int $id)`. Изменение — только через `clone with { field: newValue }`. Идеально для Money, PaymentStatus, Value Object.

### Q6. «Что такое promoted constructor?»

**A:** Синтаксический сахар: параметры конструктора с `private/public` и `readonly` автоматически становятся свойствами класса без ручного присваивания:

```php
class Payment {
    public function __construct(
        private readonly int $id,       // сразу $this->id
        public string $status,          // и $this->status
    ) {}
}
```

### Q7. «Какие способы обойти массив?»

**A:** `foreach ($items as $val)`, `foreach ($items as $i => $val)`, `array_map`, `array_filter`, генераторы (`yield`). Для больших отчётов — генераторы, чтобы не держать всё в памяти.

### Q8. «Что такое closure и зачем в биллинге?»

**A:** Функция, захватывающая переменные из области определения. Пример: `fn () => ++$count`. В биллинге — замыкание для `withDeadlockRetry`, стратегии (`fn ($payment) => $payment->status()->canTransitionTo(...)`), колбэки в обработчиках вебхуков.

### Q9. «Как обработать ошибку БД в транзакции?»

**A:** `catch (DeadlockException)` → retry с backoff. `catch (PDOException)` → rollback + алерт. Бизнес-исключения (`PaymentNotFound`) — не ошибка, а состояние; обрабатываются выше по стеку, не ловятся в слое БД.

### Q10. «Что выведет этот код и почему?»

```php
declare(strict_types=1);
$arr = ['a' => null, 'b' => 1];
echo isset($arr['a']);     // ?
echo empty($arr['b']);     // ?
echo $arr['c'] ?? 'none';  // ?
```

**A:**
- `isset($arr['a'])` → **false**, потому что `null`.
- `empty($arr['b'])` → **false**, потому что `1` — не пустое.
- `$arr['c'] ?? 'none'` → **'none'**, потому что ключа нет → `null` → ?? берёт 'none'.

### Q11. «Можно ли выбросить исключение из конструктора?»

**A:** Да, и это нормальная практика: `throw new InvalidAmountException(...)` в конструкторе `Money`, если сумма отрицательная. Но лучше — отдельный Factory Method с возвратом `Result<Money>` или `?Money`.

### Q12. «Какие типы исключений нельзя ловить?»

**A:** `TypeError`, `ValueError` (баги, а не состояния), `Error` (фатальные системные). Их ловить = скрывать баг. Доменные исключения (`PaymentNotFound`) — ловить и обрабатывать.

### Q13. «Что такое `never`-тип?»

**A:** Тип для функций, которые никогда не возвращают управление: `throw` или бесконечный цикл. Используется редко, но знать стоит.

```php
function fail(string $msg): never {
    throw new Exception($msg);
}
```

### Q14. «Как безопасно получить значение из массива?»

**A:** `$arr[$key] ?? $default` — если ключа нет, вернёт `$default`. Либо `array_key_exists($arr, $key)` для проверки существования. `$arr[$key]` на несуществующем ключе выбросит `OffsetError` (или вернёт null, без `strict_types`).

### Q15. «Какая разница между `throw` и `throw new`?»

**A:** `throw` — переброс текущего исключения (из catch). `throw new ...` — создание нового. Переброс сохраняет оригинальный trace, не заворачивает его.