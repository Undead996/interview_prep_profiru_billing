# MySQL: шпаргалка на один экран

## Индексы

```sql
-- Посмотреть план и индексы
EXPLAIN SELECT ...;                 -- план (оценка)
EXPLAIN ANALYZE SELECT ...;         -- ФАКТ (8.0.18+), выполняет запрос — осторожно на проде
EXPLAIN FORMAT=JSON SELECT ...;
SHOW INDEX FROM payment;            -- Cardinality = оценка уникальности
SHOW WARNINGS;                      -- ← после EXPLAIN: тут видны причины "индекс не используется"
ANALYZE TABLE payment;              -- обновить статистику
ANALYZE TABLE payment UPDATE HISTOGRAM ON status WITH 32 BUCKETS;  -- для неравномерных значений

-- Создать/удалить безопасно
ALTER TABLE payment ADD INDEX idx_x (a, b, c), ALGORITHM=INPLACE, LOCK=NONE;
ALTER TABLE payment ALTER INDEX idx_x SET INVISIBLE;   -- сначала невидимый, наблюдаем
ALTER TABLE payment DROP INDEX idx_x;                  -- потом удаляем

-- Найти неиспользуемые
SELECT object_name, index_name FROM performance_schema.table_io_waits_summary_by_index_usage
 WHERE object_schema=DATABASE() AND index_name IS NOT NULL AND count_star=0;
```

**Правила:** left-most prefix; после первого диапазона хвост не ищет; функции на колонке
убивают индекс; неявное приведение типов убивает индекс (`VARCHAR` vs число); `ORDER BY`
должен совпадать с порядком индекса, иначе `filesort`.

## Как читать EXPLAIN (по колонкам)

| Колонка | Смотри | Плохо |
|---|---|---|
| `type` | `const > eq_ref > ref > range > index > ALL` | `ALL` = full scan |
| `key` | какой индекс выбран | `NULL` при непустом `possible_keys` |
| `key_len` | сколько байт индекса | меньше ожидаемого → хвост не используется |
| `ref` | с чем сравниваем | `func` = вычисление/приведение |
| `rows` | оценка строк | миллионы на «точечном» |
| `Extra` | `Using index` ✅, `Using filesort` ⚠️, `Using temporary` ⚠️, `Using index condition` ✅ | |

## Транзакции и локи

```sql
SELECT @@transaction_isolation;                       -- по умолчанию REPEATABLE-READ
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;

BEGIN;
SELECT * FROM payment WHERE id=1 FOR UPDATE;          -- точечный X-лок
SELECT * FROM payment WHERE id=1 FOR UPDATE NOWAIT;   -- не ждать (ERROR 3572)
SELECT id FROM job WHERE status='new' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;  -- очередь
SELECT * FROM payment WHERE id=1 FOR SHARE;
COMMIT;
```

**Локи:** record / gap / next-key / insert-intention. Gap-локи — только в RR.
`UPDATE` без индекса → диапазонный лок → дедлоки и блокировки записи.

**Классификация ошибок для retry:**

| Код | SQLSTATE | Что | Действие |
|---|---|---|---|
| 1213 | 40001 | дедлок (жертва откатана) | повторить с backoff + джиттер |
| 1205 | 40001 | lock wait timeout | повторить / вернуть «повторите» |
| 1062 | 23000 | дубликат | это идемпотентность, не ошибка |
| 1040 | 08004 | too many connections | пул/bulkhead |
| 1406/1264 | 22001/22003 | обрезка/переполнение | не игнорировать, проверять типы |

## Диагностика

```sql
SHOW ENGINE INNODB STATUS\G                 -- LATEST DETECTED DEADLOCK, BUFFER POOL AND MEMORY
SHOW VARIABLES LIKE 'innodb_lock_wait_timeout';
SET GLOBAL innodb_print_all_deadlocks = ON; -- писать все дедлоки в error log
SELECT * FROM performance_schema.data_lock_waits;   -- кто кого ждёт
SELECT * FROM performance_schema.data_locks;
SELECT trx_id, trx_started, TIMESTAMPDIFF(SECOND,trx_started,NOW()) age, trx_rows_locked, trx_mysql_thread_id
  FROM information_schema.innodb_trx ORDER BY trx_started;   -- долгие транзакции
SHOW PROCESSLIST;                            -- что выполняется сейчас
SHOW REPLICA STATUS\G                        -- Seconds_Behind_Source
```

