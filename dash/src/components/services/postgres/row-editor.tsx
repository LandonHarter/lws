"use client";

import { useState } from "react";
import { X } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { cn } from "@/lib/utils";
import { type PgColumn, type Row } from "@/components/services/postgres/types";
import { Button } from "@/components/ui/button";

const inputCls =
  "h-8 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-foreground/30 disabled:opacity-50";

type FieldKind = "boolean" | "number" | "json" | "datetime" | "text";

function classify(dataType: string): FieldKind {
  const t = dataType.toLowerCase();
  if (t === "boolean") return "boolean";
  if (
    t === "integer" ||
    t === "bigint" ||
    t === "smallint" ||
    t === "numeric" ||
    t === "decimal" ||
    t === "real" ||
    t === "double precision"
  ) {
    return "number";
  }
  if (t === "json" || t === "jsonb") return "json";
  if (t.startsWith("date") || t.startsWith("timestamp") || t.startsWith("time")) return "datetime";
  return "text";
}

function datetimeHint(dataType: string): string {
  const t = dataType.toLowerCase();
  if (t === "date") return "YYYY-MM-DD";
  if (t.startsWith("time ") || t === "time") return "HH:MM:SS";
  return "YYYY-MM-DD HH:MM:SS";
}

type FieldState = { value: string; isNull: boolean; touched: boolean };

function initialFor(col: PgColumn, initial: Row | undefined): FieldState {
  if (!initial) return { value: "", isNull: false, touched: false };
  const raw = initial[col.name];
  if (raw === null || raw === undefined) return { value: "", isNull: true, touched: false };
  if (typeof raw === "object") return { value: JSON.stringify(raw), isNull: false, touched: false };
  if (typeof raw === "boolean") return { value: raw ? "true" : "false", isNull: false, touched: false };
  return { value: String(raw), isNull: false, touched: false };
}

// Turn a field's string form into the JS value sent as a $n parameter. json is
// parsed (validated by the caller); numbers/dates ride as strings so Postgres
// casts them and bigint/numeric precision survives.
function serialize(col: PgColumn, st: FieldState): unknown {
  if (st.isNull) return null;
  const kind = classify(col.dataType);
  if (kind === "boolean") return st.value === "true";
  if (kind === "json") return JSON.parse(st.value);
  return st.value;
}

