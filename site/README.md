# ダウンロードサイト

ツールの紹介・導入説明・紹介動画を載せたサイトです。Cloudflare Pages で公開します。

## 構成

| パス | 内容 |
| --- | --- |
| `public/` | 公開するページ（`index.html`）と素材（紹介動画・画像） |
| `functions/download.js` | `/download` … 最新版の配布用 zip へ転送する。クリックでそのままダウンロードが始まる |
| `functions/api/latest.js` | `/api/latest` … ページに表示する最新版の情報（版名・公開日・サイズ） |
| `lib/latest-release.js` | 最新 Release の配布用 zip を調べる共通処理 |

最新版は GitHub API で調べ（5分キャッシュ）、使えないときは `github.com/.../releases/latest` のリダイレクト先から読み取ります。
新しいバージョンを Release で公開すれば、サイトを直さなくても `/download` は自動で最新版を指します。

## Cloudflare Pages の設定

Workers & Pages → 作成 → Pages → Git に接続 → `RiTa-23/obs-video-playlist` を選び、次のように設定します。

| 項目 | 値 |
| --- | --- |
| 本番ブランチ | `main` |
| フレームワーク プリセット | なし |
| ビルドコマンド | （空欄） |
| ビルド出力ディレクトリ | `public` |
| ルートディレクトリ（詳細設定） | `site` |

任意：環境変数 `GITHUB_TOKEN`（権限なしの読み取り用トークンで十分）を入れると、GitHub API の回数制限が緩くなります。

## 手元で確認する

```sh
cd site
npx wrangler pages dev public
```
