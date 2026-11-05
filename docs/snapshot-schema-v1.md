# Stockpile スナップショット スキーマ v1

AI 連携（読み取り専用）で Stockpile から外部へ渡すデータ形式の正式仕様。
本書が唯一の正であり、iOS アプリ / テンプレート Worker / Muse コネクタは本書に従う。

- 版: 1
- 対応する連携プロンプト: `stockpile-link-prompt v1`
- 関連: 設計メモ（連携全体の設計）、セットアッププロンプト文案

## 1. 形式の概要

- JSON オブジェクト（トップレベルは配列ではない）
- 文字コード: UTF-8
- 日付のみの項目は `yyyy-MM-dd`、日時項目は ISO 8601（タイムゾーン付き）

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-05T18:00:00+09:00",
  "appVersion": "1.0.0",
  "familyName": "矢作家",
  "items": [
    {
      "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      "name": "水 2L",
      "janCode": "4901777018686",
      "quantity": 12,
      "expiryDate": "2027-03-31",
      "bagName": "非常袋",
      "locationNote": "玄関クローゼット",
      "updatedAt": "2026-11-01T10:15:00+09:00"
    }
  ]
}
```

## 2. フィールド定義

### トップレベル

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| schemaVersion | Int | ○ | 本仕様の版。v1 では常に `1` |
| generatedAt | String (ISO 8601) | ○ | スナップショット生成日時。読み手は鮮度表示に必ず使う |
| appVersion | String | 任意 | 生成したアプリのバージョン。切り分け用 |
| familyName | String | 任意 | 対象 Family の表示名。取り違え防止用 |
| items | Array | ○ | 対象 Family スコープの全アイテム。0件可 |

### items[] の要素

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| id | String (UUID) | ○ | Item.id。差分検出・同一アイテムの追跡に使う |
| name | String | ○ | 品名。1〜200文字 |
| janCode | String / null | 任意 | JAN コード。最大32文字。価格比較の検索キー |
| quantity | Int | ○ | 数量（整数のみ）。1〜999,999 |
| expiryDate | String (`yyyy-MM-dd`) / null | 任意 | 賞味・使用期限。期限なしは null |
| bagName | String / null | 任意 | 保管場所（Bag）の名前 |
| locationNote | String / null | 任意 | 位置メモ。最大2,000文字 |
| updatedAt | String (ISO 8601) | ○ | アイテムの最終更新（syncTimestamp: updatedAt、なければ createdAt） |

含めないもの: 通知済みフラグ、Family の参加者情報、その他個人を特定する情報。

## 3. バックアップ形式との違い

既存のバックアップ書き出し（移行用）は「JSON 配列」で、`name / janCode / quantity /
expiryDate / bagName / locationNote` のみを持つ。本形式は連携用に次を追加したもの:

- トップレベルの包み（schemaVersion / generatedAt / appVersion / familyName）
- items への `id` と `updatedAt` の追加（差分検出と鮮度判定のため）

項目名と日付形式（`yyyy-MM-dd`）はバックアップ形式と統一してある。
バックアップ形式のファイルを本形式として読み込んではならない（検証で弾く）。

## 4. 検証ルール（受信側）

既存のバックアップ検証上限をそのまま流用する。

- 全体サイズ: 5MB 以下
- items 件数: 5,000件以下
- name: 空でないこと、200文字以下
- janCode: 32文字以下
- quantity: 1〜999,999 の整数
- expiryDate: `yyyy-MM-dd` として解釈できること（null 可）
- schemaVersion が対応範囲外の場合は、黙って読み替えずエラーにする

## 5. 互換ルール

- 読み手は未知のフィールドを無視する（前方互換）。
- 書き手は v1 の間、既存フィールドの意味と型を変えない。
- 意味や型を変える変更が必要になったら schemaVersion を上げ、本書の新版を作る。
  旧版の読み手は新版を「未対応」として明示的にエラーにする。

## 6. サンプル

- `docs/examples/snapshot-sample-normal.json` — 通常のスナップショット
- `docs/examples/snapshot-sample-minimal.json` — 任意項目が null の最小形
- `docs/examples/snapshot-sample-empty.json` — 0件
