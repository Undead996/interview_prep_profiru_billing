-- ============================================================================================
-- Демо-данные со «специально сломанными» кейсами.
-- Каждый сломанный кейс помечен комментарием [ЛОМАЕМ], чтобы sql/03-queries.sql его нашёл.
--
--   docker compose exec -T mysql mysql -uroot -pbilling billing < sql/02-seed.sql
-- ============================================================================================
USE billing;
SET NAMES utf8mb4;

SET @DAY   = '2025-05-15';
SET @DAY2  = '2025-05-16';
SET @NOW   = '2025-05-15 12:00:00.000000';
SET @PAST  = '2025-05-15 09:00:00.000000';   -- «старое» время, чтобы ловиться дожимами

-- --------------------------------------------------------------------------------------------
-- Юрлица и кассы
-- --------------------------------------------------------------------------------------------
INSERT INTO legal_entity (id, code, name, inn, sno, is_active) VALUES
  (1, 'PROFI_MAIN', 'ООО «Профи.ру»',        '7700000001', 'ОСНО', 1),
  (2, 'PROFI_PART', 'ООО «Профи Партнёр»',   '7700000002', 'УСН',  1);

INSERT INTO kkt (id, legal_entity_id, serial_number, provider_code, is_active) VALUES
  (1, 1, '0000000000000001', 'atol-online', 1),
  (2, 2, '0000000000000002', 'atol-online', 1);

-- --------------------------------------------------------------------------------------------
-- Услуги, цены и ПРАВИЛА ФИСКАЛИЗАЦИИ (версионируемые)
-- --------------------------------------------------------------------------------------------
INSERT INTO service (code, name, is_active) VALUES
  ('contact_access', 'Доступ к контактам клиента', 1),
  ('promotion',      'Продвижение профиля',        1),
  ('package_10',     'Пакет из 10 откликов',       1),
  ('partner_service','Услуга партнёра (агентская)',1);

INSERT INTO service_price (service_code, amount_minor, currency, valid_from, valid_to) VALUES
  ('contact_access',   15000, 'RUB', '2025-01-01 00:00:00', NULL),
  ('promotion',        20000, 'RUB', '2025-01-01 00:00:00', NULL),
  ('package_10',      100000, 'RUB', '2025-01-01 00:00:00', NULL),
  ('partner_service',  50000, 'RUB', '2025-01-01 00:00:00', NULL);

-- subject_type: 4 = услуга (признак предмета расчёта)
-- method_type:  4 = полный расчёт, 3 = аванс, 7 = зачёт аванса
--               ⚠️ номера тегов сверить с актуальной версией ФФД у ОФД/провайдера
INSERT INTO service_fiscal_config
  (id, service_code, legal_entity_id, subject_name_tpl, subject_type, method_type, vat_rate, agent_flag, settlement_moment, valid_from)
VALUES
  (1, 'contact_access',  1, 'Доступ к контактам заказа {ref}', 4, 4, 20.00, 0, 'immediate',            '2025-01-01 00:00:00'),
  (2, 'promotion',       1, 'Продвижение профиля, {period}',   4, 4,  0.00, 0, 'immediate',            '2025-01-01 00:00:00'),
  (3, 'package_10',      1, 'Пакет откликов (10 шт.)',         4, 3, 20.00, 0, 'on_service_provided',  '2025-01-01 00:00:00'),
  (4, 'partner_service', 2, 'Услуга партнёра: {title}',        4, 4, 20.00, 1, 'immediate',            '2025-01-01 00:00:00');

-- --------------------------------------------------------------------------------------------
-- Счета: системные и пользовательские
-- --------------------------------------------------------------------------------------------
INSERT INTO account (id, owner_type, owner_id, currency, balance_minor, status) VALUES
  (1, 'system', 1, 'RUB',       0, 'active'),  -- транзит: эквайринг
  (2, 'system', 2, 'RUB',       0, 'active'),  -- выручка            [ЛОМАЕМ И2: сальдо не сходится]
  (3, 'system', 3, 'RUB',       0, 'active'),  -- НДС к уплате
  (4, 'system', 4, 'RUB',  100000, 'active'),  -- авансы полученные
  (5, 'system', 5, 'RUB',       0, 'active'),  -- транзит: выплаты
  (6, 'system', 6, 'RUB',       0, 'active'),  -- обязательства перед специалистом
  (10,'user',  42, 'RUB',       0, 'active'),  -- специалист 42
  (11,'user',  43, 'RUB',       0, 'active');  -- специалист 43

