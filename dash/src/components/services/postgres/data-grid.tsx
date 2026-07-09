"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  Pencil,
  Plus,
  RefreshCw,
  Trash2,
} from "lucide-react";

import { fmtNum } from "@/lib/format";
import { trpc } from "@/lib/trpc";
import { cn } from "@/lib/utils";
import { PgCell } from "@/components/services/postgres/cell";
import { RowEditor } from "@/components/services/postgres/row-editor";
import { type PgColumn, type Row } from "@/components/services/postgres/types";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const PAGE_SIZES = [25, 100, 500] as const;

type OrderDir = "asc" | "desc";
type EditorState = { mode: "new" | "edit"; row?: Row } | null;

export function DataGrid({
  port,
  database,
  schema,
  table,
  columns,
  primaryKey,
  onChanged,
}: {
  port: number;
  database: string;
  schema: string;
  table: string;
  columns: PgColumn[];
  primaryKey: string[];
  onChanged: () => void;
}) {
  const [rows, setRows] = useState<Row[]>([]);
  const [total, setTotal] = useState(0);
  const [limit, setLimit] = useState<number>(100);
  const [offset, setOffset] = useState(0);
  const [orderBy, setOrderBy] = useState<string | undefined>(undefined);
  const [orderDir, setOrderDir] = useState<OrderDir>("asc");
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [editor, setEditor] = useState<EditorState>(null);

  const hasPk = primaryKey.length > 0;

  const load = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const res = await trpc.postgres.tableRows.query({
        port,
        database,
        schema,
        table,
        limit,
        offset,
        orderBy,
        orderDir,
      });
      setRows(res.rows);
      setTotal(res.total);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed to load rows");
    } finally {
      setLoading(false);
    }
  }, [port, database, schema, table, limit, offset, orderBy, orderDir]);

  useEffect(() => {
    void load();
  }, [load]);

  const toggleSort = (col: string) => {
    setOffset(0);
    if (orderBy !== col) {
      setOrderBy(col);
      setOrderDir("asc");
    } else if (orderDir === "asc") {
      setOrderDir("desc");
    } else {
      setOrderBy(undefined);
      setOrderDir("asc");
    }
  };

  const refreshAfterMutation = useCallback(() => {
    void load();
    onChanged();
  }, [load, onChanged]);

  async function remove(row: Row) {
    if (!hasPk) return;
    if (!window.confirm("Delete this row?")) return;
    try {
      const key: Row = {};
      for (const col of primaryKey) key[col] = row[col];
      await trpc.postgres.deleteRow.mutate({ port, database, schema, table, key });
      refreshAfterMutation();
    } catch (e) {
      window.alert(e instanceof Error ? e.message : "delete failed");
    }
  }

  const page = Math.floor(offset / limit) + 1;
  const pageCount = Math.max(1, Math.ceil(total / limit));
  const from = total === 0 ? 0 : offset + 1;
  const to = Math.min(offset + rows.length, total);

  const pkTooltip = "no primary key — edit via the Query tab";

  const editorInitial = useMemo(
    () => (editor?.mode === "edit" ? editor.row : undefined),
    [editor],
  );

  return (
    <div className="space-y-0">
      <div className="flex flex-wrap items-center gap-2 border-b border-border px-4 py-3">
        <span className="font-mono text-[12px] text-muted-foreground">
          {fmtNum(total)} rows
        </span>
        <div className="ml-auto flex items-center gap-2">
          <select
            value={limit}
            onChange={(e) => {
              setLimit(Number(e.target.value));
              setOffset(0);
            }}
            className="h-8 rounded-md border border-border bg-card/60 px-2 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30"
          >
            {PAGE_SIZES.map((s) => (
              <option key={s} value={s}>
                {s} / page
              </option>
            ))}
          </select>
          <Button type="button" variant="ghost" size="icon-xs" onClick={() => void load()}>
            <RefreshCw className={cn("size-3.5 text-muted-foreground", loading && "animate-spin")} />
          </Button>
          <Button type="button" size="xs" onClick={() => setEditor({ mode: "new" })}>
            <Plus className="size-3.5" />
            Insert
          </Button>
        </div>
      </div>

      {err && <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">{err}</div>}

      {columns.length === 0 ? (
        <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">no columns</div>
      ) : rows.length === 0 ? (
        <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">{loading ? "loading…" : "no rows"}</div>
      ) : (
        <div className="max-h-[520px] overflow-auto">
          <Table>
            <TableHeader>
              <TableRow className="border-border hover:bg-transparent">
                {columns.map((c) => (
                  <TableHead
                    key={c.name}
                    className="h-9 cursor-pointer px-4 text-[12px] font-medium text-muted-foreground select-none hover:text-foreground"
                    onClick={() => toggleSort(c.name)}
                  >
                    <span className="inline-flex items-center gap-1">
                      {c.name}
                      {c.isPrimaryKey && <span className="text-primary">PK</span>}
                      {orderBy === c.name &&
                        (orderDir === "asc" ? (
                          <ChevronUp className="size-3" />
                        ) : (
                          <ChevronDown className="size-3" />
                        ))}
                    </span>
                  </TableHead>
                ))}
                <TableHead className="h-9 w-[80px] px-4" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, i) => (
                <TableRow key={i} className="border-border/60">
                  {columns.map((c) => (
                    <TableCell key={c.name} className="px-4">
                      <PgCell value={row[c.name]} />
                    </TableCell>
                  ))}
                  <TableCell className="px-4">
                    <div className="flex items-center justify-end gap-1">
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-xs"
                        disabled={!hasPk}
                        title={hasPk ? "edit" : pkTooltip}
                        onClick={() => setEditor({ mode: "edit", row })}
                      >
                        <Pencil className="size-3 text-muted-foreground" />
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-xs"
                        disabled={!hasPk}
                        title={hasPk ? "delete" : pkTooltip}
                        onClick={() => void remove(row)}
                      >
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
          {from}–{to} of {fmtNum(total)} · page {page}/{pageCount}
        </span>
        <div className="flex items-center gap-2">
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            disabled={offset === 0}
            onClick={() => setOffset((o) => Math.max(0, o - limit))}
          >
            <ChevronLeft className="size-3.5 text-muted-foreground" />
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            disabled={offset + limit >= total}
            onClick={() => setOffset((o) => o + limit)}
          >
            <ChevronRight className="size-3.5 text-muted-foreground" />
          </Button>
        </div>
      </div>

      {editor && (
        <RowEditor
          port={port}
          database={database}
          schema={schema}
          table={table}
          mode={editor.mode}
          columns={columns}
          primaryKey={primaryKey}
          initial={editorInitial}
          onClose={() => setEditor(null)}
          onSaved={refreshAfterMutation}
        />
      )}
    </div>
  );
}
