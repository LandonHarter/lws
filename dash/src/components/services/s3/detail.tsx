"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ChevronRight,
  Database,
  Download,
  File as FileIcon,
  Folder,
  FolderPlus,
  HardDrive,
  Package,
  Plus,
  RefreshCw,
  Sigma,
  Trash2,
  Upload,
} from "lucide-react";

import { fmtBytes, fmtNum } from "@/lib/format";
import { s3StatsSchema } from "@/lib/services";
import { trpc } from "@/lib/trpc";
import { cn } from "@/lib/utils";
import { MetricTile, SectionLabel } from "@/components/bits";
import { SyncStamp } from "@/components/services/shared";
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

const BUCKET_RE = /^[a-z0-9.-]{3,63}$/;

type Bucket = { name: string; creationDate: string | null };
type S3Object = { key: string; size: number; lastModified: string | null; etag: string };

function fmtDate(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-US", {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function readAsBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => {
      const s = String(r.result);
      const comma = s.indexOf(",");
      resolve(comma >= 0 ? s.slice(comma + 1) : s);
    };
    r.onerror = () => reject(r.error ?? new Error("read failed"));
    r.readAsDataURL(file);
  });
}

function downloadBlob(base64: string, contentType: string, filename: string) {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const url = URL.createObjectURL(new Blob([bytes], { type: contentType }));
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export function S3Detail({
  port,
  stats,
  updatedAt,
}: {
  name: string;
  port: number | null;
  stats: unknown;
  updatedAt: number | null;
}) {
  const parsed = s3StatsSchema.safeParse(stats);
  const totalBytes = parsed.success ? parsed.data.bytes : 0;

  const [buckets, setBuckets] = useState<Bucket[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [bucketErr, setBucketErr] = useState<string | null>(null);
  const [refreshNonce, setRefreshNonce] = useState(0);
  const refreshAll = useCallback(() => setRefreshNonce((n) => n + 1), []);

  const loadBuckets = useCallback(async () => {
    if (port === null) return;
    try {
      const res = await trpc.s3.listBuckets.query({ port });
      setBuckets(res.buckets);
      setBucketErr(null);
      setSelected((cur) => {
        if (cur && res.buckets.some((b) => b.name === cur)) return cur;
        return res.buckets[0]?.name ?? null;
      });
    } catch (e) {
      setBucketErr(e instanceof Error ? e.message : "failed to list buckets");
    }
  }, [port]);

  useEffect(() => {
    void loadBuckets();
  }, [loadBuckets, refreshNonce]);

  return (
    <>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <MetricTile
          label="Buckets"
          value={parsed.success ? parsed.data.buckets : buckets.length}
          icon={Package}
          tone="flight"
        />
        <MetricTile
          label="Objects"
          value={parsed.success ? parsed.data.objects : 0}
          icon={Database}
          tone="visible"
        />
        <MetricTile label="Bytes" value={totalBytes} icon={Sigma} tone="primary" hint={fmtBytes(totalBytes)} />
        <MetricTile label="Selected" value={selected ? 1 : 0} icon={HardDrive} tone="ok" hint={selected ?? "none"} />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[260px_1fr]">
        <BucketPane
          port={port}
          buckets={buckets}
          selected={selected}
          error={bucketErr}
          onSelect={setSelected}
          onChanged={refreshAll}
        />
        {selected ? (
          <ObjectPane
            key={selected}
            port={port}
            bucket={selected}
            refreshNonce={refreshNonce}
            updatedAt={updatedAt}
            onChanged={refreshAll}
          />
        ) : (
          <Card className="items-center justify-center rounded-lg border-border bg-card/50 p-0 ring-0">
            <div className="px-6 py-24 text-center font-mono text-sm text-muted-foreground">
              no bucket selected — create one to get started
            </div>
          </Card>
        )}
      </div>
    </>
  );
}

function BucketPane({
  port,
  buckets,
  selected,
  error,
  onSelect,
  onChanged,
}: {
  port: number | null;
  buckets: Bucket[];
  selected: string | null;
  error: string | null;
  onSelect: (name: string) => void;
  onChanged: () => void;
}) {
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const trimmed = name.trim();
  const valid = BUCKET_RE.test(trimmed);

  async function create() {
    if (port === null || !valid || busy) return;
    setBusy(true);
    setErr(null);
    try {
      await trpc.s3.createBucket.mutate({ port, bucket: trimmed });
      setName("");
      setCreating(false);
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "create failed");
    } finally {
      setBusy(false);
    }
  }

  async function remove(bucket: string) {
    if (port === null) return;
    if (!window.confirm(`Delete bucket "${bucket}"? It must be empty.`)) return;
    try {
      await trpc.s3.deleteBucket.mutate({ port, bucket });
      onChanged();
    } catch (e) {
      window.alert(e instanceof Error ? e.message : "delete failed");
    }
  }

  return (
    <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <SectionLabel>Buckets</SectionLabel>
        <Button type="button" variant="ghost" size="icon-xs" onClick={() => setCreating((c) => !c)}>
          <Plus className="size-3.5 text-muted-foreground" />
        </Button>
      </div>

      {creating && (
        <div className="space-y-2 border-b border-border px-4 py-3">
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void create()}
            placeholder="bucket-name"
            spellCheck={false}
            className="h-8 w-full rounded-md border border-border bg-card/60 px-2.5 font-mono text-[13px] text-foreground outline-none focus:border-foreground/30"
          />
          <div className="flex items-center justify-between gap-2">
            <span className="font-mono text-[10px] text-muted-foreground">
              {trimmed && !valid ? "3-63 chars: a-z 0-9 . -" : "dns-style name"}
            </span>
            <Button type="button" size="xs" disabled={!valid || busy} onClick={() => void create()}>
              {busy ? "…" : "Create"}
            </Button>
          </div>
          {err && <div className="font-mono text-[11px] text-down">{err}</div>}
        </div>
      )}

      {error && (
        <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">
          {error}
        </div>
      )}

      <div className="max-h-[460px] overflow-y-auto py-1">
        {buckets.length === 0 ? (
          <div className="px-4 py-10 text-center font-mono text-xs text-muted-foreground">
            no buckets yet
          </div>
        ) : (
          buckets.map((b) => (
            <div
              key={b.name}
              className={cn(
                "group flex items-center gap-2 px-3 py-1.5",
                selected === b.name ? "bg-primary/10" : "hover:bg-muted/40",
              )}
            >
              <button
                type="button"
                onClick={() => onSelect(b.name)}
                className="flex min-w-0 flex-1 items-center gap-2 text-left"
              >
                <Package
                  className={cn(
                    "size-3.5 shrink-0",
                    selected === b.name ? "text-primary" : "text-muted-foreground",
                  )}
                />
                <span
                  className={cn(
                    "truncate font-mono text-[13px]",
                    selected === b.name ? "text-foreground" : "text-muted-foreground",
                  )}
                >
                  {b.name}
                </span>
              </button>
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                className="opacity-0 transition-opacity group-hover:opacity-100"
                onClick={() => void remove(b.name)}
              >
                <Trash2 className="size-3 text-muted-foreground hover:text-down" />
              </Button>
            </div>
          ))
        )}
      </div>
    </Card>
  );
}

