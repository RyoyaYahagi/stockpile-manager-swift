// Stockpile snapshot receiver (template Worker)
//
// One deployment serves exactly one user (or one family).
// Endpoints:
//   GET  /v1/health          -> { ok: true }                      (no auth)
//   PUT  /v1/snapshot        -> store the latest snapshot         (Bearer WRITE_TOKEN)
//   GET  /v1/snapshot        -> fetch the latest snapshot         (Bearer READ_TOKEN)
//   GET  /v1/commands        -> fetch the command inbox           (Bearer COMMANDS_TOKEN or WRITE_TOKEN)
//   PUT  /v1/commands        -> replace the command inbox         (Bearer COMMANDS_TOKEN)
//   GET  /v1/command-results -> fetch the command results         (Bearer READ_TOKEN or COMMANDS_TOKEN)
//   PUT  /v1/command-results -> replace the command results       (Bearer WRITE_TOKEN)
//
// Tokens are separate on purpose (write token never leaves the app's Keychain;
// the read token and the commands token are handed to the AI assistant).
// When COMMANDS_TOKEN is unset, the four command inbox endpoints return 404.
// Storage: one KV entry per document ("latest", "commands", "command-results").
// No history is kept.
//
// Snapshot format: docs/snapshot-schema-v1.md (schemaVersion 1).
// Command inbox format: docs/command-inbox-v1.md (top-level validation only).

const MAX_BYTES = 5 * 1024 * 1024; // 5MB, aligned with the app's backup limits
const MAX_ITEMS = 5000;
const MAX_COMMAND_BYTES = 1 * 1024 * 1024;
const MAX_COMMANDS = 200;
const COMMANDS_KEY = "commands";
const COMMAND_RESULTS_KEY = "command-results";

function jsonResponse(status, obj) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

// Constant-time string comparison (lengths are not secret).
function tokenMatches(provided, expected) {
  if (!provided || !expected) return false;
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(expected);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function bearerToken(request) {
  const header = request.headers.get("authorization") || "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

function commandInboxEnabled(env) {
  return typeof env.COMMANDS_TOKEN === "string" && env.COMMANDS_TOKEN.length > 0;
}

// Reads a command inbox body, or returns null when it exceeds the 1MB limit.
async function readCommandBody(request) {
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > MAX_COMMAND_BYTES) return null;
  const text = await request.text();
  if (new TextEncoder().encode(text).length > MAX_COMMAND_BYTES) return null;
  return text;
}

// Commands and command results share only the version check at the top level.
function validateCommandEnvelope(data) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    return "top-level must be a JSON object";
  }
  if (data.version !== 1) return "unsupported version (expected 1)";
  return null;
}

function validateCommandsFile(data) {
  const envelopeError = validateCommandEnvelope(data);
  if (envelopeError) return envelopeError;
  if (!Array.isArray(data.commands)) return "commands must be an array";
  if (data.commands.length > MAX_COMMANDS) return `commands exceeds ${MAX_COMMANDS}`;
  return null;
}

function validateCommandResultsFile(data) {
  const envelopeError = validateCommandEnvelope(data);
  if (envelopeError) return envelopeError;
  if (!Array.isArray(data.results)) return "results must be an array";
  return null;
}

