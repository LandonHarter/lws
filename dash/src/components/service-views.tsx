"use client";

import { Eye, Layers, Send, Sigma, Timer } from "lucide-react";

import { fmtNum, fmtTime } from "@/lib/format";
import { aggregateStats, serviceMeta, sqsStatsSchema } from "@/lib/services";
import { cn } from "@/lib/utils";
import { DistributionBar, Legend, MetricTile, SectionLabel } from "@/components/bits";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

type DetailProps = { service: string; stats: unknown; updatedAt: number | null };

function SyncStamp({ updatedAt }: { updatedAt: number | null }) {
  return (
    <span className="font-mono text-[11px] text-muted-foreground">
      {updatedAt ? `synced ${fmtTime(updatedAt)}` : "syncing"}
    </span>
  );
}

function SqsDetail({ stats, updatedAt }: { stats: unknown; updatedAt: number | null }) {
  const parsed = sqsStatsSchema.safeParse(stats);
  if (!parsed.success) {
    return (
      <div className="rounded-md border border-border bg-card/40 px-4 py-6 text-center font-mono text-sm text-muted-foreground">
        stats endpoint unavailable
      </div>
    );
  }
  const s = parsed.data;
  const total = s.messages.visible + s.messages.in_flight + s.messages.delayed;

  return (
    <>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <MetricTile label="Visible" value={s.messages.visible} icon={Eye} tone="visible" />
        <MetricTile label="In Flight" value={s.messages.in_flight} icon={Send} tone="flight" />
        <MetricTile label="Delayed" value={s.messages.delayed} icon={Timer} tone="delayed" />
        <MetricTile label="Total" value={total} icon={Sigma} tone="primary" />
        <MetricTile label="Queues" value={s.queues} icon={Layers} tone="ok" />
      </div>

      <div className="space-y-4">
        <div className="flex items-end justify-between">
          <SectionLabel>Queues</SectionLabel>
          <div className="flex items-center gap-4">
            <Legend />
            <SyncStamp updatedAt={updatedAt} />
          </div>
        </div>

        <Card className="overflow-hidden rounded-lg border-border bg-card/70 p-0 ring-0">
          {s.detail.length === 0 ? (
            <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">
              no queues created yet
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow className="border-border hover:bg-transparent">
                  <TableHead className="h-9 px-5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                    queue
                  </TableHead>
                  <TableHead className="h-9 px-5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                    kind
                  </TableHead>
                  {["visible", "in flight", "delayed"].map((h) => (
                    <TableHead
                      key={h}
                      className="h-9 px-5 text-right font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground"
                    >
                      {h}
                    </TableHead>
                  ))}
                  <TableHead className="h-9 w-[180px] px-5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                    distribution
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {s.detail.map((q) => (
                  <TableRow key={q.name} className="border-border/60">
                    <TableCell className="px-5 font-mono text-sm text-foreground">
                      {q.name}
                    </TableCell>
                    <TableCell className="px-5">
                      <Badge
                        variant="outline"
                        className={cn(
                          "h-4 px-1.5 font-mono text-[10px] uppercase tracking-wider",
                          q.kind === "fifo"
                            ? "border-primary/30 bg-primary/10 text-primary"
                            : "border-flight/30 bg-flight/10 text-flight",
                        )}
                      >
                        {q.kind}
                      </Badge>
                    </TableCell>
                    <TableCell className="px-5 text-right font-mono text-sm tabular-nums text-foreground">
                      {fmtNum(q.visible)}
                    </TableCell>
                    <TableCell className="px-5 text-right font-mono text-sm tabular-nums text-foreground">
                      {fmtNum(q.in_flight)}
                    </TableCell>
                    <TableCell className="px-5 text-right font-mono text-sm tabular-nums text-foreground">
                      {fmtNum(q.delayed)}
                    </TableCell>
                    <TableCell className="px-5">
                      <DistributionBar
                        visible={q.visible}
                        in_flight={q.in_flight}
                        delayed={q.delayed}
                      />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Card>
      </div>
    </>
  );
}

function GenericDetail({ service, stats, updatedAt }: DetailProps) {
  const tiles = aggregateStats(service, [{ stats }]);
  const json = stats ? JSON.stringify(stats, null, 2) : null;

  return (
    <>
      {tiles.length > 0 && (
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
          {tiles.map((t) => (
            <MetricTile key={t.key} label={t.label} value={t.value} icon={t.icon} tone={t.tone} />
          ))}
        </div>
      )}

      <div className="space-y-4">
        <div className="flex items-end justify-between">
          <SectionLabel>Stats</SectionLabel>
          <SyncStamp updatedAt={updatedAt} />
        </div>
        <Card className="overflow-hidden rounded-lg border-border bg-card/70 p-0 ring-0">
          {json ? (
            <pre className="overflow-x-auto px-5 py-4 font-mono text-[13px] leading-relaxed text-muted-foreground">
              {json}
            </pre>
          ) : (
            <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">
              no stats reported
            </div>
          )}
        </Card>
      </div>
    </>
  );
}

export function ServiceDetail(props: DetailProps) {
  switch (serviceMeta(props.service).id) {
    case "sqs":
      return <SqsDetail stats={props.stats} updatedAt={props.updatedAt} />;
    default:
      return <GenericDetail {...props} />;
  }
}
