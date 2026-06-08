"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ChevronLeft,
  ChevronRight,
  Database,
  Key,
  Layers,
  Pencil,
  Plus,
  RefreshCw,
  Sigma,
  Table as TableIcon,
  Trash2,
} from "lucide-react";

import { avPreview, type AV, type Item } from "@/lib/dynamodb-types";
import { fmtBytes, fmtNum } from "@/lib/format";
import { dynamoStatsSchema } from "@/lib/services";
import { trpc } from "@/lib/trpc";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel } from "@/components/bits";
import { SyncStamp } from "@/components/services/shared";
import { CreateTableModal } from "@/components/services/dynamodb/create";
import { ItemEditor } from "@/components/services/dynamodb/item-editor";
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

const MAX_COLS = 8;

type KeySchemaEntry = { AttributeName: string; KeyType: "HASH" | "RANGE" };
type AttrDef = { AttributeName: string; AttributeType: string };
type IndexDesc = {
  IndexName: string;
  KeySchema: KeySchemaEntry[];
  Projection: { ProjectionType: string; NonKeyAttributes?: string[] };
};
type DescribedTable = {
  TableName?: string;
  TableStatus?: string;
  KeySchema?: KeySchemaEntry[];
  AttributeDefinitions?: AttrDef[];
  GlobalSecondaryIndexes?: IndexDesc[];
  LocalSecondaryIndexes?: IndexDesc[];
  BillingModeSummary?: { BillingMode?: string };
  ItemCount?: number;
  TableSizeBytes?: number;
};