async function getCommandDocument(env, key, initialDocument) {
  const stored = await env.SNAPSHOTS.get(key);
  if (!stored) return jsonResponse(200, initialDocument);
  return new Response(stored, {
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function putCommandDocument(request, env, { key, validate, countField, responseField }) {
  const text = await readCommandBody(request);
  if (text === null) {
    return jsonResponse(413, { error: "document too large" });
  }
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    return jsonResponse(400, { error: "invalid JSON" });
  }
  const validationError = validate(data);
  if (validationError) {
    return jsonResponse(400, { error: validationError });
  }
  await env.SNAPSHOTS.put(key, text);
  return jsonResponse(200, { ok: true, [responseField]: data[countField].length });
}

function isValidDateString(value) {
  if (typeof value !== "string") return false;
  const m = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return false;
  const month = Number(m[2]);
  const day = Number(m[3]);
  return month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

// Validates the snapshot schema v1. Returns an error string, or null when valid.
function validateSnapshot(data) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    return "top-level must be a JSON object";
  }
  if (data.schemaVersion !== 1) {
    return "unsupported schemaVersion (expected 1)";
  }
  if (typeof data.generatedAt !== "string" || Number.isNaN(Date.parse(data.generatedAt))) {
    return "generatedAt must be an ISO 8601 string";
  }
  if (!Array.isArray(data.items)) {
    return "items must be an array";
  }
  if (data.items.length > MAX_ITEMS) {
    return `items exceeds ${MAX_ITEMS}`;
  }
  for (let i = 0; i < data.items.length; i++) {
    const item = data.items[i];
    const at = `items[${i}]`;
    if (item === null || typeof item !== "object") return `${at} must be an object`;
    if (typeof item.id !== "string" || item.id.length === 0) return `${at}.id is required`;
    if (typeof item.name !== "string" || item.name.trim().length === 0) return `${at}.name is required`;
    if (item.name.length > 200) return `${at}.name too long`;
    if (item.janCode != null && (typeof item.janCode !== "string" || item.janCode.length > 32)) {
      return `${at}.janCode invalid`;
    }
    if (!Number.isInteger(item.quantity) || item.quantity < 1 || item.quantity > 999999) {
      return `${at}.quantity must be an integer in 1..999999`;
    }
    if (item.expiryDate != null && !isValidDateString(item.expiryDate)) {
      return `${at}.expiryDate must be yyyy-MM-dd or null`;
    }
    if (item.bagName != null && (typeof item.bagName !== "string" || item.bagName.length > 200)) {
      return `${at}.bagName invalid`;
    }
    if (item.locationNote != null && (typeof item.locationNote !== "string" || item.locationNote.length > 2000)) {
      return `${at}.locationNote invalid`;
    }
    if (typeof item.updatedAt !== "string" || Number.isNaN(Date.parse(item.updatedAt))) {
      return `${at}.updatedAt must be an ISO 8601 string`;
    }
  }
  return null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/v1/health" && request.method === "GET") {
      return jsonResponse(200, { ok: true });
    }

    // The command inbox is opt-in: without COMMANDS_TOKEN all four endpoints are 404.
    if (url.pathname === "/v1/commands" || url.pathname === "/v1/command-results") {
      if (!commandInboxEnabled(env)) {
        return jsonResponse(404, { error: "not found" });
      }
    }

    if (url.pathname === "/v1/commands" && request.method === "GET") {
      const token = bearerToken(request);
      if (!tokenMatches(token, env.COMMANDS_TOKEN) && !tokenMatches(token, env.WRITE_TOKEN)) {
        return jsonResponse(401, { error: "unauthorized" });
      }
      return getCommandDocument(env, COMMANDS_KEY, { version: 1, commands: [] });
    }

    if (url.pathname === "/v1/commands" && request.method === "PUT") {
      if (!tokenMatches(bearerToken(request), env.COMMANDS_TOKEN)) {
        return jsonResponse(401, { error: "unauthorized" });
      }
      return putCommandDocument(request, env, {
        key: COMMANDS_KEY,
        validate: validateCommandsFile,
        countField: "commands",
        responseField: "commandCount",
      });
    }

    if (url.pathname === "/v1/command-results" && request.method === "GET") {
      const token = bearerToken(request);
      if (!tokenMatches(token, env.READ_TOKEN) && !tokenMatches(token, env.COMMANDS_TOKEN)) {
        return jsonResponse(401, { error: "unauthorized" });
      }
      return getCommandDocument(env, COMMAND_RESULTS_KEY, { version: 1, results: [] });
    }

    if (url.pathname === "/v1/command-results" && request.method === "PUT") {
      if (!tokenMatches(bearerToken(request), env.WRITE_TOKEN)) {
        return jsonResponse(401, { error: "unauthorized" });
      }
      return putCommandDocument(request, env, {
        key: COMMAND_RESULTS_KEY,
        validate: validateCommandResultsFile,
        countField: "results",
        responseField: "resultCount",
      });
    }

    if (url.pathname === "/v1/snapshot" && request.method === "PUT") {
      if (!tokenMatches(bearerToken(request), env.WRITE_TOKEN)) {
        return jsonResponse(401, { error: "unauthorized" });
      }
      const contentLength = Number(request.headers.get("content-length") || 0);
      if (contentLength > MAX_BYTES) {
        return jsonResponse(413, { error: "snapshot too large" });
      }
      const text = await request.text();
      if (new TextEncoder().encode(text).length > MAX_BYTES) {
        return jsonResponse(413, { error: "snapshot too large" });
      }
      let data;
      try {
        data = JSON.parse(text);
      } catch {
        return jsonResponse(400, { error: "invalid JSON" });
      }
      const validationError = validateSnapshot(data);
      if (validationError) {
        return jsonResponse(400, { error: validationError });
      }
      await env.SNAPSHOTS.put("latest", text);
      return jsonResponse(200, {
        ok: true,
        itemCount: data.items.length,
        generatedAt: data.generatedAt,
      });
    }

    if (url.pathname === "/v1/snapshot" && request.method === "GET") {
      if (!tokenMatches(bearerToken(request), env.READ_TOKEN)) {
        return jsonResponse(401, { error: "unauthorized" });
      }
      const stored = await env.SNAPSHOTS.get("latest");
      if (!stored) {
        return jsonResponse(404, { error: "no snapshot yet" });
      }
      return new Response(stored, {
        status: 200,
        headers: { "content-type": "application/json; charset=utf-8" },
      });
    }

    return jsonResponse(404, { error: "not found" });
  },
};

export { validateSnapshot };
