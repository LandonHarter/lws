# SQS — Simple Queue Service

An AWS SQS-compatible queue service backed by the local filesystem. Part of [LWS](../../README.md).

**Location:** `services/sqs/`  ·  **Default port:** `9324`  ·  **Language:** Zig  ·  **Entry:** `services/sqs/src/main.zig`

Standard and FIFO queues, addressable over both the Query (XML/form) and JSON (`X-Amz-Target`) protocols, so existing AWS SDKs can point at it.

---

## Launch flags

| Flag | Default | Purpose |
|---|---|---|
| `--port` | `9324` | HTTP listen port |
| `--bind` | `127.0.0.1` | Bind address |
| `--data-dir` | `.lws/sqs` | Persistence directory |
| `--config` | — | Path to JSON config file |
| `--generate-config` | — | Print default config and exit |
| `--account-id` | `000000000000` | AWS account ID used in ARNs/URLs |
| `--region` | `us-east-1` | AWS region |
| `--host` | auto | Host header for generated queue URLs |
| `--log-level` | `info` | `error` \| `warn` \| `info` \| `debug` |
| `--fsync` | `true` | fsync on file writes |

Normally you launch SQS through the LWS CLI (`lws run sqs --name orders`), which sets `--port`, `--data-dir`, and `--config` for you. The flags above matter when running the binary directly.

---

## Endpoints

In addition to the SQS API, the service exposes the standard LWS control endpoints:

- `GET /health` → `{"status":"ok"}`
- `GET /stats` → runtime statistics as JSON (consumed by `lws info` and the dashboard)

---

## Supported API

- **Lifecycle:** CreateQueue, DeleteQueue, ListQueues, GetQueueUrl, PurgeQueue
- **Attributes:** GetQueueAttributes, SetQueueAttributes
- **Messages:** SendMessage, ReceiveMessage, DeleteMessage
- **Batch:** SendMessageBatch, ReceiveMessageBatch, DeleteMessageBatch
- **Tags:** TagQueue, UntagQueue, ListQueueTags
- **Permissions:** AddPermission, RemovePermission
- **Redrive/DLQ:** RedrivePolicy and message move/status operations

FIFO queues require a `.fifo` name suffix.

---

## Queue attributes

Defined and validated in `services/sqs/src/queue_config.zig`:

- `VisibilityTimeout` — integer, 0–43200, default 30
- `MessageRetentionPeriod`
- `MaximumMessageSize`
- `DelaySeconds`
- `ReceiveMessageWaitTimeSeconds` — long polling
- `FifoQueue` — boolean, create-only
- `ContentBasedDeduplication` — boolean, FIFO-only
- `DeduplicationScope` — `queue` | `messageGroup`, FIFO-only
- `RedrivePolicy` — JSON, for dead-letter queues

---

## Configuration

A config file declares queues to create at startup. Generate a default with `lws config generate sqs`, or write one by hand:

```json
{
  "queues": {
    "my-queue": { "VisibilityTimeout": "45" },
    "orders.fifo": { "FifoQueue": "true", "ContentBasedDeduplication": "true" }
  }
}
```

Pass it via `--config <path>` (or `lws run sqs --config <path>`).

---

## Internal structure

```
services/sqs/src/
├── main.zig          # arg parsing, HTTP server bootstrap
├── registry.zig      # queue registry + persistence
├── queue_config.zig  # attribute spec + validation
├── handlers/         # action handlers (lifecycle, messages, batch, …)
├── store/            # in-memory message store + operations
├── persist/          # file-backed persistence
└── wire/             # protocol parsing/encoding (JSON / Query / XML)
```