-- --------------------------------------------------------------------------------------------
-- Платежи
-- --------------------------------------------------------------------------------------------
INSERT INTO payment
  (id, public_id, user_id, legal_entity_id, service_code, amount_minor, currency, status,
   idempotency_key, provider_code, provider_payment_id,
   vat_rate, vat_base_minor, vat_amount_minor, fiscal_rule_id,
   refunded_minor, operation_day, created_at, paid_at)
VALUES
  -- 1: нормальная оплата услуги (полный расчёт)
  (1, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1', 42, 1, 'contact_access', 15000, 'RUB', 'partially_refunded',
   'idem-1', 'sbp', 'SBP-1001', 20.00, 12500, 2500, 1, 5000, @DAY, @PAST, '2025-05-15 09:05:00'),

  -- 2: пополнение пакета = АВАНС (чек на аванс; чек на зачёт появится при использовании)
  (2, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2', 42, 1, 'package_10', 100000, 'RUB', 'paid',
   'idem-2', 'card', 'CARD-2001', 20.00, 83333, 16667, 3, 0, @DAY, @PAST, '2025-05-15 09:10:00'),

  -- 3: [ЛОМАЕМ И7] зависший платёж: pending и провисел больше 10 минут — его надо дожать
  (3, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3', 43, 1, 'contact_access', 15000, 'RUB', 'pending',
   'idem-3', 'sbp', NULL, 20.00, 12500, 2500, 1, 0, @DAY, @PAST, NULL),

  -- 4: [ЛОМАЕМ И3/И5] оплачен, но в реестре ПС его нет (ours_only) и чек завис в retry_wait
  (4, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4', 44, 1, 'promotion', 20000, 'RUB', 'paid',
   'idem-4', 'card', 'CARD-2002', 0.00, 20000, 0, 2, 0, @DAY2, '2025-05-16 10:00:00', '2025-05-16 10:01:00'),

  -- 5: [ЛОМАЕМ И4] сумма в реестре ПС другая, и возврат больше платежа
  (5, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5', 45, 1, 'contact_access', 30000, 'RUB', 'refunded',
   'idem-5', 'sbp', 'SBP-1005', 20.00, 25000, 5000, 1, 30000, @DAY, @PAST, '2025-05-15 09:20:00');

-- Позиции платежа: нужны для частичных возвратов и предмета расчёта в чеке
INSERT INTO payment_item (payment_id, service_code, quantity, amount_minor, subject_name, subject_type, method_type, refunded_minor) VALUES
  (1, 'contact_access', 1, 15000, 'Доступ к контактам заказа #1001', 4, 4, 5000),
  (2, 'package_10',    10, 100000, 'Пакет откликов (10 шт.)',        4, 3, 0),
  (5, 'contact_access', 2, 30000, 'Доступ к контактам заказа #1005', 4, 4, 30000);

-- Пользователь 42: [ЛОМАЕМ] quantity_used = 3, но фактических использований 2
INSERT INTO subscription (id, user_id, service_code, status, quantity_total, quantity_used, amount_minor, currency, auto_renew, mandate_ref, valid_from, valid_to) VALUES
  (1, 42, 'package_10', 'active', 10, 3, 100000, 'RUB', 0, NULL, '2025-05-15 09:10:00', '2025-06-14 23:59:59');

INSERT INTO entitlement_usage (subscription_id, operation_id, order_ref, used_at) VALUES
  -- operation_id — CHAR(36): значения ровно 36 символов, как настоящий UUID.
  -- (более длинные в STRICT-режиме дают ERROR 1406 Data too long — это и был первый сбой сида)
  (1, '0a0a0a0a-0001-4000-8000-000000000001', 'order-2001', '2025-05-15 13:00:00'),
  (1, '0a0a0a0a-0002-4000-8000-000000000002', 'order-2002', '2025-05-15 14:00:00');

