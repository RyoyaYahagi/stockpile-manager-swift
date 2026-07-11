import http from "node:http";

import healthHandler from "./api/health.js";
import rakutenRedirectHandler from "./api/v1/rakuten/redirect.js";
import rakutenSearchHandler from "./api/v1/rakuten/search.js";
import yahooSearchHandler from "./api/v1/yahoo/search.js";

const PORT = Number.parseInt(process.env.PORT ?? "3000", 10) || 3000;
const HOST = process.env.HOST ?? "0.0.0.0";

function normalizeHeaders(headers) {
  const normalized = {};
  for (const [key, value] of Object.entries(headers)) {
    normalized[key.toLowerCase()] = value;
  }
  return normalized;
}

function createRequestAdapter(request, url) {
  const query = Object.fromEntries(url.searchParams.entries());
  return {
    method: request.method ?? "GET",
    headers: normalizeHeaders(request.headers),
    query,
    url: request.url ?? url.pathname
  };
}

function createResponseAdapter(response) {
  let statusCode = 200;
  let ended = false;

  return {
    status(code) {
      statusCode = code;
      return this;
    },
    setHeader(name, value) {
      response.setHeader(name, value);
      return this;
    },
    send(body) {
      if (ended) {
        return;
      }
      ended = true;
      response.statusCode = statusCode;
      response.end(body);
    },
    redirect(code, location) {
      if (ended) {
        return;
      }
      ended = true;
      response.statusCode = code;
      response.setHeader("Location", location);
      response.end();
    }
  };
}

function notFound(response) {
  response.statusCode = 404;
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.end(JSON.stringify({ error: "not_found" }));
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  const adaptedRequest = createRequestAdapter(request, url);
  const adaptedResponse = createResponseAdapter(response);

  try {
    if (url.pathname === "/health") {
      return await healthHandler(adaptedRequest, adaptedResponse);
    }

    if (url.pathname === "/v1/rakuten/search") {
      return await rakutenSearchHandler(adaptedRequest, adaptedResponse);
    }

    if (url.pathname === "/v1/rakuten/redirect") {
      return await rakutenRedirectHandler(adaptedRequest, adaptedResponse);
    }

    if (url.pathname === "/v1/yahoo/search") {
      return await yahooSearchHandler(adaptedRequest, adaptedResponse);
    }

    return notFound(response);
  } catch (error) {
    console.error("Standalone server request failed", {
      path: url.pathname,
      message: error instanceof Error ? error.message : String(error)
    });
    response.statusCode = 500;
    response.setHeader("Content-Type", "application/json; charset=utf-8");
    response.end(JSON.stringify({ error: "internal_server_error" }));
  }
});

server.listen(PORT, HOST, () => {
  console.info(`stockpile-product-search-api listening on http://${HOST}:${PORT}`);
});
