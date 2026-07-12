import assert from "node:assert/strict";
import test from "node:test";

import { handleRakutenRedirect } from "./redirect.js";

const env = {
  RAKUTEN_APP_ID: "test-app-id",
  RAKUTEN_ACCESS_KEY: "test-access-key",
  PRODUCT_SEARCH_RATE_LIMITER: {
    limit: async () => ({ success: true })
  }
};

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
    location: null,
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
    },
    redirect(code, location) {
      this.statusCode = code;
      this.location = location;
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

test("handleRakutenRedirect falls back to Rakuten search results when upstream requests time out", async () => {
  const response = createResponseRecorder();

  await handleRakutenRedirect(
    createRequest({ jan: "4901777300445", name: "天然水" }),
    response,
    {
      env,
      fetchImpl: timeoutFetch,
      timeouts: {
        product: 5,
        item: 5,
        keyword: 5
      }
    }
  );

  assert.equal(response.statusCode, 307);
  assert.equal(
    response.location,
    "https://search.rakuten.co.jp/search/mall/%E5%A4%A9%E7%84%B6%E6%B0%B4/"
  );
  assert.equal(response.headers["Cache-Control"], "no-store");
  assert.equal(response.headers["Referrer-Policy"], "no-referrer");
});
