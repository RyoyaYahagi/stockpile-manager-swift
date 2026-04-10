import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchUpstream,
  handleRakutenSearch,
  resetRateLimitBuckets
} from "./search.js";

const env = {
  RAKUTEN_APP_ID: "test-app-id",
  RAKUTEN_ACCESS_KEY: "test-access-key"
};

test.beforeEach(() => {
  resetRateLimitBuckets();
});

function createRequest(query = {}, headers = {}) {
  return {
    method: "GET",
    headers,
    query
  };
}

function createResponseRecorder() {
  return {
    headers: {},
    statusCode: 200,
    body: "",
    setHeader(name, value) {
      this.headers[name] = value;
      return this;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    send(body) {
      this.body = body;
      return this;
    }
  };
}

function timeoutFetch(_url, { signal }) {
  return new Promise((_, reject) => {
    signal.addEventListener(
      "abort",
      () => reject(new DOMException("aborted", "AbortError")),
      { once: true }
    );
  });
}

test("fetchUpstream marks timed out requests", async () => {
  const result = await fetchUpstream("https://example.com/product", {
    apiName: "product",
    headers: {},
    timeoutMs: 5,
    fetchImpl: timeoutFetch
  });

  assert.equal(result.timedOut, true);
  assert.equal(result.response, null);
  assert.equal(result.json, null);
});

test("handleRakutenSearch returns 429 with retryAfter when backend rate limit is exceeded", async () => {
  const headers = { "x-forwarded-for": "2001:db8::10" };
  const limitedEnv = {
    ...env,
    RATE_LIMIT_MAX_REQUESTS_PER_MINUTE: "1"
  };

  const firstResponse = createResponseRecorder();
  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }, headers),
    firstResponse,
    {
      env: limitedEnv,
      fetchImpl: async () => new Response("{}", { status: 404 })
    }
  );

  assert.equal(firstResponse.statusCode, 404);
  assert.match(firstResponse.headers["Cache-Control"], /s-maxage/);

  const secondResponse = createResponseRecorder();
  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }, headers),
    secondResponse,
    {
      env: limitedEnv,
      fetchImpl: async () => new Response("{}", { status: 404 })
    }
  );

  assert.equal(secondResponse.statusCode, 429);
  assert.equal(secondResponse.headers["Cache-Control"], "no-store");
  assert.ok(Number(secondResponse.headers["Retry-After"]) >= 1);
  assert.deepEqual(JSON.parse(secondResponse.body), {
    error: "rate_limited",
    retryAfterSeconds: Number(secondResponse.headers["Retry-After"])
  });
});

test("handleRakutenSearch returns 503 when Rakuten upstream responds with 429", async () => {
  const response = createResponseRecorder();

  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }),
    response,
    {
      env,
      fetchImpl: async (url) => {
        if (String(url).includes("ichibaproduct")) {
          return new Response("<html><body>429 Too Many Requests</body></html>", {
            status: 429,
            headers: {
              "Content-Type": "text/html"
            }
          });
        }

        return new Response("{}", { status: 404 });
      }
    }
  );

  assert.equal(response.statusCode, 503);
  assert.equal(response.headers["Cache-Control"], "no-store");
  assert.deepEqual(JSON.parse(response.body), {
    error: "upstream_rate_limited"
  });
});

test("handleRakutenSearch returns 404 with cache headers and does not fetch the HTML search page", async () => {
  const response = createResponseRecorder();
  const requestedURLs = [];

  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }),
    response,
    {
      env,
      fetchImpl: async (url) => {
        requestedURLs.push(String(url));
        return new Response("{}", { status: 404 });
      }
    }
  );

  assert.equal(response.statusCode, 404);
  assert.deepEqual(JSON.parse(response.body), {
    error: "not_found"
  });
  assert.match(response.headers["Cache-Control"], /s-maxage=86400/);
  assert.equal(requestedURLs.length, 2);
  assert.ok(
    requestedURLs.every((url) => !url.includes("search.rakuten.co.jp")),
    `Unexpected search page request: ${requestedURLs.join(", ")}`
  );
});

test("handleRakutenSearch returns 200 with cache headers when the product API succeeds", async () => {
  const response = createResponseRecorder();
  let callCount = 0;

  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }),
    response,
    {
      env,
      fetchImpl: async (url) => {
        callCount += 1;
        assert.match(String(url), /ichibaproduct/);

        return new Response(
          JSON.stringify({
            Products: [
              {
                Product: {
                  productName: "い・ろ・は・す",
                  brandName: "コカ・コーラ",
                  productCaption: "ナチュラルミネラルウォーター",
                  genreName: "水・ミネラルウォーター",
                  mediumImageUrl: "https://example.com/product.png",
                  productCode: "4901777300445"
                }
              }
            ]
          }),
          {
            status: 200,
            headers: {
              "Content-Type": "application/json"
            }
          }
        );
      }
    }
  );

  assert.equal(response.statusCode, 200);
  assert.equal(callCount, 1);
  assert.match(response.headers["Cache-Control"], /s-maxage=86400/);
  assert.deepEqual(JSON.parse(response.body), {
    name: "コカ・コーラ い・ろ・は・す",
    description: "ナチュラルミネラルウォーター",
    category: "水・ミネラルウォーター",
    imageURL: "https://example.com/product.png",
    janCode: "4901777300445",
    source: "rakuten"
  });
});