function ObjectPane({
  port,
  bucket,
  refreshNonce,
  updatedAt,
  onChanged,
}: {
  port: number | null;
  bucket: string;
  refreshNonce: number;
  updatedAt: number | null;
  onChanged: () => void;
}) {
  const [prefix, setPrefix] = useState("");
  const [objects, setObjects] = useState<S3Object[]>([]);
  const [folders, setFolders] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    if (port === null) return;
    setLoading(true);
    try {
      const res = await trpc.s3.listObjects.query({ port, bucket, prefix, delimiter: "/" });
      setObjects(res.objects);
      setFolders(res.prefixes);
      setErr(null);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed to list objects");
    } finally {
      setLoading(false);
    }
  }, [port, bucket, prefix]);

  useEffect(() => {
    void load();
  }, [load, refreshNonce]);

  const crumbs = useMemo(() => {
    const segs = prefix.split("/").filter(Boolean);
    const acc: { label: string; prefix: string }[] = [{ label: bucket, prefix: "" }];
    let cur = "";
    for (const s of segs) {
      cur += `${s}/`;
      acc.push({ label: s, prefix: cur });
    }
    return acc;
  }, [prefix, bucket]);

  async function upload(files: FileList | null) {
    if (port === null || !files || files.length === 0) return;
    setBusy(true);
    setErr(null);
    try {
      for (const file of Array.from(files)) {
        const base64 = await readAsBase64(file);
        await trpc.s3.putObject.mutate({
          port,
          bucket,
          key: prefix + file.name,
          base64,
          contentType: file.type || "application/octet-stream",
        });
      }
      await load();
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "upload failed");
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  async function newFolder() {
    if (port === null) return;
    const name = window.prompt("Folder name");
    if (!name) return;
    const clean = name.replace(/^\/+|\/+$/g, "");
    if (!clean) return;
    setBusy(true);
    try {
      await trpc.s3.putObject.mutate({ port, bucket, key: `${prefix}${clean}/`, base64: "" });
      await load();
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "create folder failed");
    } finally {
      setBusy(false);
    }
  }

  async function download(key: string) {
    if (port === null) return;
    try {
      const res = await trpc.s3.getObject.query({ port, bucket, key });
      downloadBlob(res.base64, res.contentType, key.split("/").pop() || key);
    } catch (e) {
      window.alert(e instanceof Error ? e.message : "download failed");
    }
  }

  async function remove(key: string) {
    if (port === null) return;
    if (!window.confirm(`Delete "${key}"?`)) return;
    try {
      await trpc.s3.deleteObject.mutate({ port, bucket, key });
      await load();
      onChanged();
    } catch (e) {
      window.alert(e instanceof Error ? e.message : "delete failed");
    }
  }

  const empty = !loading && objects.length === 0 && folders.length === 0;

  return (
    <Card className="gap-0 rounded-lg border-border bg-card/70 p-0 ring-0">
      <div className="flex flex-wrap items-center gap-2 border-b border-border px-4 py-3">
        <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1 font-mono text-[12px]">
          {crumbs.map((c, i) => (
            <span key={c.prefix} className="flex items-center gap-1">
              {i > 0 && <ChevronRight className="size-3 text-muted-foreground" />}
              <button
                type="button"
                onClick={() => setPrefix(c.prefix)}
                className={cn(
                  "max-w-[160px] truncate rounded px-1 hover:text-foreground",
                  i === crumbs.length - 1 ? "text-foreground" : "text-muted-foreground",
                )}
              >
                {c.label}
              </button>
            </span>
          ))}
        </div>
        <div className="flex items-center gap-1.5">
          <Button type="button" variant="ghost" size="icon-xs" onClick={() => void load()}>
            <RefreshCw className={cn("size-3.5 text-muted-foreground", loading && "animate-spin")} />
          </Button>
          <Button type="button" variant="outline" size="xs" disabled={busy} onClick={() => void newFolder()}>
            <FolderPlus className="size-3.5" />
            Folder
          </Button>
          <Button type="button" size="xs" disabled={busy} onClick={() => fileRef.current?.click()}>
            <Upload className="size-3.5" />
            {busy ? "Uploading…" : "Upload"}
          </Button>
          <input
            ref={fileRef}
            type="file"
            multiple
            hidden
            onChange={(e) => void upload(e.target.files)}
          />
        </div>
      </div>

      {err && (
        <div className="border-b border-down/20 bg-down/10 px-4 py-2 font-mono text-[11px] text-down">
          {err}
        </div>
      )}

      {empty ? (
        <div className="px-6 py-20 text-center font-mono text-sm text-muted-foreground">
          this folder is empty — upload a file to populate it
        </div>
      ) : (
        <Table>
          <TableHeader>
            <TableRow className="border-border hover:bg-transparent">
              <TableHead className="h-9 px-5 text-[12px] font-medium text-muted-foreground">
                name
              </TableHead>
              <TableHead className="h-9 px-5 text-right text-[12px] font-medium text-muted-foreground">
                size
              </TableHead>
              <TableHead className="h-9 px-5 text-[12px] font-medium text-muted-foreground">
                modified
              </TableHead>
              <TableHead className="h-9 w-[90px] px-5" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {folders.map((f) => {
              const label = f.slice(prefix.length).replace(/\/$/, "");
              return (
                <TableRow key={f} className="cursor-pointer border-border/60" onClick={() => setPrefix(f)}>
                  <TableCell className="px-5">
                    <span className="flex items-center gap-2 font-mono text-sm text-foreground">
                      <Folder className="size-3.5 text-flight" />
                      {label}/
                    </span>
                  </TableCell>
                  <TableCell className="px-5 text-right font-mono text-xs text-muted-foreground">—</TableCell>
                  <TableCell className="px-5 font-mono text-xs text-muted-foreground">—</TableCell>
                  <TableCell className="px-5" />
                </TableRow>
              );
            })}
            {objects.map((o) => {
              const label = o.key.slice(prefix.length);
              return (
                <TableRow key={o.key} className="border-border/60">
                  <TableCell className="px-5">
                    <span className="flex items-center gap-2 font-mono text-sm text-foreground">
                      <FileIcon className="size-3.5 text-muted-foreground" />
                      <span className="truncate">{label}</span>
                    </span>
                  </TableCell>
                  <TableCell className="px-5 text-right font-mono text-xs tabular-nums text-muted-foreground">
                    {fmtBytes(o.size)}
                  </TableCell>
                  <TableCell className="px-5 font-mono text-xs text-muted-foreground">
                    {fmtDate(o.lastModified)}
                  </TableCell>
                  <TableCell className="px-5">
                    <div className="flex items-center justify-end gap-1">
                      <Button type="button" variant="ghost" size="icon-xs" onClick={() => void download(o.key)}>
                        <Download className="size-3 text-muted-foreground" />
                      </Button>
                      <Button type="button" variant="ghost" size="icon-xs" onClick={() => void remove(o.key)}>
                        <Trash2 className="size-3 text-muted-foreground hover:text-down" />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}

      <div className="flex items-center justify-between border-t border-border px-4 py-2">
        <span className="font-mono text-[11px] text-muted-foreground">
          {fmtNum(folders.length)} folders · {fmtNum(objects.length)} objects
        </span>
        <SyncStamp updatedAt={updatedAt} />
      </div>
    </Card>
  );
}
