import { z } from "zod";

export type AV =
  | { S: string }
  | { N: string }
  | { B: string }
  | { BOOL: boolean }
  | { NULL: true }
  | { L: AV[] }
  | { M: Record<string, AV> }
  | { SS: string[] }
  | { NS: string[] }
  | { BS: string[] };

export const attributeValue: z.ZodType<AV> = z.lazy(() =>
  z.union([
    z.object({ S: z.string() }),
    z.object({ N: z.string() }),
    z.object({ B: z.string() }),
    z.object({ BOOL: z.boolean() }),
    z.object({ NULL: z.literal(true) }),
    z.object({ L: z.array(attributeValue) }),
    z.object({ M: z.record(z.string(), attributeValue) }),
    z.object({ SS: z.array(z.string()) }),
    z.object({ NS: z.array(z.string()) }),
    z.object({ BS: z.array(z.string()) }),
  ]),
) as z.ZodType<AV>;

export const itemSchema = z.record(z.string(), attributeValue);
export type Item = Record<string, AV>;

export const AV_TYPES = ["S", "N", "B", "BOOL", "NULL", "L", "M", "SS", "NS", "BS"] as const;
export type AVType = (typeof AV_TYPES)[number];

// Editor-side form model. Map ordering is preserved as an array of entries so the
// editor can render stable rows; the canonical AV uses a plain object.
export type FormNode =
  | { type: "S" | "N" | "B"; value: string }
  | { type: "BOOL"; value: boolean }
  | { type: "NULL" }
  | { type: "SS" | "NS" | "BS"; items: string[] }
  | { type: "L"; items: FormNode[] }
  | { type: "M"; entries: { key: string; value: FormNode }[] };

export function avType(av: AV): AVType {
  return Object.keys(av)[0] as AVType;
}

export function emptyForm(type: AVType): FormNode {
  switch (type) {
    case "S":
    case "N":
    case "B":
      return { type, value: "" };
    case "BOOL":
      return { type, value: false };
    case "NULL":
      return { type };
    case "SS":
    case "NS":
    case "BS":
      return { type, items: [] };
    case "L":
      return { type, items: [] };
    case "M":
      return { type, entries: [] };
  }
}

export function formFromAttribute(av: AV): FormNode {
  const t = avType(av);
  switch (t) {
    case "S":
    case "N":
    case "B":
      return { type: t, value: (av as Record<string, string>)[t] };
    case "BOOL":
      return { type: "BOOL", value: (av as { BOOL: boolean }).BOOL };
    case "NULL":
      return { type: "NULL" };
    case "SS":
    case "NS":
    case "BS":
      return { type: t, items: [...(av as Record<string, string[]>)[t]] };
    case "L":
      return { type: "L", items: (av as { L: AV[] }).L.map(formFromAttribute) };
    case "M": {
      const m = (av as { M: Record<string, AV> }).M;
      return {
        type: "M",
        entries: Object.entries(m).map(([key, value]) => ({ key, value: formFromAttribute(value) })),
      };
    }
  }
}

export function attributeFromForm(node: FormNode): AV {
  switch (node.type) {
    case "S":
      return { S: node.value };
    case "N":
      return { N: node.value };
    case "B":
      return { B: node.value };
    case "BOOL":
      return { BOOL: node.value };
    case "NULL":
      return { NULL: true };
    case "SS":
      return { SS: [...node.items] };
    case "NS":
      return { NS: [...node.items] };
    case "BS":
      return { BS: [...node.items] };
    case "L":
      return { L: node.items.map(attributeFromForm) };
    case "M": {
      const m: Record<string, AV> = {};
      for (const e of node.entries) m[e.key] = attributeFromForm(e.value);
      return { M: m };
    }
  }
}

const NUM_RE = /^-?\d+(\.\d+)?(e[+-]?\d+)?$/i;
const B64_RE = /^[A-Za-z0-9+/]*={0,2}$/;

export function isValidNumber(s: string): boolean {
  return NUM_RE.test(s.trim());
}

export function isValidBase64(s: string): boolean {
  return s.length % 4 === 0 && B64_RE.test(s);
}

// Returns an error string for the node (recursively), or null if valid.
export function validateForm(node: FormNode): string | null {
  switch (node.type) {
    case "N":
      return isValidNumber(node.value) ? null : "invalid number";
    case "B":
      return isValidBase64(node.value) ? null : "invalid base64";
    case "SS":
    case "NS":
    case "BS": {
      if (node.items.length === 0) return "set must have at least one element";
      if (new Set(node.items).size !== node.items.length) return "duplicate set element";
      if (node.type === "NS" && !node.items.every(isValidNumber)) return "invalid number in set";
      if (node.type === "BS" && !node.items.every(isValidBase64)) return "invalid base64 in set";
      return null;
    }
    case "L": {
      for (const it of node.items) {
        const e = validateForm(it);
        if (e) return e;
      }
      return null;
    }
    case "M": {
      const keys = new Set<string>();
      for (const ent of node.entries) {
        if (ent.key.trim() === "") return "map key required";
        if (keys.has(ent.key)) return "duplicate map key";
        keys.add(ent.key);
        const e = validateForm(ent.value);
        if (e) return e;
      }
      return null;
    }
    default:
      return null;
  }
}

// Short, single-cell rendering of an AV for the item table.
export function avPreview(av: AV): string {
  const t = avType(av);
  switch (t) {
    case "S":
      return JSON.stringify((av as { S: string }).S);
    case "N":
      return (av as { N: string }).N;
    case "B":
      return `B(${(av as { B: string }).B.length}b64)`;
    case "BOOL":
      return String((av as { BOOL: boolean }).BOOL);
    case "NULL":
      return "null";
    case "L":
      return `L[${(av as { L: AV[] }).L.length}]`;
    case "M":
      return `M{${Object.keys((av as { M: Record<string, AV> }).M).length}}`;
    case "SS":
    case "NS":
    case "BS":
      return `${t}[${(av as Record<string, string[]>)[t].length}]`;
  }
}