-- --------------------------------------------------------------------------------------------
-- Проводки (двойная запись). Сумма по operation_id обязана быть 0.
-- --------------------------------------------------------------------------------------------
INSERT INTO ledger_entry
  (created_day, created_at, operation_id, operation_type, account_id, amount_minor, currency, payment_id, refund_id, comment)
VALUES
  -- ✔ op-1: оплата услуги: +транзит, −выручка, −НДС  (сумма = 0)
  (@DAY, @PAST, 'op-00000001-0000-0000-000000000001', 'payment', 1, 15000,  'RUB', 1, NULL, 'оплата contact_access'),
  (@DAY, @PAST, 'op-00000001-0000-0000-000000000001', 'payment', 2, -12500, 'RUB', 1, NULL, 'выручка'),
  (@DAY, @PAST, 'op-00000001-0000-0000-000000000001', 'payment', 3,  -2500, 'RUB', 1, NULL, 'НДС'),

  -- ✔ op-2: аванс (пополнение пакета): +транзит, −авансы  (сумма = 0)
  (@DAY, @PAST, 'op-00000002-0000-0000-000000000002', 'payment', 1, 100000,  'RUB', 2, NULL, 'аванс за пакет'),
  (@DAY, @PAST, 'op-00000002-0000-0000-000000000002', 'payment', 4, -100000, 'RUB', 2, NULL, 'авансы полученные'),

  -- ✔ op-3: возврат по платежу 1 (частичный): +выручка/авансы, −транзит (сумма = 0)
  (@DAY, '2025-05-15 15:00:00', 'op-00000003-0000-0000-000000000003', 'refund', 4,  5000, 'RUB', 1, 1, 'возврат аванса'),
  (@DAY, '2025-05-15 15:00:00', 'op-00000003-0000-0000-000000000003', 'refund', 1, -5000, 'RUB', 1, 1, 'возврат через ПС'),

  -- ❌ [ЛОМАЕМ И1] op-4: НЕ СХОДИТСЯ — сумма проводок = -100, а должна быть 0
  (@DAY2, '2025-05-16 10:01:00', 'op-00000004-0000-0000-000000000004', 'payment', 1, 20000,  'RUB', 4, NULL, 'оплата promotion'),
  (@DAY2, '2025-05-16 10:01:00', 'op-00000004-0000-0000-000000000004', 'payment', 2, -16666, 'RUB', 4, NULL, 'выручка'),
  (@DAY2, '2025-05-16 10:01:00', 'op-00000004-0000-0000-000000000004', 'payment', 3,  -3434, 'RUB', 4, NULL, 'НДС (ошибочно вместо 0%)'),

  -- ✔ op-5: возврат по платежу 5 (по факту больше платежа) (сумма = 0)
  (@DAY, '2025-05-15 16:00:00', 'op-00000005-0000-0000-000000000005', 'refund', 2,  29167, 'RUB', 5, 2, 'выручка (возврат)'),
  (@DAY, '2025-05-15 16:00:00', 'op-00000005-0000-0000-000000000005', 'refund', 3,   5833, 'RUB', 5, 2, 'НДС (возврат)'),
  (@DAY, '2025-05-15 16:00:00', 'op-00000005-0000-0000-000000000005', 'refund', 1, -35000, 'RUB', 5, 2, 'возврат через ПС');

-- ⚠️ [ЛОМАЕМ И2] Денормализованные балансы специально не совпадают с суммой проводок:
--    счёт 1 (транзит) должен быть 15000+100000-5000-35000 = 75000, а стоит 71000
UPDATE account SET balance_minor = 71000 WHERE id = 1;
--    счёт 2 (выручка) должен быть -12500-16666+29167 = 0 ... но фактически 0, оставим 0
--    счёт 3 (НДС) должен быть -2500-3434+5833 = -101
UPDATE account SET balance_minor = 0 WHERE id = 3;
--    счёт 4 (авансы) должен быть -100000+5000 = -95000
UPDATE account SET balance_minor = -95000 WHERE id = 4;

