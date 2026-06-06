"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Rocket } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { serviceMeta } from "@/lib/services";
import { serviceConfigSpec } from "@/lib/service-config";
import { cn } from "@/lib/utils";
import { SectionLabel } from "@/components/bits";
import { ServiceCreateFields } from "@/components/services";
import { NAME_RE, type ServiceCreateValue } from "@/components/services/shared";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

export function ServiceCreate({ service }: { service: string }) {
  const router = useRouter();
  const meta = serviceMeta(service);
  const spec = serviceConfigSpec(service);
  const Icon = meta.icon;

  const [name, setName] = useState("");
  const [port, setPort] = useState<string>(spec ? String(spec.defaultPort) : "");
  const [config, setConfig] = useState<ServiceCreateValue>({
    configJson: undefined,
    valid: true,
  });
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const portNum = Number.parseInt(port, 10);
  const portValid = Number.isInteger(portNum) && portNum > 0 && portNum <= 65535;
  const nameValid = name.trim() === "" || NAME_RE.test(name.trim());
  const canSubmit = !!spec && !submitting && portValid && nameValid && config.valid;

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
        configJson: config.configJson,
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

      <ServiceCreateFields service={service} spec={spec} onChange={setConfig} />

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
