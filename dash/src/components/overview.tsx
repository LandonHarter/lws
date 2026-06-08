"use client";

import Link from "next/link";
import { Activity, ArrowUpRight, ChevronRight, RefreshCw, Server, Skull } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { usePoll } from "@/lib/use-poll";
import { fmtNum, fmtTime, fmtUptime } from "@/lib/format";
import { aggregateStats, serviceMeta, type ServiceStat } from "@/lib/services";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel, StatusDot } from "@/components/bits";
import { InstanceActions } from "@/components/instance-actions";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

type OverviewData = Awaited<ReturnType<typeof trpc.lws.overview.query>>;
type EnrichedInstance = OverviewData["instances"][number];

function MiniStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col items-end leading-tight">
      <span className="text-sm tabular-nums text-foreground">{value}</span>
      <span className="text-[11px] text-muted-foreground">{label}</span>
    </div>
  );
}

function InstanceRow({ inst, onRefresh }: { inst: EnrichedInstance; onRefresh: () => void }) {
  const running = inst.status === "running";
  const stopped = inst.status === "stopped";
  const stats = serviceMeta(inst.service).headline(inst.stats).slice(0, 2);
  return (
    <Link
      href={`/${inst.service}/${encodeURIComponent(inst.name)}`}
      className="group grid grid-cols-[auto_1fr_auto] items-center gap-4 rounded-lg px-4 py-3 transition-colors hover:bg-muted/60"
    >
      <StatusDot tone={running ? "ok" : stopped ? "idle" : "down"} />

      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="truncate text-sm font-medium text-foreground">{inst.name}</span>
          <Badge
            variant="outline"
            className={cn(
              "h-5 border-transparent px-1.5 text-[11px]",
              running
                ? "bg-ok/10 text-ok"
                : stopped
                  ? "bg-muted text-muted-foreground"
                  : "bg-down/10 text-down",
            )}
          >
            {inst.status}
          </Badge>
        </div>
        <div className="mt-1 flex items-center gap-3 text-[12px] tabular-nums text-muted-foreground">
          <span>127.0.0.1:{inst.port}</span>
          {running && <span>pid {inst.pid}</span>}
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
        <span key={s.key} className="flex items-baseline gap-1.5 text-[12px]">
          <span className="tabular-nums text-foreground">{fmtNum(s.value)}</span>
          <span className="text-muted-foreground">{s.label}</span>
        </span>
      ))}
    </div>
  );
}

function ServiceCard({
  serviceId,
  instances,
  index,
  onRefresh,
}: {
  serviceId: string;
  instances: EnrichedInstance[];
  index: number;
  onRefresh: () => void;
}) {
  const meta = serviceMeta(serviceId);
  const Icon = meta.icon;
  const running = instances.filter((i) => i.status === "running").length;
  const summary = aggregateStats(serviceId, instances);

  return (
    <Card
      className="lws-rise gap-0 rounded-xl border-border bg-card p-0 ring-0"
      style={{ animationDelay: `${index * 60}ms` }}
    >
      <div className="flex items-start justify-between gap-4 border-b border-border px-5 py-4">
        <div className="flex items-center gap-3.5">
          <span className="grid size-10 place-items-center rounded-lg bg-muted text-muted-foreground">
            <Icon className="size-5" strokeWidth={1.75} />
          </span>
          <div>
            <div className="flex items-center gap-2.5">
              <Link
                href={`/${serviceId}`}
                className="text-lg font-semibold tracking-tight text-foreground transition-colors hover:text-primary"
              >
                {meta.label}
              </Link>
              <span className="text-[12px] text-muted-foreground">{meta.title}</span>
            </div>
            <p className="mt-1 max-w-md text-[13px] text-muted-foreground">{meta.blurb}</p>
          </div>
        </div>
        <div className="flex flex-col items-end gap-2">
          <Link
            href={`/${serviceId}`}
            className="flex items-center gap-1 text-[12px] text-muted-foreground transition-colors hover:text-foreground"
          >
            {running}/{instances.length} live
            <ArrowUpRight className="size-3.5" />
          </Link>
          <ServiceSummary stats={summary} />
        </div>
      </div>

      <div className="flex flex-col gap-1 p-2">
        {instances.length === 0 ? (
          <div className="px-2 py-6 text-center text-[13px] text-muted-foreground">
            no instances
          </div>
        ) : (
          instances.map((inst) => (
            <InstanceRow key={`${inst.service}/${inst.name}`} inst={inst} onRefresh={onRefresh} />
          ))
        )}
      </div>
    </Card>
  );
}

function HeaderBar({ updatedAt, onRefresh }: { updatedAt: number | null; onRefresh: () => void }) {
  return (
    <div className="flex items-end justify-between">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight text-foreground">Local Cloud</h1>
        <p className="mt-1.5 text-sm text-muted-foreground">
          Every service running on this machine, in one console.
        </p>
      </div>
      <button
        onClick={onRefresh}
        className="flex items-center gap-2 rounded-lg px-3 py-2 text-[13px] tabular-nums text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
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
        <div className="rounded-lg border border-down/30 bg-down/10 px-4 py-3 text-sm text-down">
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
            <Card className="rounded-xl border-dashed border-border bg-transparent p-0 ring-0">
              <div className="flex flex-col items-center gap-3 px-6 py-16 text-center">
                <span className="grid size-12 place-items-center rounded-lg bg-muted text-muted-foreground">
                  <Server className="size-5" strokeWidth={1.75} />
                </span>
                <p className="text-lg font-semibold tracking-tight text-foreground">No services running</p>
                <p className="text-[13px] text-muted-foreground">
                  start one with{" "}
                  <span className="rounded bg-muted px-1.5 py-0.5 font-mono text-foreground">lws run &lt;service&gt;</span>
                </p>
              </div>
            </Card>
          ) : (
            <div className="space-y-4">
              <SectionLabel>Services</SectionLabel>
              {data.services.map((svc, idx) => (
                <ServiceCard
                  key={svc}
                  serviceId={svc}
                  index={idx}
                  instances={data.instances.filter((i) => i.service === svc)}
                  onRefresh={refresh}
                />
              ))}
            </div>
          )}
        </>
      ) : null}
    </div>
  );
}
