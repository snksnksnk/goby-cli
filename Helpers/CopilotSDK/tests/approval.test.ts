import assert from "node:assert/strict";
import test from "node:test";
import {
  approvalBindingIsValid,
  canonicalApprovalDisclosure,
  canonicalOperationDigest,
  operationDigestMatches,
} from "../src/approval.js";

test("canonical approval details bind every field independent of key order", () => {
  const first = canonicalApprovalDisclosure({ kind: "write", fileName: "b.swift", intention: "Edit", extra: { z: 2, a: 1 } });
  const reordered = canonicalApprovalDisclosure({ extra: { a: 1, z: 2 }, intention: "Edit", fileName: "b.swift", kind: "write" });

  assert.equal(first.disclosureComplete, true);
  assert.equal(first.operationDigest, reordered.operationDigest);
  assert.equal(operationDigestMatches(first.operationDigest, reordered.operationDigest), true);
});

test("oversized and lossy permission requests are decline-only", () => {
  const oversized = canonicalApprovalDisclosure({ kind: "write", content: "x".repeat(200) }, 64);
  const lossy = canonicalApprovalDisclosure({ kind: "write", content: undefined });

  assert.equal(oversized.disclosureComplete, false);
  assert.equal(oversized.details, undefined);
  assert.match(oversized.operationDigest ?? "", /^[a-f0-9]{64}$/);
  assert.equal(lossy.disclosureComplete, false);
  assert.equal(lossy.operationDigest, undefined);
});

test("changing a permission field invalidates its approval digest", () => {
  const request = { kind: "shell", commands: [{ identifier: "safe" }] };
  const disclosure = canonicalApprovalDisclosure(request);
  request.commands[0]!.identifier = "different";

  assert.equal(operationDigestMatches(
    disclosure.operationDigest,
    canonicalOperationDigest(request),
  ), false);
  assert.equal(approvalBindingIsValid(
    true,
    disclosure.operationDigest,
    request,
    disclosure.operationDigest,
  ), false);
});
