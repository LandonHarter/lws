"use client";

import { useEffect, useState } from "react";
import { AlertTriangle, Clock, Cpu, Network } from "lucide-react";
import type { LucideIcon } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { usePoll } from "@/lib/use-poll";
import { fmtUptime } from "@/lib/format";
import { serviceMeta } from "@/lib/services";
import { cn } from "@/lib/utils";
import { SectionLabel, StatusDot } from "@/components/bits";
import { InstanceActions } from "@/components/instance-actions";
import { ServiceDetail } from "@/components/services";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";

function useNow(intervalMs = 1000) {
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    setNow(Date.now());
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

function Chip({ icon: Icon, children }: { icon: LucideIcon; children: React.ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-md border border-border bg-card/60 px-2.5 py-1 font-mono text-[11px]">
      <Icon className="size-3.5 text-muted-foreground" strokeWidth={2} />
      <span className="text-foreground">{children}</span>
    </span>
  );
}

export function ResourceDetail({ service, id }: { service: string; id: string }) {
  const meta = serviceMeta(service);
  const now = useNow(1000);
  const { data, error, loading, updatedAt, refresh } = usePoll(
    () => trpc.lws.info.query({ name: id, service }),
    2000,
  );

  if (!data && loading) {
    return (
      <div className="space-y-8">
        <Skeleton className="h-20 w-2/3 rounded-md" />
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-[104px] rounded-md" />
          ))}
        </div>
        <Skeleton className="h-56 rounded-lg" />
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="rounded-md border border-down/30 bg-down/10 px-4 py-3 font-mono text-sm text-down">
        cli unreachable — {error}
      </div>
    );
  }

  if (data && !data.ok) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border bg-card/40 px-6 py-20 text-center">
        <AlertTriangle className="size-6 text-down" />
        <p className="font-heading text-2xl tracking-wide text-foreground">RESOURCE NOT FOUND</p>
        <p className="font-mono text-xs text-muted-foreground">
          {meta.label} / {id} — {data.error}
        </p>
      </div>
    );
  }

  if (!data?.meta) return null;

  const { meta: info, uptimeMs, stats } = data;
  const running = info.alive;
  const liveUptime =
    uptimeMs !== null && updatedAt && now
      ? uptimeMs + Math.max(0, now - updatedAt)
      : (uptimeMs ?? 0);

  return (
    <div className="space-y-8">
      <div className="space-y-4">
        <SectionLabel>{meta.title}</SectionLabel>
        <div className="flex flex-wrap items-center gap-4">
          <h1 className="font-heading text-5xl leading-[0.9] tracking-wide text-foreground">
            {info.name}
          </h1>
          <span
            className={cn(
              "inline-flex items-center gap-2 rounded-full border px-3 py-1 font-mono text-[11px] uppercase tracking-[0.16em]",
              running ? "border-ok/30 bg-ok/10 text-ok" : "border-down/30 bg-down/10 text-down",
            )}
          >
            <StatusDot tone={running ? "ok" : "down"} ping={running} />
            {running ? "running" : "dead"}
          </span>
          <div className="ml-auto">
            <InstanceActions
              service={service}
              name={info.name}
              status={running ? "running" : "stopped"}
              onDone={refresh}
            />
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Badge
            variant="outline"
            className="h-6 rounded-md border-primary/30 bg-primary/10 px-2 font-mono text-[11px] uppercase tracking-wider text-primary"
          >
            {meta.label}
          </Badge>
          <Chip icon={Network}>127.0.0.1:{info.port}</Chip>
          <Chip icon={Cpu}>pid {info.pid}</Chip>
          {running && <Chip icon={Clock}>up {fmtUptime(liveUptime)}</Chip>}
        </div>
      </div>

      {!running ? (
        <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border bg-card/40 px-6 py-16 text-center">
          <StatusDot tone="down" />
          <p className="font-heading text-2xl tracking-wide text-foreground">INSTANCE OFFLINE</p>
          <p className="font-mono text-xs text-muted-foreground">
            process is not alive — no live stats to report
          </p>
        </div>
      ) : (
        <ServiceDetail service={service} stats={stats} updatedAt={updatedAt} />
      )}
    </div>
  );
}
