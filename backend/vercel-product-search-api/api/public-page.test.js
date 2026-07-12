import test from "node:test";
import assert from "node:assert/strict";

const { privacyPage, supportPage } = await import("./public-page.js");

test("privacy page describes the app data flows and deletion", () => {
  assert.match(privacyPage, /CloudKit/);
  assert.match(privacyPage, /楽天/);
  assert.match(privacyPage, /Yahoo/);
  assert.match(privacyPage, /JSONバックアップ/);
  assert.match(privacyPage, /保存期間と削除/);
  assert.match(privacyPage, /HTTPS/);
});

test("support page contains actionable troubleshooting and safe-contact guidance", () => {
  assert.match(supportPage, /家族共有ができません/);
  assert.match(supportPage, /通知が届きません/);
  assert.match(supportPage, /購入を復元/);
  assert.match(supportPage, /認証コード、パスワードは送らないでください/);
  assert.match(supportPage, /プライバシーポリシーを読む/);
});