-- --------------------------------------------------------------------------------------------
-- Чеки
--    [ЛОМАЕМ И3] у платежа 4 нет выпущенного чека (retry_wait) — фискализация отстаёт
-- --------------------------------------------------------------------------------------------
INSERT INTO receipt
  (payment_id, refund_id, receipt_type, status, legal_entity_id, operation_id, total_minor, currency,
   vat_rate, vat_amount_minor, subject_name, method_type, fiscal_doc_number, fiscal_sign, fiscal_doc_attribute,
   attempts, last_error, created_at, registered_at)
VALUES
  (1, NULL, 'income',        'printed',    1, 'rc-00000001-0000-0000-000000000001',  15000, 'RUB',
   20.00, 2500, 'Доступ к контактам заказа #1001', 4, '100001', 'FPD-100001', 'FPA-100001', 1, NULL, @PAST, '2025-05-15 09:05:30'),

  (2, NULL, 'income',        'printed',    1, 'rc-00000002-0000-0000-000000000002', 100000, 'RUB',
   20.00, 16667, 'Пакет откликов (10 шт.)',       3, '100002', 'FPD-100002', 'FPA-100002', 1, NULL, @PAST, '2025-05-15 09:10:30'),

  (4, NULL, 'income',        'retry_wait', 1, 'rc-00000004-0000-0000-000000000004',  20000, 'RUB',
    0.00, 0,     'Продвижение профиля, 1 месяц',  4, NULL, NULL, NULL, 3, 'provider timeout', '2025-05-16 10:01:10', NULL),

  (5, NULL, 'income',        'printed',    1, 'rc-00000005-0000-0000-000000000005',  30000, 'RUB',
   20.00, 5000, 'Доступ к контактам заказа #1005', 4, '100005', 'FPD-100005', 'FPA-100005', 1, NULL, @PAST, '2025-05-15 09:20:30'),

  (NULL, 1, 'income_refund', 'printed',    1, 'rc-00000006-0000-0000-000000000006',   5000, 'RUB',
   20.00, 833,  'Возврат: доступ к контактам',     3, '100006', 'FPD-100006', 'FPA-100006', 1, NULL, '2025-05-15 15:01:00', '2025-05-15 15:01:10');

-- --------------------------------------------------------------------------------------------
-- Возвраты
--    [ЛОМАЕМ И4] возврат по платежу 5 больше самого платежа (35000 > 30000)
-- --------------------------------------------------------------------------------------------
INSERT INTO refund
  (id, payment_id, receipt_id, operation_id, amount_minor, currency, status, reason, provider_refund_id,
   requested_by, created_at, completed_at)
VALUES
  (1, 1, 5, 'rf-00000001-0000-0000-000000000001',  5000, 'RUB', 'completed', 'Просьба клиента',   'RFD-5001', 'support@profi', '2025-05-15 14:59:00', '2025-05-15 15:00:30'),
  (2, 5, 6, 'rf-00000005-0000-0000-000000000002', 35000, 'RUB', 'completed', 'Некорректная операция','RFD-5002','support@profi', '2025-05-15 15:59:00', '2025-05-15 16:00:30');

-- --------------------------------------------------------------------------------------------
-- Реестр ПС (для сверки)
--    [ЛОМАЕМ И5] CARD-2002 нет в реестре (ours_only)
--    [ЛОМАЕМ И6] SBP-1006 есть в реестре, но у нас такого платежа нет (theirs_only)
--    [ЛОМАЕМ]    SBP-1005 в реестре на 28000, у нас 30000 (amount_diff)
-- --------------------------------------------------------------------------------------------
INSERT INTO psp_registry_row
  (provider_code, created_day, provider_payment_id, order_id, amount_minor, currency, status, raw, matched_payment_id, match_status)
