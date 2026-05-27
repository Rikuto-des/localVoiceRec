# Cloudflare Pages 配布サイト セットアップ

`site/` ディレクトリを Cloudflare Pages にデプロイするための手順。

## 構成

```
site/
├── index.html        # トップページ（単一ページ）
├── style.css
├── favicon.svg
├── robots.txt
├── _headers          # Cloudflare Pages のセキュリティヘッダ設定
└── downloads/
    └── (ここに .dmg を置く)
```

依存ライブラリなし。ビルド不要の純粋な静的サイト。

---

## 方式 A: GitHub と連携（推奨）

1. Cloudflare ダッシュボード → **Workers & Pages** → **Create application** → **Pages** → **Connect to Git**
2. GitHub アカウントを認可し、`Rikuto-des/localVoiceRec` を選択
3. ビルド設定:
   - **Production branch**: `main`
   - **Framework preset**: `None`
   - **Build command**: (空欄)
   - **Build output directory**: `site`
   - **Root directory**: (空欄, リポジトリルート)
4. **Save and Deploy**

`main` への push で自動デプロイ。Preview deploy も PR ごとに自動生成される。

カスタムドメイン:
- **Custom domains** タブ → **Set up a custom domain** → ドメイン入力
- DNS 設定で CNAME を `<project>.pages.dev` に向ける
- HTTPS 証明書は Cloudflare が自動発行

---

## 方式 B: wrangler CLI で直接デプロイ

ローカルから手動で push する方式。CI を使わない / プライベートにしたいとき向き。

```bash
# 一度だけ
npm install -g wrangler
wrangler login    # ブラウザで認証

# デプロイ
wrangler pages deploy site --project-name=localvoicerec
```

初回実行時にプロジェクトが作成される。2 回目以降は同じコマンドで上書きデプロイ。

---

## .dmg の配置

ビルドした `.dmg` をサイトに含めるには 2 つの方法がある。

### B1. リポジトリに含める（小規模・限定配布向け）

```bash
cp dist/localVoiceRec-0.1.0.dmg site/downloads/
git add site/downloads/localVoiceRec-0.1.0.dmg
git commit -m "Release 0.1.0"
git push
```

注意: Cloudflare Pages のデプロイ単位（zip）は **25 MB** 上限。それを超える場合は B2 へ。

### B2. 外部ホスティング（推奨・将来）

R2 / S3 などのオブジェクトストレージに置き、`index.html` のダウンロードボタンの
`href` をそちらに向ける。

```html
<a class="btn btn-primary btn-lg"
   href="https://downloads.example.com/localVoiceRec-0.1.0.dmg"
   download>...</a>
```

R2 + Cloudflare の組み合わせなら egress が無料。

---

## index.html のバージョン更新

リリースごとに以下を更新:

| 場所 | 値 |
|---|---|
| `<title>`, OGP | バージョン番号 |
| `.btn` の `href` | `/downloads/localVoiceRec-<version>.dmg` |
| `.btn-meta` のサイズ | `du -sh dist/*.dmg` で確認 |
| `.download-version strong` | 例: `0.1.0` |
| `.download-build` | `released YYYY-MM-DD · build N` |
| `#sha` | `shasum -a 256 dist/*.dmg` の出力 |

将来は自動生成スクリプトを `scripts/render-site.sh` として追加する余地あり（今は手動）。

---

## セキュリティヘッダ

`site/_headers` で以下を設定済み:

- `Strict-Transport-Security` (HSTS)
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy`: マイク・カメラ・位置情報すべて禁止
- `Content-Security-Policy`: Google Fonts 以外の外部リソースを禁止

Cloudflare の Security → WAF も合わせて有効化を推奨。

---

## ローカルプレビュー

```bash
cd site
python3 -m http.server 8080
# → http://localhost:8080
```

`_headers` はローカル `http.server` では効かないが、レイアウト確認には十分。
ヘッダ動作の確認は `wrangler pages dev site` で。
