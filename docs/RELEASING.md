# Release の公開手順

新しいバージョンを配布するときの手順です。

## 仕組み

GitHub で Release を **公開（Publish）** すると、GitHub Actions のワークフロー
（[`.github/workflows/release.yml`](../.github/workflows/release.yml)）が動き、次のことを自動で行います。

1. `obs-video-playlist.lua` の `VERSION`、`video-playlist-dock.html` の `DOCK_VERSION` と Release のタグが一致しているか確認する
2. 配布用 zip `obs-video-playlist-vX.Y.Z.zip` を作る
3. その zip を Release の Assets に添付する

zip の中身は次のとおりです。

```
obs-video-playlist/
├── obs-video-playlist.lua
├── video-playlist-dock.html
├── README.md
├── LICENSE
└── docs/
    └── screenshot.png
```

配布する zip にファイルを増やしたいときは、`release.yml` の「配布用 zip を作成」ステップを編集してください。

## バージョン番号の決め方

`メジャー.マイナー.パッチ` の形にします（例：`1.0.2`）。タグはその前に `v` を付けます（例：`v1.0.2`）。

| 変更の種類 | 上げる番号 | 例 |
| --- | --- | --- |
| 不具合の修正だけ | パッチ | 1.0.1 → 1.0.2 |
| 機能の追加（今までの使い方はそのまま使える） | マイナー | 1.0.2 → 1.1.0 |
| 設定や使い方が変わり、今までどおりに使えなくなる変更 | メジャー | 1.1.0 → 2.0.0 |

## 手順

### 1. バージョンを上げて main に push する

1. `obs-video-playlist.lua` の冒頭にある `VERSION` を新しい番号にする

   ```lua
   local VERSION     = "1.0.2"
   ```

2. `video-playlist-dock.html` の `DOCK_VERSION` を同じ番号にする（冒頭のコメントにあるバージョン表記も合わせる）

   ```js
   const DOCK_VERSION = '1.0.2';
   ```

   ドックはこの番号と GitHub の最新 Release を比べて「新しいバージョンがあります」と知らせます。
3. `README.md` の「更新履歴」の一番上に変更内容を1行で追記する
4. コミットして main に push する

   ```sh
   git add -A
   git commit -m "v1.0.2"
   git push origin main
   ```

> `VERSION` や `DOCK_VERSION` を上げ忘れたままタグを作ると、ワークフローが止まり zip が添付されません。

### 2. GitHub で Release を公開する

1. リポジトリの **Releases** を開き、**Draft a new release** を押す
2. **Tag: Select tag** を押し、新しいタグ名（例：`v1.0.2`）を入力して **Create new tag** → **Create**
3. **Target** が `main` になっていることを確認する
4. **Release title** にタグと同じ名前（例：`v1.0.2`）を入れる
5. **Release notes** に下の[テンプレート](#リリースノートのテンプレート)を貼り、変更点を書き換える
6. **Publish release** を押す

> リリースノートの入力欄で番号付きリストの行末で Enter を押すと、次の番号が自動で入ります。
> テンプレートを貼り付けたあとに行を足すときは、番号が二重にならないよう注意してください。

### 3. zip が添付されたか確認する

1. **Actions** タブで「Release」ワークフローが緑のチェックになるまで待つ（1分ほど）
2. Release のページの **Assets** に `obs-video-playlist-vX.Y.Z.zip` が付いていることを確認する
3. zip をダウンロードして展開し、中身と `obs-video-playlist.lua` の `VERSION` が正しいことを確認する

README のダウンロードリンクは「最新の Release」を指しているので、README を書き換える必要はありません。

## コマンドで公開する場合（GitHub CLI）

`gh`（GitHub CLI）にログイン済みなら、画面を使わずに公開できます。手順1のあとに次を実行します。

```sh
gh release create v1.0.2 --target main --title "v1.0.2" --notes-file notes.md
```

`notes.md` にはリリースノートを書いておきます。公開と同時にワークフローが動き、zip が添付されます。

## リリースノートのテンプレート

```markdown
OBS で動画を順番／ランダムに連続再生し続けるプレイリストです。

## ダウンロード
下の Assets にある `obs-video-playlist-v1.0.2.zip` をダウンロードして展開してください（「Source code」ではありません）。

## 導入
1. OBS の「ツール → スクリプト」で `obs-video-playlist.lua` を追加し、「現在のシーンに『動画プレイリスト』を作成」を押す
2. 「ツール → WebSocket サーバー設定」でサーバーを有効にする
3. スクリプト画面の「ドックURL」（「表示」を押してコピー）を「ドック → カスタムブラウザドック」に登録する

詳しくは同梱の README を見てください。

## 変更点
- （ここに変更内容）
```

ファイル名の `v1.0.2` は公開するバージョンに合わせて書き換えてください。

## うまくいかないとき

### zip が添付されない

**Actions** タブで「Release」ワークフローのログを確認します。

- **「VERSION とタグが一致しません」「DOCK_VERSION とタグが一致しません」と出ている**
  タグがすでに古い内容を指しているため、作り直します。
  1. Release のページ右上のゴミ箱アイコン（**Delete**）で Release を削除する
  2. **Releases** ページの **Tags** タブで、該当タグの右端の **…** → **Delete tag** で削除する
     （コマンドなら `git push --delete origin v1.0.2`）
  3. `VERSION`・`DOCK_VERSION` を直して main に push し、[手順2](#2-github-で-release-を公開する)からやり直す
- **ワークフロー自体が動いていない**
  - **Save draft**（下書き）のままでは動きません。**Publish release** で公開してください
  - **Settings → Actions → General** で Actions が無効になっていないか確認してください

### 一時的な失敗で止まった

ネットワークなどの一時的な失敗なら、Actions のログ画面の **Re-run jobs** で再実行できます。
同じ名前の zip がすでに付いていても上書きされます。

### 公開した Release の内容を直したい

リリースノートやタイトルは、Release のページ右上の鉛筆アイコン（**Edit**）から後で直せます。
zip の中身を直したい場合は、新しいパッチバージョンとして公開し直してください。
