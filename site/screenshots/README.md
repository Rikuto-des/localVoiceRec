# Screenshots for the distribution site

## Required files

- `menubar.png` — MenuBarExtra ポップアップのスクショ（待機中 + 録音開始ボタンが見える状態を推奨）
- `detail.png` — 録音一覧 + 詳細ウィンドウ（波形 + チャットバブル）のスクショ

## 撮影手順 (macOS)

```bash
# ウィンドウ単体スクショ (影付き)
Cmd + Shift + 4 → Space → 対象ウィンドウをクリック
```

または `screencapture -w -o <path>` でも可。

## 推奨サイズ

- 横幅: 1200-1800px 程度（HiDPI 想定）
- フォーマット: PNG（透過不要、影は撮ったままで OK）
- 背景: マウスカーソル無し、できれば適度な余白

保存後、Cloudflare Pages を再デプロイすれば反映されます。
