"use client";

import { useCallback, useEffect, useState } from "react";
import {
  AlertTriangle,
  Check,
  Copy,
  Database,
  Hash,
  Key,
  Network,
  RefreshCw,
  Table as TableIcon,
} from "lucide-react";

import { fmtBytes } from "@/lib/format";
import { trpc } from "@/lib/trpc";
import { usePoll } from "@/lib/use-poll";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel } from "@/components/bits";
import { SyncStamp } from "@/components/services/shared";
import { DataGrid } from "@/components/services/postgres/data-grid";
import { QueryConsole } from "@/components/services/postgres/query-console";
import { type TableStructure } from "@/components/services/postgres/types";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

type TableEntry = { name: string; type: string };

const selectCls =
  "h-8 rounded-md border border-border bg-card/60 px-2 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30";

export function PostgresDetail({
  name,
  port,
  updatedAt,
}: {
  name: string;
  port: number | null;
  stats: unknown;
  updatedAt: number | null;
}) {
  const [selectedDb, setSelectedDb] = useState("postgres");
  const [databases, setDatabases] = useState<string[]>(["postgres"]);
  const [tab, setTab] = useState<"browse" | "query">("browse");
  const [deps, setDeps] = useState<{ installed: boolean; guidance: string | null } | null>(null);

  useEffect(() => {
    if (port === null) return;
    let alive = true;
    trpc.postgres.checkDeps
      .query({ port, name })
      .then((res) => alive && setDeps(res))
      .catch(() => alive && setDeps({ installed: true, guidance: null }));
    return () => {
      alive = false;
    };
  }, [port, name]);

  const loadDatabases = useCallback(async () => {
    if (port === null) return;
    try {
      const res = await trpc.postgres.databases.query({ port });
      setDatabases(res.databases);
      setSelectedDb((cur) => (res.databases.includes(cur) ? cur : res.databases[0] ?? "postgres"));
    } catch {
      // instance may not be reachable yet; keep the default
    }
  }, [port]);

  useEffect(() => {
    void loadDatabases();
  }, [loadDatabases]);

  if (deps && !deps.installed) {
    return <DepBanner guidance={deps.guidance} />;
  }

  return (
    <>
      <ConnectionPanel
        port={port}
        db={selectedDb}
        databases={databases}
        onDbChange={setSelectedDb}
      />

      <div className="flex items-center gap-1 border-b border-border">
        {(["browse", "query"] as const).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={cn(
              "-mb-px border-b-2 px-3 py-2 text-[13px] transition-colors",
              tab === t
                ? "border-primary text-foreground"
                : "border-transparent text-muted-foreground hover:text-foreground",
            )}
          >
            {t === "browse" ? "Browse" : "Query"}
          </button>
        ))}
      </div>

      {tab === "browse" ? (
        <>
          <StatsTiles port={port} database={selectedDb} />
          <SchemaBrowser port={port} database={selectedDb} updatedAt={updatedAt} />
        </>
      ) : port !== null ? (
        <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
          <QueryConsole port={port} database={selectedDb} />
        </Card>
      ) : (
        <Card className="items-center justify-center rounded-lg border-border bg-card/50 p-0 ring-0">
          <div className="px-6 py-24 text-center font-mono text-sm text-muted-foreground">
            instance not running
          </div>
        </Card>
      )}
    </>
  );
}

function DepBanner({ guidance }: { guidance: string | null }) {
  return (
    <Card className="gap-3 rounded-lg border border-delayed/40 bg-delayed/10 p-5 ring-0">
      <div className="flex items-center gap-2">
        <AlertTriangle className="size-4 text-delayed" strokeWidth={2} />
        <span className="text-[13px] font-medium text-foreground">PostgreSQL not found</span>
      </div>
      <pre className="overflow-x-auto whitespace-pre-wrap font-mono text-[12px] leading-relaxed text-muted-foreground">
        {guidance ?? "PostgreSQL is required but was not found on your PATH."}
      </pre>
    </Card>
  );
}

function CopyRow({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);
  const copy = useCallback(() => {
    void navigator.clipboard.writeText(value).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    });
  }, [value]);

  return (
    <div className="flex items-center gap-2">
      <code className="min-w-0 flex-1 truncate rounded-md border border-border bg-background px-2.5 py-1.5 font-mono text-[12px] text-foreground">
        {value}
      </code>
      <Button type="button" variant="outline" size="icon-sm" onClick={copy}>
        {copied ? (
          <Check className="size-3.5 text-ok" />
        ) : (
          <Copy className="size-3.5 text-muted-foreground" />
        )}
      </Button>
    </div>
  );
}

