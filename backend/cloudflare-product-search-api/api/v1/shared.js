export const RATE_LIMIT_MAX_REQUESTS = 30;
export const RATE_LIMIT_RETRY_AFTER_SECONDS = 60;
export const SEARCH_CACHE_CONTROL =
  "public, max-age=0, s-maxage=86400, stale-while-revalidate=3600";
export const DEFAULT_REQUEST_HEADERS = {
  "User-Agent": "stockpile-product-search-api/1.0"
};

export function readEnv(name, env = {}) {
  const value = env[name];
  return typeof value === "string" ? value.trim() : "";
}

export function validateJAN(input) {
  const rawValue = Array.isArray(input) ? input[0] : input;
  const normalized = typeof rawValue === "string" ? rawValue.trim() : "";
  return /^\d{8}$/.test(normalized) || /^\d{13}$/.test(normalized)
    ? normalized
    : null;
}

export function trimText(value) {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function clientAddress(request) {
  const headers = request.headers;
  const rawValue = typeof headers?.get === "function"
    ? headers.get("CF-Connecting-IP")
    : headers?.["cf-connecting-ip"] ?? headers?.["CF-Connecting-IP"];
  return typeof rawValue === "string" && rawValue.trim()
    ? rawValue.trim()
    : "unknown";
}

export async function consumeRateLimit(request, env = {}) {
  const limiter = env.PRODUCT_SEARCH_RATE_LIMITER;
  if (!limiter || typeof limiter.limit !== "function") {
    return {
      allowed: false,
      configured: false,
      limit: RATE_LIMIT_MAX_REQUESTS,
      retryAfterSeconds: RATE_LIMIT_RETRY_AFTER_SECONDS
    };
  }

  try {
    const result = await limiter.limit({ key: clientAddress(request) });
    return {
      allowed: Boolean(result?.success),
      configured: true,
      limit: RATE_LIMIT_MAX_REQUESTS,
      retryAfterSeconds: RATE_LIMIT_RETRY_AFTER_SECONDS
    };
  } catch (error) {
    console.error("Cloudflare rate limiter failed", {
      message: error instanceof Error ? error.message : String(error)
    });
    return {
      allowed: false,
      configured: false,
      limit: RATE_LIMIT_MAX_REQUESTS,
      retryAfterSeconds: RATE_LIMIT_RETRY_AFTER_SECONDS
    };
  }
}

export function setRateLimitHeaders(response, rateLimit) {
  response.setHeader("X-RateLimit-Limit", String(rateLimit.limit));

  if (!rateLimit.allowed) {
    response.setHeader("Retry-After", String(rateLimit.retryAfterSeconds));
  }
}

function safeParseJSON(text) {
  if (!text) {
    return null;
  }

  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function isAbortError(error) {
  if (error instanceof DOMException) {
    return error.name === "AbortError";
  }

  return (
    typeof error === "object" &&
    error !== null &&
    "name" in error &&
    error.name === "AbortError"
  );
}

export async function fetchUpstream(
  url,
  { apiName, headers, timeoutMs, fetchImpl = fetch }
) {
  const controller = new AbortController();
  const startedAt = Date.now();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetchImpl(url, {
      headers,
      signal: controller.signal
    });
    const text = await response.text();

    return {
      api: apiName,
      response,
      text,
      json: safeParseJSON(text),
      timedOut: false,
      elapsedMs: Date.now() - startedAt
    };
  } catch (error) {
    if (isAbortError(error)) {
      return {
        api: apiName,
        response: null,
        text: "",
        json: null,
        timedOut: true,
        elapsedMs: Date.now() - startedAt
      };
    }

    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}

function isUpstreamUnavailable(statusCode) {
  return statusCode === 401 || statusCode === 403 || statusCode >= 500;
}

export function classifyUpstreamResult(result) {
  if (result.timedOut) {
    return "unavailable";
  }

  const statusCode = result.response?.status;
  if (statusCode === 429) {
    return "rate_limited";
  }

  if (isUpstreamUnavailable(statusCode)) {
    return "unavailable";
  }

  return "none";
}

export function sendJSON(
  response,
  statusCode,
  body,
  { cacheControl = "no-store" } = {}
) {
  response.status(statusCode).setHeader("Cache-Control", cacheControl);
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.send(JSON.stringify(body));
}
