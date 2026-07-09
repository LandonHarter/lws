import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, isAbsolute, join } from "node:path";
import { promisify } from "node:util";
import { Pool, type PoolClient } from "pg";
import { z } from "zod";

import { publicProcedure, router } from "../trpc";

const exec = promisify(execFile);

const LWS_BIN = process.env.LWS_BIN ?? "lws";
const LWS_ROOT = process.env.LWS_ROOT;

function resolveLwsBin(): string | null {
  if (isAbsolute(LWS_BIN)) {
    try {
      accessSync(LWS_BIN, constants.X_OK);
      return LWS_BIN;
    } catch {
      return null;
    }
  }

  const pathDirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const dir of pathDirs) {
    const candidate = join(dir, LWS_BIN);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // not here; keep searching
    }
  }
  return null;
}

// Single source of truth for the install guidance, mirrored from the launcher
// (thoughts/shared/plans/postgres/00-overview.md) so the dashboard banner reads
// identically to the CLI.
const INSTALL_GUIDANCE = `PostgreSQL is required but was not found on your PATH.
Install it, then try again:
  macOS (Homebrew):   brew install postgresql@16
  Debian/Ubuntu:      sudo apt-get install -y postgresql
  Fedora/RHEL:        sudo dnf install -y postgresql-server
  Arch:               sudo pacman -S postgresql
After installing, ensure \`initdb\` and \`postgres\` are on your PATH (Homebrew may need:
  export PATH="$(brew --prefix postgresql@16)/bin:$PATH").`;

const DEP_MARKER = "PostgreSQL is required but was not found";

// Cache pools by `${port}/${database}` so we don't reconnect per call.
const pools = new Map<string, Pool>();
function poolFor(port: number, database: string): Pool {
  const key = `${port}/${database}`;
  let p = pools.get(key);
  if (!p) {
    p = new Pool({
      host: "127.0.0.1",
      port,
      user: "postgres",
      database,
      max: 4,
      idleTimeoutMillis: 10_000,
      connectionTimeoutMillis: 3_000,
    });
    p.on("error", () => {});
    pools.set(key, p);
  }
  return p;
}

