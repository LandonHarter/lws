"use client";

import { useState } from "react";
import { Plus, Trash2, X } from "lucide-react";

import {
  AV_TYPES,
  attributeFromForm,
  emptyForm,
  formFromAttribute,
  validateForm,
  type AVType,
  type FormNode,
  type Item,
} from "@/lib/dynamodb-types";
import { trpc } from "@/lib/trpc";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";

const inputCls =
  "h-8 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-foreground/30";

type Entry = { id: string; key: string; value: FormNode };

let seq = 0;
function nextId() {
  seq += 1;
  return `n${seq}`;
}

function TypeSelect({ value, onChange }: { value: AVType; onChange: (t: AVType) => void }) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value as AVType)}
      className="h-8 shrink-0 rounded-md border border-border bg-card/60 px-1.5 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30"
    >
      {AV_TYPES.map((t) => (
        <option key={t} value={t}>
          {t}
        </option>
      ))}
    </select>
  );
}

function ChipSet({ node, onChange }: { node: Extract<FormNode, { type: "SS" | "NS" | "BS" }>; onChange: (n: FormNode) => void }) {
  const [draft, setDraft] = useState("");
  const add = () => {
    const v = draft.trim();
    if (v === "") return;
    onChange({ ...node, items: [...node.items, v] });
    setDraft("");
  };
  return (
    <div className="flex-1 space-y-1.5">
      <div className="flex flex-wrap gap-1.5">
        {node.items.map((it, i) => (
          <span key={i} className="flex items-center gap-1 rounded border border-border bg-card/60 px-1.5 py-0.5 font-mono text-[12px] text-foreground">
            {it}
            <button type="button" onClick={() => onChange({ ...node, items: node.items.filter((_, j) => j !== i) })}>
              <X className="size-3 text-muted-foreground hover:text-down" />
            </button>
          </span>
        ))}
      </div>
      <div className="flex gap-1.5">
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), add())}
          placeholder="add element"
          className={inputCls}
        />
        <Button type="button" variant="outline" size="icon-sm" onClick={add}>
          <Plus className="size-3.5" />
        </Button>
      </div>
    </div>
  );
}

function AttributeEditor({ node, onChange }: { node: FormNode; onChange: (n: FormNode) => void }) {
  const changeType = (t: AVType) => {
    if (t === node.type) return;
    onChange(emptyForm(t));
  };

  return (
    <div className="flex flex-1 items-start gap-2">
      <TypeSelect value={node.type} onChange={changeType} />
      <div className="flex-1">
        {(node.type === "S" || node.type === "N") && (
          <input value={node.value} onChange={(e) => onChange({ ...node, value: e.target.value })} placeholder={node.type === "N" ? "123" : "text"} className={inputCls} />
        )}
        {node.type === "B" && (
          <textarea
            value={node.value}
            onChange={(e) => onChange({ ...node, value: e.target.value })}
            rows={2}
            placeholder="base64"
            spellCheck={false}
            className="w-full resize-y rounded-md border border-border bg-card/60 px-2.5 py-1.5 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30"
          />
        )}
        {node.type === "BOOL" && (
          <button
            type="button"
            role="switch"
            aria-checked={node.value}
            onClick={() => onChange({ ...node, value: !node.value })}
            className={cn(
              "relative inline-flex h-5 w-9 items-center rounded-full border transition-colors",
              node.value ? "border-primary/40 bg-primary/30" : "border-border bg-card",
            )}
          >
            <span className={cn("inline-block size-3.5 rounded-full bg-foreground transition-transform", node.value ? "translate-x-4" : "translate-x-0.5")} />
          </button>
        )}
        {node.type === "NULL" && <span className="font-mono text-[12px] text-muted-foreground">(null)</span>}
        {(node.type === "SS" || node.type === "NS" || node.type === "BS") && <ChipSet node={node} onChange={onChange} />}
        {node.type === "L" && <ListEditor node={node} onChange={onChange} />}
        {node.type === "M" && <MapEditor node={node} onChange={onChange} />}
      </div>
    </div>
  );
}

