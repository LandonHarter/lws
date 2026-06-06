import { Boxes, Inbox, Layers, Server, type LucideIcon } from "lucide-react";
import { z } from "zod";

export type Tone = "visible" | "flight" | "delayed" | "ok" | "down" | "primary";

export type ServiceStat = {
  key: string;
  label: string;
  value: number;
  tone: Tone;
  icon: LucideIcon;
};

export type ServiceMeta = {
  id: string;
  label: string;
  title: string;
  blurb: string;
  icon: LucideIcon;
  headline: (stats: unknown) => ServiceStat[];
};

export const sqsStatsSchema = z.object({
  service: z.string(),
  uptime_ms: z.number(),
  queues: z.number(),
  messages: z.object({
    visible: z.number(),
    in_flight: z.number(),
    delayed: z.number(),
  }),
  detail: z.array(
    z.object({
      name: z.string(),
      kind: z.string(),
      visible: z.number(),
      in_flight: z.number(),
      delayed: z.number(),
    }),
  ),
});

export type SqsStats = z.infer<typeof sqsStatsSchema>;

function sqsHeadline(raw: unknown): ServiceStat[] {
  const p = sqsStatsSchema.safeParse(raw);
  if (!p.success) return [];
  const m = p.data.messages;
  return [
    { key: "queues", label: "Queues", value: p.data.queues, tone: "flight", icon: Layers },
    {
      key: "messages",
      label: "Messages",
      value: m.visible + m.in_flight + m.delayed,
      tone: "visible",
      icon: Inbox,
    },
  ];
}

const REGISTRY: Record<string, ServiceMeta> = {
  sqs: {
    id: "sqs",
    label: "SQS",
    title: "Simple Queue Service",
    blurb: "Fully-managed message queues, running on local metal.",
    icon: Boxes,
    headline: sqsHeadline,
  },
};

export function serviceMeta(id: string): ServiceMeta {
  return (
    REGISTRY[id] ?? {
      id,
      label: id.toUpperCase(),
      title: id,
      blurb: "Local service instance.",
      icon: Server,
      headline: () => [],
    }
  );
}

export function allServices(): ServiceMeta[] {
  return Object.values(REGISTRY);
}

export function searchServices(query: string): ServiceMeta[] {
  const q = query.trim().toLowerCase();
  if (!q) return allServices();
  return allServices().filter(
    (m) =>
      m.id.toLowerCase().includes(q) ||
      m.label.toLowerCase().includes(q) ||
      m.title.toLowerCase().includes(q),
  );
}

export function aggregateStats(service: string, instances: { stats?: unknown }[]): ServiceStat[] {
  const meta = serviceMeta(service);
  const acc = new Map<string, ServiceStat>();
  for (const inst of instances) {
    for (const s of meta.headline(inst.stats)) {
      const cur = acc.get(s.key);
      if (cur) cur.value += s.value;
      else acc.set(s.key, { ...s });
    }
  }
  return [...acc.values()];
}