async function withClient<T>(
  port: number,
  database: string,
  fn: (c: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await poolFor(port, database).connect();
  try {
    return await fn(client);
  } finally {
    client.release();
  }
}

// Quote an identifier that gets interpolated into SQL text (schema/table/column
// names). Values always go through $n parameters and never hit this.
function ident(name: string): string {
  if (!/^[\w$]+$/u.test(name)) throw new Error(`unsafe identifier: ${name}`);
  return `"${name.replace(/"/g, '""')}"`;
}

const base = z.object({
  port: z.number().int().positive(),
  database: z.string().min(1).default("postgres"),
});

const columnSchema = z.object({
  name: z.string(),
  dataType: z.string(),
  nullable: z.boolean(),
  default: z.string().nullable(),
  isPrimaryKey: z.boolean(),
});

export type PgColumn = z.infer<typeof columnSchema>;

export const postgresRouter = router({
  // Probe whether Postgres is installed. When an instance is running a trivial
  // `select 1` succeeds → installed. When it's dead we tail the instance log; if
  // it carries the launcher's dependency marker we surface the install guidance.
  checkDeps: publicProcedure
    .input(z.object({ port: z.number().int().positive(), name: z.string().min(1).optional() }))
    .query(async ({ input }) => {
      try {
        await withClient(input.port, "postgres", (c) => c.query("select 1"));
        return { installed: true as const, guidance: null as string | null };
      } catch {
        // fall through to the log check
      }

      if (input.name !== undefined) {
        const bin = resolveLwsBin();
        if (bin) {
          try {
            const { stdout } = await exec(bin, ["logs", input.name, "--once", "--service", "postgres"], {
              cwd: LWS_ROOT,
              maxBuffer: 4 * 1024 * 1024,
            });
            if (stdout.includes(DEP_MARKER)) {
              return { installed: false as const, guidance: INSTALL_GUIDANCE };
            }
          } catch {
            // ignore; treat as unknown-but-reachable below
          }
        }
      }

      // Couldn't connect and no dependency marker found: the instance is likely
      // just not running. Report installed:true so the UI shows a connection
      // error rather than a false "not installed" banner.
      return { installed: true as const, guidance: null as string | null };
    }),

  databases: publicProcedure
    .input(z.object({ port: z.number().int().positive() }))
    .query(async ({ input }) => {
      const rows = await withClient(input.port, "postgres", async (c) => {
        const res = await c.query<{ datname: string }>(
          "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1",
        );
        return res.rows;
      });
      return { databases: rows.map((r) => r.datname) };
    }),

  schemas: publicProcedure.input(base).query(async ({ input }) => {
    const rows = await withClient(input.port, input.database, async (c) => {
      const res = await c.query<{ nspname: string }>(
        "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema' ORDER BY 1",
      );
      return res.rows;
    });
    return { schemas: rows.map((r) => r.nspname) };
  }),

  tables: publicProcedure
    .input(base.extend({ schema: z.string().min(1) }))
    .query(async ({ input }) => {
      const rows = await withClient(input.port, input.database, async (c) => {
        const res = await c.query<{ table_name: string; table_type: string }>(
          "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = $1 ORDER BY 1",
          [input.schema],
        );
        return res.rows;
      });
      return { tables: rows.map((r) => ({ name: r.table_name, type: r.table_type })) };
    }),

  describeTable: publicProcedure
    .input(base.extend({ schema: z.string().min(1), table: z.string().min(1) }))
    .query(async ({ input }) => {
      return withClient(input.port, input.database, async (c) => {
        const cols = await c.query<{
          column_name: string;
          data_type: string;
          is_nullable: string;
          column_default: string | null;
        }>(
          `SELECT column_name, data_type, is_nullable, column_default
             FROM information_schema.columns
            WHERE table_schema = $1 AND table_name = $2
            ORDER BY ordinal_position`,
          [input.schema, input.table],
        );

        const pk = await c.query<{ attname: string }>(
          `SELECT a.attname
             FROM pg_index i
             JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = ($1 || '.' || $2)::regclass AND i.indisprimary`,
          [ident(input.schema), ident(input.table)],
        );
        const pkSet = new Set(pk.rows.map((r) => r.attname));

        const est = await c.query<{ reltuples: number }>(
          "SELECT reltuples FROM pg_class WHERE oid = ($1 || '.' || $2)::regclass",
          [ident(input.schema), ident(input.table)],
        );

        const columns: PgColumn[] = cols.rows.map((r) => ({
          name: r.column_name,
          dataType: r.data_type,
          nullable: r.is_nullable === "YES",
          default: r.column_default,
          isPrimaryKey: pkSet.has(r.column_name),
        }));

        return {
          columns,
          primaryKey: columns.filter((col) => col.isPrimaryKey).map((col) => col.name),
          rowEstimate: Math.max(0, Math.round(est.rows[0]?.reltuples ?? 0)),
        };
      });
    }),

  stats: publicProcedure.input(base).query(async ({ input }) => {
    return withClient(input.port, input.database, async (c) => {
      const size = await c.query<{ size: string }>(
        "SELECT pg_database_size(current_database())::text AS size",
      );
      const count = await c.query<{ count: string }>(
        `SELECT count(*)::text AS count
           FROM information_schema.tables
          WHERE table_type = 'BASE TABLE'
            AND table_schema NOT IN ('pg_catalog', 'information_schema')`,
      );
      return {
        dbSizeBytes: Number(size.rows[0]?.size ?? 0),
        tableCount: Number(count.rows[0]?.count ?? 0),
      };
    });
  }),

  // Paginated rows for the data grid. Identifiers (schema/table/orderBy) go
  // through ident(); limit/offset are $n parameters.
  tableRows: publicProcedure
    .input(
      base.extend({
        schema: z.string().min(1),
        table: z.string().min(1),
        limit: z.number().int().min(1).max(500).default(100),
        offset: z.number().int().min(0).default(0),
        orderBy: z.string().min(1).optional(),
        orderDir: z.enum(["asc", "desc"]).default("asc"),
      }),
    )
    .query(async ({ input }) => {
      return withClient(input.port, input.database, async (c) => {
        const rel = `${ident(input.schema)}.${ident(input.table)}`;
        const order = input.orderBy
          ? `ORDER BY ${ident(input.orderBy)} ${input.orderDir === "desc" ? "DESC" : "ASC"}`
          : "";
        const res = await c.query(
          `SELECT * FROM ${rel} ${order} LIMIT $1 OFFSET $2`,
          [input.limit, input.offset],
        );
        const total = await c.query<{ n: string }>(
          `SELECT count(*)::text AS n FROM ${rel}`,
        );
        return {
          columns: res.fields.map((f) => ({ name: f.name, dataTypeID: f.dataTypeID })),
          rows: res.rows as Record<string, unknown>[],
          total: Number(total.rows[0]?.n ?? 0),
        };
      });
    }),

  insertRow: publicProcedure
    .input(
      base.extend({
        schema: z.string().min(1),
        table: z.string().min(1),
        values: z.record(z.string(), z.unknown()),
      }),
    )
    .mutation(async ({ input }) => {
      const cols = Object.keys(input.values);
      if (cols.length === 0) throw new Error("no columns to insert");
      return withClient(input.port, input.database, async (c) => {
        const rel = `${ident(input.schema)}.${ident(input.table)}`;
        const params = cols.map((_, i) => `$${i + 1}`);
        const res = await c.query(
          `INSERT INTO ${rel} (${cols.map(ident).join(",")}) VALUES (${params.join(",")}) RETURNING *`,
          cols.map((col) => input.values[col]),
        );
        return res.rows[0] as Record<string, unknown>;
      });
    }),

  updateRow: publicProcedure
    .input(
      base.extend({
        schema: z.string().min(1),
        table: z.string().min(1),
        key: z.record(z.string(), z.unknown()),
        changes: z.record(z.string(), z.unknown()),
      }),
    )
    .mutation(async ({ input }) => {
      const setCols = Object.keys(input.changes);
      const keyCols = Object.keys(input.key);
      if (keyCols.length === 0) throw new Error("table has no primary key; edit via raw SQL");
      if (setCols.length === 0) throw new Error("no changes to apply");
      return withClient(input.port, input.database, async (c) => {
        const rel = `${ident(input.schema)}.${ident(input.table)}`;
        const sets = setCols.map((col, i) => `${ident(col)}=$${i + 1}`);
        const wheres = keyCols.map((col, i) => `${ident(col)}=$${setCols.length + i + 1}`);
        const res = await c.query(
          `UPDATE ${rel} SET ${sets.join(",")} WHERE ${wheres.join(" AND ")} RETURNING *`,
          [...setCols.map((col) => input.changes[col]), ...keyCols.map((col) => input.key[col])],
        );
        return res.rows[0] as Record<string, unknown>;
      });
    }),

  deleteRow: publicProcedure
    .input(
      base.extend({
        schema: z.string().min(1),
        table: z.string().min(1),
        key: z.record(z.string(), z.unknown()),
      }),
    )
    .mutation(async ({ input }) => {
      const keyCols = Object.keys(input.key);
      if (keyCols.length === 0) throw new Error("table has no primary key; delete via raw SQL");
      return withClient(input.port, input.database, async (c) => {
        const rel = `${ident(input.schema)}.${ident(input.table)}`;
        const wheres = keyCols.map((col, i) => `${ident(col)}=$${i + 1}`);
        const res = await c.query(
          `DELETE FROM ${rel} WHERE ${wheres.join(" AND ")}`,
          keyCols.map((col) => input.key[col]),
        );
        return { deleted: res.rowCount ?? 0 };
      });
    }),

  // Raw SQL executor. Uses a dedicated client so multi-statement scripts and
  // errors are contained. Returns a discriminated { ok } union — SQL errors are
  // data, never thrown (only connection failures throw).
  runQuery: publicProcedure
    .input(base.extend({ sql: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const client = await poolFor(input.port, input.database).connect();
      try {
        const started = Date.now();
        const raw = await client.query(input.sql);
        const results = Array.isArray(raw) ? raw : [raw];
        return {
          ok: true as const,
          elapsedMs: Date.now() - started,
          results: results.map((r) => ({
            command: r.command,
            rowCount: r.rowCount ?? 0,
            columns: ((r.fields ?? []) as { name: string }[]).map((f) => f.name),
            rows: (r.rows ?? []) as Record<string, unknown>[],
          })),
        };
      } catch (e) {
        const err = e as {
          message?: string;
          position?: string;
          code?: string;
          detail?: string;
          hint?: string;
        };
        return {
          ok: false as const,
          error: {
            message: err.message ?? "query failed",
            position: err.position ?? null,
            code: err.code ?? null,
            detail: err.detail ?? null,
            hint: err.hint ?? null,
          },
        };
      } finally {
        client.release();
      }
    }),
});
