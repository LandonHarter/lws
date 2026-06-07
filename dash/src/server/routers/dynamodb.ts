import { TRPCError } from "@trpc/server";
import { z } from "zod";

import { attributeValue, itemSchema } from "@/lib/dynamodb-types";
import { publicProcedure, router } from "../trpc";

// The wire layer accepts any Authorization beginning with "AWS4-HMAC-SHA256"
// (no signature verification), so a static stub passes.
const STUB_AUTH =
  "AWS4-HMAC-SHA256 Credential=lws/20240101/us-east-1/dynamodb/aws4_request, SignedHeaders=host, Signature=lws";

const ERROR_MAP: Record<string, TRPCError["code"]> = {
  ValidationException: "BAD_REQUEST",
  SerializationException: "BAD_REQUEST",
  ResourceNotFoundException: "NOT_FOUND",
  ResourceInUseException: "CONFLICT",
  ConditionalCheckFailedException: "CONFLICT",
  UnknownOperationException: "BAD_REQUEST",
};

// POST a DynamoDB JSON 1.0 request to the running instance and return the parsed
// response body. Maps the AWS error envelope onto a TRPCError.
async function ddb(port: number, op: string, body: unknown): Promise<Record<string, unknown>> {
  let res: Response;
  try {
    res = await fetch(`http://127.0.0.1:${port}/`, {
      method: "POST",
      headers: {
        authorization: STUB_AUTH,
        "content-type": "application/x-amz-json-1.0",
        "x-amz-target": `DynamoDB_20120810.${op}`,
      },
      body: JSON.stringify(body ?? {}),
    });
  } catch (err) {
    throw new TRPCError({
      code: "INTERNAL_SERVER_ERROR",
      message: `dynamodb instance unreachable on port ${port}: ${(err as Error).message}`,
    });
  }

  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text) as Record<string, unknown>;
    } catch {
      throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: `bad response: ${text.slice(0, 200)}` });
    }
  }

  if (res.status >= 400) {
    const type = String(parsed.__type ?? "");
    const code = type.includes("#") ? type.slice(type.indexOf("#") + 1) : type || `HTTP ${res.status}`;
    const message = String(parsed.message ?? parsed.Message ?? "request failed");
    throw new TRPCError({ code: ERROR_MAP[code] ?? "INTERNAL_SERVER_ERROR", message: `${code}: ${message}` });
  }

  return parsed;
}

const portInput = z.object({ port: z.number().int().positive() });
const tableInput = portInput.extend({ table: z.string().min(1) });

const keyDef = z.object({
  AttributeName: z.string().min(1),
  KeyType: z.enum(["HASH", "RANGE"]),
});
const attrDef = z.object({
  AttributeName: z.string().min(1),
  AttributeType: z.enum(["S", "N", "B"]),
});
const projection = z.object({
  ProjectionType: z.enum(["ALL", "KEYS_ONLY", "INCLUDE"]),
  NonKeyAttributes: z.array(z.string()).optional(),
});
const gsi = z.object({
  IndexName: z.string().min(1),
  KeySchema: z.array(keyDef).min(1).max(2),
  Projection: projection,
});

const createTableInput = portInput.extend({
  TableName: z.string().min(1),
  AttributeDefinitions: z.array(attrDef).min(1),
  KeySchema: z.array(keyDef).min(1).max(2),
  BillingMode: z.enum(["PROVISIONED", "PAY_PER_REQUEST"]).optional(),
  GlobalSecondaryIndexes: z.array(gsi).optional(),
});

const exprNames = z.record(z.string(), z.string()).optional();
const exprValues = z.record(z.string(), attributeValue).optional();

const scanInput = portInput.extend({
  table: z.string().min(1),
  indexName: z.string().optional(),
  filterExpression: z.string().optional(),
  expressionAttributeNames: exprNames,
  expressionAttributeValues: exprValues,
  limit: z.number().int().positive().max(1000).optional(),
  exclusiveStartKey: itemSchema.optional(),
});

