// Minimal tests for the snapshot worker, runnable with plain Node:
//   npm test
import assert from "node:assert/strict";
import worker from "../src/index.js";

class FakeKV {
  constructor() { this.map = new Map(); }
  async put(k, v) { this.map.set(k, v); }
  async get(k) { return this.map.has(k) ? this.map.get(k) : null; }
}

function makeEnv(overrides = {}) {
  return {
    WRITE_TOKEN: "write-secret",
    READ_TOKEN: "read-secret",
    COMMANDS_TOKEN: "commands-secret",
    SNAPSHOTS: new FakeKV(),
    ...overrides,
  };
}

const env = makeEnv();

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

const commandsFile = {
  version: 1,
  commands: [
    {
      commandId: "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10",
      issuedAt: "2026-11-08T10:00:00+09:00",
      origin: "muse",
      type: "item.update",
      baseUpdatedAt: "2026-11-01T10:15:00+09:00",
      payload: { id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", quantity: 2 },
    },
  ],
};

const commandResultsFile = {
  version: 1,
  updatedAt: "2026-11-08T10:05:00+09:00",
  results: [
    {
      commandId: "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10",
      type: "item.update",
      origin: "muse",
      status: "applied",
      reason: null,
      message: "数量を 1 → 2 に変更しました",
      itemId: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      processedAt: "2026-11-08T10:05:00+09:00",
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

await check("command inbox GETs return the initial documents when nothing is stored", async () => {
  const fresh = makeEnv();
  const commands = await worker.fetch(req("GET", "/v1/commands", { token: "commands-secret" }), fresh);
  assert.equal(commands.status, 200);
  assert.deepEqual(await commands.json(), { version: 1, commands: [] });

  const results = await worker.fetch(req("GET", "/v1/command-results", { token: "read-secret" }), fresh);
  assert.equal(results.status, 200);
  assert.deepEqual(await results.json(), { version: 1, results: [] });
});

await check("PUT /v1/commands with COMMANDS_TOKEN stores the file", async () => {
  const res = await worker.fetch(
    req("PUT", "/v1/commands", { token: "commands-secret", body: JSON.stringify(commandsFile) }),
    env,
  );
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, commandCount: 1 });
});

await check("GET /v1/commands is readable with COMMANDS_TOKEN and WRITE_TOKEN", async () => {
  for (const token of ["commands-secret", "write-secret"]) {
    const res = await worker.fetch(req("GET", "/v1/commands", { token }), env);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.commands.length, 1);
    assert.equal(body.commands[0].type, "item.update");
  }
});

await check("PUT /v1/command-results with WRITE_TOKEN stores the file", async () => {
  const res = await worker.fetch(
    req("PUT", "/v1/command-results", { token: "write-secret", body: JSON.stringify(commandResultsFile) }),
    env,
  );
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, resultCount: 1 });
});

await check("GET /v1/command-results is readable with READ_TOKEN and COMMANDS_TOKEN", async () => {
  for (const token of ["read-secret", "commands-secret"]) {
    const res = await worker.fetch(req("GET", "/v1/command-results", { token }), env);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.results.length, 1);
    assert.equal(body.results[0].status, "applied");
  }
});

await check("PUT /v1/commands with READ_TOKEN is 401 and does not overwrite", async () => {
  const res = await worker.fetch(
    req("PUT", "/v1/commands", { token: "read-secret", body: JSON.stringify({ version: 1, commands: [] }) }),
    env,
  );
  assert.equal(res.status, 401);

  const after = await worker.fetch(req("GET", "/v1/commands", { token: "commands-secret" }), env);
  const body = await after.json();
  assert.equal(body.commands.length, 1);
});

await check("PUT /v1/commands with WRITE_TOKEN is 401", async () => {
  const res = await worker.fetch(
    req("PUT", "/v1/commands", { token: "write-secret", body: JSON.stringify({ version: 1, commands: [] }) }),
    env,
  );
  assert.equal(res.status, 401);
});