// Connection panel — reused verbatim in the query-executor header (phase 04).
export function ConnectionPanel({
  port,
  db,
  databases,
  onDbChange,
}: {
  port: number | null;
  db: string;
  databases: string[];
  onDbChange: (db: string) => void;
}) {
  const url = `postgresql://postgres@127.0.0.1:${port ?? "?"}/${db}`;

  return (
    <Card className="gap-4 rounded-lg border-border bg-card/70 p-5 ring-0">
      <div className="flex items-center justify-between">
        <SectionLabel>Connect</SectionLabel>
        <div className="flex items-center gap-2">
          <span className="font-mono text-[11px] text-muted-foreground">database</span>
          <select
            value={db}
            onChange={(e) => onDbChange(e.target.value)}
            className={selectCls}
          >
            {databases.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="space-y-2">
        <CopyRow value={url} />
        <CopyRow value={`psql "${url}"`} />
      </div>

      <span className="font-mono text-[11px] text-muted-foreground">auth: trust (local only)</span>
    </Card>
  );
}

function StatsTiles({ port, database }: { port: number | null; database: string }) {
  const { data } = usePoll(
    () =>
      port === null
        ? Promise.resolve({ dbSizeBytes: 0, tableCount: 0 })
        : trpc.postgres.stats.query({ port, database }),
    4000,
  );
  const dbSize = data?.dbSizeBytes ?? 0;

  return (
    <div className="grid grid-cols-2 gap-4 lg:grid-cols-3">
      <MetricTile label="DB size" value={dbSize} icon={Database} tone="primary" hint={fmtBytes(dbSize)} />
      <MetricTile label="Tables" value={data?.tableCount ?? 0} icon={TableIcon} tone="flight" />
      <MetricTile label="Port" value={port ?? 0} icon={Network} tone="ok" />
    </div>
  );
}

function SchemaBrowser({
  port,
  database,
  updatedAt,
}: {
  port: number | null;
  database: string;
  updatedAt: number | null;
}) {
  const [schemas, setSchemas] = useState<string[]>([]);
  const [schema, setSchema] = useState("public");
  const [tables, setTables] = useState<TableEntry[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const loadSchemas = useCallback(async () => {
    if (port === null) return;
    try {
      const res = await trpc.postgres.schemas.query({ port, database });
      setSchemas(res.schemas);
      setSchema((cur) => (res.schemas.includes(cur) ? cur : res.schemas[0] ?? "public"));
      setErr(null);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed to list schemas");
    }
  }, [port, database]);

  const loadTables = useCallback(async () => {
    if (port === null) return;
    setLoading(true);
    try {
      const res = await trpc.postgres.tables.query({ port, database, schema });
      setTables(res.tables);
      setSelected((cur) => (cur && res.tables.some((t) => t.name === cur) ? cur : res.tables[0]?.name ?? null));
      setErr(null);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed to list tables");
    } finally {
      setLoading(false);
    }
  }, [port, database, schema]);

  useEffect(() => {
    void loadSchemas();
  }, [loadSchemas]);

  useEffect(() => {
    void loadTables();
  }, [loadTables]);

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-[260px_1fr]">
      <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
        <div className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
          <select value={schema} onChange={(e) => setSchema(e.target.value)} className={cn(selectCls, "min-w-0 flex-1")}>
            {schemas.length === 0 && <option value={schema}>{schema}</option>}
            {schemas.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
          <Button type="button" variant="ghost" size="icon-xs" onClick={() => void loadTables()}>
            <RefreshCw className={cn("size-3.5 text-muted-foreground", loading && "animate-spin")} />
          </Button>
        </div>

        {err && (
          <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">{err}</div>
        )}

        <div className="max-h-[460px] overflow-y-auto py-1">
          {tables.length === 0 ? (
            <div className="px-4 py-10 text-center font-mono text-xs text-muted-foreground">no tables in this schema</div>
          ) : (
            tables.map((t) => (
              <button
                key={t.name}
                type="button"
                onClick={() => setSelected(t.name)}
                className={cn(
                  "flex w-full items-center gap-2 px-3 py-1.5 text-left",
                  selected === t.name ? "bg-primary/10" : "hover:bg-muted/40",
                )}
              >
                <TableIcon className={cn("size-3.5 shrink-0", selected === t.name ? "text-primary" : "text-muted-foreground")} />
                <span className={cn("truncate font-mono text-[13px]", selected === t.name ? "text-foreground" : "text-muted-foreground")}>
                  {t.name}
                </span>
                {t.type !== "BASE TABLE" && (
                  <span className="ml-auto rounded border border-border bg-card/60 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">
                    view
                  </span>
                )}
              </button>
            ))
          )}
        </div>
      </Card>

      {selected ? (
        <StructurePane
          key={`${schema}.${selected}`}
          port={port}
          database={database}
          schema={schema}
          table={selected}
          updatedAt={updatedAt}
        />
      ) : (
        <Card className="items-center justify-center rounded-lg border-border bg-card/50 p-0 ring-0">
          <div className="px-6 py-24 text-center font-mono text-sm text-muted-foreground">
            no table selected — pick one from the list
          </div>
        </Card>
      )}
    </div>
  );
}

function StructurePane({
  port,
  database,
  schema,
  table,
  updatedAt,
}: {
  port: number | null;
  database: string;
  schema: string;
  table: string;
  updatedAt: number | null;
}) {
  const [desc, setDesc] = useState<TableStructure | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [subTab, setSubTab] = useState<"data" | "structure">("data");

  useEffect(() => {
    if (port === null) return;
    let alive = true;
    setDesc(null);
    setErr(null);
    trpc.postgres.describeTable
      .query({ port, database, schema, table })
      .then((res) => alive && setDesc(res))
      .catch((e) => alive && setErr(e instanceof Error ? e.message : "describe failed"));
    return () => {
      alive = false;
    };
  }, [port, database, schema, table]);

  return (
    <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
      <div className="flex items-center gap-2 border-b border-border px-4 py-2">
        <div className="flex items-center gap-1">
          {(["data", "structure"] as const).map((t) => (
            <button
              key={t}
              type="button"
              onClick={() => setSubTab(t)}
              className={cn(
                "rounded px-2.5 py-1 text-[12px]",
                subTab === t ? "bg-muted text-foreground" : "text-muted-foreground hover:text-foreground",
              )}
            >
              {t}
            </button>
          ))}
        </div>
        <span className="ml-2 font-mono text-[13px] text-foreground">{schema}.{table}</span>
        {desc && (
          <span className="ml-auto flex items-center gap-3 font-mono text-[11px] text-muted-foreground">
            <span className="inline-flex items-center gap-1">
              <Key className="size-3" />
              {desc.primaryKey.length ? desc.primaryKey.join(", ") : "no pk"}
            </span>
            <span className="inline-flex items-center gap-1">
              <Hash className="size-3" />~{desc.rowEstimate} rows
            </span>
          </span>
        )}
      </div>

      {err && <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">{err}</div>}

      {!desc ? (
        <div className="px-6 py-20 text-center font-mono text-sm text-muted-foreground">{err ? "" : "loading…"}</div>
      ) : subTab === "data" && port !== null ? (
        <DataGrid
          port={port}
          database={database}
          schema={schema}
          table={table}
          columns={desc.columns}
          primaryKey={desc.primaryKey}
          onChanged={() => {}}
        />
      ) : (
        <>
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow className="border-border hover:bg-transparent">
                  <TableHead className="h-9 px-4 text-[12px] font-medium text-muted-foreground">column</TableHead>
                  <TableHead className="h-9 px-4 text-[12px] font-medium text-muted-foreground">type</TableHead>
                  <TableHead className="h-9 px-4 text-[12px] font-medium text-muted-foreground">nullable</TableHead>
                  <TableHead className="h-9 px-4 text-[12px] font-medium text-muted-foreground">default</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {desc.columns.map((c) => (
                  <TableRow key={c.name} className="border-border/60">
                    <TableCell className="px-4 font-mono text-xs text-foreground">
                      {c.name}
                      {c.isPrimaryKey && <span className="ml-1.5 text-primary">PK</span>}
                    </TableCell>
                    <TableCell className="px-4 font-mono text-xs text-muted-foreground">{c.dataType}</TableCell>
                    <TableCell className="px-4 font-mono text-xs text-muted-foreground">{c.nullable ? "yes" : "no"}</TableCell>
                    <TableCell className="px-4 font-mono text-xs text-muted-foreground">
                      {c.default ?? <span className="text-muted-foreground/50">—</span>}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>

          <div className="flex items-center justify-end border-t border-border px-4 py-2">
            <SyncStamp updatedAt={updatedAt} />
          </div>
        </>
      )}
    </Card>
  );
}
