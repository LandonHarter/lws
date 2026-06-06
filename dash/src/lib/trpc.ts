import { createTRPCClient, httpBatchLink } from "@trpc/client";
import type { AppRouter } from "@/server/routers/_app";

export const trpc = createTRPCClient<AppRouter>({
  links: [
    httpBatchLink({
      url: `http://localhost:${process.env.PORT ?? 3000}/api/trpc`,
    }),
  ],
});
