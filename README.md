# Подготовка к собеседованию — Профи.ру, команда биллинга

**Вакансия:** разработчик в команду биллинга (тимлид — Миша Хромов, основной разработчик — Катя)
**Стек вакансии:** PHP 8 · MySQL · RabbitMQ · Memcached · Redis → новые микросервисы на TypeScript
**Домен:** приём платежей, чеки, данные для налоговой отчётности, возвраты, повторная обработка
**Твой бэкграунд (из резюме):** 5 лет платёжного процессинга («Точка Оплаты»): ядро процессинга, PSP-эквайеры, 3DS, антифрод, BPM; MySQL, RabbitMQ, Kafka, Laravel/PHP + Python.

> **Главная мысль этой папки.** Вакансия — не про «знаю ли я синтаксис PHP 8». Она про
> **деньги и консистентность**: как из приёма денег получается корректный чек, корректная
> отчётность и отсутствие расхождений с банком и ОФД, и как всё это не ломается при сбоях,
> ретраях и повторной доставке. Каждый ответ на собеседовании стоит доводить до денег:
> «сколько операций, на сколько рублей, что увидит бухгалтерия».

---

## Что будет на собеседовании (цитата из вакансии) → где это разобрано

| Что обещают | Где готовиться |
|---|---|
| «Вместе спроектируем схему базы данных, обсудим таблицы, связи, ограничения и индексы» | [`08-system-design/02-db-design-walkthrough.md`](08-system-design/02-db-design-walkthrough.md), [`10-mock-interview/02-db-design-dialog.md`](10-mock-interview/02-db-design-dialog.md), [`09-practical-tasks/01-payment-acceptance.md`](09-practical-tasks/01-payment-acceptance.md) |
| «Приём и обработка платежей» | [`05-billing-domain/02-payments-and-acquiring.md`](05-billing-domain/02-payments-and-acquiring.md), [`09-practical-tasks/01-payment-acceptance.md`](09-practical-tasks/01-payment-acceptance.md) |
| «Формирование чеков» | [`05-billing-domain/03-receipts-54fz.md`](05-billing-domain/03-receipts-54fz.md), [`09-practical-tasks/02-receipt-formation.md`](09-practical-tasks/02-receipt-formation.md) |
| «Транзакции» | [`01-php/02-pdo-transactions.md`](01-php/02-pdo-transactions.md), [`02-mysql/02-transactions-isolation-locks.md`](02-mysql/02-transactions-isolation-locks.md) |
| «Возвраты» | [`05-billing-domain/05-refunds-disputes.md`](05-billing-domain/05-refunds-disputes.md), [`09-practical-tasks/03-refunds.md`](09-practical-tasks/03-refunds.md) |
| «Повторная обработка операций» | [`06-reliability/01-idempotency-state-machines.md`](06-reliability/01-idempotency-state-machines.md), [`09-practical-tasks/04-idempotent-reprocessing.md`](09-practical-tasks/04-idempotent-reprocessing.md) |
| «Поведение системы при сбоях» | [`06-reliability/03-failures-runbook.md`](06-reliability/03-failures-runbook.md), [`09-practical-tasks/05-failures-and-self-check.md`](09-practical-tasks/05-failures-and-self-check.md) |
| «Плюсы, минусы и технические компромиссы» | [`08-system-design/03-legacy-refactoring.md`](08-system-design/03-legacy-refactoring.md), `10-mock-interview/03-behavioral-and-tricky.md` |
| «Ответим на ваши вопросы» | [`00-vacancy/05-questions-to-employer.md`](00-vacancy/05-questions-to-employer.md) |

**Отдельно, из текста вакансии:** «крупный рефакторинг из-за новых требований налоговой»,
«подключение новых платёжных систем», «новые виды услуг, для которых иначе формируются чеки»,
«деньги будут принимать не только со специалистов, но и с клиентов». Это четыре темы, вокруг
которых будет крутиться весь разговор → [`05-billing-domain/04-tax-reporting.md`](05-billing-domain/04-tax-reporting.md),
[`05-billing-domain/06-subscriptions-new-products.md`](05-billing-domain/06-subscriptions-new-products.md),
[`08-system-design/03-legacy-refactoring.md`](08-system-design/03-legacy-refactoring.md).

---

## Структура папки

