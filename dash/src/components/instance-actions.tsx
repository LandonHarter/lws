"use client";

import { useState } from "react";
import { Play, Square, Trash2 } from "lucide-react";

import { trpc } from "@/lib/trpc";
import { Button } from "@/components/ui/button";

type Action = "stop" | "start" | "delete";

export function InstanceActions({
  service,
  name,
  status,
  onDone,
}: {
  service: string;
  name: string;
  status: string;
  onDone: () => void;
}) {
  const [busy, setBusy] = useState<Action | null>(null);
  const running = status === "running";

  async function fire(action: Action) {
    if (busy) return;
    if (action === "delete") {
      const ok = window.confirm(
        `Delete instance "${name}" and all its data permanently? This cannot be undone.`,
      );
      if (!ok) return;
    }
    setBusy(action);
    try {
      if (action === "stop") await trpc.lws.stop.mutate({ name, service });
      else if (action === "start") await trpc.lws.start.mutate({ name, service });
      else await trpc.lws.delete.mutate({ name, service, force: true });
      onDone();
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="flex items-center gap-1.5">
      {running ? (
        <Button
          size="xs"
          variant="outline"
          disabled={busy !== null}
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            void fire("stop");
          }}
        >
          <Square className="size-3" />
          Stop
        </Button>
      ) : (
        <Button
          size="xs"
          variant="outline"
          disabled={busy !== null}
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            void fire("start");
          }}
        >
          <Play className="size-3" />
          Start
        </Button>
      )}
      <Button
        size="xs"
        variant="destructive"
        disabled={busy !== null}
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          void fire("delete");
        }}
      >
        <Trash2 className="size-3" />
        Delete
      </Button>
    </div>
  );
}