function ListEditor({ node, onChange }: { node: Extract<FormNode, { type: "L" }>; onChange: (n: FormNode) => void }) {
  return (
    <div className="space-y-2 rounded-md border border-border/60 bg-card/40 p-2">
      {node.items.map((it, i) => (
        <div key={i} className="flex items-start gap-2">
          <span className="mt-1.5 font-mono text-[11px] text-muted-foreground">{i}</span>
          <AttributeEditor node={it} onChange={(n) => onChange({ ...node, items: node.items.map((x, j) => (j === i ? n : x)) })} />
          <Button type="button" variant="ghost" size="icon-sm" onClick={() => onChange({ ...node, items: node.items.filter((_, j) => j !== i) })}>
            <Trash2 className="size-3.5 text-muted-foreground hover:text-down" />
          </Button>
        </div>
      ))}
      <Button type="button" variant="outline" size="xs" onClick={() => onChange({ ...node, items: [...node.items, emptyForm("S")] })}>
        <Plus className="size-3" />
        item
      </Button>
    </div>
  );
}

function MapEditor({ node, onChange }: { node: Extract<FormNode, { type: "M" }>; onChange: (n: FormNode) => void }) {
  return (
    <div className="space-y-2 rounded-md border border-border/60 bg-card/40 p-2">
      {node.entries.map((ent, i) => (
        <div key={i} className="flex items-start gap-2">
          <input
            value={ent.key}
            onChange={(e) => onChange({ ...node, entries: node.entries.map((x, j) => (j === i ? { ...x, key: e.target.value } : x)) })}
            placeholder="key"
            className={cn(inputCls, "w-32 shrink-0")}
          />
          <AttributeEditor node={ent.value} onChange={(n) => onChange({ ...node, entries: node.entries.map((x, j) => (j === i ? { ...x, value: n } : x)) })} />
          <Button type="button" variant="ghost" size="icon-sm" onClick={() => onChange({ ...node, entries: node.entries.filter((_, j) => j !== i) })}>
            <Trash2 className="size-3.5 text-muted-foreground hover:text-down" />
          </Button>
        </div>
      ))}
      <Button type="button" variant="outline" size="xs" onClick={() => onChange({ ...node, entries: [...node.entries, { key: "", value: emptyForm("S") }] })}>
        <Plus className="size-3" />
        entry
      </Button>
    </div>
  );
}

function entriesFromItem(item: Item): Entry[] {
  return Object.entries(item).map(([key, av]) => ({ id: nextId(), key, value: formFromAttribute(av) }));
}

function itemFromEntries(entries: Entry[]): Item {
  const out: Item = {};
  for (const e of entries) out[e.key] = attributeFromForm(e.value);
  return out;
}

// Build an UpdateItem expression from the diff between the original item and the
// edited one, excluding key attributes (those go in Key).
function buildUpdate(
  before: Item,
  after: Item,
  keyAttrs: string[],
): { updateExpression: string; names: Record<string, string>; values: Record<string, unknown> } | null {
  const names: Record<string, string> = {};
  const values: Record<string, unknown> = {};
  const sets: string[] = [];
  const removes: string[] = [];
  let n = 0;
  const ref = (attr: string) => {
    const k = `#a${n}`;
    names[k] = attr;
    return k;
  };

  for (const [attr, av] of Object.entries(after)) {
    if (keyAttrs.includes(attr)) continue;
    const prev = before[attr];
    if (prev === undefined || JSON.stringify(prev) !== JSON.stringify(av)) {
      const nameRef = ref(attr);
      const valRef = `:v${n}`;
      values[valRef] = av;
      sets.push(`${nameRef} = ${valRef}`);
      n += 1;
    }
  }
  for (const attr of Object.keys(before)) {
    if (keyAttrs.includes(attr) || attr in after) continue;
    removes.push(ref(attr));
    n += 1;
  }

  if (sets.length === 0 && removes.length === 0) return null;
  const parts: string[] = [];
  if (sets.length) parts.push(`SET ${sets.join(", ")}`);
  if (removes.length) parts.push(`REMOVE ${removes.join(", ")}`);
  return { updateExpression: parts.join(" "), names, values };
}

