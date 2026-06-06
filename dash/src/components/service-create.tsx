"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Plus, Rocket, Trash2 } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { serviceMeta } from "@/lib/services";
import {
  GROUP_ORDER,
  serviceConfigSpec,
  type ConfigField,
  type ServiceConfigSpec,
} from "@/lib/service-config";
import { cn } from "@/lib/utils";
import { SectionLabel } from "@/components/bits";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

type QueueDraft = {
  key: string;
  name: string;
  values: Record<string, string>;
};

const NAME_RE = /^[A-Za-z0-9_.-]{1,80}$/;

function defaultString(field: ConfigField): string {
  if (field.default === undefined) return "";
  if (typeof field.default === "boolean") return field.default ? "true" : "false";
  return String(field.default);
}

function freshValues(spec: ServiceConfigSpec): Record<string, string> {
  const v: Record<string, string> = {};
  for (const f of spec.fields) v[f.name] = defaultString(f);
  return v;
}

let queueSeq = 0;
function newQueue(spec: ServiceConfigSpec): QueueDraft {
  queueSeq += 1;
  return { key: `q${queueSeq}`, name: "", values: freshValues(spec) };
}

function isFifo(spec: ServiceConfigSpec, q: QueueDraft): boolean {
  return spec.fifoField !== null && q.values[spec.fifoField] === "true";
}

function buildConfigJson(spec: ServiceConfigSpec, queues: QueueDraft[]): string | undefined {
  if (queues.length === 0) return undefined;
  const out: Record<string, Record<string, string>> = {};
  for (const q of queues) {
    const fifo = isFifo(spec, q);
    const attrs: Record<string, string> = {};
    for (const f of spec.fields) {
      if (f.fifoOnly && !fifo) continue;
      const v = q.values[f.name] ?? "";
      if (f.name === spec.fifoField) {
        if (fifo) attrs[f.name] = "true";
        continue;
      }
      if (v.trim() === "") continue;
      if (v === defaultString(f)) continue;
      attrs[f.name] = v;
    }
    out[q.name] = attrs;
  }
  return JSON.stringify({ queues: out }, null, 2);
}

function queueError(spec: ServiceConfigSpec, q: QueueDraft, names: string[]): string | null {
  const name = q.name.trim();
  if (name === "") return "name required";
  if (!NAME_RE.test(name)) return "1-80 chars: letters, digits, . _ -";
  if (names.filter((n) => n === name).length > 1) return "duplicate name";
  const fifo = isFifo(spec, q);
  const dotFifo = name.endsWith(".fifo");
  if (fifo && !dotFifo) return "FIFO queue name must end with .fifo";
  if (!fifo && dotFifo) return "only FIFO queues may end with .fifo";
  for (const f of spec.fields) {
    if (f.type !== "json") continue;
    const raw = (q.values[f.name] ?? "").trim();
    if (raw === "") continue;
    try {
      JSON.parse(raw);
    } catch {
      return `${f.label} is not valid JSON`;
    }
  }
  return null;
}

function fieldId(qKey: string, field: string) {
  return `${qKey}-${field}`;
}

function FieldControl({
  field,
  value,
  onChange,
}: {
  field: ConfigField;
  value: string;
  onChange: (v: string) => void;
}) {
  const base =
    "h-8 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-foreground/30";

  if (field.type === "boolean") {
    const on = value === "true";
    return (
      <button
        type="button"
        role="switch"
        aria-checked={on}
        onClick={() => onChange(on ? "false" : "true")}
        className={cn(
          "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full border transition-colors",
          on ? "border-primary/40 bg-primary/30" : "border-border bg-card",
        )}
      >
        <span
          className={cn(
            "inline-block size-3.5 rounded-full bg-foreground transition-transform",
            on ? "translate-x-4" : "translate-x-0.5",
          )}
        />
      </button>
    );
  }

  if (field.type === "string" && field.allowed) {
    return (
      <select value={value} onChange={(e) => onChange(e.target.value)} className={base}>
        {field.allowed.map((opt) => (
          <option key={opt} value={opt}>
            {opt}
          </option>
        ))}
      </select>
    );
  }

  if (field.type === "json") {
    return (
      <textarea
        value={value}
        onChange={(e) => onChange(e.target.value)}
        rows={3}
        placeholder="{ }"
        spellCheck={false}
        className="w-full resize-y rounded-md border border-border bg-card/60 px-2.5 py-2 font-mono text-[12px] text-foreground outline-none transition-colors focus:border-foreground/30"
      />
    );
  }

  if (field.type === "integer") {
    return (
      <input
        type="number"
        value={value}
        min={field.min}
        max={field.max}
        onChange={(e) => onChange(e.target.value)}
        className={cn(base, "tabular-nums")}
      />
    );
  }

  return (
    <input
      type="text"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={field.help ? "" : "optional"}
      className={base}
    />
  );
}

