import assert from "node:assert/strict";
import test from "node:test";

import worker from "./worker.js";

function createEnv(overrides = {}) {
  return {
    RAKUTEN_APP_ID: "test-app-id",
    RAKUTEN_ACCESS_KEY: "test-access-key",
    YAHOO_CLIENT_ID: "test-yahoo-client-id",
    OPERATOR_NAME: "Stockpile開発者",
    SUPPORT_EMAIL: "support@example.com",
    PRODUCT_SEARCH_RATE_LIMITER: {
      limit: async () => ({ success: true })
    },
    ...overrides
  };
}

test("Worker routes health and public pages through the Fetch API", async () => {
  const env = createEnv();

  const healthResponse = await worker.fetch(
    new Request("https://stockpile-product-search-api.example.workers.dev/health"),
    env
  );
  assert.equal(healthResponse.status, 200);
  assert.deepEqual(await healthResponse.json(), {
    ok: true,
    service: "stockpile-product-search-api"
  });

  const privacyResponse = await worker.fetch(
    new Request("https://stockpile-product-search-api.example.workers.dev/privacy"),
    env
  );
  const privacyBody = await privacyResponse.text();
  assert.equal(privacyResponse.status, 200);
  assert.match(privacyBody, /Cloudflare Workers/);
  assert.match(privacyBody, /support@example\.com/);
  assert.doesNotMatch(privacyBody, /Vercel/);

  const headResponse = await worker.fetch(
    new Request("https://stockpile-product-search-api.example.workers.dev/support", {
      method: "HEAD"
    }),
    env
  );
  assert.equal(headResponse.status, 200);
  assert.equal(await headResponse.text(), "");
});

test("Worker preserves validation and rate-limit responses", async () => {
  const rateLimitKeys = [];
  const invalidJANResponse = await worker.fetch(
    new Request("https://stockpile-product-search-api.example.workers.dev/v1/yahoo/search?jan=invalid", {
      headers: {
        "CF-Connecting-IP": "2001:db8::42"
      }
    }),
    createEnv({
      PRODUCT_SEARCH_RATE_LIMITER: {
        limit: async ({ key }) => {
          rateLimitKeys.push(key);
          return { success: true };
        }
      }
    })
  );
  assert.equal(invalidJANResponse.status, 400);
  assert.deepEqual(await invalidJANResponse.json(), {
    error: "invalid_jan"
  });
  assert.deepEqual(rateLimitKeys, ["2001:db8::42"]);

  const limitedResponse = await worker.fetch(
    new Request("https://stockpile-product-search-api.example.workers.dev/v1/yahoo/search?jan=4901777300445"),
    createEnv({
      PRODUCT_SEARCH_RATE_LIMITER: {
        limit: async () => ({ success: false })
      }
    })
  );
  assert.equal(limitedResponse.status, 429);
  assert.equal(limitedResponse.headers.get("X-RateLimit-Limit"), "30");
  assert.equal(limitedResponse.headers.get("Retry-After"), "60");
  assert.deepEqual(await limitedResponse.json(), {
    error: "rate_limited",
    retryAfterSeconds: 60
  });
});

test("Worker returns JSON 404 for unknown routes", async () => {
  const response = await worker.fetch(
    new Request("https://stockpile-product-search-api.example.workers.dev/unknown"),
    createEnv()
  );
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), {
    error: "not_found"
  });
});
