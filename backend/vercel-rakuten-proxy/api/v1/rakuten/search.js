const PRODUCT_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibaproduct/api/Product/Search/20250801";
const ITEM_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20220601";
const RATE_LIMIT_WINDOW_MS = 60_000;
const DEFAULT_RATE_LIMIT_MAX_REQUESTS = 30;
const rateLimitBuckets = globalThis.__stockpileRateLimitBuckets || new Map();

if (!globalThis.__stockpileRateLimitBuckets) {
  globalThis.__stockpileRateLimitBuckets = rateLimitBuckets;
}

function readEnv(name) {
  const value = process.env[name];
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

function trimText(value) {
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

function rateLimitMaxRequests() {
  const configuredValue = Number.parseInt(
    readEnv("RATE_LIMIT_MAX_REQUESTS_PER_MINUTE"),
    10
  );
  return Number.isFinite(configuredValue) && configuredValue > 0
    ? configuredValue
    : DEFAULT_RATE_LIMIT_MAX_REQUESTS;
}

function clientAddress(request) {
  const forwardedFor = request.headers["x-forwarded-for"];
  const forwardedValue = Array.isArray(forwardedFor)
    ? forwardedFor[0]
    : forwardedFor;
  if (typeof forwardedValue === "string" && forwardedValue.trim()) {
    return forwardedValue.split(",")[0].trim();
  }

  const realIp = request.headers["x-real-ip"];
  if (typeof realIp === "string" && realIp.trim()) {
    return realIp.trim();
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

function consumeRateLimit(request) {
  const now = Date.now();
  pruneRateLimitBuckets(now);

  const limit = rateLimitMaxRequests();
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

async function fetchJSON(url) {
  const response = await fetch(url, {
    headers: {
      "User-Agent": "stockpile-rakuten-proxy/1.0"
    }
  });

  const text = await response.text();
  let json = null;
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
  }

  return { response, json, text };
}

function shouldTreatAsUpstreamFailure(statusCode) {
  return statusCode === 401 || statusCode === 403 || statusCode === 429 || statusCode >= 500;
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

  const name = mergeProductName(productPayload.brandName, productPayload.productName);
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

function sendJSON(response, statusCode, body) {
  response.status(statusCode).setHeader("Cache-Control", "no-store");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.send(JSON.stringify(body));
}

export default async function handler(request, response) {
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return sendJSON(response, 405, {
      error: "method_not_allowed"
    });
  }

  const rateLimit = consumeRateLimit(request);
  setRateLimitHeaders(response, rateLimit);
  if (!rateLimit.allowed) {
    return sendJSON(response, 429, {
      error: "rate_limited"
    });
  }

  const applicationId = readEnv("RAKUTEN_APP_ID");
  const accessKey = readEnv("RAKUTEN_ACCESS_KEY");

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
  let sawUpstreamFailure = false;

  try {
    const productResult = await fetchJSON(
      buildProductSearchURL(janCode, applicationId, accessKey)
    );
    if (productResult.response.ok) {
      const product = readProductResult(productResult.json, janCode);
      if (product) {
        return sendJSON(response, 200, product);
      }
    } else if (shouldTreatAsUpstreamFailure(productResult.response.status)) {
      sawUpstreamFailure = true;
    }

    const itemResult = await fetchJSON(
      buildItemSearchURL(janCode, applicationId, accessKey)
    );
    if (itemResult.response.ok) {
      const product = readItemResult(itemResult.json, janCode);
      if (product) {
        return sendJSON(response, 200, product);
      }
    } else if (shouldTreatAsUpstreamFailure(itemResult.response.status)) {
      sawUpstreamFailure = true;
    }

    if (itemName) {
      const keywordResult = await fetchJSON(
        buildItemSearchURL(itemName, applicationId, accessKey)
      );
      if (keywordResult.response.ok) {
        const product = readItemResult(keywordResult.json, janCode);
        if (product) {
          return sendJSON(response, 200, product);
        }
      } else if (shouldTreatAsUpstreamFailure(keywordResult.response.status)) {
        sawUpstreamFailure = true;
      }
    }

    if (sawUpstreamFailure) {
      return sendJSON(response, 502, {
        error: "upstream_error"
      });
    }

    return sendJSON(response, 404, {
      error: "not_found"
    });
  } catch (error) {
    console.error("Rakuten search failed", {
      message: error instanceof Error ? error.message : String(error)
    });

    return sendJSON(response, 502, {
      error: "upstream_error"
    });
  }
}
