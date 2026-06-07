# DynamoDB — Simple NoSQL Database

AWS DynamoDB-compatible NoSQL service for LWS. Standalone Zig HTTP server, default port `8000`.

This is currently a skeleton: it boots, serves `/health` and `/stats`, and replies to every DynamoDB API call with an `UnknownOperationException` placeholder. Persistence and the wire protocol land in later plans.

## Endpoints

`GET /health` → `{"status":"ok"}`. `GET /stats` → JSON with uptime and table/item/byte counters. `OPTIONS *` → permissive CORS preflight.

Any other request (including `POST /`) returns `200` with body:

```json
{ "__type": "com.amazonaws.dynamodb.v20120810#UnknownOperationException", "message": "operation not yet implemented" }
```

and `content-type: application/x-amz-json-1.0`.

## Storage layout

Persistence is not implemented yet. Future plans store table data under:

```
<data-dir>/tables/<table>/...
```

## Flags

`--port` (default `8000`), `--bind`, `--data-dir` (default `.lws/dynamodb`), `--config`, `--generate-config`, `--account-id`, `--region`, `--host`, `--log-level` (`error|warn|info|debug`), `--fsync on|off`.

`--generate-config` emits a default config to stdout:

```json
{ "tables": {} }
```
