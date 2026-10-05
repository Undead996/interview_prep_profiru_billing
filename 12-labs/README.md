# Лаборатория: MySQL + Redis + RabbitMQ «биллинг» в docker

> **Зачем это нужно.** На собеседовании спросят «разбираетесь ли вы в транзакциях и индексах».
> Ответы запоминаются, а вот **формулировки, рождённые после того, как ты своими глазами увидел
> лок-ожидание и дедлок**, звучат совсем иначе. Здесь — минимальная лаборатория: схема биллинга
> из `08-system-design/02-db-design-walkthrough.md`, данные с «грязными» кейсами и запросы,
> которые ищут расхождения.

---

## 1. Поднять

```bash
cd 12-labs
docker compose up -d

# дождаться готовности MySQL
docker compose exec mysql sh -c 'until mysqladmin ping -h 127.0.0.1 -uroot -pbilling >/dev/null 2>&1; do sleep 1; done; echo ready'

# применить схему и данные
docker compose exec -T mysql mysql -uroot -pbilling billing < sql/01-schema.sql
docker compose exec -T mysql mysql -uroot -pbilling billing < sql/02-seed.sql

# поиграться в консоли
docker compose exec mysql mysql -uroot -pbilling billing
```

| Сервис | Порт | Доступ |
|---|---|---|
| MySQL 8 | 3306 | user `root`, password `billing`, БД `billing` |
| Redis 7 | 6379 | без пароля (только локально!) |
| RabbitMQ 3.13 + management | 5672 / **15672** | guest / guest → <http://localhost:15672> |

---

## 2. Что потрогать руками (обязательный минимум)

### А. Увидеть, что индекс определяет размер локов (и получить дедлок)

Терминал 1:

```sql
USE billing;
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
UPDATE payment SET status = status WHERE legal_entity_id = 1 AND status = 'pending';  -- диапазон!
-- НЕ коммитим!
```

Терминал 2:

```sql
USE billing;
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
UPDATE payment SET status = status WHERE id = 1;      -- точечно по PK — ЖДЁТ
-- здесь либо ожидание до innodb_lock_wait_timeout, либо дедлок
```

Посмотреть, кто кого ждёт:

```sql
SELECT * FROM performance_schema.data_lock_waits;
SELECT ENGINE_TRANSACTION_ID, OBJECT_NAME, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
  FROM performance_schema.data_locks ORDER BY ENGINE_TRANSACTION_ID;
```

**Что увидишь:** первый запрос держит локи на строки (и, в RR, на промежутки), второй ждёт.
Сравни с `READ COMMITTED` — gap-локов не будет. **Это и есть твой ответ про изоляцию.**

### Б. Проверить, что индекс работает

```sql
EXPLAIN SELECT id, amount_minor, status, created_at
  FROM payment
 WHERE user_id = 42 AND status = 'paid'
 ORDER BY created_at DESC LIMIT 20;
-- Убедись, что используется idx_user_status_created и НЕТ Using filesort

EXPLAIN SELECT COUNT(*) FROM payment WHERE DATE(created_at) = '2025-05-15';
-- type: ALL — функция на колонке убила индекс. Сравни с:
EXPLAIN SELECT COUNT(*) FROM payment
 WHERE created_at >= '2025-05-15 00:00:00' AND created_at < '2025-05-16 00:00:00';
-- сравни key_len и rows

EXPLAIN SELECT * FROM payment WHERE provider_payment_id = 1234567890;   -- число!
SHOW WARNINGS;                                                          -- найдёшь причину
```

### В. Идемпотентность

```sql
-- Повторить этот блок дважды и посмотреть на seen_count.
INSERT INTO processed_event (source, event_id, payload_hash, processed_at)
VALUES ('psp', 'evt-777', SHA2('x',256), NOW(6)) AS new
ON DUPLICATE KEY UPDATE seen_count = seen_count + 1, payload_hash = new.payload_hash;
SELECT * FROM processed_event WHERE event_id = 'evt-777';   -- после второго прогона seen_count = 2
```

