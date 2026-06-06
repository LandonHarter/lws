"use client";

import { fmtTime } from "@/lib/format";
import type { ServiceConfigSpec } from "@/lib/service-config";

export type DetailProps = {
  service: string;
  name: string;
  port: number | null;
  stats: unknown;
  updatedAt: number | null;
};

export const NAME_RE = /^[A-Za-z0-9_.-]{1,80}$/;

export type ServiceCreateValue = { configJson: string | undefined; valid: boolean };

export type ServiceCreateFieldsProps = {
  spec: ServiceConfigSpec;
  onChange: (value: ServiceCreateValue) => void;
};

export function SyncStamp({ updatedAt }: { updatedAt: number | null }) {
  return (
    <span className="font-mono text-[11px] text-muted-foreground">
      {updatedAt ? `synced ${fmtTime(updatedAt)}` : "syncing"}
    </span>
  );
}
