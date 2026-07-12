import test from "node:test";
import assert from "node:assert/strict";

const { privacyPage, supportPage } = await import("./public-page.js");

test("privacy page describes the app data flows and deletion", () => {
  const page = privacyPage();
  assert.match(page, /CloudKit/);
  assert.match(page, /Yahoo/);
  assert.match(page, /JSONバックアップ/);
  assert.match(page, /保存期間と削除/);
  assert.match(page, /HTTPS/);
  assert.match(page, /Cloudflare Workers/);
  assert.doesNotMatch(page, /Vercel/);
  assert.doesNotMatch(page, /楽天/);
});

test("support page contains actionable troubleshooting and safe-contact guidance", () => {
  const page = supportPage({ SUPPORT_EMAIL: "support@example.com" });
  assert.match(page, /家族共有ができません/);
  assert.match(page, /通知が届きません/);
  assert.match(page, /購入を復元/);
  assert.match(page, /認証コード、パスワードは送らないでください/);
  assert.match(page, /プライバシーポリシーを読む/);
  assert.match(page, /mailto:support@example.com/);
});
