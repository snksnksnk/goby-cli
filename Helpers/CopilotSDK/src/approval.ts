import { createHash, timingSafeEqual } from "node:crypto";

export const maximumApprovalDetailsBytes = 8_000;

export type CanonicalApprovalDisclosure = {
  details: string | undefined;
  operationDigest: string | undefined;
  disclosureComplete: boolean;
};

/**
 * Produces one deterministic JSON representation for both disclosure and
 * authorization binding. Values that JSON would silently discard are rejected
 * so an approval can never describe fewer fields than the provider will use.
 */
export function canonicalApprovalDisclosure(
  operation: unknown,
  maximumBytes = maximumApprovalDetailsBytes,
): CanonicalApprovalDisclosure {
  try {
    const details = canonicalJSON(operation);
    const operationDigest = sha256(details);
    if (Buffer.byteLength(details, "utf8") > maximumBytes) {
      return { details: undefined, operationDigest, disclosureComplete: false };
    }
    return { details, operationDigest, disclosureComplete: true };
  } catch {
    return { details: undefined, operationDigest: undefined, disclosureComplete: false };
  }
}

export function canonicalOperationDigest(operation: unknown): string | undefined {
  try {
    return sha256(canonicalJSON(operation));
  } catch {
    return undefined;
  }
}

export function operationDigestMatches(expected: unknown, actual: unknown): boolean {
  if (typeof expected !== "string" || typeof actual !== "string") return false;
  if (!/^[a-f0-9]{64}$/.test(expected) || !/^[a-f0-9]{64}$/.test(actual)) return false;
  return timingSafeEqual(Buffer.from(expected, "hex"), Buffer.from(actual, "hex"));
}

export function approvalBindingIsValid(
  disclosureComplete: boolean,
  expectedDigest: unknown,
  currentOperation: unknown,
  responseDigest: unknown,
): boolean {
  return disclosureComplete
    && operationDigestMatches(expectedDigest, canonicalOperationDigest(currentOperation))
    && operationDigestMatches(expectedDigest, responseDigest);
}

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function canonicalJSON(value: unknown, ancestors = new Set<object>()): string {
  if (value === null) return "null";
  switch (typeof value) {
    case "string":
      return JSON.stringify(value);
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) throw new TypeError("Non-finite numbers are not canonical JSON.");
      return JSON.stringify(value);
    case "object": {
      if (ancestors.has(value)) throw new TypeError("Cyclic values are not canonical JSON.");
      const prototype = Object.getPrototypeOf(value);
      if (prototype !== Object.prototype && prototype !== Array.prototype && prototype !== null) {
        throw new TypeError("Only plain JSON objects and arrays are approval-safe.");
      }
      if (Object.getOwnPropertySymbols(value).length > 0) {
        throw new TypeError("Symbol fields are not canonical JSON.");
      }
      ancestors.add(value);
      try {
        if (Array.isArray(value)) {
          return `[${value.map((element) => canonicalJSON(element, ancestors)).join(",")}]`;
        }
        const object = value as Record<string, unknown>;
        return `{${Object.keys(object)
          .sort()
          .map((key) => `${JSON.stringify(key)}:${canonicalJSON(object[key], ancestors)}`)
          .join(",")}}`;
      } finally {
        ancestors.delete(value);
      }
    }
    default:
      throw new TypeError(`Unsupported approval value: ${typeof value}.`);
  }
}
