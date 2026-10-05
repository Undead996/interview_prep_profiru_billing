-- ============================================================================================
-- Схема биллинга (учебная) — MySQL 8.0 / InnoDB
-- Соответствует разбору в 08-system-design/02-db-design-walkthrough.md
--
-- Принципы, зашитые в схему:
--   1. Деньги — только в минорных единицах (BIGINT), точность гарантирована.
--   2. Учёт append-only: ledger_entry не обновляется и не удаляется (компенсирующие проводки).
--   3. Идемпотентность выражается УНИКАЛЬНЫМИ ключами, а не проверками в коде.
--   4. Правила фискализации — версионируемые данные (valid_from/valid_to) + снимок в операции.
--   5. История партиционируется по дню и архивируется через DROP PARTITION.
--   6. "Защита от дублей" живёт в маленьких НЕпартиционированных таблицах
--      (partitioned InnoDB не поддерживает глобальные уникальные ключи и FOREIGN KEY).
--
-- Применить:  mysql -uroot -pbilling billing < sql/01-schema.sql
-- ============================================================================================

DROP DATABASE IF EXISTS billing;
CREATE DATABASE billing CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE billing;

SET NAMES utf8mb4;

-- ============================================================================================
-- 1. ОРГАНИЗАЦИОННОЕ: юрлица и кассы
-- ============================================================================================
CREATE TABLE legal_entity (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code        VARCHAR(32)  NOT NULL,
  name        VARCHAR(255) NOT NULL,
  inn         VARCHAR(12)  NOT NULL,
  sno         VARCHAR(16)  NOT NULL COMMENT 'система налогообложения (справочно)',
  is_active   TINYINT(1)   NOT NULL DEFAULT 1,
  created_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uq_legal_entity_code (code)
) ENGINE=InnoDB;

