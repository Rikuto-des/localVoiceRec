# localVoiceRec — Branding

S16-B で整備したロゴ・App アイコン・DMG マウント画面の根拠と一覧。

## デザインコンセプト

`site/` の editorial / 印刷物トーンを踏襲する。
- 「会議の声を、紙のフィールドノートのように残す」をモチーフに
- 派手なグラデーション・ネオン・紫は排し、紙 + インクの 4 色のみで構成
- AI 風よりも、活版印刷 / 手仕事感を優先

### パレット

| 役割 | HEX | 用途 |
|------|------|------|
| Ink (主) | `#1B1816` | 背景・本文 |
| Paper | `#F4EFE6` | 紙地・前景 |
| Deep Green | `#224431` | 補助アクセント |
| Seal Red | `#A0392B` | 録音ドット / 印影 / 注意喚起 |

### シンボルの読み |

- 5 本の縦バー = 音声波形 (録音中央が最も高い)
- 右上の赤丸 = 録音インジケーター + 印鑑 / Field Note の「印影」
- 外枠の角丸スクエア = 印刷台紙

## アセット一覧

### ロゴ (`Brand/Logo/`)

| ファイル | 用途 |
|----------|------|
| `logo.svg` | マスター 1024×1024 (紙背景 + インクパネル + 波形 + 印) |
| `logo-mark.svg` | シンボル単体 (角丸ダーク 1024×1024、App アイコンのソース) |
| `logo-wordmark.svg` | シンボル + ワードマーク 2400×640 |
| `logo-mono.svg` | モノクロ 1 色版 |
| `logo-1024.png`, `logo-mark-1024.png`, `logo-wordmark.png`, `logo-mono.png` | ラスタライズ版 |

### App アイコン (`Brand/AppIcon/`)

| ファイル | 内容 |
|----------|------|
| `AppIcon.iconset/` | Apple 仕様の 10 サイズ PNG |
| `AppIcon.icns` | `iconutil -c icns` でビルド |

Xcode 側は `App/Assets.xcassets/AppIcon.appiconset/` に同 PNG を配置し、
`project.yml` で
```yaml
ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
INFOPLIST_KEY_CFBundleIconName: AppIcon
```
を指定。`xcodegen generate` 後の Xcode ビルドで
`.app/Contents/Resources/AppIcon.icns` が自動同梱される。

### DMG (`Brand/DMG/`)

| ファイル | サイズ |
|----------|------|
| `dmg-background.svg` | ベクター原本 |
| `dmg-background.png` | 540×380 (@1x) |
| `dmg-background@2x.png` | 1080×760 (@2x) |

`scripts/make-dmg.sh` は `create-dmg` ベースに書き換え。
背景画像のスロット枠 (240×120 の薄い角丸) が
`--icon "localVoiceRec.app" 140 200` と `--app-drop-link 400 200`
の実際の Finder アイコン配置とちょうど揃うよう設計。

## 再ビルド手順

ロゴを編集したら以下を順に実行:

```bash
# 1) iconset を再生成
ICONSET=Brand/AppIcon/AppIcon.iconset
SRC=Brand/Logo/logo-mark.svg
for sz in 16 32 128 256 512; do
  rsvg-convert -w $sz -h $sz "$SRC" -o "$ICONSET/icon_${sz}x${sz}.png"
  rsvg-convert -w $((sz*2)) -h $((sz*2)) "$SRC" -o "$ICONSET/icon_${sz}x${sz}@2x.png"
done

# 2) .icns に固める
iconutil -c icns "$ICONSET" -o Brand/AppIcon/AppIcon.icns

# 3) Xcode asset catalog に同期
cp "$ICONSET"/*.png App/Assets.xcassets/AppIcon.appiconset/

# 4) DMG 背景を再ラスタライズ
rsvg-convert -w 540 -h 380 Brand/DMG/dmg-background.svg -o Brand/DMG/dmg-background.png
rsvg-convert -w 1080 -h 760 Brand/DMG/dmg-background.svg -o Brand/DMG/dmg-background@2x.png

# 5) xcodegen
xcodegen generate
```

## 注意

- ワードマーク SVG は Helvetica/Helvetica Neue 参照。macOS では確実に解決されるが、
  Linux 等で再ラスタライズする場合は別途フォント解決が必要。
- DMG 背景の `<text>` 要素も同様。再ラスタライズは macOS 上で行うこと。
- AppIcon は macOS の OS 側自動角丸ではなく、SVG 内で `rx="224"` の角丸スクエアを
  描き切っている (Apple の現行ガイドライン準拠)。
