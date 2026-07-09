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
});
