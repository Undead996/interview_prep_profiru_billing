# RabbitMQ: шпаргалка

## Модель

```
producer → exchange (по routing key) → bindings → queue(s) → consumer
```
* producer **не знает** про очереди; нет binding → сообщение молча выброшено (без `mandatory`);
* `direct` = точный ключ (команды), `topic` = шаблон `*`/`#` (события), `fanout` = всем.

## Свойства сообщения

| Свойство | Значение для биллинга |
|---|---|
| `delivery_mode = 2` | персистентность |
| `message_id` | **ключ идемпотентности у консьюмера** |
| `correlation_id` | трейсинг (например, `payment_id`) |
| `headers` | `x-retry-count` для ретраев |
| `mandatory` | вернуть сообщение, если некуда положить |

## Четыре точки потери и защита

| Точка | Защита |
|---|---|
| 1. Публикация | `publisher confirms` + `mandatory` + `publisher returns` |
| 2. Маршрутизация | alternate exchange / `mandatory` + алерт |
| 3. Хранение | `delivery_mode=2` + durable + **quorum queue** |
| 4. Обработка | manual `ack` **после** работы + идемпотентность + `prefetch` |

## Consumer: правильный каркас

```php
$channel->basic_qos(0, prefetchCount: 10, false);
$channel->basic_consume('billing.receipts', '', false, false, false, false,
  function (AMQPMessage $msg) use ($channel) {
      try {
          $this->handler->handle($msg->body, $msg->get('message_id'));   // идемпотентно
          $channel->basic_ack($msg->getDeliveryTag());                  // ack ПОСЛЕ работы
      } catch (TransientError $e) {
          $channel->basic_reject($msg->getDeliveryTag(), false);         // → retry-очередь/DLQ
      } catch (Throwable $e) {
          $channel->basic_reject($msg->getDeliveryTag(), false);         // → DLQ + алерт
      }
  });
```

❌ `nack(requeue: true)` как retry — **мгновенная петля**, сжигает CPU и блокирует очередь.
✅ retry с задержкой через TTL + DLX (или `x-delivery-limit` у quorum).

## Ретраи через TTL + DLX

```bash
# retry-очередь: полежал TTL → через DLX вернулся в основную
rabbitmqadmin declare queue name=billing.receipts.retry.30s durable=true \
  arguments='{"x-message-ttl":30000,"x-dead-letter-exchange":"billing.events","x-dead-letter-routing-key":"receipt.requested"}'
# основная: при reject отдаёт в DLQ
rabbitmqadmin declare queue name=billing.receipts durable=true \
  arguments='{"x-dead-letter-exchange":"billing.dlx","x-dead-letter-routing-key":"receipt.dlq"}'
# DLQ: без TTL, читает человек
rabbitmqadmin declare queue name=billing.receipts.dlq durable=true
```
```php
$attempts = (int) ($msg->get('application_headers')['x-retry-count'] ?? 0) + 1;
$target = match (true) {
    $attempts <= 3 => 'billing.receipts.retry.30s',
    $attempts <= 5 => 'billing.receipts.retry.5m',
    default        => 'billing.receipts.dlq',
};
// публикуем с x-retry-count, затем basic_ack оригинала ("мы его переложили")
```

## Quorum-очередь

```bash
rabbitmqadmin declare queue name=billing.receipts durable=true \
  arguments='{"x-queue-type":"quorum","x-delivery-limit":5}'
```
Raft-репликация + встроенный лимит доставок + автоматический DLX после N попыток.

## Гарантии и порядок

* Доставка **at-least-once** → консьюмер идемпотентен (`message_id` → UNIQUE).
* Порядок: внутри очереди с одним консьюмером; `requeue` ломает порядок.
* Нужен порядок по сущности → шардирование по ключу (`hash(payment_id)`), 1 консьюмер на очередь.
* Проще всего — **не гарантировать порядок**, а хранить версию/`seq` и игнорировать устаревшее.

## Метрики и команды дежурного

```bash
rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
rabbitmqctl list_queues name message_stats.publish_details.rate message_stats.ack_details.rate
rabbitmqctl list_connections user peer_host state
rabbitmqctl list_bindings
rabbitmqctl status
```

| Метрика | Тревога |
|---|---|
| `messages_ready` растёт | консьюмеры не справляются/упали |
| `consumers = 0` при непустой очереди | 🔴 никто не читает |
| `messages_unacknowledged` растёт | обработка зависла |
| DLQ > 0 | ручной разбор, алерт |
| publish_rate ≠ deliver_rate | затор или потери |

## RabbitMQ vs Kafka (одной фразой)

| | RabbitMQ | Kafka |
|---|---|---|
| Модель | очередь, сообщение удаляется после ack | лог с retention, можно отмотать offset |
| Для чего | команды, задачи, TTL/приоритеты, сложная маршрутизация | событийная лента, воспроизведение, аналитика |
| Порядок | на очередь/консьюмера | строго в пределах партиции |

## Ключевые фразы

```
• «Вебхук — оптимизация, а не источник правды: всегда есть опрос статуса.»
• «Публикация считается успешной только после publisher confirm.»
• «Даже с confirm возможен повтор — поэтому источник истины в БД (outbox).»
• «nack с requeue — не retry, а петля. Retry — с задержкой и лимитом.»
• «DLQ без алерта — это не обработка ошибок, а их накопление.»
• «Метрика не 'длина очереди', а 'оплачено без чека дольше N минут'.»
```
