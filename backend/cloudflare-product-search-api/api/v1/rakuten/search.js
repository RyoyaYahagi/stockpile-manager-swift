const PRODUCT_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibaproduct/api/Product/Search/20250801";
const ITEM_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20220601";
export const RATE_LIMIT_MAX_REQUESTS = 30;
export const RATE_LIMIT_RETRY_AFTER_SECONDS = 60;
export const SEARCH_CACHE_CONTROL =
  "public, max-age=0, s-maxage=86400, stale-while-revalidate=3600";
export const DEFAULT_REQUEST_HEADERS = {
  "User-Agent": "stockpile-product-search-api/1.0"
};
export const DEFAULT_UPSTREAM_TIMEOUTS_MS = Object.freeze({
  product: 4_000,
  item: 3_000,
  keyword: 3_000
});

export function readEnv(name, env = {}) {
  const value = env[name];
  if (typeof value !== "string") {
    return "";
  }

  return value.trim();
}

export function validateJAN(input) {
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

export function trimText(value) {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function mergeProductName(brandName, productName) {
  const normalizedBrand = trimText(brandName);
  const normalizedProductName = trimText(productName);

  if (!normalizedProductName) {
    return null;
  }

  if (
    !normalizedBrand ||
    normalizedProductName.toLowerCase().includes(normalizedBrand.toLowerCase())
  ) {
    return normalizedProductName;
  }

  return `${normalizedBrand} ${normalizedProductName}`;
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

function buildProductSearchURL(janCode, applicationId, accessKey) {
  const url = new URL(PRODUCT_SEARCH_URL);
  url.searchParams.set("format", "json");
  url.searchParams.set("formatVersion", "2");
  url.searchParams.set("applicationId", applicationId);
  url.searchParams.set("accessKey", accessKey);
  url.searchParams.set("productCode", janCode);
  url.searchParams.set(
    "elements",
    "productName,brandName,productCaption,genreName,mediumImageUrl,productCode"
  );
  url.searchParams.set("hits", "1");
  return url;
}

function buildItemSearchURL(keyword, applicationId, accessKey) {
  const url = new URL(ITEM_SEARCH_URL);
  url.searchParams.set("format", "json");
  url.searchParams.set("formatVersion", "2");
  url.searchParams.set("applicationId", applicationId);
  url.searchParams.set("accessKey", accessKey);
  url.searchParams.set("keyword", keyword);
  url.searchParams.set("hits", "1");
  url.searchParams.set(
    "elements",
    "itemName,itemCaption,genreName,mediumImageUrls,smallImageUrls,itemUrl"
  );
  return url;
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

function mergeTimeouts(overrides = {}) {
  return {
    ...DEFAULT_UPSTREAM_TIMEOUTS_MS,
    ...overrides
  };
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

function isUpstreamRateLimited(statusCode) {
  return statusCode === 429;
}

function isUpstreamUnavailable(statusCode) {
  return statusCode === 401 || statusCode === 403 || statusCode >= 500;
}

function logUpstreamResult(result) {
  const statusCode = result?.response?.status;
  const shouldError =
    result?.timedOut ||
    isUpstreamRateLimited(statusCode) ||
    isUpstreamUnavailable(statusCode);
  const log = shouldError ? console.error : console.info;

  log("Rakuten search upstream response", {
    api: result?.api,
    status: statusCode,
    timedOut: Boolean(result?.timedOut),
    elapsedMs: result?.elapsedMs
  });
}

function firstObject(value) {
  if (Array.isArray(value) && value.length > 0) {
    return value[0];
  }
  return null;
}

function readProductResult(json, janCode) {
  if (!json || typeof json !== "object") {
    return null;
  }

  const productCandidate = firstObject(json.Products);
  const productPayload =
    (productCandidate && productCandidate.Product) ||
    productCandidate ||
    firstObject(json.items);

  if (!productPayload || typeof productPayload !== "object") {
    return null;
  }

  const name = mergeProductName(
    productPayload.brandName,
    productPayload.productName
  );
  if (!name) {
    return null;
  }

  return {
    name,
    description: trimText(productPayload.productCaption),
    category: trimText(productPayload.genreName),
    imageURL: trimText(productPayload.mediumImageUrl),
    janCode,
    source: "rakuten"
  };
}

function readItemImageURL(itemPayload) {
  const mediumImage = firstObject(itemPayload?.mediumImageUrls);
  if (mediumImage && typeof mediumImage === "object") {
    const imageURL = trimText(mediumImage.imageUrl);
    if (imageURL) {
      return imageURL;
    }
  }

  const smallImage = firstObject(itemPayload?.smallImageUrls);
  if (smallImage && typeof smallImage === "object") {
    return trimText(smallImage.imageUrl);
  }

  return null;
}

function readItemResult(json, janCode) {
  if (!json || typeof json !== "object") {
    return null;
  }

  const itemCandidate = firstObject(json.Items);
  const itemPayload =
    (itemCandidate && itemCandidate.Item) ||
    itemCandidate ||
    firstObject(json.items);

  if (!itemPayload || typeof itemPayload !== "object") {
    return null;
  }

  const name = trimText(itemPayload.itemName);
  if (!name) {
    return null;
  }

  return {
    name,
    description: trimText(itemPayload.itemCaption),
    category: trimText(itemPayload.genreName),
    imageURL: readItemImageURL(itemPayload),
    janCode,
    source: "rakuten"
  };
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

export async function handleRakutenSearch(request, response, dependencies = {}) {
  const env = dependencies.env ?? {};
  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const timeouts = mergeTimeouts(dependencies.timeouts);

  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return sendJSON(response, 405, {
      error: "method_not_allowed"
    });
  }

  const rateLimit = await consumeRateLimit(request, env);
  setRateLimitHeaders(response, rateLimit);
  if (!rateLimit.configured) {
    return sendJSON(response, 500, {
      error: "server_not_configured"
    });
  }

  if (!rateLimit.allowed) {
    return sendJSON(response, 429, {
      error: "rate_limited",
      retryAfterSeconds: rateLimit.retryAfterSeconds
    });
  }

  const applicationId = readEnv("RAKUTEN_APP_ID", env);
  const accessKey = readEnv("RAKUTEN_ACCESS_KEY", env);

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
  const upstreamAttempts = [
    {
      apiName: "product",
      url: buildProductSearchURL(janCode, applicationId, accessKey),
      timeoutMs: timeouts.product,
      readProduct: (json) => readProductResult(json, janCode)
    },
    {
      apiName: "item",
      url: buildItemSearchURL(janCode, applicationId, accessKey),
      timeoutMs: timeouts.item,
      readProduct: (json) => readItemResult(json, janCode)
    }
  ];

  if (itemName) {
    upstreamAttempts.push({
      apiName: "keyword",
      url: buildItemSearchURL(itemName, applicationId, accessKey),
      timeoutMs: timeouts.keyword,
      readProduct: (json) => readItemResult(json, janCode)
    });
  }

  let sawUpstreamRateLimited = false;
  let sawUpstreamUnavailable = false;

  try {
    for (const attempt of upstreamAttempts) {
      const result = await fetchUpstream(attempt.url, {
        apiName: attempt.apiName,
        headers: DEFAULT_REQUEST_HEADERS,
        timeoutMs: attempt.timeoutMs,
        fetchImpl
      });
      logUpstreamResult(result);

      const failureType = classifyUpstreamResult(result);
      if (failureType === "rate_limited") {
        sawUpstreamRateLimited = true;
        continue;
      }
      if (failureType === "unavailable") {
        sawUpstreamUnavailable = true;
        continue;
      }

      if (result.response?.ok) {
        const product = attempt.readProduct(result.json);
        if (product) {
          return sendJSON(response, 200, product, {
            cacheControl: SEARCH_CACHE_CONTROL
          });
        }
      }
    }

    if (sawUpstreamRateLimited) {
      return sendJSON(response, 503, {
        error: "upstream_rate_limited"
      });
    }

    if (sawUpstreamUnavailable) {
      return sendJSON(response, 503, {
        error: "upstream_unavailable"
      });
    }

    return sendJSON(
      response,
      404,
      {
        error: "not_found"
      },
      {
        cacheControl: SEARCH_CACHE_CONTROL
      }
    );
  } catch (error) {
    console.error("Rakuten search failed", {
      message: error instanceof Error ? error.message : String(error)
    });

    return sendJSON(response, 503, {
      error: "upstream_unavailable"
    });
  }
}

export default async function handler(request, response, env = {}) {
  return handleRakutenSearch(request, response, { env });
}
