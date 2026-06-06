import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { delimiter, isAbsolute, join } from "node:path";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import { z } from "zod";

import { publicProcedure, router } from "../trpc";

const exec = promisify(execFile);

const LWS_BIN = process.env.LWS_BIN ?? "lws";
const LWS_ROOT = process.env.LWS_ROOT;

function resolveLwsBin(): string | null {
  if (isAbsolute(LWS_BIN)) {
    try {
      accessSync(LWS_BIN, constants.X_OK);
      return LWS_BIN;
    } catch {
      return null;
    }
  }

  const pathDirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const dir of pathDirs) {
    const candidate = join(dir, LWS_BIN);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // not here; keep searching
    }
  }
  return null;
}

type RunResult = {
  stdout: string;
  stderr: string;
};

async function lws(args: string[]): Promise<RunResult> {
  const bin = resolveLwsBin();
  if (!bin) {
    throw new Error(
      `lws CLI not found on PATH (looked for '${LWS_BIN}'). Add lws to your PATH to use the dashboard.`,
    );
  }
  const { stdout, stderr } = await exec(bin, args, {
    cwd: LWS_ROOT,
    maxBuffer: 16 * 1024 * 1024,
  });
  return { stdout, stderr };
}

const instanceSchema = z.object({
  service: z.string(),
  name: z.string(),
  pid: z.number(),
  port: z.number(),
  status: z.string(),
});

type Instance = z.infer<typeof instanceSchema>;

const runtimeStats = z.object({ uptime_ms: z.number() }).passthrough();

const infoEnvelope = z.object({
  service: z.string(),
  name: z.string(),
  pid: z.number(),
  port: z.number(),
  alive: z.boolean(),
  stats: z.unknown().nullable(),
});

type InfoEnvelope = z.infer<typeof infoEnvelope>;

