"use client";

import { useEffect, useMemo, useState } from "react";
import { Plus, Trash2 } from "lucide-react";

import { cn } from "@/lib/utils";
import { SectionLabel } from "@/components/bits";
import { type ServiceCreateFieldsProps } from "@/components/services/shared";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

const inputCls =
  "h-8 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-foreground/30";

// Postgres identifier rule: starts with a letter or underscore, then letters,
// digits, underscore or $. Mirrors the launcher's CREATE DATABASE handling.
const DB_NAME_RE = /^[A-Za-z_][A-Za-z0-9_$]*$/;

type DbDraft = { key: string; name: string };

let seq = 0;
function nextId() {
  seq += 1;
  return `db${seq}`;
}

function dbError(d: DbDraft, names: string[]): string | null {
  const name = d.name.trim();
  if (name === "") return "name required";
  if (!DB_NAME_RE.test(name)) return "start with a letter/_, then letters, digits, _ or $";
  if (names.filter((n) => n === name).length > 1) return "duplicate name";
  return null;
}

function buildConfigJson(dbs: DbDraft[], seedSql: string): string | undefined {
  const databases = dbs.map((d) => d.name.trim()).filter((n) => n !== "");
  const seed = seedSql.trim();
  if (databases.length === 0 && seed === "") return undefined;
  return JSON.stringify({ databases, seed_sql: seed === "" ? null : seedSql }, null, 2);
}

export function PostgresCreateFields({ onChange }: ServiceCreateFieldsProps) {
  const [dbs, setDbs] = useState<DbDraft[]>([]);
  const [seedSql, setSeedSql] = useState("");
  const [showJson, setShowJson] = useState(false);

  const names = useMemo(() => dbs.map((d) => d.name.trim()), [dbs]);
  const errors = useMemo(() => dbs.map((d) => dbError(d, names)), [dbs, names]);
  const configJson = useMemo(() => buildConfigJson(dbs, seedSql), [dbs, seedSql]);
  const valid = errors.every((e) => e === null);

  useEffect(() => {
    onChange({ configJson, valid });
  }, [onChange, configJson, valid]);

  return (
    <>
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <SectionLabel>Databases</SectionLabel>
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => setDbs((d) => [...d, { key: nextId(), name: "" }])}
          >
            <Plus className="size-3.5" />
            Add database
          </Button>
        </div>

        {dbs.length === 0 ? (
          <Card className="rounded-lg border-dashed border-border bg-card/40 p-0 ring-0">
            <div className="px-6 py-12 text-center font-mono text-xs text-muted-foreground">
              none — instance starts with the default `postgres` database. add more to pre-create them.
            </div>
          </Card>
        ) : (
          <div className="space-y-2">
            {dbs.map((d, i) => (
              <div key={d.key} className="space-y-1">
                <div className="flex items-center gap-2">
                  <span className="w-6 text-[12px] text-muted-foreground">{String(i + 1).padStart(2, "0")}</span>
                  <input
                    value={d.name}
                    onChange={(e) => setDbs((ds) => ds.map((x) => (x.key === d.key ? { ...x, name: e.target.value } : x)))}
                    placeholder="appdb"
                    spellCheck={false}
                    className={cn(inputCls, "flex-1", errors[i] && "border-down/50")}
                  />
                  <Button type="button" variant="ghost" size="icon-sm" onClick={() => setDbs((ds) => ds.filter((x) => x.key !== d.key))}>
                    <Trash2 className="size-3.5 text-muted-foreground hover:text-down" />
                  </Button>
                </div>
                {errors[i] && <span className="ml-8 font-mono text-[11px] text-down">{errors[i]}</span>}
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="space-y-3">
        <SectionLabel>Seed SQL</SectionLabel>
        <textarea
          value={seedSql}
          onChange={(e) => setSeedSql(e.target.value)}
          rows={6}
          spellCheck={false}
          placeholder="create table users (id serial primary key, email text not null);"
          className="w-full resize-y rounded-lg border border-border bg-card/60 px-3 py-2 font-mono text-[12px] leading-relaxed text-foreground outline-none focus:border-foreground/30"
        />
        <span className="font-mono text-[11px] text-muted-foreground">
          optional — runs once against the default database after launch.
        </span>
      </div>

      {configJson && (
        <div className="space-y-3">
          <button
            type="button"
            onClick={() => setShowJson((s) => !s)}
            className="text-[12px] text-muted-foreground transition-colors hover:text-foreground"
          >
            {showJson ? "hide" : "show"} generated config
          </button>
          {showJson && (
            <pre className="overflow-x-auto rounded-lg border border-border bg-card/60 p-4 font-mono text-[12px] leading-relaxed text-foreground">
              {configJson}
            </pre>
          )}
        </div>
      )}
    </>
  );
}
