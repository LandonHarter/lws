export type ConfigFieldType = "integer" | "boolean" | "string" | "json";

export type ConfigField = {
  name: string;
  label: string;
  type: ConfigFieldType;
  group: string;
  help?: string;
  default?: string | number | boolean;
  min?: number;
  max?: number;
  allowed?: string[];
  createOnly?: boolean;
  fifoOnly?: boolean;
};

export type ServiceConfigSpec = {
  id: string;
  defaultPort: number;
  fifoField: string | null;
  queueNameLabel: string;
  fields: ConfigField[];
};

const SQS_FIELDS: ConfigField[] = [
  {
    name: "FifoQueue",
    label: "FIFO queue",
    type: "boolean",
    group: "Type",
    default: false,
    createOnly: true,
    help: "First-in-first-out delivery with exactly-once processing. Cannot be changed after creation.",
  },
  {
    name: "VisibilityTimeout",
    label: "Visibility timeout (s)",
    type: "integer",
    group: "Delivery",
    default: 30,
    min: 0,
    max: 43200,
    help: "Seconds a received message stays hidden from other consumers.",
  },
  {
    name: "DelaySeconds",
    label: "Delivery delay (s)",
    type: "integer",
    group: "Delivery",
    default: 0,
    min: 0,
    max: 900,
    help: "Seconds to delay every message before it becomes visible.",
  },
  {
    name: "ReceiveMessageWaitTimeSeconds",
    label: "Receive wait time (s)",
    type: "integer",
    group: "Delivery",
    default: 0,
    min: 0,
    max: 20,
    help: "Long-poll wait time for ReceiveMessage.",
  },
  {
    name: "MaximumMessageSize",
    label: "Max message size (bytes)",
    type: "integer",
    group: "Message",
    default: 1048576,
    min: 1024,
    max: 1048576,
  },
  {
    name: "MessageRetentionPeriod",
    label: "Retention period (s)",
    type: "integer",
    group: "Message",
    default: 345600,
    min: 60,
    max: 1209600,
    help: "Seconds a message is kept before being discarded.",
  },
  {
    name: "ContentBasedDeduplication",
    label: "Content-based dedup",
    type: "boolean",
    group: "FIFO",
    default: false,
    fifoOnly: true,
    help: "Derive the deduplication ID from a SHA-256 of the message body.",
  },
  {
    name: "DeduplicationScope",
    label: "Deduplication scope",
    type: "string",
    group: "FIFO",
    default: "queue",
    allowed: ["queue", "messageGroup"],
    fifoOnly: true,
  },
  {
    name: "FifoThroughputLimit",
    label: "Throughput limit",
    type: "string",
    group: "FIFO",
    default: "perQueue",
    allowed: ["perQueue", "perMessageGroupId"],
    fifoOnly: true,
  },
  {
    name: "SqsManagedSseEnabled",
    label: "SQS-managed SSE",
    type: "boolean",
    group: "Encryption",
    default: true,
    help: "Enable encryption at rest with an SQS-owned key.",
  },
  {
    name: "KmsMasterKeyId",
    label: "KMS master key ID",
    type: "string",
    group: "Encryption",
    help: "Use a customer KMS key instead of the SQS-managed key.",
  },
  {
    name: "KmsDataKeyReusePeriodSeconds",
    label: "KMS data key reuse (s)",
    type: "integer",
    group: "Encryption",
    default: 300,
    min: 60,
    max: 86400,
  },
  {
    name: "Policy",
    label: "Access policy",
    type: "json",
    group: "Advanced",
    help: "IAM access policy document (JSON).",
  },
  {
    name: "RedrivePolicy",
    label: "Redrive policy",
    type: "json",
    group: "Advanced",
    help: "Dead-letter queue configuration (JSON).",
  },
  {
    name: "RedriveAllowPolicy",
    label: "Redrive allow policy",
    type: "json",
    group: "Advanced",
    help: "Which source queues may use this queue as a DLQ (JSON).",
  },
];

const REGISTRY: Record<string, ServiceConfigSpec> = {
  sqs: {
    id: "sqs",
    defaultPort: 9324,
    fifoField: "FifoQueue",
    queueNameLabel: "Queue name",
    fields: SQS_FIELDS,
  },
  s3: {
    id: "s3",
    defaultPort: 9000,
    fifoField: null,
    queueNameLabel: "Bucket name",
    fields: [],
  },
  dynamodb: {
    id: "dynamodb",
    defaultPort: 8000,
    fifoField: null,
    queueNameLabel: "Table name",
    fields: [],
  },
};

export function serviceConfigSpec(id: string): ServiceConfigSpec | null {
  return REGISTRY[id] ?? null;
}

export const GROUP_ORDER = [
  "Type",
  "Delivery",
  "Message",
  "FIFO",
  "Encryption",
  "Advanced",
];
