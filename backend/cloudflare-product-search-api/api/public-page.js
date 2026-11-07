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
<title>${title} - らくストック</title><style>${pageStyle}</style></head>
<body><main><h1>${title}</h1>${content}</main></body></html>`;
}

function escapeHTML(value) {
  return value.replace(/[&<>\"']/g, (character) => {
    const entities = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
    return entities[character];
  });
}

function configuredOperatorName(env = {}) {
  const name = typeof env.OPERATOR_NAME === "string" ? env.OPERATOR_NAME.trim() : "";
  return name ? escapeHTML(name) : "らくストック開発者";
}

function configuredSupportContact(env = {}) {
  const email = typeof env.SUPPORT_EMAIL === "string" ? env.SUPPORT_EMAIL.trim() : "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return `<p>お問い合わせ先は、App Store Connectに掲載しているサポートURLの案内をご確認ください。</p>`;
  }
  const safeEmail = escapeHTML(email);
  return `<p>お問い合わせ先: <a href="mailto:${safeEmail}">${safeEmail}</a></p>`;
}

export function privacyPage(env = {}) {
  return htmlPage(
    "プライバシーポリシー",
  `<p class="updated">制定日: 2026年7月16日 ・ 最終更新日: 2026年11月7日</p>
  <p><strong>運営者:</strong> ${configuredOperatorName(env)}（以下「運営者」）</p>
  <p>らくストック（以下「本アプリ」）は、備蓄品の管理、期限通知、商品検索、利用者が選択した家族とのデータ共有を提供します。本ポリシーは、本アプリと本ページで取り扱う情報を説明します。</p>
  <h2>取得・保存する情報</h2>
  <ul>
    <li><strong>ユーザーコンテンツ:</strong> 家族名、表示名、メールアドレス（入力した場合）、収納場所、備蓄品名、JANコード、数量、期限、メモ。</li>
    <li><strong>iCloud共有情報:</strong> iCloud共有を有効にした場合、上記の共有対象データとCloudKitの共有参加者情報がAppleのCloudKitに保存されます。共有は招待制です。</li>
    <li><strong>商品検索:</strong> 検索に使ったJANコードと、入力した場合の商品名。検索結果を返すため、Cloudflare Workers上の本アプリサーバーを経由してYahoo! JAPAN、Open Food Factsへ送信されます。</li>
    <li><strong>カメラ:</strong> バーコード読み取りと端末上のOCRに使用します。カメラ映像・画像を運営者のサーバーへ保存しません。</li>
    <li><strong>通知:</strong> 期限通知の設定とApple Push Notificationの登録。</li>
    <li><strong>技術情報:</strong> 不正利用防止のため、商品検索APIでは接続元IPをレート制限の識別に一時的に使用します。検索語や商品データを運営者が独自のデータベースへ保存する設計ではありません。</li>
    <li><strong>AI連携スナップショット:</strong> 任意機能「Muse連携」を有効にした場合に限り、備蓄スナップショット（家族名、備蓄品名、JANコード、数量、期限、収納場所、メモなどを含むJSON形式のデータ）が、利用者自身が設定した送信先に送信されます。送信先は、利用者自身が管理するサーバー（カスタムURL）、または利用者自身のGoogle Driveのいずれかです。運営者は送信されたスナップショットの内容を受け取りません。</li>
  </ul>
  <h2>利用目的</h2>
  <ul>
    <li>備蓄品、家族共有、期限通知など本アプリの機能を提供するため。</li>
    <li>商品情報を検索し、検索結果を表示するため。</li>
    <li>障害調査、不正利用防止、サービスの安定運用のため。</li>
  </ul>
  <h2>第三者サービス</h2>
  <ul>
    <li><strong>Apple iCloud / CloudKit:</strong> 利用者が有効にした家族共有データの保存・同期。</li>
    <li><strong>Apple Push Notification:</strong> 期限通知の提供。</li>
    <li><strong>Cloudflare Workers:</strong> 商品検索APIの実行基盤。通信元の技術情報はCloudflareのサービスログで処理される場合があります。</li>
    <li><strong>Yahoo! JAPAN、Open Food Facts:</strong> 商品検索結果の提供。各サービスのプライバシー方針も確認してください。</li>
    <li><strong>Google Drive（利用者がAI連携の送信先として選択した場合）:</strong> スナップショットの保存先として利用されます。Googleサインインはこの連携のためにのみ使用し、本アプリ自体のログインには使用しません。サインインで取得するメールアドレスは、連携中アカウントの確認表示にのみ使用し、運営者のサーバーへ送信しません。アクセス範囲は、本アプリが作成したファイルのみにアクセスできる権限（drive.file）に限定されます。スナップショットは、利用者のGoogle Drive内の「Stockpile」フォルダに「snapshot.json」という名前で保存されます。</li>
  </ul>
  <p>広告目的の追跡、行動履歴の広告利用、個人データの販売は行いません。商品検索サービスへの送信は、検索機能を利用した場合に限られます。</p>
  <h2>保存期間と削除</h2>
  <ul>
    <li>端末内データは、利用者が削除するまで端末に保存されます。アプリ削除時は端末内データも失われます。</li>
    <li>CloudKit共有データは、共有所有者が家族共有設定から共有やデータを削除できます。AppleのiCloud設定・保持方針が適用される場合があります。</li>
    <li>JSONバックアップはアプリ外へ書き出される平文ファイルです。不要になったファイルは利用者自身で削除してください。</li>
    <li>AI連携で送信されたスナップショットは、送信先（利用者自身のサーバーまたはGoogle Drive）に保存され、利用者自身が管理・削除できます。連携はアプリの設定画面からいつでも解除できます。解除後も送信済みのファイルは送信先に残るため、不要な場合は送信先側で削除してください。</li>
    <li>検索APIのレート制限情報は不正利用防止に必要な期間だけ一時的に保持されます。運営者は商品検索履歴を独自データベースへ蓄積しません。</li>
  </ul>
  <h2>安全管理</h2>
  <p>通信はHTTPSで行い、商品検索サービスの認証情報はiOSアプリに埋め込まずサーバー側で管理します。CloudKit共有は招待制で、共有URLやJSONバックアップは第三者へ渡らないよう利用者自身で管理してください。</p>
  <h2>子どもの利用</h2>
  <p>本アプリは子どもを主な対象として設計していません。保護者の同意なく個人情報を入力しないでください。</p>
  <h2>ポリシーの変更</h2>
  <p>法令や機能変更に応じて本ポリシーを更新することがあります。重要な変更は本ページの更新日でお知らせします。</p>
  <h2>お問い合わせ</h2>
  ${configuredSupportContact(env)}
  <p>データの取扱いや削除については<a href="/support">サポートページ</a>もご確認ください。</p>`
  );
}

export function supportPage(env = {}) {
  return htmlPage(
    "サポート",
  `<p class="updated">最終更新日: 2026年7月16日</p>
  <p>らくストックは、備蓄品の登録、期限通知、商品検索、家族共有を提供するiOSアプリです。対応OSはiOS 17以降です。</p>
  <h2>よくある質問</h2>
  <h3>家族共有ができません</h3>
  <p>所有者の端末でiCloudにサインインし、家族共有設定から共有を開始してください。招待を受ける側もiCloudにサインインし、受け取った共有リンクをiOSで開いてください。通信状態やiCloud容量も確認してください。</p>
  <h3>データが同期されません</h3>
  <p>両方の端末でiCloudが有効か確認し、アプリを前面に戻してしばらく待ってください。共有の所有者が共有を削除した場合、参加者側のデータ状態が変わることがあります。</p>
  <h3>通知が届きません</h3>
  <p>iOSの設定でらくストックの通知を許可し、アプリ内の通知設定と期限日を確認してください。集中モードや通知の要約によって表示が遅れる場合があります。</p>
  <h3>商品検索が失敗します</h3>
  <p>有効な8桁または13桁のJANコード、通信状態、商品検索サービスの一時障害を確認してください。検索サービス側に商品情報がない場合もあります。</p>
  <h3>バックアップを復元したいです</h3>
  <p>設定の「バックアップから復元」からJSONファイルを選択してください。JSONバックアップは暗号化されていないため、信頼できるファイルだけを選択してください。</p>
  <h2>データの削除</h2>
  <p>本アプリには独自アカウントはありません。端末内の備蓄品はアプリ内で削除できます。iCloud共有データは共有所有者が家族共有設定から削除してください。JSONバックアップを保存している場合は、ファイルアプリやクラウドストレージ側のコピーも削除してください。</p>
  <h2>お問い合わせ</h2>
  <p>お問い合わせの際は、アプリバージョン、iOSバージョン、端末名、発生した操作、再現手順を記載してください。備蓄品の内容、共有URL、APIキー、Apple ID、認証コード、パスワードは送らないでください。</p>
  ${configuredSupportContact(env)}
  <p><a href="/privacy">プライバシーポリシーを読む</a></p>`
  );
}

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
