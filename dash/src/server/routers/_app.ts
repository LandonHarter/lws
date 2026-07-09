import { router } from "../trpc";
import { dynamodbRouter } from "./dynamodb";
import { lwsRouter } from "./lws";
import { postgresRouter } from "./postgres";
import { s3Router } from "./s3";

export const appRouter = router({
    lws: lwsRouter,
    s3: s3Router,
    dynamodb: dynamodbRouter,
    postgres: postgresRouter,
});

export type AppRouter = typeof appRouter;
