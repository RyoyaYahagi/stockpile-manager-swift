import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchUpstream,
  handleRakutenSearch
} from "./search.js";

const env = {
  RAKUTEN_APP_ID: "test-app-id",
  RAKUTEN_ACCESS_KEY: "test-access-key"
};

function createRequest(query = {}) {
  return {
    method: "GET",
    headers: {},
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

test("handleRakutenSearch returns 502 when upstream requests time out", async () => {
  const response = createResponseRecorder();

  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }),
    response,
    {
      env,
      fetchImpl: timeoutFetch,
      timeouts: {
        product: 5,
        item: 5,
        searchResultsPage: 5
      }
    }
  );

  assert.equal(response.statusCode, 502);
  assert.deepEqual(JSON.parse(response.body), {
    error: "upstream_error"
  });
});

test("handleRakutenSearch returns 404 when no product is found", async () => {
  const response = createResponseRecorder();

  await handleRakutenSearch(
    createRequest({ jan: "4901777300445" }),
    response,
    {
      env,
      fetchImpl: async (url) => {
        if (String(url).includes("search.rakuten.co.jp")) {
          return new Response("", { status: 404 });
        }

        return new Response("{}", { status: 404 });
      }
    }
  );

  assert.equal(response.statusCode, 404);
  assert.deepEqual(JSON.parse(response.body), {
    error: "not_found"
  });
});

test("handleRakutenSearch returns 200 when the product API succeeds", async () => {
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
  assert.deepEqual(JSON.parse(response.body), {
    name: "い・ろ・は・す",
    description: null,
    category: null,
    imageURL: null,
    janCode: "4901777300445",
    source: "rakuten"
  });
});
