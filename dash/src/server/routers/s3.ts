import { TRPCError } from "@trpc/server";
import { z } from "zod";

import { publicProcedure, router } from "../trpc";

// The S3 service only checks that an Authorization header *starts with*
// "AWS4-HMAC-SHA256" (no signature verification), so a static stub passes.
const STUB_AUTH =
  "AWS4-HMAC-SHA256 Credential=lws/20240101/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=lws";

type FetchResult = { status: number; text: string; buffer: Buffer; contentType: string };

async function s3Fetch(
  port: number,
  method: string,
  path: string,
  opts: { body?: Uint8Array | string; headers?: Record<string, string> } = {},
): Promise<FetchResult> {
  const url = `http://127.0.0.1:${port}${path}`;
  const headers: Record<string, string> = {
    authorization: STUB_AUTH,
    ...opts.headers,
  };
  const init: RequestInit = { method, headers };
  // GET/HEAD must not carry a body. For body-bearing methods, send an explicit
  // (possibly empty) body so Content-Length is set — otherwise the server
  // blocks waiting for bytes it will never receive.
  if (method !== "GET" && method !== "HEAD") {
    init.body = (opts.body ?? "") as BodyInit;
  }
  let res: Response;
  try {
    res = await fetch(url, init);
  } catch (err) {
    throw new TRPCError({
      code: "INTERNAL_SERVER_ERROR",
      message: `s3 instance unreachable on port ${port}: ${(err as Error).message}`,
    });
  }
  const buffer = Buffer.from(await res.arrayBuffer());
  return {
    status: res.status,
    text: buffer.toString("utf8"),
    buffer,
    contentType: res.headers.get("content-type") ?? "application/octet-stream",
  };
}

// ---- tiny XML readers (S3 responses have a fixed, simple shape) ----------

function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function firstTag(xml: string, tag: string): string | undefined {
  const m = xml.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return m ? decodeEntities(m[1]) : undefined;
}

function blocks(xml: string, tag: string): string[] {
  const re = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, "g");
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) out.push(m[1]);
  return out;
}

function unquoteEtag(s: string | undefined): string {
  return (s ?? "").replace(/^"|"$/g, "");
}

function s3Error(res: FetchResult): TRPCError {
  const code = firstTag(res.text, "Code") ?? `HTTP ${res.status}`;
  const message = firstTag(res.text, "Message") ?? "request failed";
  const map: Record<string, TRPCError["code"]> = {
    NoSuchBucket: "NOT_FOUND",
    NoSuchKey: "NOT_FOUND",
    BucketNotEmpty: "CONFLICT",
    BucketAlreadyExists: "CONFLICT",
    InvalidBucketName: "BAD_REQUEST",
  };
  return new TRPCError({ code: map[code] ?? "INTERNAL_SERVER_ERROR", message: `${code}: ${message}` });
}

function ensureOk(res: FetchResult) {
  if (res.status >= 400) throw s3Error(res);
}

// ---- router --------------------------------------------------------------

const portInput = z.object({ port: z.number().int().positive() });

export const s3Router = router({
  listBuckets: publicProcedure.input(portInput).query(async ({ input }) => {
    const res = await s3Fetch(input.port, "GET", "/");
    ensureOk(res);
    return {
      buckets: blocks(res.text, "Bucket").map((b) => ({
        name: firstTag(b, "Name") ?? "",
        creationDate: firstTag(b, "CreationDate") ?? null,
      })),
    };
  }),

  createBucket: publicProcedure
    .input(portInput.extend({ bucket: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await s3Fetch(input.port, "PUT", `/${encodeURIComponent(input.bucket)}`);
      ensureOk(res);
      return { ok: true };
    }),

  deleteBucket: publicProcedure
    .input(portInput.extend({ bucket: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await s3Fetch(input.port, "DELETE", `/${encodeURIComponent(input.bucket)}`);
      ensureOk(res);
      return { ok: true };
    }),

  listObjects: publicProcedure
    .input(
      portInput.extend({
        bucket: z.string().min(1),
        prefix: z.string().optional(),
        delimiter: z.string().optional(),
        continuationToken: z.string().optional(),
        maxKeys: z.number().int().positive().max(1000).optional(),
      }),
    )
    .query(async ({ input }) => {
      const params = new URLSearchParams({ "list-type": "2" });
      if (input.prefix) params.set("prefix", input.prefix);
      if (input.delimiter) params.set("delimiter", input.delimiter);
      if (input.continuationToken) params.set("continuation-token", input.continuationToken);
      if (input.maxKeys) params.set("max-keys", String(input.maxKeys));
      const res = await s3Fetch(
        input.port,
        "GET",
        `/${encodeURIComponent(input.bucket)}/?${params.toString()}`,
      );
      ensureOk(res);
      return {
        objects: blocks(res.text, "Contents").map((c) => ({
          key: firstTag(c, "Key") ?? "",
          size: Number(firstTag(c, "Size") ?? "0"),
          lastModified: firstTag(c, "LastModified") ?? null,
          etag: unquoteEtag(firstTag(c, "ETag")),
        })),
        prefixes: blocks(res.text, "CommonPrefixes")
          .map((p) => firstTag(p, "Prefix") ?? "")
          .filter(Boolean),
        isTruncated: firstTag(res.text, "IsTruncated") === "true",
        nextContinuationToken: firstTag(res.text, "NextContinuationToken") ?? null,
      };
    }),

  getObject: publicProcedure
    .input(portInput.extend({ bucket: z.string().min(1), key: z.string().min(1) }))
    .query(async ({ input }) => {
      const res = await s3Fetch(
        input.port,
        "GET",
        `/${encodeURIComponent(input.bucket)}/${encodeKey(input.key)}`,
      );
      ensureOk(res);
      return {
        contentType: res.contentType,
        size: res.buffer.length,
        base64: res.buffer.toString("base64"),
      };
    }),

  putObject: publicProcedure
    .input(
      portInput.extend({
        bucket: z.string().min(1),
        key: z.string().min(1),
        base64: z.string(),
        contentType: z.string().optional(),
      }),
    )
    .mutation(async ({ input }) => {
      const body = new Uint8Array(Buffer.from(input.base64, "base64"));
      const res = await s3Fetch(
        input.port,
        "PUT",
        `/${encodeURIComponent(input.bucket)}/${encodeKey(input.key)}`,
        { body, headers: { "content-type": input.contentType ?? "application/octet-stream" } },
      );
      ensureOk(res);
      return { ok: true };
    }),

  deleteObject: publicProcedure
    .input(portInput.extend({ bucket: z.string().min(1), key: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await s3Fetch(
        input.port,
        "DELETE",
        `/${encodeURIComponent(input.bucket)}/${encodeKey(input.key)}`,
      );
      ensureOk(res);
      return { ok: true };
    }),

  deleteObjects: publicProcedure
    .input(portInput.extend({ bucket: z.string().min(1), keys: z.array(z.string().min(1)).min(1) }))
    .mutation(async ({ input }) => {
      const xml =
        "<Delete>" +
        input.keys.map((k) => `<Object><Key>${escapeXml(k)}</Key></Object>`).join("") +
        "</Delete>";
      const res = await s3Fetch(
        input.port,
        "POST",
        `/${encodeURIComponent(input.bucket)}/?delete`,
        { body: xml, headers: { "content-type": "application/xml" } },
      );
      ensureOk(res);
      return { deleted: blocks(res.text, "Deleted").map((d) => firstTag(d, "Key") ?? "") };
    }),
});

// Encode a key for use in a path while preserving "/" separators.
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