const queryInput = scanInput.extend({
  keyConditionExpression: z.string().min(1),
});

type ScanResult = {
  items: Record<string, unknown>[];
  count: number;
  scannedCount: number;
  lastEvaluatedKey: Record<string, unknown> | null;
};

function shapeScan(res: Record<string, unknown>): ScanResult {
  return {
    items: (res.Items as Record<string, unknown>[]) ?? [],
    count: Number(res.Count ?? 0),
    scannedCount: Number(res.ScannedCount ?? 0),
    lastEvaluatedKey: (res.LastEvaluatedKey as Record<string, unknown>) ?? null,
  };
}

export const dynamodbRouter = router({
  listTables: publicProcedure.input(portInput).query(async ({ input }) => {
    const res = await ddb(input.port, "ListTables", {});
    return { tables: ((res.TableNames as string[]) ?? []) };
  }),

  describeTable: publicProcedure.input(tableInput).query(async ({ input }) => {
    const res = await ddb(input.port, "DescribeTable", { TableName: input.table });
    return { table: (res.Table as Record<string, unknown>) ?? {} };
  }),

  createTable: publicProcedure.input(createTableInput).mutation(async ({ input }) => {
    const { port, ...body } = input;
    await ddb(port, "CreateTable", body);
    return { ok: true };
  }),

  deleteTable: publicProcedure.input(tableInput).mutation(async ({ input }) => {
    await ddb(input.port, "DeleteTable", { TableName: input.table });
    return { ok: true };
  }),

  scan: publicProcedure.input(scanInput).query(async ({ input }) => {
    const res = await ddb(input.port, "Scan", {
      TableName: input.table,
      IndexName: input.indexName,
      FilterExpression: input.filterExpression || undefined,
      ExpressionAttributeNames: input.expressionAttributeNames,
      ExpressionAttributeValues: input.expressionAttributeValues,
      Limit: input.limit,
      ExclusiveStartKey: input.exclusiveStartKey,
    });
    return shapeScan(res);
  }),

  query: publicProcedure.input(queryInput).query(async ({ input }) => {
    const res = await ddb(input.port, "Query", {
      TableName: input.table,
      IndexName: input.indexName,
      KeyConditionExpression: input.keyConditionExpression,
      FilterExpression: input.filterExpression || undefined,
      ExpressionAttributeNames: input.expressionAttributeNames,
      ExpressionAttributeValues: input.expressionAttributeValues,
      Limit: input.limit,
      ExclusiveStartKey: input.exclusiveStartKey,
    });
    return shapeScan(res);
  }),

  getItem: publicProcedure
    .input(tableInput.extend({ key: itemSchema }))
    .query(async ({ input }) => {
      const res = await ddb(input.port, "GetItem", { TableName: input.table, Key: input.key });
      return { item: (res.Item as Record<string, unknown>) ?? null };
    }),

  putItem: publicProcedure
    .input(tableInput.extend({ item: itemSchema }))
    .mutation(async ({ input }) => {
      await ddb(input.port, "PutItem", { TableName: input.table, Item: input.item });
      return { ok: true };
    }),

  updateItem: publicProcedure
    .input(
      tableInput.extend({
        key: itemSchema,
        updateExpression: z.string().min(1),
        expressionAttributeNames: exprNames,
        expressionAttributeValues: exprValues,
      }),
    )
    .mutation(async ({ input }) => {
      await ddb(input.port, "UpdateItem", {
        TableName: input.table,
        Key: input.key,
        UpdateExpression: input.updateExpression,
        ExpressionAttributeNames: input.expressionAttributeNames,
        ExpressionAttributeValues: input.expressionAttributeValues,
      });
      return { ok: true };
    }),

  deleteItem: publicProcedure
    .input(tableInput.extend({ key: itemSchema }))
    .mutation(async ({ input }) => {
      await ddb(input.port, "DeleteItem", { TableName: input.table, Key: input.key });
      return { ok: true };
    }),
});