function QueueCard({
  spec,
  queue,
  index,
  error,
  onChange,
  onRemove,
}: {
  spec: ServiceConfigSpec;
  queue: QueueDraft;
  index: number;
  error: string | null;
  onChange: (next: QueueDraft) => void;
  onRemove: () => void;
}) {
  const fifo = isFifo(spec, queue);
  const setValue = (name: string, v: string) =>
    onChange({ ...queue, values: { ...queue.values, [name]: v } });

  return (
    <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
      <div className="flex items-center gap-3 border-b border-border px-5 py-3">
        <span className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted-foreground">
          {String(index + 1).padStart(2, "0")}
        </span>
        <input
          value={queue.name}
          onChange={(e) => onChange({ ...queue, name: e.target.value })}
          placeholder={spec.queueNameLabel.toLowerCase()}
          spellCheck={false}
          className="h-8 flex-1 rounded-md border border-border bg-card/60 px-2.5 font-mono text-sm text-foreground outline-none transition-colors focus:border-foreground/30"
        />
        <Button type="button" variant="ghost" size="icon-sm" onClick={onRemove}>
          <Trash2 className="size-3.5 text-muted-foreground" />
        </Button>
      </div>

      {error && (
        <div className="border-b border-down/20 bg-down/10 px-5 py-1.5 font-mono text-[11px] text-down">
          {error}
        </div>
      )}

      <div className="space-y-5 px-5 py-4">
        {GROUP_ORDER.map((group) => {
          const fields = spec.fields.filter(
            (f) => f.group === group && (!f.fifoOnly || fifo),
          );
          if (fields.length === 0) return null;
          return (
            <div key={group} className="space-y-3">
              <SectionLabel>{group}</SectionLabel>
              <div className="grid grid-cols-2 gap-x-6 gap-y-3">
                {fields.map((f) => (
                  <div
                    key={f.name}
                    className={cn(
                      "flex flex-col gap-1.5",
                      f.type === "json" && "col-span-2",
                    )}
                  >
                    <label
                      htmlFor={fieldId(queue.key, f.name)}
                      className="flex items-center justify-between gap-2"
                    >
                      <span className="font-mono text-[12px] text-foreground">{f.label}</span>
                      {f.type === "boolean" && (
                        <FieldControl
                          field={f}
                          value={queue.values[f.name] ?? ""}
                          onChange={(v) => setValue(f.name, v)}
                        />
                      )}
                    </label>
                    {f.type !== "boolean" && (
                      <FieldControl
                        field={f}
                        value={queue.values[f.name] ?? ""}
                        onChange={(v) => setValue(f.name, v)}
                      />
                    )}
                    {f.help && (
                      <span className="font-mono text-[11px] leading-snug text-muted-foreground">
                        {f.help}
                      </span>
                    )}
                  </div>
                ))}
              </div>
            </div>
          );
        })}
      </div>
    </Card>
  );
}

