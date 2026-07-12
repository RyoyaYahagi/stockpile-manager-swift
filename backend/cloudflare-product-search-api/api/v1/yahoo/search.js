import {
  SEARCH_CACHE_CONTROL,
  DEFAULT_REQUEST_HEADERS,
  readEnv,
  validateJAN,
  trimText,
  consumeRateLimit,
  setRateLimitHeaders,
  fetchUpstream,
  sendJSON,
  classifyUpstreamResult
} from "../rakuten/search.js";

const YAHOO_SEARCH_URL =
  "https://shopping.yahooapis.jp/ShoppingWebService/V3/itemSearch";
const DEFAULT_UPSTREAM_TIMEOUT_MS = 3_000;

function buildYahooSearchURL(janCode, clientId) {
  const url = new URL(YAHOO_SEARCH_URL);
  url.searchParams.set("appid", clientId);
  url.searchParams.set("jan_code", janCode);
  url.searchParams.set("results", "1");
  url.searchParams.set("image_size", "300");
  return url;
}

function normalizedField(value) {
  return trimText(value);
}

function readYahooResult(json, janCode) {
  if (!json || typeof json !== "object" || !Array.isArray(json.hits)) {
    return null;
  }

  const firstHit = json.hits[0];
  if (!firstHit || typeof firstHit !== "object") {
    return null;
  }

  const genreCategory =
    firstHit.genreCategory && typeof firstHit.genreCategory === "object"
      ? firstHit.genreCategory
      : null;
  const exImage =
    firstHit.exImage && typeof firstHit.exImage === "object"
      ? firstHit.exImage
      : null;
  const image =
    firstHit.image && typeof firstHit.image === "object" ? firstHit.image : null;

  const name = normalizedField(firstHit.name);
  if (!name) {
    return null;
  }

  return {
    name,
    description:
      normalizedField(firstHit.description) || normalizedField(firstHit.headLine),
    category: normalizedField(genreCategory?.name),
    imageURL:
      normalizedField(exImage?.url) ||
      normalizedField(image?.medium) ||
      normalizedField(image?.small),
    janCode: normalizedField(firstHit.janCode) || janCode,
    source: "yahoo"
  };
}

function logUpstreamResult(result) {
  const statusCode = result?.response?.status;
  const failureType = classifyUpstreamResult(result);
  const shouldError = failureType !== "none";
  const log = shouldError ? console.error : console.info;

  log("Yahoo search upstream response", {
    api: result?.api,
    status: statusCode,
    timedOut: Boolean(result?.timedOut),
    elapsedMs: result?.elapsedMs
  });
}

export async function handleYahooSearch(request, response, dependencies = {}) {
  const env = dependencies.env ?? {};
  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const timeoutMs = dependencies.timeoutMs ?? DEFAULT_UPSTREAM_TIMEOUT_MS;

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

  const clientId = readEnv("YAHOO_CLIENT_ID", env);
  if (!clientId) {
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

  const url = buildYahooSearchURL(janCode, clientId);
  const result = await fetchUpstream(url, {
    apiName: "search",
    headers: DEFAULT_REQUEST_HEADERS,
    timeoutMs,
    fetchImpl
  });
  logUpstreamResult(result);

  const failureType = classifyUpstreamResult(result);
  if (failureType === "rate_limited") {
    return sendJSON(response, 503, {
      error: "upstream_rate_limited"
    });
  }

  if (failureType === "unavailable") {
    return sendJSON(response, 503, {
      error: "upstream_unavailable"
    });
  }

  const product = readYahooResult(result.json, janCode);
  if (result.response?.ok && product) {
    return sendJSON(response, 200, product, {
      cacheControl: SEARCH_CACHE_CONTROL
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
}

export default function yahooSearchHandler(request, response, env = {}) {
  return handleYahooSearch(request, response, { env });
}
