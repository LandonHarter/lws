"use client";

import { useEffect, useState } from "react";
import { Plus, Trash2, X } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { cn } from "@/lib/utils";
import { SectionLabel } from "@/components/bits";
import { type ServiceCreateFieldsProps } from "@/components/services/shared";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

const inputCls =
  "h-8 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-foreground/30";

const KEY_TYPES = ["S", "N", "B"] as const;
type KeyType = (typeof KEY_TYPES)[number];

type KeySpec = { name: string; type: KeyType };
type GsiDraft = {
  id: string;
  name: string;
  partition: KeySpec;
  sort: KeySpec | null;
  projection: "ALL" | "KEYS_ONLY" | "INCLUDE";
  include: string;
};

let seq = 0;
function nextId() {
  seq += 1;
  return `g${seq}`;
}

function KeyTypeSelect({ value, onChange }: { value: KeyType; onChange: (t: KeyType) => void }) {
  return (
    <select value={value} onChange={(e) => onChange(e.target.value as KeyType)} className="h-8 shrink-0 rounded-md border border-border bg-card/60 px-2 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30">
      {KEY_TYPES.map((t) => (
        <option key={t} value={t}>
          {t}
        </option>
      ))}
    </select>
  );
}

type Body = {
  TableName: string;
  AttributeDefinitions: { AttributeName: string; AttributeType: KeyType }[];
  KeySchema: { AttributeName: string; KeyType: "HASH" | "RANGE" }[];
  BillingMode: "PROVISIONED" | "PAY_PER_REQUEST";
  GlobalSecondaryIndexes?: {
    IndexName: string;
    KeySchema: { AttributeName: string; KeyType: "HASH" | "RANGE" }[];
    Projection: { ProjectionType: "ALL" | "KEYS_ONLY" | "INCLUDE"; NonKeyAttributes?: string[] };
  }[];
};

function buildBody(
  name: string,
  pk: KeySpec,
  sk: KeySpec | null,
  gsis: GsiDraft[],
  billing: "PROVISIONED" | "PAY_PER_REQUEST",
): { body: Body | null; error: string | null } {
  if (name.trim() === "") return { body: null, error: "table name required" };
  if (pk.name.trim() === "") return { body: null, error: "partition key name required" };

  const defs = new Map<string, KeyType>();
  const addDef = (k: KeySpec): string | null => {
    const nm = k.name.trim();
    if (nm === "") return "key attribute name required";
    const existing = defs.get(nm);
    if (existing && existing !== k.type) return `attribute "${nm}" has conflicting types`;
    defs.set(nm, k.type);
    return null;
  };

  let e = addDef(pk);
  if (e) return { body: null, error: e };
  if (sk) {
    e = addDef(sk);
    if (e) return { body: null, error: e };
  }

  const keySchema: { AttributeName: string; KeyType: "HASH" | "RANGE" }[] = [
    { AttributeName: pk.name.trim(), KeyType: "HASH" },
  ];
  if (sk) keySchema.push({ AttributeName: sk.name.trim(), KeyType: "RANGE" });

  const gsiOut: NonNullable<Body["GlobalSecondaryIndexes"]> = [];
  const gsiNames = new Set<string>();
  for (const g of gsis) {
    if (g.name.trim() === "") return { body: null, error: "GSI name required" };
    if (gsiNames.has(g.name.trim())) return { body: null, error: `duplicate GSI "${g.name.trim()}"` };
    gsiNames.add(g.name.trim());
    e = addDef(g.partition);
    if (e) return { body: null, error: e };
    const ks: { AttributeName: string; KeyType: "HASH" | "RANGE" }[] = [
      { AttributeName: g.partition.name.trim(), KeyType: "HASH" },
    ];
    if (g.sort) {
      e = addDef(g.sort);
      if (e) return { body: null, error: e };
      ks.push({ AttributeName: g.sort.name.trim(), KeyType: "RANGE" });
    }
    const projection: NonNullable<Body["GlobalSecondaryIndexes"]>[number]["Projection"] = { ProjectionType: g.projection };
    if (g.projection === "INCLUDE") {
      const attrs = g.include.split(",").map((s) => s.trim()).filter(Boolean);
      if (attrs.length === 0) return { body: null, error: `GSI "${g.name.trim()}" needs INCLUDE attributes` };
      projection.NonKeyAttributes = attrs;
    }
    gsiOut.push({ IndexName: g.name.trim(), KeySchema: ks, Projection: projection });
  }

  const body: Body = {
    TableName: name.trim(),
    AttributeDefinitions: [...defs].map(([AttributeName, AttributeType]) => ({ AttributeName, AttributeType })),
    KeySchema: keySchema,
    BillingMode: billing,
  };
  if (gsiOut.length) body.GlobalSecondaryIndexes = gsiOut;
  return { body, error: null };
}

