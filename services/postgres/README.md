# Postgres — PostgreSQL Database

Runs a real PostgreSQL cluster on your laptop by wrapping your system's `postgres`/`initdb`. Part of [LWS](../../README.md).

**Location:** `services/postgres/`  ·  **Default port:** `5432`  ·  **Language:** Zig  ·  **Entry:** `services/postgres/src/main.zig`

Unlike the other LWS services, Postgres does **not** reimplement the wire protocol — it supervises the real `postgres` server. That means you need PostgreSQL installed on the machine.

---

## Requirements

`initdb` and `postgres` must be on your `PATH` (v14+ recommended). The launcher also probes common install locations (Homebrew, `/usr/lib/postgresql`, PGDG, EDB) if they aren't on `PATH`.

Install:

| OS | Command |
|---|---|
| macOS (Homebrew) | `brew install postgresql@16` |
| Debian/Ubuntu | `sudo apt-get install -y postgresql` |
| Fedora/RHEL | `sudo dnf install -y postgresql-server` |
| Arch | `sudo pacman -S postgresql` |

After a Homebrew install you may need: `export PATH="$(brew --prefix postgresql@16)/bin:$PATH"`.

`lws run postgres` runs a dependency preflight first; if Postgres is missing it prints install guidance to your terminal and creates **no** instance.

---

## Launch flags

| Flag | Default | Purpose |
|---|---|---|
| `--port` | `5432` | Listen port |
| `--bind` | `127.0.0.1` | Bind address (loopback only) |
| `--data-dir` | `.lws/postgres` | Cluster directory |
| `--config` | — | Path to JSON config file |
| `--generate-config` | — | Print default config and exit |
| `--check-deps` | — | Print resolved `initdb`/`postgres` paths, exit 0 (non-zero if missing) |
| `--log-level` | `info` | `error` \| `warn` \| `info` \| `debug` |

Normally you launch through the CLI (`lws run postgres --name db1`), which sets `--port`, `--data-dir`, and `--config` for you.

---

## Connecting

```
postgresql://postgres@127.0.0.1:<port>/postgres
```

```sh
psql "postgresql://postgres@127.0.0.1:5432/postgres"
```

Auth is `trust` (no password) and the server binds to **loopback only**. This is fine for local dev — **do not expose it**; never bind to `0.0.0.0`.

---

## Config file

```json
{
  "databases": ["appdb", "analytics"],
  "seed_sql": "create table t(id int);"
}
```

- `databases` — extra databases to `CREATE DATABASE` on boot (the built-in `postgres` DB always exists). Optional; default `[]`.
- `seed_sql` — optional SQL applied after startup. If it's a readable file path, it runs via `psql -f`; otherwise it's treated as inline SQL. Targets the first entry of `databases` (or `postgres`). Best-effort: a failed seed logs but does not abort the server. Skipped if `psql` isn't found.

Generate a stub with `lws config generate postgres`.

---

## Data layout

```
.lws/postgres/<instance>/
├── pgdata/        # the PostgreSQL cluster (initdb output)
├── config.json    # this instance's config
└── output.log     # captured initdb/postgres output
```

`stop` keeps `pgdata/`; `start` reuses it (no re-`initdb`). `delete` removes the whole instance directory.

---

## Caveats

- **Deep project paths.** The unix socket lives at `<data-dir>/.s.PGSQL.<port>`; macOS caps socket paths at ~104 chars. A deeply nested project root can exceed it — keep the root shallow, or the socket connection will fail.
- **Shutdown modes.** `stop` sends a Postgres *fast* shutdown (clean, disconnects clients, rolls back open transactions). `stop --force` group-kills immediately (SIGKILL) — the next `start` may run crash recovery.
