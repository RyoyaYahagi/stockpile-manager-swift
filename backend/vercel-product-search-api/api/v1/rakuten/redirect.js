import {
  DEFAULT_REQUEST_HEADERS,
  DEFAULT_UPSTREAM_TIMEOUTS_MS,
  fetchUpstream
} from "./search.js";

const PRODUCT_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibaproduct/api/Product/Search/20250801";
const ITEM_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20220601";
const RATE_LIMIT_WINDOW_MS = 60_000;
const DEFAULT_RATE_LIMIT_MAX_REQUESTS = 30;
const ALLOWED_REDIRECT_HOST_SUFFIXES = ["rakuten.co.jp"];
const rateLimitBuckets = globalThis.__stockpileRateLimitBuckets || new Map();

if (!globalThis.__stockpileRateLimitBuckets) {
  globalThis.__stockpileRateLimitBuckets = rateLimitBuckets;
}

function readEnv(name, env = process.env) {
  const value = env[name];
  if (typeof value !== "string") {
    return "";
  }

  return value.trim();
}

function validateJAN(input) {
  const rawValue = Array.isArray(input) ? input[0] : input;
  const normalized = typeof rawValue === "string" ? rawValue.trim() : "";
  if (/^\d{8}$/.test(normalized) || /^\d{13}$/.test(normalized)) {
    return normalized;
  }
  return null;
}

function normalizeKeyword(input) {
  const rawValue = Array.isArray(input) ? input[0] : input;
  if (typeof rawValue !== "string") {
    return "";
  }

  return rawValue.replace(/\s+/g, " ").trim().slice(0, 80);
}

function rateLimitMaxRequests(env = process.env) {
  const configuredValue = Number.parseInt(
    readEnv("RATE_LIMIT_MAX_REQUESTS_PER_MINUTE", env),
    10
  );
  return Number.isFinite(configuredValue) && configuredValue > 0
    ? configuredValue
    : DEFAULT_RATE_LIMIT_MAX_REQUESTS;
}

function clientAddress(request) {
  const forwardedFor = request.headers["x-vercel-forwarded-for"];
  const forwardedValue = Array.isArray(forwardedFor)
    ? forwardedFor[0]
    : forwardedFor;
  if (typeof forwardedValue === "string" && forwardedValue.trim()) {
    return forwardedValue.split(",")[0].trim();
  }

  const remoteAddress = request.socket?.remoteAddress ?? request.remoteAddress;
  if (typeof remoteAddress === "string" && remoteAddress.trim()) {
    return remoteAddress.trim();
  }

  return "unknown";
}

function pruneRateLimitBuckets(now) {
  for (const [key, bucket] of rateLimitBuckets.entries()) {
    bucket.timestamps = bucket.timestamps.filter(
      (timestamp) => now - timestamp < RATE_LIMIT_WINDOW_MS
    );

    if (bucket.timestamps.length === 0) {
      rateLimitBuckets.delete(key);
    }
  }
}

function consumeRateLimit(request, env = process.env) {
  const now = Date.now();
  pruneRateLimitBuckets(now);

  const limit = rateLimitMaxRequests(env);
  const bucketKey = clientAddress(request);
  const bucket = rateLimitBuckets.get(bucketKey) || { timestamps: [] };
  bucket.timestamps = bucket.timestamps.filter(
    (timestamp) => now - timestamp < RATE_LIMIT_WINDOW_MS
  );

  if (bucket.timestamps.length >= limit) {
    const retryAfterSeconds = Math.max(
      1,
      Math.ceil((RATE_LIMIT_WINDOW_MS - (now - bucket.timestamps[0])) / 1000)
    );
    rateLimitBuckets.set(bucketKey, bucket);
    return {
      allowed: false,
      limit,
      remaining: 0,
      retryAfterSeconds
    };
  }

  bucket.timestamps.push(now);
  rateLimitBuckets.set(bucketKey, bucket);
  return {
    allowed: true,
    limit,
    remaining: Math.max(0, limit - bucket.timestamps.length),
    retryAfterSeconds: 0
  };
}

