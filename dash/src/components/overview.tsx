"use client";

import Link from "next/link";
import { Activity, ArrowUpRight, ChevronRight, RefreshCw, Server, Skull } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { usePoll } from "@/lib/use-poll";
import { fmtNum, fmtTime, fmtUptime } from "@/lib/format";
import { aggregateStats, serviceMeta, type ServiceStat } from "@/lib/services";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel, StatusDot } from "@/components/bits";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

type OverviewData = Awaited<ReturnType<typeof trpc.lws.overview.query>>;
type EnrichedInstance = OverviewData["instances"][number];

function MiniStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col items-end leading-tight">
      <span className="font-mono text-sm tabular-nums text-foreground">{value}</span>
      <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
        {label}
      </span>
    </div>
  );
}

function InstanceRow({ inst }: { inst: EnrichedInstance }) {
  const running = inst.status === "running";
  const stats = serviceMeta(inst.service).headline(inst.stats).slice(0, 2);
  return (
    <Link
      href={`/${inst.service}/${encodeURIComponent(inst.name)}`}
      className="group grid grid-cols-[auto_1fr_auto] items-center gap-4 rounded-md border border-border/60 bg-background/30 px-4 py-3 transition-all hover:border-foreground/25 hover:bg-accent/40"
    >
      <StatusDot tone={running ? "ok" : "down"} ping={running} />

      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="truncate font-mono text-sm text-foreground">{inst.name}</span>
          <Badge
            variant="outline"
            className={cn(
              "h-4 px-1.5 font-mono text-[10px] uppercase tracking-wider",
              running ? "border-ok/30 bg-ok/10 text-ok" : "border-down/30 bg-down/10 text-down",
            )}
          >
            {inst.status}
          </Badge>
        </div>
        <div className="mt-1 flex items-center gap-3 font-mono text-[11px] text-muted-foreground">
          <span className="text-foreground/70">127.0.0.1:{inst.port}</span>
          <span>pid {inst.pid}</span>
          {running && inst.uptimeMs !== null && <span>up {fmtUptime(inst.uptimeMs)}</span>}
        </div>
      </div>

      <div className="flex items-center gap-5">
        {running && stats.length > 0 ? (
          stats.map((s) => <MiniStat key={s.key} label={s.label} value={fmtNum(s.value)} />)
        ) : (
          <MiniStat label="stats" value="—" />
        )}
        <ChevronRight className="size-4 text-muted-foreground transition-transform group-hover:translate-x-0.5 group-hover:text-foreground" />
      </div>
    </Link>
  );
}

function ServiceSummary({ stats }: { stats: ServiceStat[] }) {
  if (stats.length === 0) return null;
  return (
    <div className="flex items-center gap-4">
      {stats.map((s) => (
        <span key={s.key} className="flex items-baseline gap-1.5 font-mono text-[11px]">
          <span className="tabular-nums text-foreground">{fmtNum(s.value)}</span>
          <span className="uppercase tracking-[0.16em] text-muted-foreground">{s.label}</span>
        </span>
      ))}
    </div>
  );
}

function ServiceCard({
  serviceId,
  instances,
  index,
}: {
  serviceId: string;
  instances: EnrichedInstance[];
  index: number;
}) {
  const meta = serviceMeta(serviceId);
  const Icon = meta.icon;
  const running = instances.filter((i) => i.status === "running").length;
  const summary = aggregateStats(serviceId, instances);

  return (
    <Card
      className="lws-rise gap-0 rounded-lg border-border bg-card/70 p-0 ring-0"
      style={{ animationDelay: `${index * 80}ms` }}
    >
      <div className="flex items-start justify-between gap-4 border-b border-border px-5 py-4">
        <div className="flex items-center gap-3.5">
          <span className="grid size-11 place-items-center rounded-md border border-primary/25 bg-primary/10 text-primary">
            <Icon className="size-5" strokeWidth={2} />
          </span>
          <div>
            <div className="flex items-center gap-2.5">
              <Link
                href={`/${serviceId}`}
                className="font-heading text-2xl leading-none tracking-wide text-foreground transition-colors hover:text-primary"
              >
                {meta.label}
              </Link>
              <span className="font-mono text-[11px] uppercase tracking-[0.16em] text-muted-foreground">
                {meta.title}
              </span>
            </div>
            <p className="mt-1.5 max-w-md font-mono text-xs text-muted-foreground">{meta.blurb}</p>
          </div>
        </div>
        <div className="flex flex-col items-end gap-2">
          <Link
            href={`/${serviceId}`}
            className="flex items-center gap-1 font-mono text-[11px] uppercase tracking-wider text-muted-foreground transition-colors hover:text-foreground"
          >
            {running}/{instances.length} live
            <ArrowUpRight className="size-3.5" />
          </Link>
          <ServiceSummary stats={summary} />
        </div>
      </div>

      <div className="flex flex-col gap-2 p-3">
        {instances.length === 0 ? (
          <div className="px-2 py-6 text-center font-mono text-xs text-muted-foreground">
            no instances
          </div>
        ) : (
          instances.map((inst) => <InstanceRow key={`${inst.service}/${inst.name}`} inst={inst} />)
        )}
      </div>
    </Card>
  );
}

