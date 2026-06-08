# DynamoDB — Simple NoSQL Database

AWS DynamoDB-compatible NoSQL service for LWS. Standalone Zig HTTP server, default port `8000`.

Speaks the DynamoDB JSON wire protocol (`application/x-amz-json-1.0`), persists tables and items to disk, and recovers state on boot. Item data is durable across restarts via atomic whole-file writes.

## Endpoints

`GET /health` → `{"status":"ok","version":"..."}`. `GET /stats` → JSON with uptime plus table/item/byte counters and a per-table `detail` array. `OPTIONS *` → permissive CORS preflight.

All API calls are `POST` with an `X-Amz-Target` header (e.g. `DynamoDB_20120810.PutItem`); the action after the final `.` selects the operation. Responses carry `content-type: application/x-amz-json-1.0` plus `x-amzn-requestid`, `x-amz-crc32` (CRC32 of the body), and `x-amz-id-2` headers.

An unrecognized target returns `200` with an `UnknownOperationException`. A malformed JSON body returns `SerializationException`; a missing `X-Amz-Target` or non-`POST` method returns `UnknownOperationException`.

## Supported operations

**Tables:** `CreateTable`, `DeleteTable`, `DescribeTable`, `ListTables`, `UpdateTable`, `UpdateTimeToLive`, `DescribeTimeToLive`, `ListTagsOfResource`, `TagResource`, `UntagResource`.

**Items:** `PutItem`, `GetItem`, `UpdateItem`, `DeleteItem`.

**Multi-item:** `BatchGetItem`, `BatchWriteItem`, `Query`, `Scan`.

**Transactions:** `TransactGetItems`, `TransactWriteItems`.

## Expressions

A full expression engine (lexer + parser + evaluator) backs condition, filter, key-condition, projection, and update expressions, with `ExpressionAttributeNames` (`#ref`) and `ExpressionAttributeValues` (`:ref`) substitution.

- **Functions:** `attribute_exists`, `attribute_not_exists`, `attribute_type`, `begins_with`, `contains`, `size`.
- **Operators:** comparisons, `BETWEEN`, `IN`, `AND`/`OR`/`NOT`, parentheses, nested paths (`a.b[0]`).
- **Update actions:** `SET`, `REMOVE`, `ADD`, `DELETE`, including `if_not_exists(path, val)` and `list_append`.

Global and local secondary indexes are supported and maintained on writes. TTL attributes are tracked per table.

## Storage layout

Each table lives under the data dir; item and index entries are individual JSON files named by a hash of the key:

```
<data-dir>/tables/<table>/schema.json
<data-dir>/tables/<table>/items/<hash(key)>.json
<data-dir>/tables/<table>/indexes/<index>/<hash(idx-key)>/<hash(pk)>.json
```

Writes are atomic: bytes go to `<path>.tmp`, fsync (when enabled), then rename over the target — no WAL. A crash leaves at most a stale `*.tmp`, which the next write overwrites and recovery ignores. On boot the registry rescans `tables/` and reloads every schema and item.

## Flags

`--port` (default `8000`), `--bind` (default `127.0.0.1`), `--data-dir` (default `.lws/dynamodb`), `--config`, `--generate-config`, `--account-id` (default `000000000000`), `--region` (default `us-east-1`), `--host`, `--log-level` (`error|warn|info|debug`, default `info`), `--fsync on|off` (default `on`).

`--generate-config` emits a default config to stdout:

```json
{
  "tables": {}
}
```
