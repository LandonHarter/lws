"use client";

import { useState } from "react";
import { Play } from "lucide-react";

import { fmtNum } from "@/lib/format";
import { trpc } from "@/lib/trpc";
import { PgCell } from "@/components/services/postgres/cell";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const MAX_ROWS = 1000;

type QueryResult = Awaited<ReturnType<typeof trpc.postgres.runQuery.mutate>>;
type OkResult = Extract<QueryResult, { ok: true }>;
type ResultRow = OkResult["results"][number];

// Locate a 1-based character offset (Postgres error position) within the SQL.
function locate(sql: string, position: string | null): { line: number; col: number; text: string } | null {
  if (!position) return null;
  const pos = Number(position);
  if (!Number.isFinite(pos) || pos < 1) return null;
  const lines = sql.split("\n");
  let remaining = pos - 1;
  for (let i = 0; i < lines.length; i += 1) {
    if (remaining <= lines[i].length) return { line: i + 1, col: remaining, text: lines[i] };
    remaining -= lines[i].length + 1;
  }
  return null;
}

export function QueryConsole({ port, database }: { port: number; database: string }) {
  const [sql, setSql] = useState("");
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState<QueryResult | null>(null);
  const [connErr, setConnErr] = useState<string | null>(null);

  async function run() {
    if (sql.trim() === "" || running) return;
    setRunning(true);
    setConnErr(null);
    try {
      const res = await trpc.postgres.runQuery.mutate({ port, database, sql });
      setResult(res);
    } catch (e) {
      setResult(null);
      setConnErr(e instanceof Error ? e.message : "connection failed");
    } finally {
      setRunning(false);
    }
  }

  return (
    <div className="space-y-0">
      <div className="space-y-2 border-b border-border px-4 py-3">
        <textarea
          value={sql}
          onChange={(e) => setSql(e.target.value)}
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
              e.preventDefault();
              void run();
            }
          }}
          rows={5}
          spellCheck={false}
          placeholder="SELECT * FROM …"
          className="w-full resize-y rounded-md border border-border bg-card/60 px-3 py-2 font-mono text-[13px] leading-relaxed text-foreground outline-none focus:border-foreground/30"
        />
        <div className="flex items-center justify-between">
          <span className="font-mono text-[11px] text-muted-foreground">
            Runs against <span className="text-foreground">{database}</span> with full privileges (trust auth) — local dev database. ⌘/Ctrl+Enter to run.
          </span>
          <Button type="button" size="xs" disabled={running || sql.trim() === ""} onClick={() => void run()}>
            <Play className="size-3.5" />
            {running ? "running…" : "Run"}
          </Button>
        </div>
      </div>

      <div className="space-y-4 px-4 py-4">
        {connErr && (
          <Card className="gap-1 rounded-md border-down/40 bg-down/10 p-4 ring-0">
            <span className="font-mono text-[12px] text-down">{connErr}</span>
          </Card>
        )}

        {result && result.ok === false && (
          <Card className="gap-2 rounded-md border-down/40 bg-down/10 p-4 ring-0">
            <span className="font-mono text-[13px] text-down">{result.error.message}</span>
            {(() => {
              const loc = locate(sql, result.error.position);
              if (!loc) return null;
              return (
                <pre className="overflow-x-auto rounded border border-down/20 bg-background/60 p-2 font-mono text-[12px] leading-tight text-foreground">
                  {loc.text}
                  {"\n"}
                  {" ".repeat(loc.col)}^
                </pre>
              );
            })()}
            <div className="flex flex-wrap gap-x-4 gap-y-1 font-mono text-[11px] text-muted-foreground">
              {result.error.code && <span>code: {result.error.code}</span>}
              {result.error.detail && <span>detail: {result.error.detail}</span>}
              {result.error.hint && <span>hint: {result.error.hint}</span>}
            </div>
          </Card>
        )}

        {result && result.ok === true && (
          <>
            <span className="font-mono text-[11px] text-muted-foreground">
              {result.results.length} statement{result.results.length === 1 ? "" : "s"} · {result.elapsedMs}ms
            </span>
            {result.results.map((r, i) => (
              <ResultBlock key={i} result={r} />
            ))}
          </>
        )}
      </div>
    </div>
  );
}

function ResultBlock({ result }: { result: ResultRow }) {
  const rows = result.rows.slice(0, MAX_ROWS);
  const truncated = result.rows.length > MAX_ROWS;

  return (
    <Card className="gap-0 rounded-md border-border bg-card/60 p-0 ring-0">
      <div className="flex items-center gap-3 border-b border-border px-3 py-2 font-mono text-[11px] text-muted-foreground">
        <span className="text-foreground">{result.command}</span>
        <span>{fmtNum(result.rowCount)} rows</span>
        {truncated && <span className="text-delayed">showing first {MAX_ROWS}</span>}
      </div>

      {result.columns.length === 0 ? (
        <div className="px-3 py-3 font-mono text-[12px] text-muted-foreground">
          {result.command} {result.rowCount}
        </div>
      ) : (
        <div className="max-h-[420px] overflow-auto">
          <Table>
            <TableHeader>
              <TableRow className="border-border hover:bg-transparent">
                {result.columns.map((c, i) => (
                  <TableHead key={`${c}-${i}`} className="h-9 px-4 text-[12px] font-medium text-muted-foreground">
                    {c}
                  </TableHead>
                ))}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, ri) => (
                <TableRow key={ri} className="border-border/60">
                  {result.columns.map((c, ci) => (
                    <TableCell key={`${c}-${ci}`} className="px-4">
                      <PgCell value={row[c]} />
                    </TableCell>
                  ))}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </Card>
  );
}
