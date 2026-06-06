# S3 — Simple Storage Service

AWS S3-compatible object storage service for LWS. Standalone Zig HTTP server, file-backed persistence under `.lws/s3/<instance>/`, default port `9000`.

Status: scaffolding (Phase 1). `/health`, `/stats`, and `--generate-config` work; S3 operations are not yet implemented.

## Flags

`--port`, `--bind`, `--data-dir`, `--config`, `--generate-config`, `--account-id`, `--region`, `--host`, `--log-level`, `--fsync on|off`.
