-- ============================================================================================
-- Запросы биллинга: инварианты, сверки, отчёты и EXPLAIN-примеры.
--
-- В демо-данных специально заложены нарушения, поэтому часть запросов ДОЛЖНА что-то найти
-- (это и есть проверка, что ты умеешь искать расхождения в деньгах, а не только писать CRUD).
--
--   docker compose exec -T mysql mysql -uroot -pbilling billing < sql/03-queries.sql
--
-- «Текущее время» для демо фиксируем константой, потому что данные исторические.
-- В проде вместо @REF_NOW используй NOW().
-- ============================================================================================
USE billing;
SET NAMES utf8mb4;
SET @REF_NOW = '2025-05-17 12:00:00.000000';

SELECT '=========== И1. Сумма проводок по операции должна быть 0 ===========' AS `--`;
SELECT operation_id,
       COUNT(*)          AS entries,
       SUM(amount_minor) AS sum_minor,
       MIN(created_day)  AS day
  FROM ledger_entry
 GROUP BY operation_id
HAVING SUM(amount_minor) <> 0
 ORDER BY day, operation_id;
-- Ожидание в лаборатории: найдётся op-00000004... (перекос на -100 копеек: неверный НДС).
-- В проде это 🔴 немедленный разбор: значит, кто-то писал проводки не через двойную запись.

SELECT '=========== И2. Сальдо счёта должно равняться сумме его проводок ===========' AS `--`;
SELECT a.id,
       a.owner_type,
       a.owner_id,
       a.balance_minor                                   AS stored_balance,
       COALESCE(SUM(l.amount_minor), 0)                  AS ledger_sum,
       a.balance_minor - COALESCE(SUM(l.amount_minor),0) AS diff
  FROM account a
  LEFT JOIN ledger_entry l ON l.account_id = a.id
 GROUP BY a.id, a.owner_type, a.owner_id, a.balance_minor
HAVING COALESCE(SUM(l.amount_minor), 0) <> a.balance_minor
 ORDER BY ABS(a.balance_minor - COALESCE(SUM(l.amount_minor),0)) DESC;
-- Ожидание: счета 1 (транзит) и 3 (НДС) разойдутся с проводками (денормализованный кэш отстал).

SELECT '=========== И3. Оплачено, но чека нет (дольше 10 минут) ===========' AS `--`;
SELECT p.id,
       p.service_code,
       p.amount_minor,
       p.paid_at,
       r.status               AS receipt_status,
       r.attempts             AS receipt_attempts,
       TIMESTAMPDIFF(MINUTE, p.paid_at, @REF_NOW) AS minutes_without_receipt
  FROM payment p
  LEFT JOIN receipt r ON r.payment_id = p.id AND r.receipt_type = 'income'
 WHERE p.status IN ('paid','partially_refunded','refunded')
   AND p.paid_at IS NOT NULL
   AND p.paid_at < @REF_NOW - INTERVAL 10 MINUTE
   AND p.paid_at > @REF_NOW - INTERVAL 30 DAY
   AND (r.id IS NULL OR r.status <> 'printed')
 ORDER BY p.paid_at;
-- Ожидание: платёж 4 (чек в retry_wait — провайдер таймаутил).
-- ЭТО ГЛАВНАЯ ДОМЕННАЯ МЕТРИКА ФИСКАЛИЗАЦИИ — она должна быть на дашборде и в алертах.

SELECT '=========== И4. Возвраты не должны превышать платёж ===========' AS `--`;
SELECT p.id,
       p.amount_minor                   AS paid_minor,
       p.refunded_minor                 AS payment_counter,
       COALESCE(SUM(r.amount_minor), 0) AS refunds_sum,
       COALESCE(SUM(r.amount_minor), 0) - p.amount_minor AS over_refund,
       p.refunded_minor - COALESCE(SUM(r.amount_minor), 0) AS counter_mismatch
  FROM payment p
  JOIN refund r ON r.payment_id = p.id AND r.status = 'completed'
 GROUP BY p.id, p.amount_minor, p.refunded_minor
