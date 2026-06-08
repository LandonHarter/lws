"use client";

import { aggregateStats } from "@/lib/services";
import { MetricTile, SectionLabel } from "@/components/bits";
import { DetailProps, SyncStamp } from "@/components/services/shared";
import { Card } from "@/components/ui/card";

export function GenericDetail({ service, stats, updatedAt }: DetailProps) {
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
        <Card className="overflow-hidden rounded-xl border-border bg-card p-0 ring-0">
          {json ? (
            <pre className="overflow-x-auto px-5 py-4 text-[13px] leading-relaxed text-muted-foreground">
              {json}
            </pre>
          ) : (
            <div className="px-6 py-16 text-center text-sm text-muted-foreground">
              no stats reported
            </div>
          )}
        </Card>
      </div>
    </>
  );
}
