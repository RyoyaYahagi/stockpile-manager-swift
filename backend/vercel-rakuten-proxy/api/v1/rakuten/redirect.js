const PRODUCT_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibaproduct/api/Product/Search/20250801";
const ITEM_SEARCH_URL =
  "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20220601";

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

  return typeof target === "string" && target.trim() ? target.trim() : null;
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

  return typeof target === "string" && target.trim() ? target.trim() : null;
}

function sendJSON(response, statusCode, body) {
  response.status(statusCode).setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.send(JSON.stringify(body));
}

function buildRakutenSearchResultsURL(keyword) {
  const normalizedKeyword = normalizeKeyword(keyword);
  const searchKeyword = normalizedKeyword || "備蓄";
  return `https://search.rakuten.co.jp/search/mall/${encodeURIComponent(searchKeyword)}/`;
}

export default async function handler(request, response) {
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return sendJSON(response, 405, {
      error: "method_not_allowed"
    });
  }

  const applicationId = readEnv("RAKUTEN_APP_ID");
  const accessKey = readEnv("RAKUTEN_ACCESS_KEY");
  const affiliateId = readEnv("RAKUTEN_AFFILIATE_ID");

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
      buildProductSearchURL(janCode, applicationId, accessKey, affiliateId)
    );
    const productTarget = readProductAffiliateURL(productResult.json);
    if (productResult.response.ok && productTarget) {
      response.setHeader("Cache-Control", "no-store");
      return response.redirect(307, productTarget);
    }

    const itemResult = await fetchJSON(
      buildItemSearchURL(janCode, applicationId, accessKey, affiliateId)
    );
    const itemTarget = readItemAffiliateURL(itemResult.json);
    if (itemResult.response.ok && itemTarget) {
      response.setHeader("Cache-Control", "no-store");
      return response.redirect(307, itemTarget);
    }

    if (itemName) {
      const keywordResult = await fetchJSON(
        buildKeywordSearchURL(itemName, applicationId, accessKey, affiliateId)
      );
      const keywordTarget = readItemAffiliateURL(keywordResult.json);
      if (keywordResult.response.ok && keywordTarget) {
        response.setHeader("Cache-Control", "no-store");
        return response.redirect(307, keywordTarget);
      }
    }

    response.setHeader("Cache-Control", "no-store");
    return response.redirect(307, buildRakutenSearchResultsURL(itemName || janCode));
  } catch (error) {
    console.error("Rakuten redirect failed", {
      message: error instanceof Error ? error.message : String(error),
      janCode,
      itemName
    });

    return sendJSON(response, 502, {
      error: "upstream_error"
    });
  }
}