function HeaderBar({ updatedAt, onRefresh }: { updatedAt: number | null; onRefresh: () => void }) {
  return (
    <div className="flex items-end justify-between">
      <div>
        <SectionLabel>Control Plane</SectionLabel>
        <h1 className="mt-3 font-heading text-5xl leading-[0.9] tracking-wide text-foreground">
          LOCAL CLOUD
        </h1>
        <p className="mt-2 font-mono text-sm text-muted-foreground">
          Every service running on this machine, in one console.
        </p>
      </div>
      <button
        onClick={onRefresh}
        className="flex items-center gap-2 rounded-md border border-border bg-card/60 px-3 py-2 font-mono text-[11px] uppercase tracking-wider text-muted-foreground transition-colors hover:border-foreground/25 hover:text-foreground"
      >
        <RefreshCw className="size-3.5" />
        {updatedAt ? `synced ${fmtTime(updatedAt)}` : "syncing"}
      </button>
    </div>
  );
}

function LoadingState() {
  return (
    <div className="space-y-8">
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {Array.from({ length: 4 }).map((_, i) => (
          <Skeleton key={i} className="h-[104px] rounded-md" />
        ))}
      </div>
      <Skeleton className="h-64 rounded-lg" />
    </div>
  );
}

export function Overview() {
  const { data, error, loading, updatedAt, refresh } = usePoll(
    () => trpc.lws.overview.query(),
    2500,
  );

  return (
    <div className="space-y-8">
      <HeaderBar updatedAt={updatedAt} onRefresh={refresh} />

      {error && !data && (
        <div className="rounded-md border border-down/30 bg-down/10 px-4 py-3 font-mono text-sm text-down">
          cli unreachable — {error}
        </div>
      )}

      {!data && loading ? (
        <LoadingState />
      ) : data ? (
        <>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <MetricTile label="Services" value={data.counts.services} icon={Server} tone="primary" />
            <MetricTile label="Instances" value={data.counts.total} icon={Activity} tone="flight" />
            <MetricTile
              label="Running"
              value={data.counts.running}
              icon={Activity}
              tone="ok"
              hint={`/ ${data.counts.total}`}
            />
            <MetricTile label="Dead" value={data.counts.dead} icon={Skull} tone="down" />
          </div>

          {data.instances.length === 0 ? (
            <Card className="rounded-lg border-dashed border-border bg-card/40 p-0 ring-0">
              <div className="flex flex-col items-center gap-3 px-6 py-16 text-center">
                <span className="grid size-12 place-items-center rounded-md border border-border bg-background/60 text-muted-foreground">
                  <Server className="size-5" />
                </span>
                <p className="font-heading text-2xl tracking-wide text-foreground">NO SERVICES RUNNING</p>
                <p className="font-mono text-xs text-muted-foreground">
                  start one with{" "}
                  <span className="rounded bg-muted px-1.5 py-0.5 text-foreground">lws run &lt;service&gt;</span>
                </p>
              </div>
            </Card>
          ) : (
            <div className="space-y-5">
              <SectionLabel>Services</SectionLabel>
              {data.services.map((svc, idx) => (
                <ServiceCard
                  key={svc}
                  serviceId={svc}
                  index={idx}
                  instances={data.instances.filter((i) => i.service === svc)}
                />
              ))}
            </div>
          )}
        </>
      ) : null}
    </div>
  );
}
