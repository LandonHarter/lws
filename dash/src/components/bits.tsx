import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { fmtNum } from "@/lib/format";
import type { Tone } from "@/lib/services";

export type { Tone };

const toneText: Record<Tone, string> = {
  visible: "text-visible",
  flight: "text-flight",
  delayed: "text-delayed",
  ok: "text-ok",
  down: "text-down",
  primary: "text-primary",
};

const toneBg: Record<Tone, string> = {
  visible: "bg-visible",
  flight: "bg-flight",
  delayed: "bg-delayed",
  ok: "bg-ok",
  down: "bg-down",
  primary: "bg-primary",
};

export function StatusDot({
  tone,
  ping: _ping = false,
  className,
}: {
  tone: "ok" | "down" | "idle";
  ping?: boolean;
  className?: string;
}) {
  const color = tone === "ok" ? "bg-ok" : tone === "down" ? "bg-down" : "bg-muted-foreground";
  return (
    <span className={cn("relative inline-flex size-2 shrink-0", className)}>
      <span className={cn("relative inline-flex size-2 rounded-full", color)} />
    </span>
  );
}

export function SectionLabel({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "text-[13px] font-medium text-muted-foreground",
        className,
      )}
    >
      {children}
    </div>
  );
}

export function MetricTile({
  label,
  value,
  icon: Icon,
  tone,
  hint,
  className,
}: {
  label: string;
  value: number;
  icon: LucideIcon;
  tone: Tone;
  hint?: string;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "group relative overflow-hidden rounded-lg border border-border bg-card p-4 transition-colors hover:border-foreground/15",
        className,
      )}
    >
      <div className="flex items-center justify-between">
        <span className="text-[13px] text-muted-foreground">{label}</span>
        <Icon className={cn("size-4", toneText[tone])} strokeWidth={1.75} />
      </div>
      <div className="mt-4 flex items-baseline gap-1.5">
        <span className="text-3xl font-semibold tabular-nums leading-none tracking-tight text-foreground">
          {fmtNum(value)}
        </span>
        {hint && <span className="text-xs text-muted-foreground">{hint}</span>}
      </div>
    </div>
  );
}

export function DistributionBar({
  visible,
  in_flight,
  delayed,
  className,
}: {
  visible: number;
  in_flight: number;
  delayed: number;
  className?: string;
}) {
  const total = visible + in_flight + delayed;
  if (total === 0) {
    return (
      <div
        className={cn(
          "lws-hatch h-2 w-full rounded-full border border-border/60",
          className,
        )}
        aria-label="empty"
      />
    );
  }
  const seg = (n: number) => `${(n / total) * 100}%`;
  return (
    <div
      className={cn(
        "flex h-2 w-full overflow-hidden rounded-full bg-muted/50",
        className,
      )}
    >
      {visible > 0 && <span className="bg-visible" style={{ width: seg(visible) }} />}
      {in_flight > 0 && <span className="bg-flight" style={{ width: seg(in_flight) }} />}
      {delayed > 0 && <span className="bg-delayed" style={{ width: seg(delayed) }} />}
    </div>
  );
}

export function Legend() {
  const items: { tone: Tone; label: string }[] = [
    { tone: "visible", label: "visible" },
    { tone: "flight", label: "in flight" },
    { tone: "delayed", label: "delayed" },
  ];
  return (
    <div className="flex items-center gap-4">
      {items.map((i) => (
        <span key={i.label} className="flex items-center gap-1.5">
          <span className={cn("size-2 rounded-full", toneBg[i.tone])} />
          <span className="text-[12px] text-muted-foreground">{i.label}</span>
        </span>
      ))}
    </div>
  );
}