## DDL: алгоритмы и блокировки

| DDL | Алгоритм | Блокирует запись? |
|---|---|---|
| `ADD COLUMN` в конец | INSTANT | нет |
| `ADD/DROP INDEX` | INPLACE | нет |
| `DROP COLUMN` | INPLACE | нет (данные потеряны!) |
| `MODIFY/CHANGE` типа | COPY | да (на большой таблице — инцидент) |
| `ADD PRIMARY KEY` | COPY | да |

Всегда указывай `ALGORITHM=INPLACE, LOCK=NONE` — пусть сервер откажет заранее.

## Идемпотентность в SQL

```sql
-- Вариант 1: узнать о дубле через rowCount()
INSERT INTO processed_event (...) VALUES (...) AS new
ON DUPLICATE KEY UPDATE seen_count = seen_count + 1, payload_hash = new.payload_hash;
-- 1 = вставили, 0 = дубль без изменений, 2 = дубль + обновили
-- ВАЖНО: VALUES() устарел с 8.0.20 → алиас (AS new) и new.<col>

-- Вариант 2: вернуть id существующей строки
INSERT INTO payment (...) VALUES (...) AS new
ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id);   -- insertId() даст id новой ИЛИ существующей
```

❌ `INSERT IGNORE` (глотает все ошибки) · ❌ `SELECT` + `INSERT` (гонка)

## Денежные инварианты (проверяй в CI и ночью)

```sql
-- сумма проводок по операции = 0
SELECT operation_id FROM ledger_entry WHERE created_day >= CURDATE()-INTERVAL 1 DAY
 GROUP BY operation_id HAVING SUM(amount_minor) <> 0;

-- баланс счёта = сумма проводок
SELECT a.id, a.balance_minor, COALESCE(SUM(l.amount_minor),0) s FROM account a
 LEFT JOIN ledger_entry l ON l.account_id=a.id GROUP BY a.id,a.balance_minor
HAVING COALESCE(SUM(l.amount_minor),0) <> a.balance_minor;

-- сумма проводок по платежу = сумме платежа
-- возвраты не больше платежа
-- у каждого оплаченного расчёта есть чек (старше N минут)
```

## Партиционирование: главное

```sql
PARTITION BY RANGE COLUMNS(created_day) (
  PARTITION p2025_05 VALUES LESS THAN ('2025-06-01'),
  PARTITION p_max    VALUES LESS THAN (MAXVALUE)
);
```
* партиционирующая колонка **обязана** входить в PK и все UNIQUE;
* нет глобальных уникальных индексов → «защиту от дублей» держи в отдельной
  **непартиционированной** таблице;
* фильтр без даты = все партиции;
* архивация: `EXCHANGE PARTITION` → архив → `DROP PARTITION`.

## Бэкфилл (6 правил)

```
1. keyset: WHERE id > :last ORDER BY id LIMIT 1000   (не OFFSET!)
2. короткие транзакции, батчами
3. пауза между батчами (троттлинг)
4. идемпотентно: можно перезапустить (WHERE ... IS NULL)
5. следи за отставанием реплик, останови при превышении
6. после — проверка-инвариант «расхождений 0»
```

## Чек-лист «индекс есть, а медленно»

```
□ функция на колонке → переписать диапазоном или денормализовать
□ left-most prefix нарушен → порядок колонок
□ диапазон «сломал» хвост → перенести диапазон после равенств
□ неявное приведение типов (VARCHAR vs число, коллация) → SHOW WARNINGS
□ селективность низкая → оптимизатор прав, нужен другой вход
□ статистика устарела → ANALYZE TABLE / гистограмма
□ ORDER BY не совпадает → filesort → индекс в порядке сортировки
□ мало строк? проверь на реальных данных (EXPLAIN — оценка)
```