function setRateLimitHeaders(response, rateLimit) {
  response.setHeader("X-RateLimit-Limit", String(rateLimit.limit));
  response.setHeader("X-RateLimit-Remaining", String(rateLimit.remaining));

  if (!rateLimit.allowed) {
    response.setHeader("Retry-After", String(rateLimit.retryAfterSeconds));
  }
}

function sanitizeRedirectURL(target) {
  if (typeof target !== "string" || !target.trim()) {
    return null;
  }

  try {
    const url = new URL(target.trim());
    const hostname = url.hostname.toLowerCase();
    const isAllowedHost = ALLOWED_REDIRECT_HOST_SUFFIXES.some((suffix) => {
      return hostname === suffix || hostname.endsWith(`.${suffix}`);
    });

    if (url.protocol !== "https:" || !isAllowedHost) {
      return null;
    }

    return url.toString();
  } catch {
    return null;
  }
}

function buildProductSearchURL(janCode, applicationId, accessKey, affiliateId) {
  const url = new URL(PRODUCT_SEARCH_URL);
  url.searchParams.set("format", "json");
  url.searchParams.set("formatVersion", "2");
  url.searchParams.set("applicationId", applicationId);
  url.searchParams.set("accessKey", accessKey);
  if (affiliateId) {
    url.searchParams.set("affiliateId", affiliateId);
  }
  url.searchParams.set("productCode", janCode);
  url.searchParams.set(
    "elements",
    "productName,affiliateUrl,productUrlPC,productCode"
  );
  url.searchParams.set("hits", "1");
  return url;
}

function buildItemSearchURL(janCode, applicationId, accessKey, affiliateId) {
  const url = new URL(ITEM_SEARCH_URL);
  url.searchParams.set("format", "json");
  url.searchParams.set("formatVersion", "2");
  url.searchParams.set("applicationId", applicationId);
  url.searchParams.set("accessKey", accessKey);
  if (affiliateId) {
    url.searchParams.set("affiliateId", affiliateId);
  }
  url.searchParams.set("keyword", janCode);
  url.searchParams.set("hits", "1");
  url.searchParams.set("elements", "itemName,affiliateUrl,itemUrl");
  return url;
}

function buildKeywordSearchURL(keyword, applicationId, accessKey, affiliateId) {
  const url = new URL(ITEM_SEARCH_URL);
  url.searchParams.set("format", "json");
  url.searchParams.set("formatVersion", "2");
  url.searchParams.set("applicationId", applicationId);
  url.searchParams.set("accessKey", accessKey);
  if (affiliateId) {
    url.searchParams.set("affiliateId", affiliateId);
  }
  url.searchParams.set("keyword", keyword);
  url.searchParams.set("hits", "1");
  url.searchParams.set("elements", "itemName,affiliateUrl,itemUrl");
  return url;
}

function mergeTimeouts(overrides = {}) {
  return {
    ...DEFAULT_UPSTREAM_TIMEOUTS_MS,
    ...overrides
  };
}

async function fetchJSON(url, { apiName, timeoutMs, fetchImpl = fetch }) {
  return fetchUpstream(url, {
    apiName,
    headers: DEFAULT_REQUEST_HEADERS,
    timeoutMs,
    fetchImpl
  });
}

function firstObject(value) {
  if (Array.isArray(value) && value.length > 0) {
    return value[0];
  }
  return null;
}

function readProductAffiliateURL(json) {
  if (!json || typeof json !== "object") {
    return null;
  }

  const productCandidate = firstObject(json.Products);
  const productPayload =
    (productCandidate && productCandidate.Product) ||
    productCandidate ||
    firstObject(json.items);

  const target =
    productPayload?.affiliateUrl ||
    productPayload?.productUrlPC ||
    null;

  return sanitizeRedirectURL(target);
}

