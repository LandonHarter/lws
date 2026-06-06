"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export type Poll<T> = {
  data: T | null;
  error: string | null;
  loading: boolean;
  updatedAt: number | null;
  refresh: () => void;
};

export function usePoll<T>(fn: () => Promise<T>, intervalMs = 2000): Poll<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const fnRef = useRef(fn);
  fnRef.current = fn;

  const tick = useCallback(async () => {
    try {
      const next = await fnRef.current();
      setData(next);
      setError(null);
      setUpdatedAt(Date.now());
    } catch (e) {
      setError(e instanceof Error ? e.message : "request failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let alive = true;
    void tick();
    const id = setInterval(() => {
      if (alive) void tick();
    }, intervalMs);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [tick, intervalMs]);

  return { data, error, loading, updatedAt, refresh: tick };
}
