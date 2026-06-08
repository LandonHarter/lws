"use client";

import { Eye, Layers, Send, Sigma, Timer } from "lucide-react";

import { fmtNum } from "@/lib/format";
import { sqsStatsSchema } from "@/lib/services";
import { cn } from "@/lib/utils";
import { DistributionBar, Legend, MetricTile, SectionLabel } from "@/components/bits";
import { SyncStamp } from "@/components/services/shared";
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

export function SqsDetail({ stats, updatedAt }: { stats: unknown; updatedAt: number | null }) {
  const parsed = sqsStatsSchema.safeParse(stats);
  if (!parsed.success) {
    return (
      <div className="rounded-lg border border-border bg-card px-4 py-6 text-center text-sm text-muted-foreground">
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

        <Card className="overflow-hidden rounded-xl border-border bg-card p-0 ring-0">
          {s.detail.length === 0 ? (
            <div className="px-6 py-16 text-center text-sm text-muted-foreground">
              no queues created yet
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow className="border-border hover:bg-transparent">
                  <TableHead className="h-9 px-5 text-[12px] font-medium text-muted-foreground">
                    queue
                  </TableHead>
                  <TableHead className="h-9 px-5 text-[12px] font-medium text-muted-foreground">
                    kind
                  </TableHead>
                  {["visible", "in flight", "delayed"].map((h) => (
                    <TableHead
                      key={h}
                      className="h-9 px-5 text-right text-[12px] font-medium text-muted-foreground"
                    >
                      {h}
                    </TableHead>
                  ))}
                  <TableHead className="h-9 w-[180px] px-5 text-[12px] font-medium text-muted-foreground">
                    distribution
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {s.detail.map((q) => (
                  <TableRow key={q.name} className="border-border/60">
                    <TableCell className="px-5 text-sm font-medium text-foreground">
                      {q.name}
                    </TableCell>
                    <TableCell className="px-5">
                      <Badge
                        variant="outline"
                        className={cn(
                          "h-5 border-transparent px-1.5 text-[11px]",
                          q.kind === "fifo"
                            ? "bg-primary/10 text-primary"
                            : "bg-flight/10 text-flight",
                        )}
                      >
                        {q.kind}
                      </Badge>
                    </TableCell>
                    <TableCell className="px-5 text-right text-sm tabular-nums text-foreground">
                      {fmtNum(q.visible)}
                    </TableCell>
                    <TableCell className="px-5 text-right text-sm tabular-nums text-foreground">
                      {fmtNum(q.in_flight)}
                    </TableCell>
                    <TableCell className="px-5 text-right text-sm tabular-nums text-foreground">
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