VALUES
  ('sbp',  @DAY,  'SBP-1001', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1', 15000, 'RUB', 'paid', '{"row":1}', 1, 'matched'),
  ('card', @DAY,  'CARD-2001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2',100000, 'RUB', 'paid', '{"row":2}', 2, 'matched'),
  ('sbp',  @DAY,  'SBP-1005', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5', 28000, 'RUB', 'paid', '{"row":3}', 5, 'amount_diff'),
  ('sbp',  @DAY,  'SBP-1006', NULL,                               25000, 'RUB', 'paid', '{"row":4}', NULL, 'theirs_only'),
  ('card', @DAY2, 'CARD-2009', NULL,                              99000, 'RUB', 'paid', '{"row":5}', NULL, 'theirs_only');

-- --------------------------------------------------------------------------------------------
-- Outbox: неопубликованные события (для демонстрации FOR UPDATE SKIP LOCKED)
-- --------------------------------------------------------------------------------------------
INSERT INTO outbox (event_type, aggregate_id, payload, created_at, published_at, attempts) VALUES
  ('receipt.requested', 4, '{"payment_id":4,"service":"promotion"}', @NOW, NULL, 3),
  ('receipt.requested', 5, '{"payment_id":5,"service":"contact_access"}', @NOW, NULL, 0),
  ('payment.settled',   1, '{"payment_id":1}', @NOW, '2025-05-15 12:00:05.000000', 1),
  ('payment.settled',   2, '{"payment_id":2}', @NOW, '2025-05-15 12:00:06.000000', 1),
  ('payout.requested',  6, '{"payment_id":6,"amount_minor":25000}', @NOW, NULL, 11);

-- --------------------------------------------------------------------------------------------
-- Обработанные события
-- --------------------------------------------------------------------------------------------
INSERT INTO processed_event (source, event_id, payload_hash, seen_count, processed_at) VALUES
  ('psp', 'evt-1001', SHA2('{"event":"evt-1001"}', 256), 1, '2025-05-15 09:05:01'),
  ('psp', 'evt-1002', SHA2('{"event":"evt-1002"}', 256), 3, '2025-05-15 09:10:01');  -- приходил 3 раза

-- --------------------------------------------------------------------------------------------
-- Результаты сверки и агрегаты
--    [ЛОМАЕМ] агрегат за день не совпадает с фактической суммой (проверка И8)
-- --------------------------------------------------------------------------------------------
INSERT INTO reconciliation_run (provider_code, created_day, started_at, finished_at, status, mismatch_count, mismatch_minor) VALUES
  ('sbp',  @DAY, '2025-05-16 02:00:00', '2025-05-16 02:00:12', 'mismatch', 2, 45000),
  ('card', @DAY, '2025-05-16 02:05:00', '2025-05-16 02:05:10', 'ok',       0, 0);

INSERT INTO billing_daily_agg (legal_entity_id, day, service_code, status, operations_cnt, amount_minor, vat_amount_minor, updated_at) VALUES
  (1, @DAY,  'contact_access', 'paid', 99, 9999999, 1000000, @NOW),   -- ← не сходится с фактом
  (1, @DAY,  'package_10',     'paid',  1,  100000,   16667, @NOW);

-- --------------------------------------------------------------------------------------------
-- Аудит: пример ручной корректировки (должна быть всегда)
-- --------------------------------------------------------------------------------------------
INSERT INTO audit_log (entity_type, entity_id, action, actor, reason, before_json, after_json, created_at) VALUES
  ('account', 1, 'manual_balance_adjustment', 'support@profi', 'компенсация после разбора расхождения',
   '{"balance_minor": 75000}', '{"balance_minor": 71000}', '2025-05-16 03:00:00');

-- --------------------------------------------------------------------------------------------
-- Итог: сколько чего в базе
-- --------------------------------------------------------------------------------------------
SELECT 'legal_entity' AS tbl, COUNT(*) AS cnt FROM legal_entity
UNION ALL SELECT 'service',            COUNT(*) FROM service
UNION ALL SELECT 'account',            COUNT(*) FROM account
UNION ALL SELECT 'ledger_entry',       COUNT(*) FROM ledger_entry
UNION ALL SELECT 'payment',            COUNT(*) FROM payment
UNION ALL SELECT 'receipt',            COUNT(*) FROM receipt
UNION ALL SELECT 'refund',             COUNT(*) FROM refund
UNION ALL SELECT 'psp_registry_row',   COUNT(*) FROM psp_registry_row
UNION ALL SELECT 'outbox',             COUNT(*) FROM outbox;
