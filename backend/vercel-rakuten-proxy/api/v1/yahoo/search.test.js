import assert from "node:assert/strict";
import test from "node:test";

import { resetRateLimitBuckets } from "../rakuten/search.js";
import { handleYahooSearch } from "./search.js";

const env = {
  YAHOO_CLIENT_ID: "test-yahoo-client-id"
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

test("handleYahooSearch returns 429 with retryAfter when backend rate limit is exceeded", async () => {
  const headers = { "x-forwarded-for": "203.0.113.10" };
  const limitedEnv = {
    ...env,
    RATE_LIMIT_MAX_REQUESTS_PER_MINUTE: "1"
  };

  const firstResponse = createResponseRecorder();
  await handleYahooSearch(createRequest({ jan: "4901777300445" }, headers), firstResponse, {
    env: limitedEnv,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          hits: []
        }),
        { status: 200 }
      )
  });

  assert.equal(firstResponse.statusCode, 404);
  assert.match(firstResponse.headers["Cache-Control"], /s-maxage/);

  const secondResponse = createResponseRecorder();
  await handleYahooSearch(createRequest({ jan: "4901777300445" }, headers), secondResponse, {
    env: limitedEnv,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          hits: []
        }),
        { status: 200 }
      )
  });

  assert.equal(secondResponse.statusCode, 429);
  assert.equal(secondResponse.headers["Cache-Control"], "no-store");
  assert.ok(Number(secondResponse.headers["Retry-After"]) >= 1);
  assert.deepEqual(JSON.parse(secondResponse.body), {
    error: "rate_limited",
    retryAfterSeconds: Number(secondResponse.headers["Retry-After"])
  });
});

test("handleYahooSearch returns 503 when Yahoo upstream responds with 429", async () => {
  const response = createResponseRecorder();

  await handleYahooSearch(createRequest({ jan: "4901777300445" }), response, {
    env,
    fetchImpl: async () =>
      new Response("<html><body>429 Too Many Requests</body></html>", {
        status: 429,
        headers: {
          "Content-Type": "text/html"
        }
      })
  });

  assert.equal(response.statusCode, 503);
  assert.equal(response.headers["Cache-Control"], "no-store");
  assert.deepEqual(JSON.parse(response.body), {
    error: "upstream_rate_limited"
  });
});

test("handleYahooSearch returns 404 with cache headers when no hits are found", async () => {
  const response = createResponseRecorder();
  const requestedURLs = [];

  await handleYahooSearch(createRequest({ jan: "4901777300445" }), response, {
    env,
    fetchImpl: async (url) => {
      requestedURLs.push(String(url));
      return new Response(
        JSON.stringify({
          totalResultsReturned: 0,
          hits: []
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json"
          }
        }
      );
    }
  });

  assert.equal(response.statusCode, 404);
  assert.deepEqual(JSON.parse(response.body), {
    error: "not_found"
  });
  assert.match(response.headers["Cache-Control"], /s-maxage=86400/);
  assert.equal(requestedURLs.length, 1);
  assert.match(requestedURLs[0], /shopping\.yahooapis\.jp/);
  assert.match(requestedURLs[0], /jan_code=4901777300445/);
  assert.match(requestedURLs[0], /image_size=300/);
});

test("handleYahooSearch returns 200 with cache headers when Yahoo search succeeds", async () => {
  const response = createResponseRecorder();

  await handleYahooSearch(createRequest({ jan: "4901777300445" }), response, {
    env,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          totalResultsReturned: 1,
          hits: [
            {
              name: "ヤフーの水",
              description: "天然水",
              genreCategory: {
                name: "水、ミネラルウォーター"
              },
              janCode: "4901777300445",
              exImage: {
                url: "https://example.com/water-300.jpg"
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
      )
  });

  assert.equal(response.statusCode, 200);
  assert.match(response.headers["Cache-Control"], /s-maxage=86400/);
  assert.deepEqual(JSON.parse(response.body), {
    name: "ヤフーの水",
    description: "天然水",
    category: "水、ミネラルウォーター",
    imageURL: "https://example.com/water-300.jpg",
    janCode: "4901777300445",
    source: "yahoo"
  });
});
