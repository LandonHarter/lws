"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import {
  ArrowUpRight,
  CornerDownLeft,
  Layers,
  LayoutGrid,
  Search,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { fmtTime } from "@/lib/format";
import { searchServices, serviceMeta } from "@/lib/services";
import { StatusDot } from "@/components/bits";
import { ThemeToggle } from "@/components/theme-toggle";

type NavItem = { href: string; label: string; icon: LucideIcon };

const NAV: NavItem[] = [
  { href: "/", label: "Overview", icon: LayoutGrid },
  { href: "/resources", label: "Resources", icon: Layers },
];

function useClock() {
  const [t, setT] = useState<number | null>(null);
  useEffect(() => {
    setT(Date.now());
    const id = setInterval(() => setT(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  return t;
}

function Brand() {
  return (
    <Link href="/" className="flex flex-col leading-tight">
      <span className="text-sm font-semibold tracking-tight text-foreground">Local Cloud</span>
      <span className="mt-0.5 text-xs text-muted-foreground">Control plane</span>
    </Link>
  );
}

function SideRail({ pathname }: { pathname: string }) {
  return (
    <aside className="fixed inset-y-0 left-0 z-30 flex w-60 flex-col border-r border-border bg-sidebar">
      <div className="px-5 pb-6 pt-6">
        <Brand />
      </div>

      <div className="mx-3 mb-4 rounded-lg bg-muted/60 px-3 py-2.5">
        <div className="flex items-center justify-between">
          <span className="text-xs text-muted-foreground">Region</span>
          <span className="text-xs tabular-nums text-foreground">us-local-1</span>
        </div>
        <div className="mt-1.5 flex items-center justify-between">
          <span className="text-xs text-muted-foreground">Endpoint</span>
          <span className="text-xs tabular-nums text-foreground">127.0.0.1</span>
        </div>
      </div>

      <nav className="flex flex-1 flex-col gap-0.5 px-3">
        {NAV.map((item) => {
          const active =
            item.href === "/"
              ? pathname === "/"
              : pathname === item.href || pathname.startsWith(`${item.href}/`);
          const Icon = item.icon;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors",
                active
                  ? "bg-muted font-medium text-foreground"
                  : "text-muted-foreground hover:bg-muted/60 hover:text-foreground",
              )}
            >
              <Icon
                className={cn("size-4", active ? "text-foreground" : "text-muted-foreground")}
                strokeWidth={1.75}
              />
              {item.label}
            </Link>
          );
        })}
      </nav>

      <div className="px-5 py-4">
        <div className="flex items-center gap-2">
          <StatusDot tone="ok" />
          <span className="text-xs text-foreground">Live</span>
          <span className="ml-auto text-xs text-muted-foreground">2s poll</span>
        </div>
        <div className="mt-2 text-xs text-muted-foreground">lws · v{process.env.LWS_VERSION}</div>
      </div>
    </aside>
  );
}

function Breadcrumbs({ pathname }: { pathname: string }) {
  const segs = pathname.split("/").filter(Boolean);
  const crumbs: { label: string; href?: string }[] = [{ label: "Control Plane", href: "/" }];
  if (segs.length >= 1) {
    crumbs.push({ label: serviceMeta(segs[0]).label, href: `/${segs[0]}` });
  }
  if (segs.length >= 2) {
    crumbs.push({ label: decodeURIComponent(segs[1]) });
  }

  return (
    <div className="flex items-center gap-2 text-sm">
      {crumbs.map((c, i) => {
        const last = i === crumbs.length - 1;
        return (
          <span key={i} className="flex items-center gap-2">
            {i > 0 && <span className="text-muted-foreground/40">/</span>}
            {c.href && !last ? (
              <Link href={c.href} className="text-muted-foreground transition-colors hover:text-foreground">
                {c.label}
              </Link>
            ) : (
              <span className={last ? "text-foreground" : "text-muted-foreground"}>{c.label}</span>
            )}
          </span>
        );
      })}
    </div>
  );
}

function ServiceSearch() {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const boxRef = useRef<HTMLDivElement>(null);

  const hits = searchServices(query);

  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, []);

  function go(id: string) {
    router.push(`/${id}`);
    setQuery("");
    setOpen(false);
  }

  return (
    <div ref={boxRef} className="relative hidden md:block">
      <div className="group flex w-72 items-center rounded-lg bg-muted/60 px-3 transition-colors focus-within:bg-muted">
        <Search className="size-4 text-muted-foreground" strokeWidth={1.75} />
        <input
          value={query}
          onFocus={() => setOpen(true)}
          onChange={(e) => {
            setQuery(e.target.value);
            setActive(0);
            setOpen(true);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setActive((a) => Math.min(a + 1, hits.length - 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setActive((a) => Math.max(a - 1, 0));
            } else if (e.key === "Enter" && hits[active]) {
              go(hits[active].id);
            } else if (e.key === "Escape") {
              setOpen(false);
            }
          }}
          placeholder="Search services…"
          className="h-9 w-full bg-transparent px-2.5 text-[13px] text-foreground outline-none placeholder:text-muted-foreground/60"
        />
      </div>

      {open && (
        <div className="absolute right-0 top-11 z-40 w-72 overflow-hidden rounded-lg border border-border bg-popover shadow-lg">
          {hits.length === 0 ? (
            <div className="px-3 py-4 text-center text-[13px] text-muted-foreground">
              no service types match
            </div>
          ) : (
            <ul className="py-1">
              {hits.map((m, i) => {
                const Icon = m.icon;
                return (
                  <li key={m.id}>
                    <button
                      onMouseEnter={() => setActive(i)}
                      onClick={() => go(m.id)}
                      className={cn(
                        "flex w-full items-center gap-2.5 px-3 py-2 text-left transition-colors",
                        i === active ? "bg-muted" : "hover:bg-muted/60",
                      )}
                    >
                      <span className="grid size-7 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground">
                        <Icon className="size-3.5" strokeWidth={1.75} />
                      </span>
                      <span className="flex min-w-0 flex-col leading-tight">
                        <span className="text-[13px] text-foreground">{m.label}</span>
                        <span className="truncate text-[11px] text-muted-foreground">
                          {m.title}
                        </span>
                      </span>
                      {i === active ? (
                        <CornerDownLeft className="ml-auto size-3.5 text-muted-foreground" />
                      ) : (
                        <ArrowUpRight className="ml-auto size-3.5 text-muted-foreground/50" />
                      )}
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}

function TopBar({ pathname }: { pathname: string }) {
  const t = useClock();
  return (
    <header className="sticky top-0 z-20 flex h-14 items-center justify-between gap-4 border-b border-border bg-background/80 px-8 backdrop-blur">
      <Breadcrumbs pathname={pathname} />
      <div className="flex items-center gap-4">
        <ServiceSearch />
        <span className="hidden items-center gap-2 sm:flex">
          <StatusDot tone="ok" />
          <span className="text-xs text-muted-foreground">Connected</span>
        </span>
        <span className="h-4 w-px bg-border" />
        <span className="text-sm tabular-nums text-muted-foreground">
          {t === null ? "--:--:--" : fmtTime(t)}
        </span>
        <ThemeToggle />
      </div>
    </header>
  );
}

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return (
    <div className="relative min-h-screen">
      <SideRail pathname={pathname} />
      <div className="ml-60 flex min-h-screen flex-col">
        <TopBar pathname={pathname} />
        <main className="mx-auto w-full max-w-[1180px] flex-1 px-8 py-8">{children}</main>
      </div>
    </div>
  );
}