HAVING SUM(r.amount_minor) > p.amount_minor
    OR p.refunded_minor <> COALESCE(SUM(r.amount_minor), 0);
-- Ожидание: платёж 5 — возврат 35000 при оплате 30000 (пере-возврат) + расхождение счётчика.

SELECT '=========== И5. У нас "оплачено", а в реестре ПС операции нет (ours_only) ===========' AS `--`;
SELECT p.id, p.provider_code, p.provider_payment_id, p.amount_minor, p.operation_day, p.paid_at
  FROM payment p
  LEFT JOIN psp_registry_row r
    ON  r.provider_code       = p.provider_code
    AND r.provider_payment_id = p.provider_payment_id
    AND r.created_day         = p.operation_day
 WHERE p.status IN ('paid','partially_refunded','refunded')
   AND p.paid_at < @REF_NOW - INTERVAL 6 HOUR      -- окно задержки реестра истекло
   AND r.id IS NULL
 ORDER BY p.paid_at;
-- Ожидание: платёж 4 (CARD-2002) — «мы считаем оплаченным без подтверждения ПС». Приоритет 1.

SELECT '=========== И6. У ПС операция есть, у нас записи нет (theirs_only) ===========' AS `--`;
SELECT r.provider_code, r.provider_payment_id, r.order_id, r.amount_minor, r.created_day, r.status
  FROM psp_registry_row r
  LEFT JOIN payment p
    ON  p.provider_code       = r.provider_code
    AND p.provider_payment_id = r.provider_payment_id
 WHERE r.created_day >= @REF_NOW - INTERVAL 30 DAY
   AND p.id IS NULL
 ORDER BY r.created_day, r.provider_payment_id;
-- Ожидание: SBP-1006 и CARD-2009 — «потеряли платёж». Приоритет 1: деньги есть, учёта нет.

SELECT '=========== И7. Зависшие платежи: нужно дожать через getStatus ===========' AS `--`;
SELECT id, provider_code, provider_payment_id, status, created_at,
       TIMESTAMPDIFF(MINUTE, created_at, @REF_NOW) AS age_minutes
  FROM payment
 WHERE status IN ('pending','unknown')
   AND created_at < @REF_NOW - INTERVAL 10 MINUTE
   AND created_at > @REF_NOW - INTERVAL 7 DAY
 ORDER BY created_at
 LIMIT 500;
-- Ожидание: платёж 3 (pending с 2025-05-15). В проде это вход в reconciler.

SELECT '=========== И8. Агрегат должен совпадать с фактическими данными ===========' AS `--`;
SELECT a.legal_entity_id, a.day, a.service_code, a.status,
       a.operations_cnt AS agg_cnt, x.cnt AS raw_cnt,
       a.amount_minor   AS agg_sum, x.sum_minor AS raw_sum
  FROM billing_daily_agg a
  LEFT JOIN (
      SELECT legal_entity_id, operation_day AS day, service_code, status,
             COUNT(*) AS cnt, SUM(amount_minor) AS sum_minor
        FROM payment
       WHERE status IN ('paid','partially_refunded','refunded')
       GROUP BY legal_entity_id, operation_day, service_code, status
  ) x ON  x.legal_entity_id = a.legal_entity_id
      AND x.day             = a.day
      AND x.service_code    = a.service_code
      AND x.status          = a.status
 WHERE a.operations_cnt <> COALESCE(x.cnt, 0) OR a.amount_minor <> COALESCE(x.sum_minor, 0);
-- Ожидание: строка contact_access/paid (в агрегате 99 операций и 9 999 999 копеек).
-- Правило: агрегат — производная величина; расхождение с источником = алерт, а не «поправим».

SELECT '=========== И9. Использования подписки должны совпадать со счётчиком ===========' AS `--`;
SELECT s.id, s.quantity_total, s.quantity_used, COALESCE(u.used_cnt, 0) AS actual_used
  FROM subscription s
  LEFT JOIN (SELECT subscription_id, COUNT(*) AS used_cnt FROM entitlement_usage GROUP BY subscription_id) u
    ON u.subscription_id = s.id
 WHERE s.quantity_used <> COALESCE(u.used_cnt, 0);