await check("GET /v1/commands with READ_TOKEN is 401", async () => {
  const res = await worker.fetch(req("GET", "/v1/commands", { token: "read-secret" }), env);
  assert.equal(res.status, 401);
});

await check("PUT /v1/command-results rejects READ_TOKEN and COMMANDS_TOKEN", async () => {
  for (const token of ["read-secret", "commands-secret"]) {
    const res = await worker.fetch(
      req("PUT", "/v1/command-results", { token, body: JSON.stringify({ version: 1, results: [] }) }),
      env,
    );
    assert.equal(res.status, 401);
  }
});

await check("GET /v1/command-results with WRITE_TOKEN is 401", async () => {
  const res = await worker.fetch(req("GET", "/v1/command-results", { token: "write-secret" }), env);
  assert.equal(res.status, 401);
});

await check("command endpoints are 404 when COMMANDS_TOKEN is unset", async () => {
  const disabled = makeEnv();
  delete disabled.COMMANDS_TOKEN;
  const cases = [
    ["GET", "/v1/commands", "write-secret"],
    ["PUT", "/v1/commands", "commands-secret"],
    ["GET", "/v1/command-results", "read-secret"],
    ["PUT", "/v1/command-results", "write-secret"],
  ];
  for (const [method, path, token] of cases) {
    const body = method === "PUT" ? JSON.stringify({ version: 1, commands: [], results: [] }) : undefined;
    const res = await worker.fetch(req(method, path, { token, body }), disabled);
    assert.equal(res.status, 404);
  }
});

await check("snapshot endpoints keep working when COMMANDS_TOKEN is unset", async () => {
  const disabled = makeEnv();
  delete disabled.COMMANDS_TOKEN;

  const put = await worker.fetch(
    req("PUT", "/v1/snapshot", { token: "write-secret", body: JSON.stringify(snapshot) }),
    disabled,
  );
  assert.equal(put.status, 200);

  const get = await worker.fetch(req("GET", "/v1/snapshot", { token: "read-secret" }), disabled);
  assert.equal(get.status, 200);
});

await check("command bodies over 1MB are 413", async () => {
  const padding = "x".repeat(1024 * 1024);
  const oversizedCommands = JSON.stringify({ version: 1, commands: [], padding });
  const oversizedResults = JSON.stringify({ version: 1, results: [], padding });
  const cases = [
    ["/v1/commands", "commands-secret", oversizedCommands],
    ["/v1/command-results", "write-secret", oversizedResults],
  ];
  for (const [path, token, body] of cases) {
    const res = await worker.fetch(req("PUT", path, { token, body }), env);
    assert.equal(res.status, 413);
  }
});

await check("broken JSON is 400", async () => {
  const commands = await worker.fetch(req("PUT", "/v1/commands", { token: "commands-secret", body: "{" }), env);
  assert.equal(commands.status, 400);

  const results = await worker.fetch(req("PUT", "/v1/command-results", { token: "write-secret", body: "not json" }), env);
  assert.equal(results.status, 400);
});

await check("commands over 200 are 400 and do not overwrite", async () => {
  const tooMany = { version: 1, commands: Array.from({ length: 201 }, () => ({})) };
  const res = await worker.fetch(
    req("PUT", "/v1/commands", { token: "commands-secret", body: JSON.stringify(tooMany) }),
    env,
  );
  assert.equal(res.status, 400);

  const after = await worker.fetch(req("GET", "/v1/commands", { token: "commands-secret" }), env);
  const body = await after.json();
  assert.equal(body.commands.length, 1);
});

await check("invalid top-level shape is 400", async () => {
  const cases = [
    ["/v1/commands", "commands-secret", [1, 2]],
    ["/v1/commands", "commands-secret", { version: 2, commands: [] }],
    ["/v1/commands", "commands-secret", { version: 1, commands: {} }],
    ["/v1/command-results", "write-secret", { version: 1, results: {} }],
  ];
  for (const [path, token, data] of cases) {
    const res = await worker.fetch(req("PUT", path, { token, body: JSON.stringify(data) }), env);
    assert.equal(res.status, 400);
  }
});

console.log(`\n${passed} tests passed`);
