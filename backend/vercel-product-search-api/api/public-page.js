const PAGE_HEADERS = {
  "Cache-Control": "public, max-age=300, s-maxage=3600",
  "Content-Type": "text/html; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
};

const pageStyle = `
  :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
  body { max-width: 760px; margin: 0 auto; padding: 32px 20px 64px; line-height: 1.7; }
  h1, h2 { line-height: 1.3; }
  h2 { margin-top: 2rem; }
  a { color: #0a84ff; }
  .updated { color: #666; }
`;

function htmlPage(title, content) {
  return `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title} - Stockpile</title><style>${pageStyle}</style></head>
<body><main><h1>${title}</h1>${content}</main></body></html>`;
}

export const privacyPage = htmlPage(
  "プライバシーポリシー",
  `<p class="updated">最終更新日: 2026年7月12日</p>
  <p>Stockpile（以下「本アプリ」）は、備蓄品の管理と、利用者が選択した家族とのデータ共有を提供します。</p>
  <h2>取り扱うデータ</h2>
  <ul>
    <li>家族名、収納場所、備蓄品名、JANコード、数量、期限、メモなどは端末内に保存されます。</li>
    <li>iCloud共有を利用した場合、これらのデータはAppleのCloudKitへ送信され、招待された参加者との同期に使われます。共有は招待制です。</li>
    <li>商品検索を利用した場合、JANコードと、入力された場合は商品名を、検索結果取得のため本アプリのサーバーおよび楽天・Yahoo! JAPAN・Open Food Factsへ送信します。</li>
    <li>カメラ画像はバーコード読み取りまたは端末上の文字認識に使用し、本アプリのサーバーへ保存しません。</li>
    <li>通知設定は期限通知の作成に使用します。購入状態はApple StoreKitを通じて確認します。</li>
  </ul>
  <h2>利用目的と第三者提供</h2>
  <p>データは本アプリの機能提供、同期、商品検索、不正利用防止にのみ使用します。広告目的の追跡やデータ販売は行いません。機能提供に必要な範囲でAppleおよび商品検索サービスへ送信されます。</p>
  <h2>保存と削除</h2>
  <p>端末内データはアプリ内の削除操作またはアプリの削除で消去できます。CloudKit共有データは共有の所有者が家族共有設定から削除できます。JSONバックアップは暗号化されないため、安全な保存先で管理してください。</p>
  <h2>お問い合わせ</h2>
  <p>データの取扱いや削除については<a href="/support">サポートページ</a>をご確認ください。</p>`
);

export const supportPage = htmlPage(
  "サポート",
  `<p>Stockpileの不具合、購入、データ削除、プライバシーに関するお問い合わせを受け付けています。</p>
  <h2>お問い合わせ時のお願い</h2>
  <p>アプリのバージョン、iOSのバージョン、発生した操作をお知らせください。備蓄品の内容、共有URL、APIキー、Apple IDなどの機密情報は送らないでください。</p>
  <h2>データ削除</h2>
  <p>端末内の備蓄品はアプリ内で削除できます。iCloud共有の所有者は家族共有設定から共有データを削除できます。本アプリには独自アカウントはありません。</p>
  <p><a href="/privacy">プライバシーポリシーを読む</a></p>`
);

export function sendPublicPage(request, response, page) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.setHeader("Allow", "GET, HEAD");
    return response.status(405).send("Method Not Allowed");
  }

  for (const [name, value] of Object.entries(PAGE_HEADERS)) {
    response.setHeader(name, value);
  }
  return response.status(200).send(request.method === "HEAD" ? "" : page);
}