```
interview_prep_profiru_billing/
├── README.md                                  ← ты здесь: навигация + план подготовки
│
├── 00-vacancy/                                Разбор вакансии и стратегия разговора
│   ├── 01-vacancy-breakdown.md                Построчно: что проверяют, как отвечать, что сказать обязательно
│   ├── 02-profiru-billing-domain.md           Что за продукт, из чего состоит биллинг, откуда деньги
│   ├── 03-self-assessment-and-stories.md      Требование → твоя позиция → чем закрывать; 6 историй STAR
│   ├── 04-prep-plan.md                        План на 14 / 7 / 3 дня и на день перед собесом
│   └── 05-questions-to-employer.md            Что спросить у Миши и Кати (и как этим показать уровень)
│
├── 01-php/                                    PHP 8 — но только то, что нужно биллингу
│   ├── 01-money-precision-php.md              Деньги и точность: float, копейки, DECIMAL, BCMath, округление
│   ├── 02-pdo-transactions.md                 PDO, транзакции, SAVEPOINT, deadlock-retry, SELECT FOR UPDATE
│   ├── 03-php8-for-billing.md                 enum/readonly/match/named args, генераторы, всё про VO денег
│   └── 04-oop-solid-billing.md                Слои биллинга, Strategy для ПС и чеков, State, DI, тесты
│
├── 02-mysql/                                  MySQL — требование №1 («особенно транзакции и индексы»)
│   ├── 01-innodb-indexes.md                   InnoDB, B+tree, кластерный индекс, композитные, EXPLAIN
│   ├── 02-transactions-isolation-locks.md     ACID, MVCC, уровни изоляции, gap-локи, дедлоки, ретраи
│   ├── 03-migrations-and-partitioning.md      Безопасные миграции, online DDL, expand/contract, партиции
│   └── 04-explain-and-sql-tasks.md            Живые EXPLAIN-разборы + 10 SQL-задач биллинга с ответами
│
├── 03-messaging/
│   ├── 01-rabbitmq-deep.md                    AMQP-модель, confirms, ack/nack, DLQ, ретраи, порядок, quorum
│   └── 02-rabbitmq-in-billing.md              Где очереди в биллинге: чеки, отчётность, вебхуки, outbox
│
├── 04-cache/
│   └── 01-redis-memcached.md                  Сравнение, кэш стратегии, инвалидация, локи, идемпотентность
│
├── 05-billing-domain/                         Домен — твой козырь, здесь говорят «на языке денег»
│   ├── 01-domain-map.md                       Карта домена: плательщики, услуги, счета, проводки, границы
│   ├── 02-payments-and-acquiring.md           Эквайринг, СБП, авторизация/холд/списание, вебхуки, статусы
│   ├── 03-receipts-54fz.md                    54-ФЗ: ККТ, ФН, ОФД, ФФД-теги, виды чеков, аванс и зачёт
│   ├── 04-tax-reporting.md                    Отчётность: реестры, НДС, СНО, сверки, «новые требования»
│   ├── 05-refunds-disputes.md                 Возвраты (полные/частичные), chargeback, связка с чеками
│   ├── 06-subscriptions-new-products.md       Рекуррент, холды, эскроу, оплата со стороны клиентов
│   └── 07-reconciliation.md                   Сверка с ПС / ОФД / банком / леджером, расхождения и разбор
│
├── 06-reliability/                            Сюда придёт 70% «практических задач»
│   ├── 01-idempotency-state-machines.md       Идемпотентность + машины состояний платежа и чека
│   ├── 02-consistency-patterns.md             Saga, outbox, TCC, 2PC, dual-write, компенсации
│   └── 03-failures-runbook.md                 Ретраи, таймауты, circuit breaker, «unknown», runbook, метрики
│
├── 07-typescript/
│   └── 01-ts-node-for-php-devs.md             TypeScript/Node для PHP-разработчика + микросервисы биллинга
│
├── 08-system-design/
│   ├── 01-billing-architecture.md             Общая архитектура биллинга: компоненты, потоки, почему так
│   ├── 02-db-design-walkthrough.md            Метод + полный разбор схемы БД биллинга (ER + DDL)
│   └── 03-legacy-refactoring.md               Большой рефакторинг: стратегия, strangler, границы, флаги
│
├── 09-practical-tasks/                        Ровно те задачи, что перечислены в вакансии
│   ├── 01-payment-acceptance.md               Задача: приём платежа (вебхук ПС, зачисление, чек)
│   ├── 02-receipt-formation.md                Задача: формирование чека (аванс/услуга/агент/возврат)
│   ├── 03-refunds.md                          Задача: возврат — полный, частичный, при сбое
│   ├── 04-idempotent-reprocessing.md          Задача: повторная обработка и дубликаты
│   └── 05-failures-and-self-check.md          Задача: поведение при сбоях + чек-лист самопроверки
│
├── 10-mock-interview/                         Прогоняй вслух, а не читай глазами
│   ├── 01-full-transcript.md                  60-минутный мок целиком: вопрос → ответ → что хотел услышать
│   ├── 02-db-design-dialog.md                 Живой диалог «давай вместе спроектируем схему»
│   └── 03-behavioral-and-tricky.md            Поведенческие, «а если», проверка на упёртость + разбор
│
├── 11-cheatsheets/                            На последний день
│   ├── 01-mysql.md                            MySQL: индексы, локи, EXPLAIN, DDL — одной страницей
│   ├── 02-php-and-money.md                    PHP-деньги, транзакции, код-паттерны
│   ├── 03-rabbitmq.md                         RabbitMQ: команды, гарантии, DLQ, разбор инцидентов
│   ├── 04-redis.md                            Redis/Memcached: команды и рецепты
│   ├── 05-billing-glossary.md                 Словарь: 60+ терминов биллинга, налоговой, эквайринга
│   └── 06-last-day.md                         За 2 часа до собеса: 30 тезисов, которые надо сказать
│
└── 12-labs/                                   Руками: MySQL + RabbitMQ + Redis в docker, схема, запросы
    ├── README.md                              Как поднять и что проверить
    ├── docker-compose.yml                     MySQL 8 + Redis 7 + RabbitMQ 3.13 (+ management UI)
    ├── sql/01-schema.sql                      Схема биллинга из 08-02: таблицы, индексы, ограничения
    ├── sql/02-seed.sql                        Демо-данные: платежи, чеки, возвраты, «битые» кейсы
    ├── sql/03-queries.sql                     Запросы: сверка, поиск расхождений, отчётные выборки
    └── php/payment_flow_demo.php              Набросок обработки платежа с идемпотентностью и транзакцией
```

