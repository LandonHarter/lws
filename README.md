# LWS — Local Web Services

LWS is basically a local clone of AWS.

---

## Table of Contents

- [Architecture](#architecture)
- [Repository Layout](#repository-layout)
- [Concepts](#concepts)
- [The CLI](#the-cli)
- [Services](#services)
- [Runtime State Layout](#runtime-state-layout)
- [Building & Running](#building--running)
- [Configuration](#configuration)

---

## Architecture

LWS is built from three layers:

```
┌─────────────────────────────────────────────────┐
│  Dashboard (Next.js + tRPC)                       │
│  Thin UI over the CLI — spawns CLI commands       │
└───────────────────────┬───────────────────────────┘
                        │  execFile(LWS_BIN, args)
┌───────────────────────▼───────────────────────────┐
│  CLI (Zig)                                          │
│  Lifecycle control: run / start / stop / delete     │
│  Instance registry, logs, stats, config             │
└───────────────────────┬───────────────────────────┘
                        │  spawns process, talks HTTP
┌───────────────────────▼───────────────────────────┐
│  Service binaries (Zig)  — e.g. SQS                 │
│  Independent HTTP servers, file-backed persistence  │
└─────────────────────────────────────────────────┘
```

Key properties:

- **CLI-first.** The dashboard is a thin wrapper — every dashboard action shells out to the CLI binary and parses its output. There is no separate backend.
- **Independent service binaries.** Each service is its own Zig executable that listens on HTTP. The CLI launches them as background processes and tracks their PIDs.
- **File-based registry.** No database. Instance metadata, config, logs, and service data all live as files under a `.lws/` directory at the project root.
- **AWS-compatible wire protocols.** Services follow the real AWS API surface (e.g. SQS Query and JSON protocols, ARNs, error codes) so existing SDKs can point at them.

---

## Repository Layout

```
lws/
├── cli/         # Zig CLI — the control plane entry point
├── dash/        # Next.js dashboard (TypeScript/React)
├── services/    # Service implementations (Zig HTTP servers)
│   ├── sqs/      # SQS service
│   ├── s3/       # S3 service
│   └── dynamodb/ # DynamoDB service
├── shared/      # Shared Zig libraries used by CLI + services
│   ├── core/    # logging, IDs, timing
│   ├── config/  # attribute validation, config parsing
│   └── server/  # threaded HTTP server
├── .lws/        # runtime state (instance metadata, logs, data) — generated
└── .lwsroot     # empty marker file that identifies the project root
```

---

## Concepts

- **Service** — a kind of thing you can run (e.g. `sqs`). Defined in the CLI's service registry (`cli/src/services.zig`) with a name, binary, default port, and description.
- **Instance** — a running (or stopped) copy of a service, identified by name. Each instance has its own port, config, data directory, and log file. Multiple instances of the same service can run side by side on different ports.
- **Project root** — the directory containing the `.lwsroot` marker. All runtime state is stored under `.lws/` relative to this root, so the CLI behaves the same regardless of which subdirectory you invoke it from.

---

## The CLI

**Location:** `cli/`  ·  **Language:** Zig (≥ 0.16.0)  ·  **CLI framework:** [`zli`](https://github.com/xcaeser/zli) v5.0.0

Entry point is `cli/src/main.zig`; the command tree is assembled in `cli/src/root.zig`. Commands live in `cli/src/commands/`, and instance bookkeeping in `cli/src/core/` (`root_dir.zig` for root discovery, `instances.zig` for the registry, `namegen.zig` for random instance names).

### Commands

| Command | Description |
|---|---|
| `version` | Print CLI version. |
| `run <service>` | Build (if needed) and launch a new instance of a service. |
| `list` / `ls` | List instances in a table: `SERVICE  NAME  PID  PORT  STATUS`. |
| `start <name>` | Revive a stopped instance on its original port, config, and data. |
| `stop <name>` | Stop a running instance (SIGTERM, or SIGKILL with `--force`). Registration, data, and config are kept. |
| `delete <name>` | Permanently remove an instance — registration, config, data, logs. |
| `logs <name>` | Stream an instance's logs (follow mode, or one-shot with `--once`). |
| `info <name>` | Show metadata plus live stats fetched from the running service. |
| `config generate <service>` | Emit a default config file for a service. |

### Common flags

- `run`: `--port/-p`, `--name/-n` (auto-generated if omitted), `--config/-c`
- `stop`: `--service/-s`, `--force/-f`
- `start`: `--service/-s`
- `delete`: `--service/-s`, `--force/-f` (kill if still running)
- `logs`: `--service/-s`, `--once/-o`
- `info`: `--service/-s`, `--json/-j`
- `config generate`: `--output/-o`

### How `run` works

1. Resolves the service spec from the registry and ensures its binary is built.
2. Allocates an instance directory at `.lws/<service>/<name>/`.
3. Launches the service binary with `--port`, `--data-dir`, and (optionally) `--config`.
4. Redirects stdout/stderr to `.lws/<service>/<name>/output.log`.
5. Records the instance (name, service, PID, port, status) in the registry.

`info` goes a step further than the local registry: it issues an HTTP `GET /stats` to the live process and returns a JSON envelope (`service`, `name`, `pid`, `port`, `alive`, `stats`).

---

## Services

Each service is a standalone Zig HTTP server. Services share common libraries from `shared/` (HTTP server, config validation, logging) but build and run independently.

Every service exposes:

- `GET /health` → `{"status":"ok"}`
- `GET /stats` → runtime statistics as JSON (consumed by `lws info` and the dashboard)
- `--generate-config` → print a default JSON config to stdout (consumed by `lws config generate`)

Available services — see each service's README for launch flags, supported API, config, and internals:

| Service | Default port | Description | Docs |
|---|---|---|---|
| `sqs` | `9324` | Simple Queue Service — AWS SQS-compatible queues (standard + FIFO) | [services/sqs/README.md](services/sqs/README.md) |
| `s3`  | `9000` | Simple Storage Service — AWS S3-compatible buckets and objects | [services/s3/README.md](services/s3/README.md) |
| `dynamodb` | `8000` | Simple NoSQL Database — AWS DynamoDB-compatible tables and items | [services/dynamodb/README.md](services/dynamodb/README.md) |

---

## Runtime State Layout

All state lives under `.lws/` at the project root:

```
.lws/
└── <service-name>/
    └── <instance-name>/
        ├── config.json     # queue configuration for this instance
        ├── output.log      # captured stdout/stderr
        └── <other-data>     # persisted messages + attributes
```

The instance registry (name → service, PID, port, status) is also stored as files here, which is how `list`, `stop`, `start`, and `delete` find instances across CLI invocations.

---

## Building & Running

### Prerequisites

- Zig ≥ 0.16.0
- Bun or NPM

### CLI

```bash
cd cli
zig build              # → cli/zig-out/bin/cli
zig build run -- ls    # build and run with args
zig build test
```

### Dashboard

The dashboard shells out to the `lws` command, which **must be on your `PATH`** (see [Configuration](#configuration)). Make the built CLI available as `lws`:

```bash
# from the repo root, after `cd cli && zig build`
ln -sf "$(pwd)/cli/zig-out/bin/cli" /usr/local/bin/lws   # or any PATH dir
lws version                                              # verify
```

```bash
cd dash
bun install
bun run dev            # http://localhost:3000
bun run build && bun start   # production
```

### Typical workflow

```bash
# 1. Build the CLI
cd cli && zig build

# 2. Start an SQS instance
./zig-out/bin/cli run sqs --name orders

# 3. Inspect
./zig-out/bin/cli list
./zig-out/bin/cli info orders --json
./zig-out/bin/cli logs orders
```

---

## Configuration

Dashboard environment variables (with defaults from `dash/src/server/routers/lws.ts`):

| Variable | Default | Purpose |
|---|---|---|
| `LWS_BIN` | `lws` | CLI command the dashboard shells out to. Resolved against `PATH` unless an absolute path is given. If it cannot be found, the dashboard refuses to run any CLI action. |
| `LWS_ROOT` | _(process cwd)_ | Working directory the CLI runs against. |

> **`lws` must be on your `PATH`.** By default the dashboard invokes the bare `lws` command and looks it up in `PATH`. If `lws` is not found there, every dashboard action fails with a clear error instead of running. Either add the compiled CLI to your `PATH` (e.g. symlink `cli/zig-out/bin/cli` to a `PATH` directory as `lws`), or set `LWS_BIN` to an absolute path.

Service-level configuration is supplied per instance via `--config` (a JSON file) or generated with `lws config generate <service>`.
