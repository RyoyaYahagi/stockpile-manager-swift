// Minimal tests for the snapshot worker, runnable with plain Node:
//   npm test
import assert from "node:assert/strict";
import worker from "../src/index.js";

class FakeKV {
  constructor() { this.map = new Map(); }
  async put(k, v) { this.map.set(k, v); }
  async get(k) { return this.map.has(k) ? this.map.get(k) : null; }
}

const env = {
  WRITE_TOKEN: "write-secret",
  READ_TOKEN: "read-secret",
  SNAPSHOTS: new FakeKV(),
};

const snapshot = {
  schemaVersion: 1,
  generatedAt: "2026-11-05T18:00:00+09:00",
  items: [
    {
      id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      name: "Water 2L",
      janCode: "4901777018686",
      quantity: 12,
      expiryDate: "2027-03-31",
      bagName: "Emergency Bag",
      locationNote: null,
      updatedAt: "2026-11-01T10:15:00+09:00",
    },
  ],
};

function req(method, path, { token, body } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body) headers["content-type"] = "application/json";
  return new Request(`https://example.workers.dev${path}`, { method, headers, body });
}

let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`ok - ${name}`);
}

await check("health needs no auth", async () => {
  const res = await worker.fetch(req("GET", "/v1/health"), env);
  assert.equal(res.status, 200);
});

await check("PUT without token is 401", async () => {
  const res = await worker.fetch(req("PUT", "/v1/snapshot", { body: JSON.stringify(snapshot) }), env);
  assert.equal(res.status, 401);
});

await check("PUT with read token is 401 (tokens are separate)", async () => {
  const res = await worker.fetch(req("PUT", "/v1/snapshot", { token: "read-secret", body: JSON.stringify(snapshot) }), env);
  assert.equal(res.status, 401);
});

await check("PUT with write token stores the snapshot", async () => {
  const res = await worker.fetch(req("PUT", "/v1/snapshot", { token: "write-secret", body: JSON.stringify(snapshot) }), env);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.itemCount, 1);
});

await check("GET with read token returns the stored snapshot", async () => {
  const res = await worker.fetch(req("GET", "/v1/snapshot", { token: "read-secret" }), env);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.items[0].name, "Water 2L");
});

await check("GET with write token is 401", async () => {
  const res = await worker.fetch(req("GET", "/v1/snapshot", { token: "write-secret" }), env);
  assert.equal(res.status, 401);
});

await check("backup-style array body is rejected", async () => {
  const res = await worker.fetch(req("PUT", "/v1/snapshot", { token: "write-secret", body: JSON.stringify([{ name: "x" }]) }), env);
  assert.equal(res.status, 400);
});

await check("invalid quantity is rejected and does not overwrite", async () => {
  const bad = structuredClone(snapshot);
  bad.items[0].quantity = 0;
  const res = await worker.fetch(req("PUT", "/v1/snapshot", { token: "write-secret", body: JSON.stringify(bad) }), env);
  assert.equal(res.status, 400);
  const after = await worker.fetch(req("GET", "/v1/snapshot", { token: "read-secret" }), env);
  const body = await after.json();
  assert.equal(body.items[0].quantity, 12);
});

await check("unknown path is 404", async () => {
  const res = await worker.fetch(req("GET", "/nope"), env);
  assert.equal(res.status, 404);
});

console.log(`\n${passed} tests passed`);
