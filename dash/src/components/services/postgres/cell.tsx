"use client";

// Renders a single Postgres result cell. Over tRPC's JSON transport a row's
// values arrive as: string (text / bigint / numeric / timestamp), number,
// boolean, null, or a parsed object/array (json / jsonb).
export function PgCell({ value }: { value: unknown }) {
  if (value === null || value === undefined) {
    return (
      <span className="rounded border border-border bg-card/60 px-1 py-0.5 font-mono text-[10px] text-muted-foreground/70">
        NULL
      </span>
    );
  }

  if (typeof value === "boolean") {
    return <span className="font-mono text-xs text-foreground">{value ? "true" : "false"}</span>;
  }

  if (typeof value === "object") {
    const json = JSON.stringify(value);
    const short = json.length > 120 ? `${json.slice(0, 120)}…` : json;
    return (
      <span className="font-mono text-xs text-foreground" title={json}>
        {short}
      </span>
    );
  }

  const text = String(value);
  const short = text.length > 200 ? `${text.slice(0, 200)}…` : text;
  return (
    <span className="font-mono text-xs text-foreground" title={text.length > 200 ? text : undefined}>
      {short}
    </span>
  );
}
