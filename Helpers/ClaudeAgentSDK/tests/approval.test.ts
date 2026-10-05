import assert from "node:assert/strict";
import test from "node:test";
import {
  approvalBindingIsValid,
  canonicalApprovalDisclosure,
  canonicalOperationDigest,
  operationDigestMatches,
} from "../src/approval.js";

test("canonical approval details bind every field independent of key order", () => {
  const first = canonicalApprovalDisclosure({ toolName: "Write", input: { z: 2, a: "value" } });
  const reordered = canonicalApprovalDisclosure({ input: { a: "value", z: 2 }, toolName: "Write" });

  assert.equal(first.disclosureComplete, true);
  assert.equal(first.details, '{"input":{"a":"value","z":2},"toolName":"Write"}');
  assert.equal(first.operationDigest, reordered.operationDigest);
  assert.equal(operationDigestMatches(first.operationDigest, canonicalOperationDigest({
    input: { a: "value", z: 2 },
    toolName: "Write",
  })), true);
});

test("oversized and lossy operation values are decline-only", () => {
  const oversized = canonicalApprovalDisclosure({ input: "x".repeat(200) }, 64);
  const lossy = canonicalApprovalDisclosure({ input: undefined });

  assert.equal(oversized.disclosureComplete, false);
  assert.equal(oversized.details, undefined);
  assert.match(oversized.operationDigest ?? "", /^[a-f0-9]{64}$/);
  assert.deepEqual(lossy, {
    details: undefined,
    operationDigest: undefined,
    disclosureComplete: false,
  });
});

test("changing a hidden operation field invalidates its approval digest", () => {
  const operation = { toolName: "Bash", input: { command: "printf safe" } };
  const disclosure = canonicalApprovalDisclosure(operation);
  operation.input.command = "rm important";

  assert.equal(operationDigestMatches(
    disclosure.operationDigest,
    canonicalOperationDigest(operation),
  ), false);
  assert.equal(operationDigestMatches(disclosure.operationDigest, "invalid"), false);
  assert.equal(approvalBindingIsValid(
    true,
    disclosure.operationDigest,
    operation,
    disclosure.operationDigest,
  ), false);
  assert.equal(approvalBindingIsValid(false, disclosure.operationDigest, operation, disclosure.operationDigest), false);
});
