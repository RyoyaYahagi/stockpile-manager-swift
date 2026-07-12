import healthHandler from "./api/health.js";
import privacyHandler from "./api/privacy.js";
import supportHandler from "./api/support.js";
import yahooSearchHandler from "./api/v1/yahoo/search.js";

function createRequestAdapter(request, url) {
  return {
    method: request.method,
    headers: Object.fromEntries(request.headers.entries()),
    query: Object.fromEntries(url.searchParams.entries()),
    url: request.url,
    remoteAddress: request.headers.get("CF-Connecting-IP")
  };
}

function createResponseAdapter() {
  let statusCode = 200;
  let body = null;
  const headers = new Headers();

  const adapter = {
    status(code) {
      statusCode = code;
      return this;
    },
    setHeader(name, value) {
      headers.set(name, String(value));
      return this;
    },
    send(value) {
      body = value ?? "";
      return this;
    },
    json(value) {
      headers.set("Content-Type", "application/json; charset=utf-8");
      body = JSON.stringify(value);
      return this;
    },
    redirect(code, location) {
      statusCode = code;
      headers.set("Location", location);
      body = "";
      return this;
    }
  };

  return {
    adapter,
    toResponse() {
      return new Response(body, {
        status: statusCode,
        headers
      });
    }
  };
}

function notFound(response) {
  return response
    .status(404)
    .setHeader("Content-Type", "application/json; charset=utf-8")
    .send(JSON.stringify({ error: "not_found" }));
}

export async function handleRequest(request, env = {}) {
  const url = new URL(request.url);
  const adaptedRequest = createRequestAdapter(request, url);
  const { adapter, toResponse } = createResponseAdapter();

  try {
    if (url.pathname === "/health") {
      await healthHandler(adaptedRequest, adapter, env);
    } else if (url.pathname === "/privacy") {
      await privacyHandler(adaptedRequest, adapter, env);
    } else if (url.pathname === "/support") {
      await supportHandler(adaptedRequest, adapter, env);
    } else if (url.pathname === "/v1/yahoo/search") {
      await yahooSearchHandler(adaptedRequest, adapter, env);
    } else {
      notFound(adapter);
    }
  } catch (error) {
    console.error("Worker request failed", {
      path: url.pathname,
      message: error instanceof Error ? error.message : String(error)
    });
    adapter
      .status(500)
      .setHeader("Content-Type", "application/json; charset=utf-8")
      .send(JSON.stringify({ error: "internal_server_error" }));
  }

  return toResponse();
}

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  }
};