export function ItemEditor({
  port,
  table,
  mode,
  initial,
  keyAttrs,
  onClose,
  onSaved,
}: {
  port: number;
  table: string;
  mode: "new" | "edit";
  initial?: Item;
  keyAttrs: string[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [entries, setEntries] = useState<Entry[]>(() => (initial ? entriesFromItem(initial) : []));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  function validate(): string | null {
    const seen = new Set<string>();
    for (const e of entries) {
      if (e.key.trim() === "") return "attribute name required";
      if (seen.has(e.key)) return `duplicate attribute "${e.key}"`;
      seen.add(e.key);
      const v = validateForm(e.value);
      if (v) return `${e.key}: ${v}`;
    }
    for (const k of keyAttrs) if (!seen.has(k)) return `key attribute "${k}" required`;
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
      const item = itemFromEntries(entries);
      if (mode === "edit" && initial) {
        const key: Item = {};
        for (const k of keyAttrs) key[k] = item[k];
        const upd = buildUpdate(initial, item, keyAttrs);
        if (upd) {
          await trpc.dynamodb.updateItem.mutate({
            port,
            table,
            key,
            updateExpression: upd.updateExpression,
            expressionAttributeNames: upd.names,
            expressionAttributeValues: upd.values as Item,
          });
        }
      } else {
        await trpc.dynamodb.putItem.mutate({ port, table, item });
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
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-background/70 p-6 backdrop-blur-sm" onClick={onClose}>
      <div
        className="my-4 w-full max-w-2xl rounded-lg border border-border bg-card shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <span className="font-mono text-[11px] uppercase tracking-[0.2em] text-muted-foreground">
            {mode === "new" ? "New item" : "Edit item"} · {table}
          </span>
          <Button type="button" variant="ghost" size="icon-sm" onClick={onClose}>
            <X className="size-4 text-muted-foreground" />
          </Button>
        </div>

        <div className="max-h-[60vh] space-y-2 overflow-y-auto px-5 py-4">
          {entries.length === 0 && (
            <div className="py-6 text-center font-mono text-xs text-muted-foreground">no attributes — add one</div>
          )}
          {entries.map((ent, i) => {
            const isKey = keyAttrs.includes(ent.key);
            return (
              <div key={ent.id} className="flex items-start gap-2 border-b border-border/40 pb-2">
                <input
                  value={ent.key}
                  onChange={(e) => setEntries((es) => es.map((x) => (x.id === ent.id ? { ...x, key: e.target.value } : x)))}
                  placeholder="name"
                  className={cn(inputCls, "w-36 shrink-0", isKey && "border-primary/40")}
                />
                <AttributeEditor
                  node={ent.value}
                  onChange={(n) => setEntries((es) => es.map((x) => (x.id === ent.id ? { ...x, value: n } : x)))}
                />
                <Button type="button" variant="ghost" size="icon-sm" onClick={() => setEntries((es) => es.filter((x) => x.id !== ent.id))}>
                  <Trash2 className="size-3.5 text-muted-foreground hover:text-down" />
                </Button>
              </div>
            );
          })}
          <Button type="button" variant="outline" size="xs" onClick={() => setEntries((es) => [...es, { id: nextId(), key: "", value: emptyForm("S") }])}>
            <Plus className="size-3" />
            attribute
          </Button>
        </div>

        {err && <div className="border-t border-down/20 bg-down/10 px-5 py-2 font-mono text-[11px] text-down">{err}</div>}

        <div className="flex items-center justify-end gap-2 border-t border-border px-5 py-3">
          <Button type="button" variant="ghost" size="sm" onClick={onClose}>
            Cancel
          </Button>
          <Button type="button" size="sm" disabled={busy} onClick={() => void save()}>
            {busy ? "saving…" : "Save"}
          </Button>
        </div>
      </div>
    </div>
  );
}