async function infoFor(name: string, service?: string): Promise<InfoEnvelope | null> {
  const args = ["info", name, "--json"];
  if (service) args.push("--service", service);
  try {
    const { stdout } = await lws(args);
    const line = stdout.trim();
    if (!line.startsWith("{")) return null;
    const parsed = infoEnvelope.safeParse(JSON.parse(line));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

function parseInstances(stdout: string): Instance[] {
  const lines = stdout.split("\n");
  const out: Instance[] = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    if (trimmed === "no instances") continue;
    if (trimmed.startsWith("SERVICE")) continue;

    const cols = trimmed.split(/\s+/);
    if (cols.length < 5) continue;

    const [service, name, pid, port, status] = cols;
    out.push({
      service,
      name,
      pid: Number.parseInt(pid, 10),
      port: Number.parseInt(port, 10),
      status,
    });
  }
  return out;
}

export const lwsRouter = router({
  version: publicProcedure.query(async () => {
    const { stdout, stderr } = await lws(["version"]);
    return { version: stdout.trim(), stdout, stderr };
  }),

  list: publicProcedure.query(async () => {
    const { stdout, stderr } = await lws(["list"]);
    return { instances: parseInstances(stdout), stdout, stderr };
  }),

  info: publicProcedure
    .input(
      z.object({
        name: z.string().min(1),
        service: z.string().min(1).optional(),
      }),
    )
    .query(async ({ input }) => {
      const args = ["info", input.name, "--json"];
      if (input.service !== undefined) args.push("--service", input.service);

      let raw: RunResult;
      try {
        raw = await lws(args);
      } catch (err) {
        const e = err as { stdout?: string; stderr?: string; message?: string };
        const msg = (e.stdout ?? "").trim() || (e.stderr ?? "").trim() || e.message || "command failed";
        return { ok: false as const, error: msg, meta: null, uptimeMs: null, stats: null };
      }

      const line = raw.stdout.trim();
      if (!line.startsWith("{")) {
        return { ok: false as const, error: line || raw.stderr.trim() || "not found", meta: null, uptimeMs: null, stats: null };
      }

      const parsed = infoEnvelope.safeParse(JSON.parse(line));
      if (!parsed.success) {
        return { ok: false as const, error: "unrecognized info payload", meta: null, uptimeMs: null, stats: null };
      }

      const { stats, ...meta } = parsed.data;
      const rt = runtimeStats.safeParse(stats);
      return {
        ok: true as const,
        error: null,
        meta,
        uptimeMs: rt.success ? rt.data.uptime_ms : null,
        stats: stats ?? null,
      };
    }),

  overview: publicProcedure.query(async () => {
    const { stdout } = await lws(["list"]);
    const instances = parseInstances(stdout);

    const enriched = await Promise.all(
      instances.map(async (inst) => {
        const base = { ...inst, uptimeMs: null as number | null, stats: null as unknown };
        if (inst.status !== "running") return base;
        const env = await infoFor(inst.name, inst.service);
        const rt = runtimeStats.safeParse(env?.stats);
        return {
          ...base,
          uptimeMs: rt.success ? rt.data.uptime_ms : null,
          stats: env?.stats ?? null,
        };
      }),
    );

    const services = Array.from(new Set(instances.map((i) => i.service))).sort();
    const running = instances.filter((i) => i.status === "running").length;

    return {
      instances: enriched,
      services,
      counts: {
        total: instances.length,
        running,
        dead: instances.length - running,
        services: services.length,
      },
    };
  }),

  run: publicProcedure
    .input(
      z.object({
        service: z.string().min(1),
        port: z.number().int().positive().optional(),
        name: z.string().min(1).optional(),
        config: z.string().min(1).optional(),
        configJson: z.string().min(1).optional(),
      }),
    )
    .mutation(async ({ input }) => {
      const args = ["run", input.service];
      if (input.port !== undefined) args.push("--port", String(input.port));
      if (input.name !== undefined) args.push("--name", input.name);

      let tmpDir: string | null = null;
      if (input.configJson !== undefined) {
        tmpDir = await mkdtemp(join(tmpdir(), "lws-config-"));
        const configPath = join(tmpDir, `${input.service}.json`);
        await writeFile(configPath, input.configJson, "utf8");
        args.push("--config", configPath);
      } else if (input.config !== undefined) {
        args.push("--config", input.config);
      }

      const { stdout, stderr } = await lws(args);

      if (tmpDir) {
        const dir = tmpDir;
        setTimeout(() => void rm(dir, { recursive: true, force: true }), 30_000);
      }

      const started = /started (\S+) instance '([^']+)' \(pid (\d+)\) on port (\d+)/.exec(stdout);
      const logMatch = /logs: (.+)/.exec(stdout);

      return {
        stdout,
        stderr,
        started: started
          ? {
              service: started[1],
              name: started[2],
              pid: Number.parseInt(started[3], 10),
              port: Number.parseInt(started[4], 10),
            }
          : null,
        logPath: logMatch ? logMatch[1].trim() : null,
      };
    }),

  stop: publicProcedure
    .input(
      z.object({
        name: z.string().min(1),
        service: z.string().min(1).optional(),
        force: z.boolean().optional(),
      }),
    )
    .mutation(async ({ input }) => {
      const args = ["stop", input.name];
      if (input.service !== undefined) args.push("--service", input.service);
      if (input.force) args.push("--force");

      const { stdout, stderr } = await lws(args);
      return { stdout, stderr };
    }),

  start: publicProcedure
    .input(
      z.object({
        name: z.string().min(1),
        service: z.string().min(1).optional(),
      }),
    )
    .mutation(async ({ input }) => {
      const args = ["start", input.name];
      if (input.service !== undefined) args.push("--service", input.service);

      const { stdout, stderr } = await lws(args);
      return { stdout, stderr };
    }),

  delete: publicProcedure
    .input(
      z.object({
        name: z.string().min(1),
        service: z.string().min(1).optional(),
        force: z.boolean().optional(),
      }),
    )
    .mutation(async ({ input }) => {
      const args = ["delete", input.name];
      if (input.service !== undefined) args.push("--service", input.service);
      if (input.force) args.push("--force");

      const { stdout, stderr } = await lws(args);
      return { stdout, stderr };
    }),

  logs: publicProcedure
    .input(
      z.object({
        name: z.string().min(1),
        service: z.string().min(1).optional(),
      }),
    )
    .query(async ({ input }) => {
      const args = ["logs", input.name, "--once"];
      if (input.service !== undefined) args.push("--service", input.service);

      const { stdout, stderr } = await lws(args);
      return { logs: stdout, stderr };
    }),

  config: router({
    generate: publicProcedure
      .input(
        z.object({
          service: z.string().min(1),
          output: z.string().min(1).optional(),
        }),
      )
      .mutation(async ({ input }) => {
        const args = ["config", "generate", input.service];
        if (input.output !== undefined) args.push("--output", input.output);

        const { stdout, stderr } = await lws(args);
        return { stdout, stderr };
      }),
  }),
});