> ⚠️ **Ловушка rowCount() — на ней легко ошибиться, поэтому разберём явно.**
> `ON DUPLICATE KEY UPDATE` возвращает:
> * **1** — строку вставили (событие первое);
> * **2** — строка была, и мы её **обновили** (`seen_count + 1`) — это дубль;
> * **0** — строка была, и мы **ничего не изменили** (если апдейт — no-op, например `id = id`).
>
> То есть «дубль» — это НЕ всегда 0. Если в апдейте есть реальное изменение (как `seen_count + 1`
> выше), дубль даст **2**, и проверка `rowCount() === 0` его не поймает. Универсальная проверка —
> **`rowCount() !== 1`**, а если нужен именно no-op-вариант (для `insertId()`), пиши `UPDATE id = id`
> и тогда 0 действительно означает дубль.

> ℹ️ **Совместимость синтаксиса.** Алиас в `INSERT ... VALUES (...) AS new` — это **MySQL 8.0.19+**
> (и он заменил устаревший `VALUES(col)`). Лаборатория из `docker-compose.yml` использует
> MySQL 8.0, поэтому здесь всё работает как есть. Если запускаешь на локальной MariaDB
> (например, XAMPP) — замени `AS new` и `new.col` на `VALUES(col)`;
> в MariaDB 10.4/10.5 также нет `SKIP LOCKED` (см. примечание в `sql/03-queries.sql`).

### Г. Денежные инварианты

```sql
SOURCE sql/03-queries.sql;   -- или выполнить файл целиком
```

Смотри, какие запросы находят «специально сломанные» кейсы в `02-seed.sql`:

| Запрос | Что найдёт в данных |
|---|---|
| И1: сумма проводок по операции ≠ 0 | операция с перекосом проводок |
| И2: сальдо ≠ сумме проводок | счёт, где денормализованный баланс «отстал» |
| И3: оплачено без чека | платёж `paid`, чек в статусе `retry_wait`/отсутствует |
| И4: пере-возврат | возвратов больше, чем оплачено |
| И5: у нас `paid`, в реестре ПС нет | расхождение сверки |
| И6: у ПС есть, у нас нет | потерянный платёж |
| И7: зависшие `pending` | платёж старше 10 минут для дожима |

**Это и есть половина практических задач собеседования** — в виде, который можно проверить.

### Д. Очередь в БД через `SKIP LOCKED`

```sql
-- Терминал 1
BEGIN;
SELECT id, event_type FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT 5 FOR UPDATE SKIP LOCKED;
-- Терминал 2 (параллельно): та же выборка вернёт ДРУГИЕ строки (или пусто), а не будет ждать
```

---

## 3. PHP-демо

```bash
docker compose exec php php /app/php/payment_flow_demo.php
```

Скрипт (`php/payment_flow_demo.php`) показывает:
1. создание платежа с ключом идемпотентности и повторный вызов (возврат того же платежа);
2. обработку «вебхука» с защитой от дубля;
3. запись проводок с суммой 0 и `outbox` в одной транзакции;
4. таймаут → статус `unknown` (а не `failed`);
5. печать инвариантов учёта после операций.

---

## 4. Что делать, если docker недоступен

Все смыслы можно получить и на одном MySQL (или даже на локальном XAMPP, см. соседнюю папку
`php_xampp`):

```bash
mysql -uroot -p billing < sql/01-schema.sql
mysql -uroot -p billing < sql/02-seed.sql
mysql -uroot -p billing < sql/03-queries.sql
```

Redis/RabbitMQ в этом случае пропускай — по ним достаточно шпаргалки
`11-cheatsheets/03-rabbitmq.md` и `04-redis.md`.

---

## 5. Остановить и убрать

```bash
docker compose down          # оставить данные
docker compose down -v       # снести всё, включая volume
```