-- Ожидание: подписка 1 (quantity_used = 3, фактических использований 2).

SELECT '=========== И10. Дубли ключей идемпотентности (в норме — пусто) ===========' AS `--`;
SELECT 'payment' AS entity, idempotency_key AS k, COUNT(*) AS cnt
  FROM payment GROUP BY idempotency_key HAVING COUNT(*) > 1
UNION ALL
SELECT 'payment_event', CONCAT(source,':',event_id), COUNT(*)
  FROM payment_event GROUP BY source, event_id HAVING COUNT(*) > 1
UNION ALL
SELECT 'processed_event', CONCAT(source,':',event_id), COUNT(*)
  FROM processed_event GROUP BY source, event_id HAVING COUNT(*) > 1
UNION ALL
SELECT 'receipt', operation_id, COUNT(*)
  FROM receipt GROUP BY operation_id HAVING COUNT(*) > 1;
-- В норме пусто: это гарантия уровня БД. Непустой результат = отсутствует UNIQUE (или ключ "плавающий").

SELECT '=========== И11. Чек без расчёта (противоречие) ===========' AS `--`;
SELECT r.id, r.receipt_type, r.status, r.total_minor, r.payment_id, p.status AS payment_status
  FROM receipt r
  LEFT JOIN payment p ON p.id = r.payment_id
 WHERE r.receipt_type = 'income'
   AND (r.payment_id IS NULL OR p.status NOT IN ('paid','partially_refunded','refunded'));
-- В норме пусто: чек на приход не может существовать без состоявшейся оплаты. 🔴 если найдётся.

SELECT '=========== И12. Сверка с ПС: сводка по статусам сопоставления ===========' AS `--`;
SELECT provider_code, created_day, match_status, COUNT(*) AS cnt, SUM(amount_minor) AS sum_minor
  FROM psp_registry_row
 GROUP BY provider_code, created_day, match_status
 ORDER BY created_day DESC, provider_code, match_status;
-- Используется как «отчёт о сверке дня»: сколько сошлось, сколько расхождений и на какую сумму.

SELECT '=========== Отчёт 1. Выручка по дням/услугам/ставкам (для бухгалтерии) ===========' AS `--`;
SELECT p.operation_day,
       p.legal_entity_id,
       p.service_code,
       p.status,
       p.vat_rate,
       COUNT(*)               AS operations,
       SUM(p.vat_base_minor)  AS base_minor,
       SUM(p.vat_amount_minor) AS vat_minor,
       SUM(p.amount_minor)    AS gross_minor
  FROM payment p
 WHERE p.status IN ('paid','partially_refunded','refunded')
   AND p.operation_day >= '2025-05-01' AND p.operation_day < '2025-06-01'
 GROUP BY p.operation_day, p.legal_entity_id, p.service_code, p.status, p.vat_rate
 ORDER BY p.operation_day, p.service_code;

SELECT '=========== Отчёт 2. Контрольные итоги по дням (сверить с банком и ОФД) ===========' AS `--`;
SELECT p.operation_day,
       COUNT(*)                AS operations,
       SUM(p.amount_minor)     AS gross_minor,
       SUM(p.vat_amount_minor) AS vat_minor,
       (SELECT COUNT(*) FROM receipt r
         WHERE r.created_at >= p.operation_day AND r.created_at < p.operation_day + INTERVAL 1 DAY
           AND r.receipt_type = 'income' AND r.status = 'printed') AS receipts_printed,
       (SELECT SUM(rf.amount_minor) FROM refund rf
         WHERE DATE(rf.created_at) = p.operation_day AND rf.status = 'completed') AS refunded_minor
  FROM payment p
 WHERE p.operation_day >= '2025-05-01' AND p.operation_day < '2025-06-01'
   AND p.status IN ('paid','partially_refunded','refunded')
 GROUP BY p.operation_day
 ORDER BY p.operation_day;
-- Именно этот отчёт показывает расхождение «операций vs чеков» — то, что видит бухгалтерия.

