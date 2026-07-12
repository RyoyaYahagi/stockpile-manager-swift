import {
  DEFAULT_REQUEST_HEADERS,
  DEFAULT_UPSTREAM_TIMEOUTS_MS,
  consumeRateLimit,
  fetchUpstream,
  readEnv,
  setRateLimitHeaders,
  validateJAN
} from "./search.js";

const PRODUCT_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibaproduct/api/Product/Search/20250801";
const ITEM_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20220601";
const ALLOWED_REDIRECT_HOST_SUFFIXES = ["rakuten.co.jp"];
function normalizeKeyword(input) {
  const rawValue = Array.isArray(input) ? input[0] : input;
  if (typeof rawValue !== "string") {
    return "";
  }

  return rawValue.replace(/\s+/g, " ").trim().slice(0, 80);
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

export default async function handler(request, response, env = {}) {
  return handleRakutenRedirect(request, response, { env });
}
