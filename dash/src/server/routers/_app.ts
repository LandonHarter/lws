import { router } from "../trpc";
import { lwsRouter } from "./lws";

export const appRouter = router({
    lws: lwsRouter
});

export type AppRouter = typeof appRouter;