export function DynamoDetail({
  port,
  stats,
  updatedAt,
}: {
  name: string;
  port: number | null;
  stats: unknown;
  updatedAt: number | null;
}) {
  const parsed = dynamoStatsSchema.safeParse(stats);
  const totalBytes = parsed.success ? parsed.data.bytes : 0;

  const [tables, setTables] = useState<string[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [refreshNonce, setRefreshNonce] = useState(0);
  const refreshAll = useCallback(() => setRefreshNonce((n) => n + 1), []);

  const loadTables = useCallback(async () => {
    if (port === null) return;
    try {
      const res = await trpc.dynamodb.listTables.query({ port });
      setTables(res.tables);
      setErr(null);
      setSelected((cur) => (cur && res.tables.includes(cur) ? cur : res.tables[0] ?? null));
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed to list tables");
    }
  }, [port]);

  useEffect(() => {
    void loadTables();
  }, [loadTables, refreshNonce]);

  return (
    <>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <MetricTile label="Tables" value={parsed.success ? parsed.data.tables : tables.length} icon={Layers} tone="flight" />
        <MetricTile label="Items" value={parsed.success ? parsed.data.items : 0} icon={Database} tone="visible" />
        <MetricTile label="Bytes" value={totalBytes} icon={Sigma} tone="primary" hint={fmtBytes(totalBytes)} />
        <MetricTile label="Selected" value={selected ? 1 : 0} icon={TableIcon} tone="ok" hint={selected ?? "none"} />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[260px_1fr]">
        <TablePane port={port} tables={tables} selected={selected} error={err} onSelect={setSelected} onChanged={refreshAll} />
        {selected ? (
          <TableView key={selected} port={port} table={selected} updatedAt={updatedAt} />
        ) : (
          <Card className="items-center justify-center rounded-lg border-border bg-card/50 p-0 ring-0">
            <div className="px-6 py-24 text-center font-mono text-sm text-muted-foreground">
              no table selected — create one to get started
            </div>
          </Card>
        )}
      </div>
    </>
  );
}

function TablePane({
  port,
  tables,
  selected,
  error,
  onSelect,
  onChanged,
}: {
  port: number | null;
  tables: string[];
  selected: string | null;
  error: string | null;
  onSelect: (name: string) => void;
  onChanged: () => void;
}) {
  const [creating, setCreating] = useState(false);

  async function remove(table: string) {
    if (port === null) return;
    if (!window.confirm(`Delete table "${table}"? All items are lost.`)) return;
    try {
      await trpc.dynamodb.deleteTable.mutate({ port, table });
      onChanged();
    } catch (e) {
      window.alert(e instanceof Error ? e.message : "delete failed");
    }
  }

  return (
    <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <SectionLabel>Tables</SectionLabel>
        <Button type="button" variant="ghost" size="icon-xs" disabled={port === null} onClick={() => setCreating(true)}>
          <Plus className="size-3.5 text-muted-foreground" />
        </Button>
      </div>

      {error && (
        <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">{error}</div>
      )}

      <div className="max-h-[460px] overflow-y-auto py-1">
        {tables.length === 0 ? (
          <div className="px-4 py-10 text-center font-mono text-xs text-muted-foreground">no tables yet</div>
        ) : (
          tables.map((t) => (
            <div key={t} className={cn("group flex items-center gap-2 px-3 py-1.5", selected === t ? "bg-primary/10" : "hover:bg-muted/40")}>
              <button type="button" onClick={() => onSelect(t)} className="flex min-w-0 flex-1 items-center gap-2 text-left">
                <TableIcon className={cn("size-3.5 shrink-0", selected === t ? "text-primary" : "text-muted-foreground")} />
                <span className={cn("truncate font-mono text-[13px]", selected === t ? "text-foreground" : "text-muted-foreground")}>{t}</span>
              </button>
              <Button type="button" variant="ghost" size="icon-xs" className="opacity-0 transition-opacity group-hover:opacity-100" onClick={() => void remove(t)}>
                <Trash2 className="size-3 text-muted-foreground hover:text-down" />
              </Button>
            </div>
          ))
        )}
      </div>

      {creating && port !== null && (
        <CreateTableModal port={port} onClose={() => setCreating(false)} onCreated={onChanged} />
      )}
    </Card>
  );
}

function Chip({ children, tone }: { children: React.ReactNode; tone?: "primary" | "muted" }) {
  return (
    <span className={cn("rounded border px-1.5 py-0.5 font-mono text-[11px]", tone === "primary" ? "border-primary/30 bg-primary/10 text-primary" : "border-border bg-card/60 text-muted-foreground")}>
      {children}
    </span>
  );
}

function SchemaTab({ desc }: { desc: DescribedTable }) {
  const indexes = [
    ...(desc.GlobalSecondaryIndexes ?? []).map((i) => ({ ...i, kind: "GSI" as const })),
    ...(desc.LocalSecondaryIndexes ?? []).map((i) => ({ ...i, kind: "LSI" as const })),
  ];
  return (
    <div className="space-y-5 px-5 py-4">
      <div className="space-y-2">
        <SectionLabel>Key schema</SectionLabel>
        <div className="flex flex-wrap items-center gap-1.5">
          {(desc.KeySchema ?? []).map((k) => (
            <Chip key={k.AttributeName} tone="primary">
              <Key className="mr-1 inline size-3" />
              {k.AttributeName} · {k.KeyType}
            </Chip>
          ))}
          <Chip>{desc.BillingModeSummary?.BillingMode ?? "—"}</Chip>
          <Chip>{desc.TableStatus ?? "—"}</Chip>
          <Chip>{fmtNum(desc.ItemCount ?? 0)} items</Chip>
          <Chip>{fmtBytes(desc.TableSizeBytes ?? 0)}</Chip>
        </div>
      </div>

      <div className="space-y-2">
        <SectionLabel>Attributes</SectionLabel>
        <div className="flex flex-wrap gap-1.5">
          {(desc.AttributeDefinitions ?? []).map((a) => (
            <Chip key={a.AttributeName}>{a.AttributeName}: {a.AttributeType}</Chip>
          ))}
        </div>
      </div>

      {indexes.length > 0 && (
        <div className="space-y-2">
          <SectionLabel>Indexes</SectionLabel>
          <div className="grid gap-2 sm:grid-cols-2">
            {indexes.map((idx) => (
              <Card key={idx.IndexName} className="gap-2 rounded-md border-border bg-card/60 p-3 ring-0">
                <div className="flex items-center justify-between">
                  <span className="font-mono text-[13px] text-foreground">{idx.IndexName}</span>
                  <Chip>{idx.kind}</Chip>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {idx.KeySchema.map((k) => (
                    <Chip key={k.AttributeName}>{k.AttributeName} · {k.KeyType}</Chip>
                  ))}
                </div>
                <span className="font-mono text-[11px] text-muted-foreground">
                  projection: {idx.Projection.ProjectionType}
                  {idx.Projection.NonKeyAttributes?.length ? ` (${idx.Projection.NonKeyAttributes.join(", ")})` : ""}
                </span>
              </Card>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

type EditorState = { mode: "new" | "edit"; item?: Item } | null;

function ItemsTab({ port, table, desc, updatedAt }: { port: number; table: string; desc: DescribedTable; updatedAt: number | null }) {
  const keyAttrs = useMemo(() => (desc.KeySchema ?? []).map((k) => k.AttributeName), [desc]);
  const gsiNames = useMemo(() => (desc.GlobalSecondaryIndexes ?? []).map((i) => i.IndexName), [desc]);

  const [mode, setMode] = useState<"scan" | "query">("scan");
  const [indexName, setIndexName] = useState("");
  const [expr, setExpr] = useState("");
  const [valuesJson, setValuesJson] = useState("");
  const [items, setItems] = useState<Item[]>([]);
  const [pageKeys, setPageKeys] = useState<(Item | null)[]>([null]);
  const [nextKey, setNextKey] = useState<Item | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [editor, setEditor] = useState<EditorState>(null);

  const load = useCallback(
    async (startKey: Item | null) => {
      setLoading(true);
      setErr(null);
      try {
        let values: Item | undefined;
        if (valuesJson.trim() !== "") {
          values = JSON.parse(valuesJson) as Item;
        }
        const common = {
          port,
          table,
          indexName: indexName || undefined,
          expressionAttributeValues: values,
          exclusiveStartKey: startKey ?? undefined,
          limit: 100,
        };
        const res =
          mode === "query"
            ? await trpc.dynamodb.query.query({ ...common, keyConditionExpression: expr })
            : await trpc.dynamodb.scan.query({ ...common, filterExpression: expr || undefined });
        setItems(res.items as Item[]);
        setNextKey((res.lastEvaluatedKey as Item) ?? null);
      } catch (e) {
        setErr(e instanceof Error ? e.message : "request failed");
      } finally {
        setLoading(false);
      }
    },
    [port, table, mode, indexName, expr, valuesJson],
  );

  // Reset to first page and load whenever the query parameters change.
  useEffect(() => {
    setPageKeys([null]);
    void load(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [port, table, mode, indexName]);

  const submit = () => {
    setPageKeys([null]);
    void load(null);
  };

  const nextPage = () => {
    if (!nextKey) return;
    setPageKeys((p) => [...p, nextKey]);
    void load(nextKey);
  };

  const prevPage = () => {
    if (pageKeys.length <= 1) return;
    const trimmed = pageKeys.slice(0, -1);
    setPageKeys(trimmed);
    void load(trimmed[trimmed.length - 1]);
  };

  const columns = useMemo(() => {
    const names: string[] = [];
    for (const a of keyAttrs) if (!names.includes(a)) names.push(a);
    for (const it of items) for (const k of Object.keys(it)) if (!names.includes(k)) names.push(k);
    return names;
  }, [items, keyAttrs]);
  const visibleCols = columns.slice(0, MAX_COLS);
  const overflow = columns.length - visibleCols.length;

  async function remove(it: Item) {
    if (!window.confirm("Delete this item?")) return;
    try {
      const key: Item = {};
      for (const k of keyAttrs) key[k] = it[k];
      await trpc.dynamodb.deleteItem.mutate({ port, table, key });
      void load(pageKeys[pageKeys.length - 1]);
    } catch (e) {
      window.alert(e instanceof Error ? e.message : "delete failed");
    }
  }

  return (
    <div className="space-y-0">
      <div className="flex flex-wrap items-center gap-2 border-b border-border px-4 py-3">
        <div className="flex overflow-hidden rounded-md border border-border">
          {(["scan", "query"] as const).map((m) => (
            <button
              key={m}
              type="button"
              onClick={() => setMode(m)}
              className={cn("px-2.5 py-1 text-[12px]", mode === m ? "bg-primary/15 text-primary" : "text-muted-foreground hover:text-foreground")}
            >
              {m}
            </button>
          ))}
        </div>

        {gsiNames.length > 0 && (
          <select value={indexName} onChange={(e) => setIndexName(e.target.value)} className="h-8 rounded-md border border-border bg-card/60 px-2 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30">
            <option value="">(table)</option>
            {gsiNames.map((n) => (
              <option key={n} value={n}>{n}</option>
            ))}
          </select>
        )}

        <input
          value={expr}
          onChange={(e) => setExpr(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()}
          placeholder={mode === "query" ? "KeyConditionExpression e.g. id = :id" : "FilterExpression (optional)"}
          spellCheck={false}
          className="h-8 min-w-[220px] flex-1 rounded-md border border-border bg-card/60 px-2.5 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30"
        />

        <Button type="button" variant="ghost" size="icon-xs" onClick={() => void load(pageKeys[pageKeys.length - 1])}>
          <RefreshCw className={cn("size-3.5 text-muted-foreground", loading && "animate-spin")} />
        </Button>
        <Button type="button" variant="outline" size="xs" onClick={submit}>
          Run
        </Button>
        <Button type="button" size="xs" onClick={() => setEditor({ mode: "new" })}>
          <Plus className="size-3.5" />
          New
        </Button>
      </div>

      <div className="border-b border-border px-4 py-2">
        <input
          value={valuesJson}
          onChange={(e) => setValuesJson(e.target.value)}
          placeholder={'ExpressionAttributeValues JSON e.g. {":id":{"S":"abc"}}'}
          spellCheck={false}
          className="h-7 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[11px] text-muted-foreground outline-none focus:border-foreground/30"
        />
      </div>

      {err && <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">{err}</div>}

      {items.length === 0 ? (
        <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">no items</div>
      ) : (
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow className="border-border hover:bg-transparent">
                {visibleCols.map((c) => (
                  <TableHead key={c} className="h-9 px-4 text-[12px] font-medium text-muted-foreground">
                    {c}
                    {keyAttrs.includes(c) && <span className="ml-1 text-primary">*</span>}
                  </TableHead>
                ))}
                {overflow > 0 && <TableHead className="h-9 px-4 font-mono text-[10px] text-muted-foreground">+{overflow}</TableHead>}
                <TableHead className="h-9 w-[80px] px-4" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.map((it, i) => (
                <TableRow key={i} className="cursor-pointer border-border/60" onClick={() => setEditor({ mode: "edit", item: it })}>
                  {visibleCols.map((c) => (
                    <TableCell key={c} className="px-4 font-mono text-xs text-foreground">
                      {it[c] ? avPreview(it[c] as AV) : <span className="text-muted-foreground">—</span>}
                    </TableCell>
                  ))}
                  {overflow > 0 && <TableCell className="px-4 text-muted-foreground">…</TableCell>}
                  <TableCell className="px-4">
                    <div className="flex items-center justify-end gap-1" onClick={(e) => e.stopPropagation()}>
                      <Button type="button" variant="ghost" size="icon-xs" onClick={() => setEditor({ mode: "edit", item: it })}>
                        <Pencil className="size-3 text-muted-foreground" />
                      </Button>
                      <Button type="button" variant="ghost" size="icon-xs" onClick={() => void remove(it)}>
                        <Trash2 className="size-3 text-muted-foreground hover:text-down" />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <div className="flex items-center justify-between border-t border-border px-4 py-2">
        <span className="font-mono text-[11px] text-muted-foreground">
          page {pageKeys.length} · {fmtNum(items.length)} items
        </span>
        <div className="flex items-center gap-2">
          <Button type="button" variant="ghost" size="icon-xs" disabled={pageKeys.length <= 1} onClick={prevPage}>
            <ChevronLeft className="size-3.5 text-muted-foreground" />
          </Button>
          <Button type="button" variant="ghost" size="icon-xs" disabled={!nextKey} onClick={nextPage}>
            <ChevronRight className="size-3.5 text-muted-foreground" />
          </Button>
          <SyncStamp updatedAt={updatedAt} />
        </div>
      </div>

      {editor && (
        <ItemEditor
          port={port}
          table={table}
          mode={editor.mode}
          initial={editor.item}
          keyAttrs={keyAttrs}
          onClose={() => setEditor(null)}
          onSaved={() => void load(pageKeys[pageKeys.length - 1])}
        />
      )}
    </div>
  );
}

function TableView({ port, table, updatedAt }: { port: number | null; table: string; updatedAt: number | null }) {
  const [tab, setTab] = useState<"schema" | "items">("items");
  const [desc, setDesc] = useState<DescribedTable | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (port === null) return;
    let alive = true;
    setDesc(null);
    setErr(null);
    trpc.dynamodb.describeTable
      .query({ port, table })
      .then((res) => alive && setDesc(res.table as DescribedTable))
      .catch((e) => alive && setErr(e instanceof Error ? e.message : "describe failed"));
    return () => {
      alive = false;
    };
  }, [port, table]);

  return (
    <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
      <div className="flex items-center gap-1 border-b border-border px-4 py-2">
        {(["items", "schema"] as const).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={cn("rounded px-2.5 py-1 text-[12px]", tab === t ? "bg-muted text-foreground" : "text-muted-foreground hover:text-foreground")}
          >
            {t}
          </button>
        ))}
        <span className="ml-auto font-mono text-[13px] text-foreground">{table}</span>
      </div>

      {err && <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">{err}</div>}

      {!desc ? (
        <div className="px-6 py-20 text-center font-mono text-sm text-muted-foreground">{err ? "" : "loading…"}</div>
      ) : tab === "schema" ? (
        <SchemaTab desc={desc} />
      ) : port !== null ? (
        <ItemsTab port={port} table={table} desc={desc} updatedAt={updatedAt} />
      ) : null}
    </Card>
  );
}