function readItemAffiliateURL(json) {
  if (!json || typeof json !== "object") {
    return null;
  }

  const itemCandidate = firstObject(json.Items);
  const itemPayload =
    (itemCandidate && itemCandidate.Item) ||
    itemCandidate ||
    firstObject(json.items);

  const target =
    itemPayload?.affiliateUrl ||
    itemPayload?.itemUrl ||
    null;

  return sanitizeRedirectURL(target);
}

function sendJSON(response, statusCode, body) {
  response.status(statusCode).setHeader("Cache-Control", "no-store");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.send(JSON.stringify(body));
}

function buildRakutenSearchResultsURL(keyword) {
  const normalizedKeyword = normalizeKeyword(keyword);
  const searchKeyword = normalizedKeyword || "備蓄";
  return `https://search.rakuten.co.jp/search/mall/${encodeURIComponent(searchKeyword)}/`;
}

export async function handleRakutenRedirect(request, response, dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const timeouts = mergeTimeouts(dependencies.timeouts);

  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return sendJSON(response, 405, {
      error: "method_not_allowed"
    });
  }

  const rateLimit = consumeRateLimit(request, env);
  setRateLimitHeaders(response, rateLimit);
  if (!rateLimit.allowed) {
    return sendJSON(response, 429, {
      error: "rate_limited"
    });
  }

  const applicationId = readEnv("RAKUTEN_APP_ID", env);
  const accessKey = readEnv("RAKUTEN_ACCESS_KEY", env);
  const affiliateId = readEnv("RAKUTEN_AFFILIATE_ID", env);

  if (!applicationId || !accessKey) {
    return sendJSON(response, 500, {
      error: "server_not_configured"
    });
  }

  const janCode = validateJAN(request.query?.jan);
  if (!janCode) {
    return sendJSON(response, 400, {
      error: "invalid_jan"
    });
  }

  const itemName = normalizeKeyword(request.query?.name);

  try {
    const productResult = await fetchJSON(
      buildProductSearchURL(janCode, applicationId, accessKey, affiliateId),
      {
        apiName: "product",
        timeoutMs: timeouts.product,
        fetchImpl
      }
    );
    const productTarget = readProductAffiliateURL(productResult.json);
    if (productResult.response?.ok && productTarget) {
      response.setHeader("Cache-Control", "no-store");
      response.setHeader("Referrer-Policy", "no-referrer");
      return response.redirect(307, productTarget);
    }

    const itemResult = await fetchJSON(
      buildItemSearchURL(janCode, applicationId, accessKey, affiliateId),
      {
        apiName: "item",
        timeoutMs: timeouts.item,
        fetchImpl
      }
    );
    const itemTarget = readItemAffiliateURL(itemResult.json);
    if (itemResult.response?.ok && itemTarget) {
      response.setHeader("Cache-Control", "no-store");
      response.setHeader("Referrer-Policy", "no-referrer");
      return response.redirect(307, itemTarget);
    }

    if (itemName) {
      const keywordResult = await fetchJSON(
        buildKeywordSearchURL(itemName, applicationId, accessKey, affiliateId),
        {
          apiName: "keyword",
          timeoutMs: timeouts.keyword,
          fetchImpl
        }
      );
      const keywordTarget = readItemAffiliateURL(keywordResult.json);
      if (keywordResult.response?.ok && keywordTarget) {
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("Referrer-Policy", "no-referrer");
        return response.redirect(307, keywordTarget);
      }
    }

    response.setHeader("Cache-Control", "no-store");
    response.setHeader("Referrer-Policy", "no-referrer");
    return response.redirect(307, buildRakutenSearchResultsURL(itemName || janCode));
  } catch (error) {
    console.error("Rakuten redirect failed", {
      message: error instanceof Error ? error.message : String(error)
    });

    return sendJSON(response, 502, {
      error: "upstream_error"
    });
  }
}

export default async function handler(request, response) {
  return handleRakutenRedirect(request, response);
}
