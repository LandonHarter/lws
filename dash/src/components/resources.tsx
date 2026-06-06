"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Activity, Boxes, ChevronRight, RefreshCw, Search, Server } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { usePoll } from "@/lib/use-poll";
import { fmtNum, fmtTime, fmtUptime } from "@/lib/format";
import { serviceMeta } from "@/lib/services";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel, StatusDot } from "@/components/bits";
import { Badge } from "@/components/ui/badge";
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

type OverviewData = Awaited<ReturnType<typeof trpc.lws.overview.query>>;
type EnrichedInstance = OverviewData["instances"][number];

function matches(inst: EnrichedInstance, q: string) {
  if (!q) return true;
  const meta = serviceMeta(inst.service);
  return (
    inst.name.toLowerCase().includes(q) ||
    inst.service.toLowerCase().includes(q) ||
    meta.label.toLowerCase().includes(q) ||
    meta.title.toLowerCase().includes(q)
  );
}

function StatsCell({ inst }: { inst: EnrichedInstance }) {
  if (inst.status !== "running") return <span className="text-muted-foreground">—</span>;
  const stats = serviceMeta(inst.service).headline(inst.stats);
  if (stats.length === 0) return <span className="text-muted-foreground">—</span>;
  return (
    <div className="flex items-center gap-3">
      {stats.map((s) => (
        <span key={s.key} className="flex items-baseline gap-1.5">
          <span className="tabular-nums text-foreground">{fmtNum(s.value)}</span>
          <span className="text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
            {s.label}
          </span>
        </span>
      ))}
    </div>
  );
}

function FilterBar({ query, setQuery }: { query: string; setQuery: (v: string) => void }) {
  return (
    <div className="group relative flex items-center rounded-md border border-border bg-card/60 px-3 transition-colors focus-within:border-foreground/30">
      <Search className="size-4 text-muted-foreground" strokeWidth={2} />
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Escape") setQuery("");
        }}
        placeholder="Filter resources by name or type…"
        className="h-11 w-full bg-transparent px-3 font-mono text-sm text-foreground outline-none placeholder:text-muted-foreground/60"
      />
      {query && (
        <button
          onClick={() => setQuery("")}
          className="font-mono text-[11px] uppercase tracking-wider text-muted-foreground transition-colors hover:text-foreground"
        >
          clear
        </button>
      )}
    </div>
  );
}

function HeaderBar({ updatedAt, onRefresh }: { updatedAt: number | null; onRefresh: () => void }) {
  return (
    <div className="flex items-end justify-between">
      <div>
        <SectionLabel>Resources</SectionLabel>
        <h1 className="mt-3 font-heading text-5xl leading-[0.9] tracking-wide text-foreground">
          RESOURCES
        </h1>
        <p className="mt-2 font-mono text-sm text-muted-foreground">
          Every running resource on this machine, regardless of type.
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

export function Resources() {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const { data, error, loading, updatedAt, refresh } = usePoll(
    () => trpc.lws.overview.query(),
    2500,
  );

  const all = data?.instances ?? [];
  const q = query.trim().toLowerCase();

  const filtered = useMemo(() => all.filter((i) => matches(i, q)), [all, q]);
  const running = filtered.filter((i) => i.status === "running").length;
  const types = new Set(filtered.map((i) => i.service)).size;

  return (
    <div className="space-y-8">
      <HeaderBar updatedAt={updatedAt} onRefresh={refresh} />

      <FilterBar query={query} setQuery={setQuery} />

      {error && !data && (
        <div className="rounded-md border border-down/30 bg-down/10 px-4 py-3 font-mono text-sm text-down">
          cli unreachable — {error}
        </div>
      )}

      <div className="grid grid-cols-3 gap-4">
        <MetricTile label="Resources" value={filtered.length} icon={Server} tone="primary" />
        <MetricTile
          label="Running"
          value={running}
          icon={Activity}
          tone="ok"
          hint={`/ ${filtered.length}`}
        />
        <MetricTile label="Service Types" value={types} icon={Boxes} tone="flight" />
      </div>

      <div className="space-y-4">
        <SectionLabel>{q ? `Matches · "${query}"` : "All Resources"}</SectionLabel>
        <Card className="overflow-hidden rounded-lg border-border bg-card/70 p-0 ring-0">
          {!data && loading ? (
            <div className="space-y-px p-3">
              {Array.from({ length: 4 }).map((_, i) => (
                <Skeleton key={i} className="h-12 rounded-md" />
              ))}
            </div>
          ) : filtered.length === 0 ? (
            <div className="px-6 py-16 text-center font-mono text-sm text-muted-foreground">
              {all.length === 0 ? "no resources running" : `no resources match "${query}"`}
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow className="border-border hover:bg-transparent">
                  {["status", "name", "type", "endpoint", "pid", "uptime", "stats", ""].map(
                    (h, i) => (
                      <TableHead
                        key={i}
                        className="h-9 px-5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground"
                      >
                        {h}
                      </TableHead>
                    ),
                  )}
                </TableRow>
              </TableHeader>
              <TableBody>
                {filtered.map((inst) => {
                  const live = inst.status === "running";
                  const meta = serviceMeta(inst.service);
                  return (
                    <TableRow
                      key={`${inst.service}/${inst.name}`}
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
                      <TableCell className="px-5">
                        <Badge
                          variant="outline"
                          className="h-4 px-1.5 font-mono text-[10px] uppercase tracking-wider text-muted-foreground"
                        >
                          {meta.label}
                        </Badge>
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
                      <TableCell className="px-5 font-mono text-[13px]">
                        <StatsCell inst={inst} />
                      </TableCell>
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