SELECT '=========== Отчёт 3. Накопительная выручка по услугам (окно) ===========' AS `--`;
WITH daily AS (
  SELECT service_code, operation_day, SUM(amount_minor) AS revenue_minor
    FROM payment
   WHERE status IN ('paid','partially_refunded','refunded')
     AND operation_day >= '2025-05-01' AND operation_day < '2025-06-01'
   GROUP BY service_code, operation_day
)
SELECT service_code,
       operation_day,
       revenue_minor,
       SUM(revenue_minor) OVER (PARTITION BY service_code ORDER BY operation_day) AS cumulative_minor,
       ROUND(100 * revenue_minor
             / NULLIF(SUM(revenue_minor) OVER (PARTITION BY operation_day), 0), 2) AS share_pct
  FROM daily
 ORDER BY operation_day, revenue_minor DESC;

SELECT '=========== Диагностика 1. Сколько раз ПС дублировал события ===========' AS `--`;
SELECT source,
       COUNT(*)             AS distinct_events,
       SUM(seen_count)      AS total_deliveries,
       SUM(seen_count) - COUNT(*) AS duplicates
  FROM processed_event
 GROUP BY source;
-- Полезно, чтобы понимать «шум» интеграции: если duplicates большой — задумайся о NOWAIT
-- и о быстром ответе 200, потому что нас будут долбить.

SELECT '=========== Диагностика 2. Возраст самых старых незавершённых операций ===========' AS `--`;
SELECT 'payment.pending'   AS what, MIN(created_at) AS oldest, COUNT(*) AS cnt
  FROM payment WHERE status IN ('pending','unknown')
UNION ALL
SELECT 'receipt.not_printed', MIN(created_at), COUNT(*)
  FROM receipt WHERE status NOT IN ('printed','corrected')
UNION ALL
SELECT 'refund.not_completed', MIN(created_at), COUNT(*)
  FROM refund WHERE status NOT IN ('completed','failed','rejected')
UNION ALL
SELECT 'outbox.unpublished', MIN(created_at), COUNT(*)
  FROM outbox WHERE published_at IS NULL;
-- Это «метрика здоровья»: если oldest стареет — что-то системно не догоняется.

-- ============================================================================================
-- EXPLAIN-упражнения
--
-- ⚠️ ВАЖНО про чтение этих планов: в лаборатории всего 5 платежей, поэтому оптимизатор
--    почти всегда честно выбирает ALL — на маленьких данных это ДЕШЕВЛЕ, чем идти по индексу.
--    План зависит от данных, а не только от запроса. Поэтому смотри не только `type`,
--    но и `possible_keys` (какие индексы ВООБЩЕ подходят) и `key_len`: если индекс даже
--    не рассматривается — дело не в объёме, а в форме запроса (функция на колонке,
--    не тот тип, приведение). Смысл упражнения — увидеть разницу в possible_keys/key,
--    а не «план на 5 строках».
--    Хочешь реалистичный план — залей побольше данных:
--      INSERT INTO payment (...) SELECT ... FROM payment;  (повторить 10-15 раз)
-- ============================================================================================

SELECT '=========== EXPLAIN 1: кабинет пользователя (использует композитный индекс) ===========' AS `--`;
EXPLAIN SELECT id, amount_minor, currency, status, created_at
  FROM payment
 WHERE user_id = 42 AND status = 'paid'
 ORDER BY created_at DESC
 LIMIT 20;
-- Ждём: key = idx_user_status_created (равенства user_id+status вперёд, created_at последним —
-- именно поэтому нет Using filesort). Это единственный пример, который на 5 строках
-- показывает работу индекса: условие очень селективное (user_id+status).

SELECT '=========== EXPLAIN 2: функция на колонке — диапазонная часть индекса потеряна ===========' AS `--`;
EXPLAIN SELECT COUNT(*) FROM payment
 WHERE legal_entity_id = 1 AND DATE(operation_day) = '2025-05-15';