export function ServiceCreate({ service }: { service: string }) {
  const router = useRouter();
  const meta = serviceMeta(service);
  const spec = serviceConfigSpec(service);
  const Icon = meta.icon;

  const [name, setName] = useState("");
  const [port, setPort] = useState<string>(spec ? String(spec.defaultPort) : "");
  const [queues, setQueues] = useState<QueueDraft[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showJson, setShowJson] = useState(false);

  const names = useMemo(() => queues.map((q) => q.name.trim()), [queues]);
  const queueErrors = useMemo(
    () => (spec ? queues.map((q) => queueError(spec, q, names)) : []),
    [spec, queues, names],
  );
  const configJson = useMemo(
    () => (spec ? buildConfigJson(spec, queues) : undefined),
    [spec, queues],
  );

  const portNum = Number.parseInt(port, 10);
  const portValid = Number.isInteger(portNum) && portNum > 0 && portNum <= 65535;
  const nameValid = name.trim() === "" || NAME_RE.test(name.trim());
  const canSubmit =
    !!spec &&
    !submitting &&
    portValid &&
    nameValid &&
    queueErrors.every((e) => e === null);

  if (!spec) {
    return (
      <div className="space-y-4">
        <SectionLabel>Create</SectionLabel>
        <Card className="rounded-lg border-dashed border-border bg-card/40 p-0 ring-0">
          <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">
            no creation form defined for {meta.label}
          </div>
        </Card>
      </div>
    );
  }

  async function submit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const res = await trpc.lws.run.mutate({
        service,
        name: name.trim() === "" ? undefined : name.trim(),
        port: portNum,
        configJson,
      });
      if (res.started) {
        router.push(`/${service}/${encodeURIComponent(res.started.name)}`);
      } else {
        setError(res.stderr.trim() || res.stdout.trim() || "failed to start instance");
        setSubmitting(false);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "failed to start instance");
      setSubmitting(false);
    }
  }

  return (
    <div className="space-y-8">
      <div className="flex items-center gap-4">
        <span className="grid size-14 place-items-center rounded-lg border border-primary/25 bg-primary/10 text-primary">
          <Icon className="size-6" strokeWidth={2} />
        </span>
        <div>
          <SectionLabel>New {meta.label} instance</SectionLabel>
          <h1 className="mt-2 font-heading text-5xl leading-[0.9] tracking-wide text-foreground">
            CREATE
          </h1>
        </div>
      </div>

      <div className="space-y-4">
        <SectionLabel>Instance</SectionLabel>
        <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
          <div className="grid grid-cols-2 gap-x-6 gap-y-3 px-5 py-4">
            <div className="flex flex-col gap-1.5">
              <span className="font-mono text-[12px] text-foreground">Name</span>
              <input
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="auto-generated"
                spellCheck={false}
                className={cn(
                  "h-8 w-full rounded-md border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-foreground/30",
                  nameValid ? "border-border" : "border-down/50",
                )}
              />
              <span className="font-mono text-[11px] text-muted-foreground">
                leave blank for a generated name
              </span>
            </div>
            <div className="flex flex-col gap-1.5">
              <span className="font-mono text-[12px] text-foreground">Port</span>
              <input
                type="number"
                value={port}
                min={1}
                max={65535}
                onChange={(e) => setPort(e.target.value)}
                className={cn(
                  "h-8 w-full rounded-md border bg-card/60 px-2.5 font-mono text-[13px] tabular-nums text-foreground outline-none transition-colors focus:border-foreground/30",
                  portValid ? "border-border" : "border-down/50",
                )}
              />
              <span className="font-mono text-[11px] text-muted-foreground">
                default {spec.defaultPort}
              </span>
            </div>
          </div>
        </Card>
      </div>

      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <SectionLabel>Initial queues</SectionLabel>
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => setQueues((qs) => [...qs, newQueue(spec)])}
          >
            <Plus className="size-3.5" />
            Add queue
          </Button>
        </div>

        {queues.length === 0 ? (
          <Card className="rounded-lg border-dashed border-border bg-card/40 p-0 ring-0">
            <div className="px-6 py-12 text-center font-mono text-xs text-muted-foreground">
              no queues — instance starts empty. add one to pre-provision it.
            </div>
          </Card>
        ) : (
          <div className="space-y-4">
            {queues.map((q, i) => (
              <QueueCard
                key={q.key}
                spec={spec}
                queue={q}
                index={i}
                error={queueErrors[i]}
                onChange={(next) =>
                  setQueues((qs) => qs.map((x) => (x.key === q.key ? next : x)))
                }
                onRemove={() => setQueues((qs) => qs.filter((x) => x.key !== q.key))}
              />
            ))}
          </div>
        )}
      </div>

      {configJson && (
        <div className="space-y-3">
          <button
            type="button"
            onClick={() => setShowJson((s) => !s)}
            className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted-foreground transition-colors hover:text-foreground"
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

      {error && (
        <div className="rounded-md border border-down/30 bg-down/10 px-4 py-3 font-mono text-sm text-down">
          {error}
        </div>
      )}

      <div className="flex items-center gap-3 border-t border-border pt-6">
        <Button type="button" disabled={!canSubmit} onClick={submit}>
          <Rocket className="size-4" />
          {submitting ? "starting…" : `Launch ${meta.label} instance`}
        </Button>
        <Button type="button" variant="ghost" onClick={() => router.push(`/${service}`)}>
          Cancel
        </Button>
      </div>
    </div>
  );
}
