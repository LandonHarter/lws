"use client";

import { useEffect } from "react";

import { SectionLabel } from "@/components/bits";
import { type ServiceCreateFieldsProps } from "@/components/services/shared";
import { Card } from "@/components/ui/card";

// Rendered on /postgres/new. The full databases + seed-SQL form lands in phase
// 04; for now the instance launches with the default `postgres` database and
// everything else is managed from the detail page.
export function PostgresCreateFields({ onChange }: ServiceCreateFieldsProps) {
  useEffect(() => {
    onChange({ configJson: undefined, valid: true });
  }, [onChange]);

  return (
    <div className="space-y-4">
      <SectionLabel>Databases</SectionLabel>
      <Card className="rounded-lg border-dashed border-border bg-card/40 p-0 ring-0">
        <div className="px-6 py-12 text-center font-mono text-xs text-muted-foreground">
          instance starts with the default `postgres` database — create more from psql or the detail page after launch.
        </div>
      </Card>
    </div>
  );
}