export function RowEditor({
  port,
  database,
  schema,
  table,
  mode,
  columns,
  primaryKey,
  initial,
  onClose,
  onSaved,
}: {
  port: number;
  database: string;
  schema: string;
  table: string;
  mode: "new" | "edit";
  columns: PgColumn[];
  primaryKey: string[];
  initial?: Row;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [fields, setFields] = useState<Record<string, FieldState>>(() => {
    const out: Record<string, FieldState> = {};
    for (const c of columns) out[c.name] = initialFor(c, initial);
    return out;
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const setField = (name: string, patch: Partial<FieldState>) =>
    setFields((f) => ({ ...f, [name]: { ...f[name], ...patch, touched: true } }));

  function validate(): string | null {
    for (const c of columns) {
      const st = fields[c.name];
      const isPk = primaryKey.includes(c.name);
      if (mode === "edit" && isPk) continue;
      const included = mode === "edit" ? st.touched : st.touched || st.isNull;

      if (st.isNull && !c.nullable) return `${c.name}: column is not nullable`;

      if (mode === "new" && !included) {
        if (!c.nullable && c.default === null) return `${c.name}: value required`;
        continue;
      }
      if (mode === "edit" && !included) continue;
      if (st.isNull) continue;

      const kind = classify(c.dataType);
      if (kind === "json") {
        try {
          JSON.parse(st.value);
        } catch {
          return `${c.name}: invalid JSON`;
        }
      }
      if (kind === "number" && st.value.trim() === "") return `${c.name}: value required`;
    }
    return null;
  }

  async function save() {
    const ve = validate();
    if (ve) {
      setErr(ve);
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      if (mode === "new") {
        const values: Row = {};
        for (const c of columns) {
          const st = fields[c.name];
          if (!(st.touched || st.isNull)) continue;
          values[c.name] = serialize(c, st);
        }
        await trpc.postgres.insertRow.mutate({ port, database, schema, table, values });
      } else {
        const key: Row = {};
        for (const col of primaryKey) key[col] = initial?.[col];
        const changes: Row = {};
        for (const c of columns) {
          if (primaryKey.includes(c.name)) continue;
          const st = fields[c.name];
          if (!st.touched) continue;
          changes[c.name] = serialize(c, st);
        }
        if (Object.keys(changes).length === 0) {
          onClose();
          return;
        }
        await trpc.postgres.updateRow.mutate({ port, database, schema, table, key, changes });
      }
      onSaved();
      onClose();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-background/70 p-6 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="my-4 w-full max-w-2xl rounded-lg border border-border bg-card shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <span className="text-[13px] font-medium text-foreground">
            {mode === "new" ? "New row" : "Edit row"} · {schema}.{table}
          </span>
          <Button type="button" variant="ghost" size="icon-sm" onClick={onClose}>
            <X className="size-4 text-muted-foreground" />
          </Button>
        </div>

        <div className="max-h-[60vh] space-y-3 overflow-y-auto px-5 py-4">
          {columns.map((c) => {
            const st = fields[c.name];
            const isPk = primaryKey.includes(c.name);
            const readOnly = mode === "edit" && isPk;
            const kind = classify(c.dataType);
            return (
              <div key={c.name} className="space-y-1.5">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-mono text-[12px] text-foreground">
                    {c.name}
                    {isPk && <span className="ml-1 text-primary">PK</span>}
                    <span className="ml-2 text-[11px] text-muted-foreground">{c.dataType}</span>
                  </span>
                  {c.nullable && !readOnly && (
                    <label className="flex items-center gap-1.5 font-mono text-[11px] text-muted-foreground">
                      <input
                        type="checkbox"
                        checked={st.isNull}
                        onChange={(e) => setField(c.name, { isNull: e.target.checked })}
                      />
                      NULL
                    </label>
                  )}
                </div>

                {kind === "boolean" ? (
                  <select
                    value={st.value === "" ? "false" : st.value}
                    disabled={readOnly || st.isNull}
                    onChange={(e) => setField(c.name, { value: e.target.value })}
                    className={inputCls}
                  >
                    <option value="true">true</option>
                    <option value="false">false</option>
                  </select>
                ) : kind === "json" ? (
                  <textarea
                    value={st.value}
                    disabled={readOnly || st.isNull}
                    onChange={(e) => setField(c.name, { value: e.target.value })}
                    rows={3}
                    spellCheck={false}
                    placeholder="{ }"
                    className="w-full resize-y rounded-md border border-border bg-card/60 px-2.5 py-1.5 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30 disabled:opacity-50"
                  />
                ) : (
                  <input
                    type={kind === "number" ? "number" : "text"}
                    value={st.value}
                    disabled={readOnly || st.isNull}
                    onChange={(e) => setField(c.name, { value: e.target.value })}
                    placeholder={
                      kind === "datetime"
                        ? datetimeHint(c.dataType)
                        : c.default !== null && mode === "new"
                          ? `default: ${c.default}`
                          : ""
                    }
                    spellCheck={false}
                    className={cn(inputCls, kind === "number" && "tabular-nums")}
                  />
                )}
              </div>
            );
          })}
        </div>

        {err && <div className="border-t border-down/20 bg-down/10 px-5 py-2 font-mono text-[11px] text-down">{err}</div>}

        <div className="flex items-center justify-end gap-2 border-t border-border px-5 py-3">
          <Button type="button" variant="ghost" size="sm" onClick={onClose}>
            Cancel
          </Button>
          <Button type="button" size="sm" disabled={busy} onClick={() => void save()}>
            {busy ? "saving…" : mode === "new" ? "Insert" : "Save"}
          </Button>
        </div>
      </div>
    </div>
  );
}
