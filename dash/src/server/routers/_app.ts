import { router } from "../trpc";
import { lwsRouter } from "./lws";
import { s3Router } from "./s3";

export const appRouter = router({
    lws: lwsRouter,
    s3: s3Router,
});

export type AppRouter = typeof appRouter;
