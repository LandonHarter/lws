"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { Activity, ChevronRight, Plus } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { usePoll } from "@/lib/use-poll";
import { fmtNum, fmtUptime } from "@/lib/format";
import { aggregateStats, serviceMeta } from "@/lib/services";
import { serviceConfigSpec } from "@/lib/service-config";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel, StatusDot } from "@/components/bits";
import { buttonVariants } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export function ServiceIndex({ service }: { service: string }) {
  const router = useRouter();
  const meta = serviceMeta(service);
  const Icon = meta.icon;
  const { data, loading } = usePoll(() => trpc.lws.overview.query(), 2500);

  const instances = (data?.instances ?? []).filter((i) => i.service === service);
  const running = instances.filter((i) => i.status === "running").length;
  const summary = aggregateStats(service, instances);
  const statCols = summary.map((s) => s.label);
  const canCreate = serviceConfigSpec(service) !== null;

  return (
    <div className="space-y-8">
      <div className="flex items-center gap-4">
        <span className="grid size-14 place-items-center rounded-lg border border-primary/25 bg-primary/10 text-primary">
          <Icon className="size-6" strokeWidth={2} />
        </span>
        <div>
          <SectionLabel>{meta.title}</SectionLabel>
          <h1 className="mt-2 font-heading text-5xl leading-[0.9] tracking-wide text-foreground">
            {meta.label}
          </h1>
        </div>
        {canCreate && (
          <Link href={`/${service}/new`} className={cn(buttonVariants(), "ml-auto self-end")}>
            <Plus className="size-4" />
            New instance
          </Link>
        )}
      </div>

      <div
        className={cn(
          "grid gap-4",
          summary.length >= 2 ? "grid-cols-3" : summary.length === 1 ? "grid-cols-2" : "grid-cols-1",
        )}
      >
        <MetricTile
          label="Instances"
          value={running}
          icon={Activity}
          tone="ok"
          hint={`/ ${instances.length}`}
        />
        {summary.map((s) => (
          <MetricTile key={s.key} label={s.label} value={s.value} icon={s.icon} tone={s.tone} />
        ))}
      </div>

      <div className="space-y-4">
        <SectionLabel>Instances</SectionLabel>
        <Card className="overflow-hidden rounded-lg border-border bg-card/70 p-0 ring-0">
          {!data && loading ? (
            <div className="space-y-px p-3">
              {Array.from({ length: 3 }).map((_, i) => (
                <Skeleton key={i} className="h-12 rounded-md" />
              ))}
            </div>
          ) : instances.length === 0 ? (
            <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">
              no {meta.label} instances running
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow className="border-border hover:bg-transparent">
                  {["status", "name", "endpoint", "pid", "uptime"].map((h) => (
                    <TableHead
                      key={h}
                      className="h-9 px-5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground"
                    >
                      {h}
                    </TableHead>
                  ))}
                  {statCols.map((h) => (
                    <TableHead
                      key={h}
                      className="h-9 px-5 text-right font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground"
                    >
                      {h}
                    </TableHead>
                  ))}
                  <TableHead className="h-9 px-5" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {instances.map((inst) => {
                  const live = inst.status === "running";
                  const stats = serviceMeta(service).headline(inst.stats);
                  const byLabel = new Map(stats.map((s) => [s.label, s.value]));
                  return (
                    <TableRow
                      key={inst.name}
                      onClick={() =>
                        router.push(`/${inst.service}/${encodeURIComponent(inst.name)}`)
                      }
                      className="cursor-pointer border-border/60"
                    >
                      <TableCell className="px-5">
                        <StatusDot tone={live ? "ok" : "down"} ping={live} />
                      </TableCell>
                      <TableCell className="px-5 font-mono text-sm text-foreground">
                        {inst.name}
                      </TableCell>
                      <TableCell className="px-5 font-mono text-[13px] text-muted-foreground">
                        127.0.0.1:{inst.port}
                      </TableCell>
                      <TableCell className="px-5 font-mono text-[13px] text-muted-foreground">
                        {inst.pid}
                      </TableCell>
                      <TableCell className="px-5 font-mono text-[13px] text-muted-foreground">
                        {live && inst.uptimeMs !== null ? fmtUptime(inst.uptimeMs) : "—"}
                      </TableCell>
                      {statCols.map((label) => (
                        <TableCell
                          key={label}
                          className="px-5 text-right font-mono text-sm tabular-nums text-foreground"
                        >
                          {live && byLabel.has(label) ? fmtNum(byLabel.get(label)!) : "—"}
                        </TableCell>
                      ))}
                      <TableCell className="px-5">
                        <ChevronRight className="size-4 text-muted-foreground" />
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </Card>
      </div>
    </div>
  );
}
