# S3 — Simple Storage Service

AWS S3-compatible object storage service for LWS. Standalone Zig HTTP server, file-backed persistence under `<data-dir>/buckets/`, default port `9000`.

## Operations

Bucket: `ListBuckets`, `CreateBucket`, `HeadBucket`, `DeleteBucket`, `ListObjects` (v1 + v2), `ListMultipartUploads`, `DeleteObjects` (batch).

Object: `PutObject`, `GetObject`, `HeadObject`, `DeleteObject`, `CopyObject` (via `x-amz-copy-source`).

Multipart: `CreateMultipartUpload`, `UploadPart`, `CompleteMultipartUpload`, `AbortMultipartUpload`, `ListParts`.

Both path-style (`/bucket/key`) and virtual-host (`bucket.<host>/key`) addressing. `aws-chunked` streaming payloads (`STREAMING-*` content sha256) are decoded.

Not implemented: bucket subresources (location, versioning, tagging, etc.) and object subresources (acl, tagging, attributes, retention, legal-hold) return `NotImplemented`.

## Auth

Presence-only. A request must carry an `AWS4-HMAC-SHA256` `Authorization` header or an `X-Amz-Signature` query param; the signature is **not** verified. Requests without either get `AccessDenied`.

## Endpoints

`GET /health` → `{"status":"ok"}`. `GET /stats` → JSON with uptime, bucket/object/byte totals, and per-bucket detail. `OPTIONS *` → permissive CORS preflight.

## Storage layout

```
<data-dir>/buckets/<bucket>/meta.json
<data-dir>/buckets/<bucket>/objects/<sha256(key)>/{data,meta.json}
<data-dir>/buckets/<bucket>/uploads/<upload-id>/...
```

Object keys are content-addressed by `sha256(key)` (sidesteps filename-length and path-traversal limits). Writes are atomic (temp + rename); `--fsync` controls durability. On startup the registry recovers existing buckets/objects from disk.

## Flags

`--port`, `--bind`, `--data-dir`, `--config`, `--generate-config`, `--account-id`, `--region`, `--host`, `--log-level` (`error|warn|info|debug`), `--fsync on|off`.

`--generate-config` emits a default config to stdout. Config format:

```json
{ "buckets": { "logs": {}, "uploads": { "Region": "us-west-2" } } }
```