// Reusable create-table modal, used by the detail page's table pane.
export function CreateTableModal({
  port,
  onClose,
  onCreated,
}: {
  port: number;
  onClose: () => void;
  onCreated: (name: string) => void;
}) {
  const [name, setName] = useState("");
  const [pk, setPk] = useState<KeySpec>({ name: "", type: "S" });
  const [hasSort, setHasSort] = useState(false);
  const [sk, setSk] = useState<KeySpec>({ name: "", type: "S" });
  const [gsis, setGsis] = useState<GsiDraft[]>([]);
  const [billing, setBilling] = useState<"PROVISIONED" | "PAY_PER_REQUEST">("PAY_PER_REQUEST");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function create() {
    const { body, error } = buildBody(name, pk, hasSort ? sk : null, gsis, billing);
    if (error || !body) {
      setErr(error);
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      await trpc.dynamodb.createTable.mutate({ port, ...body });
      onCreated(body.TableName);
      onClose();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "create failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-background/70 p-6 backdrop-blur-sm" onClick={onClose}>
      <div className="my-4 w-full max-w-2xl rounded-lg border border-border bg-card shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <span className="text-[13px] font-medium text-foreground">New table</span>
          <Button type="button" variant="ghost" size="icon-sm" onClick={onClose}>
            <X className="size-4 text-muted-foreground" />
          </Button>
        </div>

        <div className="max-h-[60vh] space-y-5 overflow-y-auto px-5 py-4">
          <div className="space-y-1.5">
            <span className="font-mono text-[12px] text-foreground">Table name</span>
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Users" spellCheck={false} className={inputCls} />
          </div>

          <div className="space-y-3">
            <SectionLabel>Primary key</SectionLabel>
            <div className="flex items-end gap-2">
              <div className="flex-1 space-y-1.5">
                <span className="font-mono text-[11px] text-muted-foreground">partition key (HASH)</span>
                <input value={pk.name} onChange={(e) => setPk({ ...pk, name: e.target.value })} placeholder="id" className={inputCls} />
              </div>
              <KeyTypeSelect value={pk.type} onChange={(t) => setPk({ ...pk, type: t })} />
            </div>
            <label className="flex items-center gap-2 font-mono text-[12px] text-muted-foreground">
              <input type="checkbox" checked={hasSort} onChange={(e) => setHasSort(e.target.checked)} />
              add sort key (RANGE)
            </label>
            {hasSort && (
              <div className="flex items-end gap-2">
                <div className="flex-1 space-y-1.5">
                  <span className="font-mono text-[11px] text-muted-foreground">sort key</span>
                  <input value={sk.name} onChange={(e) => setSk({ ...sk, name: e.target.value })} placeholder="createdAt" className={inputCls} />
                </div>
                <KeyTypeSelect value={sk.type} onChange={(t) => setSk({ ...sk, type: t })} />
              </div>
            )}
          </div>

          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <SectionLabel>Global secondary indexes</SectionLabel>
              <Button type="button" variant="outline" size="xs" onClick={() => setGsis((g) => [...g, { id: nextId(), name: "", partition: { name: "", type: "S" }, sort: null, projection: "ALL", include: "" }])}>
                <Plus className="size-3" />
                Add GSI
              </Button>
            </div>
            {gsis.map((g) => (
              <Card key={g.id} className="gap-0 rounded-md border-border bg-card/60 p-0 ring-0">
                <div className="flex items-center gap-2 border-b border-border px-3 py-2">
                  <input value={g.name} onChange={(e) => setGsis((gs) => gs.map((x) => (x.id === g.id ? { ...x, name: e.target.value } : x)))} placeholder="index name" className={cn(inputCls, "flex-1")} />
                  <Button type="button" variant="ghost" size="icon-sm" onClick={() => setGsis((gs) => gs.filter((x) => x.id !== g.id))}>
                    <Trash2 className="size-3.5 text-muted-foreground hover:text-down" />
                  </Button>
                </div>
                <div className="space-y-2 px-3 py-2.5">
                  <div className="flex items-end gap-2">
                    <div className="flex-1 space-y-1">
                      <span className="font-mono text-[11px] text-muted-foreground">partition key</span>
                      <input value={g.partition.name} onChange={(e) => setGsis((gs) => gs.map((x) => (x.id === g.id ? { ...x, partition: { ...x.partition, name: e.target.value } } : x)))} className={inputCls} />
                    </div>
                    <KeyTypeSelect value={g.partition.type} onChange={(t) => setGsis((gs) => gs.map((x) => (x.id === g.id ? { ...x, partition: { ...x.partition, type: t } } : x)))} />
                  </div>
                  <label className="flex items-center gap-2 font-mono text-[11px] text-muted-foreground">
                    <input type="checkbox" checked={g.sort !== null} onChange={(e) => setGsis((gs) => gs.map((x) => (x.id === g.id ? { ...x, sort: e.target.checked ? { name: "", type: "S" } : null } : x)))} />
                    sort key
                  </label>
                  {g.sort && (
                    <div className="flex items-end gap-2">
                      <div className="flex-1 space-y-1">
                        <span className="font-mono text-[11px] text-muted-foreground">sort key</span>
                        <input value={g.sort.name} onChange={(e) => setGsis((gs) => gs.map((x) => (x.id === g.id && x.sort ? { ...x, sort: { ...x.sort, name: e.target.value } } : x)))} className={inputCls} />
                      </div>
                      <KeyTypeSelect value={g.sort.type} onChange={(t) => setGsis((gs) => gs.map((x) => (x.id === g.id && x.sort ? { ...x, sort: { ...x.sort, type: t } } : x)))} />
                    </div>
                  )}
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[11px] text-muted-foreground">projection</span>
                    <select value={g.projection} onChange={(e) => setGsis((gs) => gs.map((x) => (x.id === g.id ? { ...x, projection: e.target.value as GsiDraft["projection"] } : x)))} className="h-8 rounded-md border border-border bg-card/60 px-2 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30">
                      <option value="ALL">ALL</option>
                      <option value="KEYS_ONLY">KEYS_ONLY</option>
                      <option value="INCLUDE">INCLUDE</option>
                    </select>
                  </div>
                  {g.projection === "INCLUDE" && (
                    <input value={g.include} onChange={(e) => setGsis((gs) => gs.map((x) => (x.id === g.id ? { ...x, include: e.target.value } : x)))} placeholder="attr1, attr2" className={inputCls} />
                  )}
                </div>
              </Card>
            ))}
          </div>

          <div className="flex items-center gap-2">
            <span className="font-mono text-[12px] text-foreground">Billing</span>
            <select value={billing} onChange={(e) => setBilling(e.target.value as typeof billing)} className="h-8 rounded-md border border-border bg-card/60 px-2 font-mono text-[12px] text-foreground outline-none focus:border-foreground/30">
              <option value="PAY_PER_REQUEST">PAY_PER_REQUEST</option>
              <option value="PROVISIONED">PROVISIONED</option>
            </select>
          </div>
        </div>

        {err && <div className="border-t border-down/20 bg-down/10 px-5 py-2 font-mono text-[11px] text-down">{err}</div>}

        <div className="flex items-center justify-end gap-2 border-t border-border px-5 py-3">
          <Button type="button" variant="ghost" size="sm" onClick={onClose}>
            Cancel
          </Button>
          <Button type="button" size="sm" disabled={busy} onClick={() => void create()}>
            {busy ? "creating…" : "Create table"}
          </Button>
        </div>
      </div>
    </div>
  );
}

// Rendered on /dynamodb/new. The service starts with no tables and does not
// pre-provision from config, so there is nothing to configure at launch —
// tables are created from the instance detail page.
export function DynamoCreate({ onChange }: ServiceCreateFieldsProps) {
  useEffect(() => {
    onChange({ configJson: undefined, valid: true });
  }, [onChange]);

  return (
    <div className="space-y-4">
      <SectionLabel>Tables</SectionLabel>
      <Card className="rounded-lg border-dashed border-border bg-card/40 p-0 ring-0">
        <div className="px-6 py-12 text-center font-mono text-xs text-muted-foreground">
          instance starts empty — create tables from the instance page after launch.
        </div>
      </Card>
    </div>
  );
}
