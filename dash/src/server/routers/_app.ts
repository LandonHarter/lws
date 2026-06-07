import { router } from "../trpc";
import { dynamodbRouter } from "./dynamodb";
import { lwsRouter } from "./lws";
import { s3Router } from "./s3";

export const appRouter = router({
    lws: lwsRouter,
    s3: s3Router,
    dynamodb: dynamodbRouter,
});

export type AppRouter = typeof appRouter;