---

## Как готовиться (не читать подряд!)

Порядок важен: сначала домен и деньги, потом техника. Иначе на собеседовании будешь
рассказывать про B+tree там, где ждут «как мы не возьмём деньги дважды».

**Волна 1 — говорить как биллинговый разработчик (≈2 часа)**
1. `00-vacancy/01-vacancy-breakdown.md` — понять, что именно проверяют.
2. `00-vacancy/02-profiru-billing-domain.md` — что за бизнес, откуда деньги.
3. `05-billing-domain/01-domain-map.md` + `11-cheatsheets/05-billing-glossary.md`.

**Волна 2 — практические задачи (≈3 часа, главное)**
4. `06-reliability/01-idempotency-state-machines.md` — фундамент всех задач.
5. `09-practical-tasks/*` — по одной задаче, с закрытой страницей: сначала решаешь сам,
   потом сверяешься с разбором. Это самая полезная часть.

**Волна 3 — техническая база (≈3 часа)**
6. `02-mysql/01-innodb-indexes.md` → `02-transactions-isolation-locks.md` → `02-mysql/04-explain-and-sql-tasks.md`.
7. `01-php/01-money-precision-php.md` → `01-php/02-pdo-transactions.md`.
8. `03-messaging/01-rabbitmq-deep.md`, `04-cache/01-redis-memcached.md`.

**Волна 4 — схема БД и дизайн (≈2 часа)**
9. `08-system-design/02-db-design-walkthrough.md` — самое вероятное практическое задание.
10. `08-system-design/01-billing-architecture.md`, `03-legacy-refactoring.md`.

**Волна 5 — прогон (≈1.5 часа)**
11. `10-mock-interview/01-full-transcript.md` вслух целиком.
12. `10-mock-interview/03-behavioral-and-tricky.md` — подготовить 6 историй.
13. `00-vacancy/05-questions-to-employer.md` — выбрать 5 вопросов.

**За день до:** `11-cheatsheets/06-last-day.md` + запустить `12-labs/` и своими руками
выполнить три запроса: найти расхождение, найти дубликат, посчитать оборот за день.

---

## Как читать файлы

Каждый файл построен по одному шаблону:

* **Что проверяет** — зачем этот вопрос вообще задают.
* **Объяснение** — глубина: как работает внутри, а не «правильные слова».
* **Схема / код / SQL** — mermaid-диаграммы, ASCII-картинки, реальный код и запросы.
* **Ответ вслух** — готовая формулировка на 1–2 минуты, которую можно сказать почти дословно.
* **Продолжение разговора** — что спросят следом и куда это ведёт.
* **Красные флаги** — формулировки, которые лучше не произносить.

Диаграммы — в формате [Mermaid](https://mermaid.js.org/) (```mermaid-блоки). Они рендерятся
в GitHub, GitLab, Obsidian, VS Code (Markdown Preview Mermaid Support), JetBrains. Если
просматриваешь в «голом» редакторе — рядом всегда есть ASCII-версия или таблица с тем же смыслом.

---

## Три правила ответов на этом собеседовании

1. **Всегда доводи до денег.** «Потеряли вебхук» — плохо. «Не зачислили 300 оплат на 450 000 ₽,
   клиенты видят долг, бухгалтерия увидит расхождение с банком в закрытии дня» — хорошо.
2. **Проговаривай компромисс, а не только решение.** Миша прямо написал: важны trade-offs.
   Формула: «делаю A, потому что B; цена этого — C; если C станет критично, переключаюсь на D».
3. **Сначала уточняющие вопросы, потом архитектура.** В задачах биллинга половина условий
   спрятана: идемпотентность, частичный возврат, мультивалюта, предоплата или постоплата,
   кто плательщик. Спросить про это — плюс, а не минус: `09-practical-tasks/05-failures-and-self-check.md` → «Вопросы, которые надо задать».