-- Ключ к пониманию — key_len и rows. Индекс idx_entity_day_status =
-- (legal_entity_id, operation_day, status): ключ (BIGINT=8) + DATE(3) + VARCHAR.
-- Здесь key_len = 8, то есть используется ТОЛЬКО первая колонка (равенство по legal_entity_id):
-- функция DATE(operation_day) убила диапазонную часть, и по индексу мы прочитаем ВСЕ строки
-- этого юрлица. Именно поэтому функции на колонке — классический источник «индекс есть,
-- а запрос медленный»: индекс формально участвует, а селективности не даёт.

SELECT '=========== EXPLAIN 3: тот же смысл диапазоном — индекс используется полностью ===========' AS `--`;
EXPLAIN SELECT COUNT(*) FROM payment
 WHERE legal_entity_id = 1
   AND operation_day >= '2025-05-15' AND operation_day < '2025-05-16';
-- Сравни key_len с EXPLAIN 2: теперь в индекс попало и равенство, и диапазон
-- (equalities first, then range). На реальных объёмах это превратится в type = range
-- с чтением одной «полосы» индекса вместо всех строк юрлица.
-- (Если фильтровать по created_at — индекса на этой колонке нет, и урок будет другой:
--  «диапазон работает только по индексированной колонке». Именно поэтому в схеме есть
--  отдельная колонка operation_day с индексом.)

SELECT '=========== EXPLAIN 4: неявное приведение типа (VARCHAR vs число) ===========' AS `--`;
EXPLAIN SELECT * FROM payment WHERE provider_payment_id = 1000500071;
SHOW WARNINGS;
EXPLAIN SELECT * FROM payment WHERE provider_payment_id = '1000500071';
-- На 5 строках оба плана будут одинаковыми (ALL и possible_keys = NULL) — оптимизатору
-- просто нечего оптимизировать. Урок про приведение типов здесь видно НЕ будет.
-- Чтобы увидеть его реально: залей побольше данных (см. подсказку в начале этого блока)
-- и повтори. Тогда первый запрос (число вместо строки) не сможет использовать
-- uq_provider_payment, потому что сравнивается с приведённой к числу колонкой;
-- во втором (строка, тип совпадает) индекс применим.
-- Скрытая опасность приведения: '1000500071abc' при сравнении с числом может «совпасть»
-- с 1000500071 — это уже логическая ошибка в деньгах, а не только производительность.

SELECT '=========== EXPLAIN 5: очередь в БД через SKIP LOCKED ===========' AS `--`;
SELECT id, event_type, attempts
  FROM outbox
 WHERE published_at IS NULL
 ORDER BY id
 LIMIT 10
   FOR UPDATE SKIP LOCKED;
-- Запусти в двух сессиях одновременно: каждый воркер возьмёт СВОИ строки, а не встанет в очередь.
-- ⚠️ Совместимость: `SKIP LOCKED` — MySQL 8.0.1+ и MariaDB 10.6+.
--    На MariaDB 10.4/10.5 это синтаксическая ошибка (1064) — поэтому, если ты запускаешь
--    лабораторию не на MySQL 8 из docker-compose, а на локальной MariaDB постарше,
--    просто закомментируй этот блок: остальные запросы совместимы.

-- ============================================================================================
-- Транзакции и локи: эксперименты в двух сессиях (см. 12-labs/README.md)
-- ============================================================================================
-- Сессия A:
--   SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
--   BEGIN; UPDATE payment SET status = status WHERE legal_entity_id = 1 AND status = 'pending';
-- Сессия B (параллельно):
--   SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
--   BEGIN; UPDATE payment SET status = status WHERE id = 1;   -- ЖДЁТ (или дедлок)
-- Диагностика из третьей сессии:
--   SELECT * FROM performance_schema.data_lock_waits;
--   SELECT ENGINE_TRANSACTION_ID, OBJECT_NAME, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
--     FROM performance_schema.data_locks ORDER BY ENGINE_TRANSACTION_ID;
--   SHOW ENGINE INNODB STATUS\G          -- секция LATEST DETECTED DEADLOCK
--
-- Затем повтори то же на READ COMMITTED — и убедись, что gap-локов больше нет.