CREATE TABLE kkt (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  legal_entity_id BIGINT UNSIGNED NOT NULL,
  serial_number   VARCHAR(64)     NOT NULL,
  provider_code   VARCHAR(32)     NOT NULL COMMENT 'агрегатор/ОФД',
  is_active       TINYINT(1)      NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY uq_kkt (legal_entity_id, serial_number),
  KEY idx_kkt_active (legal_entity_id, is_active),
  CONSTRAINT fk_kkt_entity FOREIGN KEY (legal_entity_id) REFERENCES legal_entity(id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 2. СПРАВОЧНИКИ: услуги, цены и ПРАВИЛА ФИСКАЛИЗАЦИИ (версионируемые!)
-- ============================================================================================
CREATE TABLE service (
  code        VARCHAR(32)  NOT NULL COMMENT 'contact_access | promotion | package_10 | partner_service',
  name        VARCHAR(255) NOT NULL,
  is_active   TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (code)
) ENGINE=InnoDB;

CREATE TABLE service_price (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  service_code VARCHAR(32)     NOT NULL,
  amount_minor BIGINT          NOT NULL,
  currency     CHAR(3)         NOT NULL,
  valid_from   DATETIME(6)     NOT NULL,
  valid_to     DATETIME(6)     NULL COMMENT 'NULL = действует сейчас',
  PRIMARY KEY (id),
  KEY idx_price_lookup (service_code, valid_from, valid_to),
  CONSTRAINT fk_price_service FOREIGN KEY (service_code) REFERENCES service(code)
) ENGINE=InnoDB;

-- ★ Ядро рефакторинга: правила чеков как ДАННЫЕ, а не как if в коде.
--   Новый вид услуги = новая запись + тест, а не релиз денежного ядра.
CREATE TABLE service_fiscal_config (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  service_code      VARCHAR(32)     NOT NULL,
  legal_entity_id   BIGINT UNSIGNED NOT NULL,
  subject_name_tpl  VARCHAR(255)    NOT NULL COMMENT 'шаблон наименования предмета расчёта',
  subject_type      TINYINT UNSIGNED NOT NULL COMMENT 'признак предмета расчёта: 3 работа / 4 услуга / 1 товар',
  method_type       TINYINT UNSIGNED NOT NULL COMMENT 'признак способа расчёта: 3 аванс / 4 полный / 7 зачёт (сверить с ФФД!)',
  vat_rate          DECIMAL(5,2)    NOT NULL,
  agent_flag        TINYINT UNSIGNED NOT NULL DEFAULT 0,
  settlement_moment ENUM('immediate','on_service_provided') NOT NULL DEFAULT 'immediate',
  valid_from        DATETIME(6)     NOT NULL,
  valid_to          DATETIME(6)     NULL,
  PRIMARY KEY (id),
  KEY idx_fiscal_config_lookup (service_code, legal_entity_id, valid_from, valid_to),
  CONSTRAINT fk_fiscal_service FOREIGN KEY (service_code) REFERENCES service(code),
  CONSTRAINT fk_fiscal_entity  FOREIGN KEY (legal_entity_id) REFERENCES legal_entity(id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 3. ДЕНЬГИ: счета и проводки (двойная запись)
-- ============================================================================================
CREATE TABLE account (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  owner_type    ENUM('user','legal_entity','system') NOT NULL,
  owner_id      BIGINT UNSIGNED NOT NULL COMMENT 'для system — код системного счёта',
  currency      CHAR(3)         NOT NULL,
  balance_minor BIGINT          NOT NULL DEFAULT 0 COMMENT 'ДЕНОРМАЛИЗОВАННЫЙ кэш; истина — проводки',
  status        ENUM('active','frozen','closed') NOT NULL DEFAULT 'active',
  created_at    DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at    DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uq_account_owner (owner_type, owner_id, currency),
  KEY idx_account_negative (balance_minor)
) ENGINE=InnoDB;

-- ★ Основная денежная таблица. Append-only!
--   amount_minor со знаком: + дебет, − кредит. Сумма проводок по operation_id обязана быть 0.
--
--   Обратите внимание: у партиционированной таблицы НЕТ внешних ключей —
--   InnoDB не поддерживает FOREIGN KEY на партиционированных таблицах.
--   Целостность обеспечивается приложением + ночными проверками-инвариантами.
CREATE TABLE ledger_entry (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  created_day    DATE            NOT NULL COMMENT 'партиционирующая колонка — обязана входить в PK и UNIQUE',
  created_at     DATETIME(6)     NOT NULL,
  operation_id   CHAR(36)        NOT NULL COMMENT 'ключ идемпотентности учётной операции',
  operation_type ENUM('payment','refund','chargeback','offset','payout','adjustment') NOT NULL,
  account_id     BIGINT UNSIGNED NOT NULL,
  amount_minor   BIGINT          NOT NULL,
  currency       CHAR(3)         NOT NULL,
  payment_id     BIGINT UNSIGNED NULL,
  refund_id      BIGINT UNSIGNED NULL,
  comment        VARCHAR(255)    NULL,
  PRIMARY KEY (id, created_day),
  UNIQUE KEY uq_operation_account (operation_id, account_id, created_day)
    COMMENT 'защита от двойных проводок по одной операции и одному счёту',
  KEY idx_account_day (account_id, created_day),
  KEY idx_payment (payment_id, created_day),
  CONSTRAINT chk_le_nonzero CHECK (amount_minor <> 0)
) ENGINE=InnoDB
PARTITION BY RANGE COLUMNS(created_day) (
  PARTITION p2025_05 VALUES LESS THAN ('2025-06-01'),
  PARTITION p2025_06 VALUES LESS THAN ('2025-07-01'),
  PARTITION p2025_07 VALUES LESS THAN ('2025-08-01'),
  PARTITION p_max    VALUES LESS THAN (MAXVALUE)
);

-- ============================================================================================
-- 4. ПЛАТЕЖИ
-- ============================================================================================
CREATE TABLE payment (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  public_id           CHAR(32)        NOT NULL COMMENT 'HEX от ULID/UUIDv7 — то, что отдаём наружу',
  user_id             BIGINT UNSIGNED NOT NULL,
  legal_entity_id     BIGINT UNSIGNED NOT NULL,
  service_code        VARCHAR(32)     NOT NULL,
  amount_minor        BIGINT          NOT NULL,
  currency            CHAR(3)         NOT NULL,
  status              ENUM('created','pending','unknown','paid','partially_refunded','refunded','failed','expired')
                                      NOT NULL,
  idempotency_key     VARCHAR(128)    NOT NULL,
  provider_code       VARCHAR(16)     NOT NULL,
  provider_payment_id VARCHAR(128)    NULL,
  -- снимок применённых правил: гарантия воспроизводимости отчётности
  vat_rate            DECIMAL(5,2)    NOT NULL,
  vat_base_minor      BIGINT          NOT NULL,
  vat_amount_minor    BIGINT          NOT NULL,
  fiscal_rule_id      BIGINT UNSIGNED NOT NULL COMMENT 'версия правила, применённая к операции',
  refunded_minor      BIGINT          NOT NULL DEFAULT 0 COMMENT 'денормализовано, со сверкой',
  operation_day       DATE            NOT NULL COMMENT 'бизнес-день (не UTC!) — для отчётности',
  created_at          DATETIME(6)     NOT NULL,
  paid_at             DATETIME(6)     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_public_id (public_id),
  UNIQUE KEY uq_idempotency (idempotency_key),
  UNIQUE KEY uq_provider_payment (provider_code, provider_payment_id),
  KEY idx_user_status_created (user_id, status, created_at),
  KEY idx_entity_day_status (legal_entity_id, operation_day, status),
  KEY idx_status_created (status, created_at) COMMENT 'дожим pending/unknown + узкие локи воркера',
  CONSTRAINT chk_payment_amount_positive CHECK (amount_minor > 0),
  CONSTRAINT chk_refunded_not_exceed   CHECK (refunded_minor <= amount_minor)
) ENGINE=InnoDB;

-- Позиции платежа: нужны для частичных возвратов и корректного предмета расчёта в чеке
CREATE TABLE payment_item (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  payment_id         BIGINT UNSIGNED NOT NULL,
  service_code       VARCHAR(32)     NOT NULL,
  quantity           INT UNSIGNED    NOT NULL DEFAULT 1,
  amount_minor       BIGINT          NOT NULL,
  subject_name       VARCHAR(255)    NOT NULL,
  subject_type       TINYINT UNSIGNED NOT NULL,
  method_type        TINYINT UNSIGNED NOT NULL,
  refunded_minor     BIGINT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_payment (payment_id),
  CONSTRAINT fk_item_payment FOREIGN KEY (payment_id) REFERENCES payment(id)
) ENGINE=InnoDB;

-- Все входящие события (вебхуки, опросы): идемпотентность + разбор
CREATE TABLE payment_event (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  source      VARCHAR(16)     NOT NULL COMMENT 'psp | ofd | product',
  event_id    VARCHAR(128)    NOT NULL,
  payment_id  BIGINT UNSIGNED NULL,
  raw_status  VARCHAR(64)     NOT NULL,
  raw_payload JSON            NOT NULL,
  seen_count  INT UNSIGNED    NOT NULL DEFAULT 1,
  received_at DATETIME(6)     NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_source_event (source, event_id),
  KEY idx_payment (payment_id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 5. ЧЕКИ (фискализация)
--    ВАЖНО: уникальность — по operation_id (нашему ключу), а НЕ по payment_id:
--    при авансе и зачёте на один платёж законно приходится ДВА чека.
-- ============================================================================================
CREATE TABLE receipt (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  payment_id           BIGINT UNSIGNED NULL,
  refund_id            BIGINT UNSIGNED NULL,
  receipt_type         ENUM('income','income_refund','expense','expense_refund','correction') NOT NULL,
  status               ENUM('requested','registering','retry_wait','printed','rejected','corrected','manual') NOT NULL,
  legal_entity_id      BIGINT UNSIGNED NOT NULL,
  operation_id         CHAR(36)        NOT NULL COMMENT 'идемпотентность фискализации (в т.ч. у провайдера)',
  total_minor          BIGINT          NOT NULL,
  currency             CHAR(3)         NOT NULL,
  vat_rate             DECIMAL(5,2)    NOT NULL,
  vat_amount_minor     BIGINT          NOT NULL,
  subject_name         VARCHAR(255)    NOT NULL COMMENT 'снимок наименования',
  method_type          TINYINT UNSIGNED NOT NULL COMMENT 'признак способа расчёта (аванс/зачёт/полный)',
  fiscal_doc_number    VARCHAR(32)     NULL COMMENT '№ ФД',
  fiscal_sign          VARCHAR(64)     NULL COMMENT 'ФПД',
  fiscal_doc_attribute VARCHAR(64)     NULL COMMENT 'ФПС',
  attempts             INT UNSIGNED    NOT NULL DEFAULT 0,
  last_error           VARCHAR(512)    NULL,
  created_at           DATETIME(6)     NOT NULL,
  registered_at        DATETIME(6)     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_receipt_operation (operation_id),
  KEY idx_payment (payment_id),
  KEY idx_status_created (status, created_at) COMMENT 'метрика "чек отстаёт" + выборка воркера',
  CONSTRAINT fk_receipt_payment FOREIGN KEY (payment_id) REFERENCES payment(id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 6. ВОЗВРАТЫ
-- ============================================================================================
CREATE TABLE refund (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  payment_id         BIGINT UNSIGNED NOT NULL,
  receipt_id         BIGINT UNSIGNED NULL COMMENT 'чек возврата',
  operation_id       CHAR(36)        NOT NULL,
  amount_minor       BIGINT          NOT NULL COMMENT 'всегда положительное',
  currency           CHAR(3)         NOT NULL,
  status             ENUM('requested','processing','unknown','completed','failed','rejected') NOT NULL,
  reason             VARCHAR(255)    NOT NULL,
  provider_refund_id VARCHAR(128)    NULL,
  requested_by       VARCHAR(64)     NOT NULL COMMENT 'кто инициировал (аудит/фрод)',
  created_at         DATETIME(6)     NOT NULL,
  completed_at       DATETIME(6)     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_refund_operation (operation_id),
  UNIQUE KEY uq_refund_provider (provider_refund_id),
  KEY idx_payment_status (payment_id, status),
  CONSTRAINT chk_refund_positive CHECK (amount_minor > 0),
  CONSTRAINT fk_refund_payment FOREIGN KEY (payment_id) REFERENCES payment(id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 7. ПОДПИСКИ / ПАКЕТЫ (права и лимиты — не деньги, но связаны)
-- ============================================================================================
CREATE TABLE subscription (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id        BIGINT UNSIGNED NOT NULL,
  service_code   VARCHAR(32)     NOT NULL,
  status         ENUM('active','paused','expired','cancelled') NOT NULL,
  quantity_total INT UNSIGNED    NOT NULL DEFAULT 0,
  quantity_used  INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'денормализовано, со сверкой по usage',
  amount_minor   BIGINT          NOT NULL,
  currency       CHAR(3)         NOT NULL,
  auto_renew     TINYINT(1)      NOT NULL DEFAULT 0,
  mandate_ref    VARCHAR(128)    NULL COMMENT 'ссылка на согласие/токен',
  valid_from     DATETIME(6)     NOT NULL,
  valid_to       DATETIME(6)     NULL,
  PRIMARY KEY (id),
  KEY idx_user_status (user_id, status),
  KEY idx_renew (status, auto_renew, valid_to),
  CONSTRAINT fk_sub_service FOREIGN KEY (service_code) REFERENCES service(code)
) ENGINE=InnoDB;

CREATE TABLE entitlement_usage (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  subscription_id BIGINT UNSIGNED NOT NULL,
  operation_id    CHAR(36)        NOT NULL,
  order_ref       VARCHAR(64)     NULL,
  used_at         DATETIME(6)     NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_usage_operation (operation_id),
  KEY idx_subscription_used (subscription_id, used_at),
  CONSTRAINT fk_usage_sub FOREIGN KEY (subscription_id) REFERENCES subscription(id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 8. ИНФРАСТРУКТУРА НАДЁЖНОСТИ: outbox и обработанные события
-- ============================================================================================
CREATE TABLE outbox (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  event_type   VARCHAR(64)     NOT NULL COMMENT 'receipt.requested | payment.settled | ...',
  aggregate_id BIGINT UNSIGNED NOT NULL,
  payload      JSON            NOT NULL,
  created_at   DATETIME(6)     NOT NULL,
  published_at DATETIME(6)     NULL,
  attempts     SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_unpublished (published_at, id) COMMENT 'publisher читает по этому индексу; он же даёт узкие локи'
) ENGINE=InnoDB;

CREATE TABLE processed_event (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  source       VARCHAR(32)     NOT NULL,
  event_id     VARCHAR(128)    NOT NULL,
  payload_hash CHAR(64)        NOT NULL,
  seen_count   INT UNSIGNED    NOT NULL DEFAULT 1,
  processed_at DATETIME(6)     NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_source_event (source, event_id)
) ENGINE=InnoDB;

-- ============================================================================================
-- 9. СВЕРКА
-- ============================================================================================
CREATE TABLE psp_registry_row (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_code       VARCHAR(16)     NOT NULL,
  created_day         DATE            NOT NULL,
  provider_payment_id VARCHAR(128)    NULL,
  order_id            VARCHAR(128)    NULL COMMENT 'наш public_id/id, если ПС его отдаёт',
  amount_minor        BIGINT          NOT NULL,
  currency            CHAR(3)         NOT NULL,
  status              VARCHAR(32)     NOT NULL COMMENT 'как есть у ПС',
  raw                 JSON            NOT NULL COMMENT 'сырая строка реестра — для разбора',
  matched_payment_id  BIGINT UNSIGNED NULL,
  match_status        ENUM('matched','ours_only','theirs_only','amount_diff','status_diff') NULL,
  PRIMARY KEY (id),
  KEY idx_provider_day (provider_code, created_day),
  KEY idx_provider_payment (provider_code, provider_payment_id),
  KEY idx_match (provider_code, created_day, match_status)
) ENGINE=InnoDB;

CREATE TABLE reconciliation_run (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_code  VARCHAR(16)     NOT NULL,
  created_day    DATE            NOT NULL,
  started_at     DATETIME(6)     NOT NULL,
  finished_at    DATETIME(6)     NULL,
  status         ENUM('running','ok','mismatch','failed') NOT NULL,
  mismatch_count INT UNSIGNED    NOT NULL DEFAULT 0,
  mismatch_minor BIGINT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  UNIQUE KEY uq_run (provider_code, created_day)
) ENGINE=InnoDB;

-- ============================================================================================
-- 10. ОТЧЁТНОСТЬ И АУДИТ
-- ============================================================================================
CREATE TABLE billing_daily_agg (
  legal_entity_id  BIGINT UNSIGNED NOT NULL,
  day              DATE            NOT NULL,
  service_code     VARCHAR(32)     NOT NULL,
  status           VARCHAR(16)     NOT NULL,
  operations_cnt   BIGINT UNSIGNED NOT NULL,
  amount_minor     BIGINT          NOT NULL,
  vat_amount_minor BIGINT          NOT NULL,
  updated_at       DATETIME(6)     NOT NULL,
  PRIMARY KEY (legal_entity_id, day, service_code, status),
  KEY idx_day (day)
) ENGINE=InnoDB;

CREATE TABLE audit_log (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type VARCHAR(32)     NOT NULL,
  entity_id   BIGINT UNSIGNED NOT NULL,
  action      VARCHAR(64)     NOT NULL,
  actor       VARCHAR(64)     NOT NULL,
  reason      VARCHAR(255)    NULL,
  before_json JSON            NULL,
  after_json  JSON            NULL,
  created_at  DATETIME(6)     NOT NULL,
  PRIMARY KEY (id),
  KEY idx_entity (entity_type, entity_id, created_at)
) ENGINE=InnoDB;
