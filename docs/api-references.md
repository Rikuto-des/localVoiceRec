# macOS 26 (Tahoe) ネイティブアプリ開発 API リファレンス

> このドキュメントは `localVoiceRec` の Contract 設計の根拠資料です。
> Apple 公式ドキュメント (developer.apple.com) と WWDC25 セッションを一次情報源とし、
> 実 API シグネチャ・最小サンプル・ハマりどころを引用 URL とともにまとめます。
>
> 各 API 末尾の **Availability** は公式ドキュメント表記そのままを記載しています。
> 推測で埋めた箇所はありません。不明点は **未確定** と明記しています。

---

## 目次

1. [SpeechAnalyzer / SpeechTranscriber (macOS 26 新フレームワーク)](#1-speechanalyzer--speechtranscriber-macos-26-新フレームワーク)
2. [Foundation Models (Apple Intelligence オンデバイス LLM)](#2-foundation-models-apple-intelligence-オンデバイス-llm)
3. [Core Audio Process Tap (macOS 14.2+)](#3-core-audio-process-tap-macos-142)
4. [AVAudioEngine マイク収音](#4-avaudioengine-マイク収音)
5. [SwiftData (macOS 26)](#5-swiftdata-macos-26)
6. [MenuBarExtra (SwiftUI)](#6-menubarextra-swiftui)

---

## 1. SpeechAnalyzer / SpeechTranscriber (macOS 26 新フレームワーク)

### 1.1 概要

**SpeechAnalyzer** は WWDC 2025 で導入された新フレームワーク。`Speech` framework 内に追加され、
従来の `SFSpeechRecognizer` を置き換える設計。Notes / Voice Memos / Journal 等 Apple 純正アプリ
で使われている同一エンジンに直接アクセスできる。

- **availability**: iOS 26.0+ / iPadOS 26.0+ / Mac Catalyst 26.0+ / macOS 26.0+ / visionOS 26.0+
- **WWDC 2025**: [Session 277 — "Bring advanced speech-to-text to your app with SpeechAnalyzer"](https://developer.apple.com/videos/play/wwdc2025/277/)

### 1.2 クラス構造

```swift
import Speech

final actor SpeechAnalyzer        // 解析セッション管理 (Swift actor)
final class  SpeechTranscriber    // STT を行う SpeechModule の具象クラス
struct       AnalyzerInput        // 入力音声バッファのラッパ
```

`SpeechAnalyzer` は **actor**。`await` 経由で呼び出す必要がある。
複数のモジュール (例: `SpeechTranscriber`, `SpeechDetector` など) を組み合わせ可能。

引用元:
- <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>
- <https://developer.apple.com/documentation/speech/speechtranscriber>

---

### 1.3 SpeechAnalyzer の初期化 API

```swift
// 1) モジュールのみ指定する初期化
convenience init(
    modules: [any SpeechModule],
    options: SpeechAnalyzer.Options?
)

// 2) 入力 sequence と一緒に渡し、すぐに分析開始する初期化
convenience init<InputSequence>(
    inputSequence: InputSequence,
    modules: [any SpeechModule],
    options: SpeechAnalyzer.Options?,
    analysisContext: AnalysisContext,
    volatileRangeChangedHandler: sending ((CMTimeRange, Bool, Bool) -> Void)?
)

// 3) AVAudioFile から分析するための初期化 (一括解析向け)
convenience init(
    inputAudioFile: AVAudioFile,
    modules: [any SpeechModule],
    options: SpeechAnalyzer.Options?,
    analysisContext: AnalysisContext,
    finishAfterFile: Bool,
    volatileRangeChangedHandler: sending ((CMTimeRange, Bool, Bool) -> Void)?
) async throws
```

引用元: <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>

#### 主要メソッド

| メソッド | 役割 |
| --- | --- |
| `analyzeSequence(_ inputSequence:)` | input sequence を消費しながら同期的に分析。最終 `CMTime` を返す。 |
| `analyzeSequence(from:)` | `AVAudioFile` 等から分析 |
| `start(inputSequence:)` | 「autonomous モード」で開始。Task は analyzer 内部管理。 |
| `start(inputAudioFile:finishAfterFile:)` | ファイル autonomous モード |
| `finalizeAndFinish(through:)` | 指定 `CMTime` まで処理してセッション終了 |
| `finalizeAndFinishThroughEndOfInput()` | 入力 EOF を待って終了 |
| `cancelAndFinishNow()` | 直ちに中断 |

ステータス監視:
```swift
func setVolatileRangeChangedHandler(sending ((CMTimeRange, Bool, Bool) -> Void)?)
var volatileRange: CMTimeRange?  // 結果が変動しうる範囲
```

引用元: <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>
(Section: "Topics > Creating an analyzer", "Monitoring analysis")

---

### 1.4 SpeechTranscriber API

```swift
final class SpeechTranscriber {
    // プリセット指定
    convenience init(locale: Locale, preset: SpeechTranscriber.Preset)

    // 個別オプション指定
    convenience init(
        locale: Locale,
        transcriptionOptions: Set<SpeechTranscriber.TranscriptionOption>,
        reportingOptions: Set<SpeechTranscriber.ReportingOption>,
        attributeOptions: Set<SpeechTranscriber.ResultAttributeOption>
    )

    // 結果ストリーム (AsyncSequence)
    var results: some AsyncSequence<Result, Error> { get }

    // ロケール解決
    static func supportedLocale(equivalentTo locale: Locale) -> Locale?
    static var supportedLocales: [Locale] { get }   // 利用可能 (DL 可) なロケール全体
    static var installedLocales: [Locale] { get }   // すでに端末に DL 済みのロケール
}
```

`Preset` / `ReportingOption` / `ResultAttributeOption` / `TranscriptionOption` の各列挙体で
動作を細かく制御できる。Preset の一例として `.offlineTranscription`(オフライン専用) がある。

引用元:
- <https://developer.apple.com/documentation/speech/speechtranscriber>
- <https://developer.apple.com/documentation/speech/speechtranscriber> (Section: "Locale Management")

---

### 1.5 AnalyzerInput

```swift
struct AnalyzerInput {
    init(buffer: AVAudioPCMBuffer)
    init(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime?)
    let buffer: AVAudioPCMBuffer
}
```

`bufferStartTime` を指定することで、(連続でない) 音声に対しても結果の `CMTime` を
正しい時間軸に合わせることが可能。

引用元: <https://developer.apple.com/documentation/speech/analyzerinput>

---

### 1.6 結果 (`SpeechModuleResult` / `SpeechTranscriber.Result`)

```swift
protocol SpeechModuleResult {
    var range: CMTimeRange { get }              // 音声上の範囲 (タイムスタンプ)
    var isFinal: Bool { get }                   // 確定済みかどうか
    var resultsFinalizationTime: CMTime { get } // この結果が確定したと見なされる時刻
}

// SpeechTranscriber が出力する具象結果
struct SpeechTranscriber.Result {
    var text: AttributedString  // 確定/暫定の単語アトリビュート付き
    var range: CMTimeRange      // この phrase の音声範囲
    var isFinal: Bool
}
```

- `result.text` は `AttributedString`。プレーンテキスト化は
  `String(result.text.characters)`。
- `AttributedString.rangeOfAudioTimeRangeAttributes(intersecting:)` で
  単語ごとの `CMTimeRange` を取得可能。

引用元:
- <https://developer.apple.com/documentation/speech/speechmoduleresult>
- <https://developer.apple.com/documentation/Foundation/AttributedString> (`rangeOfAudioTimeRangeAttributes`)

---

### 1.7 入力フォーマット (AVAudioPCMBuffer の要件)

明示的なサンプルレート/ビット深度の値は API ドキュメントには **記載されていない**。
代わりに **モジュール側に問い合わせる形** をとる。

```swift
// 全モジュールに互換のあるベスト format を取得
let audioFormat: AVAudioFormat? = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber]
)

// 単一モジュールの互換 format リストを取得
let formats = await transcriber.availableCompatibleAudioFormats
```

> 「Analyze audio buffers: To analyze audio buffers directly, convert them to a supported audio format,
> either on the fly or in advance. You can use `bestAvailableAudioFormat(compatibleWith:)` or
> individual modules' `availableCompatibleAudioFormats` methods to select a format to convert to.」
> — Apple Docs

**重要**: 自前で 16 kHz mono に固定するのではなく、上記 API で得た `AVAudioFormat` を
使って `AVAudioConverter` で変換するのが正解。具体的なサンプルレート値は **未確定** で、
Apple 側がモデル世代に応じて変更しうる。

引用元: <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>
(Section: "Analyze audio buffers")

---

### 1.8 オンデバイス動作確認方法 (Asset 管理)

```swift
import Speech

// 1) 端末/OS のサポートロケールに変換
guard let locale = SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
    // 未サポート
    throw MyError.unsupportedLanguage
}

let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)

// 2) 必要なら asset を DL & インストール
if let installationRequest = try await AssetInventory
    .assetInstallationRequest(supporting: [transcriber]) {
    try await installationRequest.downloadAndInstall()
}

// 3) すでに端末に入っているロケールだけを表示するなら
let alreadyOnDevice = SpeechTranscriber.installedLocales
```

- `AssetInventory.assetInstallationRequest(supporting:)` は `nil` を返したらすでに必要 asset が
  インストール済み。
- `installedLocales` は「いま端末に DL 済み」、`supportedLocales` は「DL 可能なものを含む全部」。

引用元:
- <https://developer.apple.com/documentation/speech/assetinventory>
- <https://developer.apple.com/documentation/speech/speechtranscriber>

---

### 1.9 完全な最小サンプル (公式)

```swift
import Speech

// Step 1: Modules
guard let locale = SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
    /* Note unsupported language */
    return
}
let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)

// Step 2: Assets
if let installationRequest = try await AssetInventory
    .assetInstallationRequest(supporting: [transcriber]) {
    try await installationRequest.downloadAndInstall()
}

// Step 3: Input sequence
let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

// Step 4: Analyzer
let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
let analyzer = SpeechAnalyzer(modules: [transcriber])

// Step 5: Supply audio
Task {
    while /* audio remains */ true {
        /* Get some audio */
        /* Convert to audioFormat */
        let pcmBuffer: AVAudioPCMBuffer = /* an AVAudioPCMBuffer containing some converted audio */
        let input = AnalyzerInput(buffer: pcmBuffer)
        inputBuilder.yield(input)
    }
    inputBuilder.finish()
}

// Step 7: Act on results
Task {
    do {
        for try await result in transcriber.results {
            let bestTranscription = result.text                 // AttributedString
            let plainText = String(bestTranscription.characters) // String
            print(plainText)
        }
    } catch {
        /* Handle error */
    }
}

// Step 6: Perform analysis
let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)

// Step 8: Finish analysis
if let lastSampleTime {
    try await analyzer.finalizeAndFinish(through: lastSampleTime)
} else {
    try analyzer.cancelAndFinishNow()
}
```

引用元: <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>

---

### 1.10 タイムスタンプ取得方法

- 各 `Result.range` (`CMTimeRange`) が phrase 単位の音声範囲。
- 秒に変換するには `result.range.start.seconds`。
- 単語レベル: `result.text` が `AttributedString` で、各 run に `audioTimeRange` 属性が
  付与される (上記 1.6 参照)。

```swift
for try await result in transcriber.results {
    let startSec = result.range.start.seconds
    let endSec   = result.range.end.seconds
    // 単語 (run) ごとの timing
    for run in result.text.runs {
        if let tr = run.audioTimeRange {
            print("word=\(result.text[run.range]) at \(tr.start.seconds)")
        }
    }
}
```

> 注: `audioTimeRange` runtime attribute は `ResultAttributeOption` の指定によって ON/OFF。
> 詳細は `SpeechTranscriber.ResultAttributeOption` を参照。 — **個別の case 名は未確定**
> (Apple Docs 上では enum の case 列挙が見つからなかったため明示しない)。

引用元: <https://developer.apple.com/documentation/speech/speechtranscriber>

---

### 1.11 2 つの SpeechAnalyzer を並列で走らせる場合 (マイク + システム音声)

**公式ドキュメントの該当記述**:

> "Several transcriber instances can share the same backing engine instances and models,
> so long as the transcribers are configured similarly in certain respects."
> — `SpeechTranscriber` Overview

つまり 2 つの `SpeechTranscriber` (例: マイク用 / システム音声用) を同じロケール・同じ
preset で作ると、バックエンドのエンジンとモデルは共有される設計。**メモリ上のモデルは
1 セットで済む** と読み取れる。

ただし以下は **未確定** (公式ドキュメントに具体数値なし):
- アクティブインスタンスあたりの追加メモリ
- 同時並列インスタンスの上限
- CPU/Neural Engine の負荷分散挙動

推奨される実装方針 (Contract 候補):
- 2 つの `SpeechAnalyzer` actor を別々に作り、それぞれに 1 つの `SpeechTranscriber` を
  渡す (2 入力ストリームを混ぜないため)。
- Transcriber の `locale` / `preset` / オプションは揃える (バックエンド共有のため)。
- それぞれの結果 `AsyncSequence` を別 Task で消費。
- 終了時は片方ずつ `finalizeAndFinish(through:)` を呼ぶ。

引用元: <https://developer.apple.com/documentation/speech/speechtranscriber>

---

### 1.12 ハマりどころ

| 項目 | 内容 |
| --- | --- |
| Actor 越境 | `SpeechAnalyzer` は actor。`await` 必須、`Sendable` でないオブジェクトは渡せない。 |
| バッファ format | サンプルレートは決め打ちせず、`bestAvailableAudioFormat(compatibleWith:)` で取得した `AVAudioFormat` に変換すること。 |
| Asset DL | 初回起動時はネットワークが必要。`AssetInventory.assetInstallationRequest(supporting:)` が `nil` を返したら DL 不要。 |
| Locale | `Locale.current` をそのまま渡さず `supportedLocale(equivalentTo:)` で正規化。 |
| 暫定結果 | `result.isFinal == false` の間は文言が更新されうる。UI 描画はその前提で。 |
| Volatile range | `setVolatileRangeChangedHandler` で「ここから先はまだ揺れる」範囲を取得可能。 |
| autonomous モード | `start(inputSequence:)` を呼ぶと analyzer 内部 Task で消費される。終了は `finalizeAndFinishThroughEndOfInput()`。 |

---

### 1.13 引用 URL (Section 1)

- SpeechAnalyzer API: <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>
- SpeechTranscriber API: <https://developer.apple.com/documentation/speech/speechtranscriber>
- AnalyzerInput: <https://developer.apple.com/documentation/speech/analyzerinput>
- AssetInventory: <https://developer.apple.com/documentation/speech/assetinventory>
- SpeechModuleResult: <https://developer.apple.com/documentation/speech/speechmoduleresult>
- "Bringing advanced speech-to-text capabilities to your app": <https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app>
- WWDC 2025 Session 277: <https://developer.apple.com/videos/play/wwdc2025/277/>

---

## 2. Foundation Models (Apple Intelligence オンデバイス LLM)

### 2.1 概要

`FoundationModels` framework は Apple Intelligence のオンデバイス LLM を Swift API として
直接呼び出せるフレームワーク。WWDC 2025 で導入。

- **availability**: iOS 26.0+ / iPadOS 26.0+ / Mac Catalyst 26.0+ / macOS 26.0+ / visionOS 26.0+
- **WWDC 2025**:
  - [Session 286 — "Meet the Foundation Models framework"](https://developer.apple.com/videos/play/wwdc2025/286/)
  - [Session 301 — "Deep dive into the Foundation Models framework"](https://developer.apple.com/videos/play/wwdc2025/301/)

### 2.2 主要型

```swift
import FoundationModels

struct SystemLanguageModel         // モデルの可用性チェック・参照
final class LanguageModelSession   // 会話状態を持つセッション (会話 transcript つき)
@Generable                         // 構造化出力用 macro
@Guide(description:)               // プロパティガイド macro
struct GenerationOptions           // サンプリング/温度/最大 token 数
enum  LanguageModelSession.GenerationError
```

引用元: <https://developer.apple.com/documentation/FoundationModels>

---

### 2.3 利用可能性チェック (`SystemLanguageModel.default.availability`)

```swift
import FoundationModels
import SwiftUI

struct GenerativeView: View {
    private var model = SystemLanguageModel.default

    var body: some View {
        switch model.availability {
        case .available:
            // インテリジェンス UI を出す
            EmptyView()
        case .unavailable(.deviceNotEligible):
            // M1 未満 or 非対応端末
            Text("This device doesn't support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            // 設定 > Apple Intelligence で ON にしてもらう
            Text("Please enable Apple Intelligence")
        case .unavailable(.modelNotReady):
            // モデル DL 中 / ストレージ不足等
            Text("Model not ready (downloading?)")
        case .unavailable(let other):
            Text("Unavailable: \(String(describing: other))")
        }
    }
}
```

`SystemLanguageModel` のプロパティ:

| プロパティ | 型 | 役割 |
| --- | --- | --- |
| `isAvailable` | `Bool` | 全部 OK な時のみ true |
| `availability` | `SystemLanguageModel.Availability` | `.available` / `.unavailable(reason)` |

`UnavailableReason` enum:
- `case deviceNotEligible`
- `case appleIntelligenceNotEnabled`
- `case modelNotReady`

引用元:
- <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel>
- <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/devicenoteligible>
- <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/appleintelligencenotenabled>

---

### 2.4 LanguageModelSession 初期化

```swift
// インストラクション文字列で
let session = LanguageModelSession(instructions: """
    You are a helpful workout coach.
    """)

// model / tools / instructions 完全指定
init(
    model: SystemLanguageModel = .default,
    tools: [any Tool] = [],
    instructions: (() throws -> Instructions)
)

// インストラクション無しでも OK
let session = LanguageModelSession()

// 既存 transcript から再開 (会話継続)
init(model: SystemLanguageModel, tools: [any Tool], transcript: Transcript)
```

引用元:
- <https://developer.apple.com/documentation/foundationmodels/languagemodelsession>
- <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init%28model%3Atools%3Ainstructions%3A%29>

---

### 2.5 一括生成 (respond) と ストリーミング (streamResponse)

#### 2.5.1 文字列の一括生成

```swift
let session = LanguageModelSession()
let response = try await session.respond(to: "Generate a motivational quote.")
print(response.content)  // String
```

#### 2.5.2 ストリーミング (UI 表示向け)

```swift
final func streamResponse(
    to prompt: Prompt,
    options: GenerationOptions = .init()
) -> LanguageModelSession.ResponseStream<String>

// 使い方
for try await partial in session.streamResponse(to: "Tell me a story") {
    // partial は途中までの集約された文字列スナップショット
    await MainActor.run { textView.text = partial }
}
```

> **Important** (公式注記): バックグラウンドで動かす場合は `streamResponse` を使うと
> `LanguageModelSession.GenerationError.rateLimited(_:)` を踏みやすいので、
> 代わりに `respond(to:options:)` を使うこと。 — Apple Docs

引用元: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse%28to%3Aoptions%3A%29>

#### 2.5.3 構造化出力 (Generable 型を生成)

```swift
let response = try await session.respond(
    to: "Generate a cute rescue cat",
    generating: CatProfile.self
)
let cat: CatProfile = response.content
```

オーバーロード一覧:
```swift
func respond(to:options:) async throws -> Response<String>
func respond(to:generating:includeSchemaInPrompt:options:) async throws -> Response<Content>
func respond(to:schema:includeSchemaInPrompt:options:) async throws -> Response<GeneratedContent>
func respond(options:prompt:) async throws -> Response<String>
```

引用元: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/respond%28to%3Aschema%3Aincludeschemainprompt%3Aoptions%3A%29>

---

### 2.6 GenerationOptions

```swift
struct GenerationOptions {
    init(
        sampling: SamplingMode? = nil,
        temperature: Double? = nil,           // 0...1 inclusive
        maximumResponseTokens: Int? = nil     // 正の整数
    )
}

// 例
let options = GenerationOptions(temperature: 0.7, maximumResponseTokens: 200)
let r = try await session.respond(to: "Write a haiku", options: options)
```

引用元: <https://developer.apple.com/documentation/foundationmodels/generationoptions/init%28sampling%3Atemperature%3Amaximumresponsetokens%3A%29>

---

### 2.7 @Generable / @Guide マクロ

#### 2.7.1 基本 (struct)

```swift
import FoundationModels

@Generable(description: "Basic profile information about a cat")
struct CatProfile {
    // ガイドが無くてもよい
    var name: String

    @Guide(description: "The age of the cat", .range(0...20))
    var age: Int

    @Guide(description: "A one sentence profile about the cat's personality")
    var profile: String
}
```

#### 2.7.2 enum (列挙される選択肢を強制)

```swift
@Generable
enum Breakfast {
    case waffles
    case pancakes
    case bagels
    case eggs
}

let response = try await session.respond(
    to: "Pick the ideal breakfast for: \(userInput)",
    generating: Breakfast.self
)
```

#### 2.7.3 ネスト構造 + count 制約

```swift
@Generable
struct SearchSuggestions {
    @Guide(description: "A list of suggested search terms.", .count(4))
    var searchTerms: [SearchTerm]

    @Generable
    struct SearchTerm {
        var id: GenerationID  // 自動生成 ID
        @Guide(description: "A two- or three-word search term, like 'Beautiful sunsets'.")
        var searchTerm: String
    }
}
```

#### 2.7.4 マクロのシグネチャ

```swift
// Generable
@attached(...) macro Generable(description: String)
@attached(...) macro Generable(description: String, representNilExplicitlyInGeneratedContent: Bool)

// Guide
@attached(peer) macro Guide(description: String)
@attached(peer) macro Guide<RegexOutput>(
    description: String? = nil,
    _ guides: Regex<RegexOutput>
)
```

引用元:
- <https://developer.apple.com/documentation/foundationmodels/generable%28description%3A%29>
- <https://developer.apple.com/documentation/foundationmodels/guide%28description%3A%29>
- <https://developer.apple.com/documentation/FoundationModels/Generable>
- <https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation>

> 内部実装: `@Generable` はコンパイル時に schema と initializer を生成し、constrained decoding
> によってモデルが schema を守る形でトークン列を生成する (構造的ミスをハードに防止)。

---

### 2.8 @Guide の role

`@Guide` プロパティは大きく以下の役割を持つ:

| 役割 | 例 | 効果 |
| --- | --- | --- |
| 自然言語ヒント | `@Guide(description: "Short title")` | モデルへの追加プロンプト |
| 値域制約 | `@Guide(.range(0...20))` | 数値レンジを強制 |
| 個数制約 | `@Guide(.count(4))` | 配列長を強制 |
| 正規表現制約 | `@Guide(_:)` w/ `Regex<...>` | 文字列パターンを強制 |

引用元: <https://developer.apple.com/documentation/foundationmodels/guide%28description%3A_%3A%29>

---

### 2.9 prewarm() — ウォームアップ / コールドスタート対策

```swift
final func prewarm(promptPrefix: Prompt? = nil)
```

- セッションが必要とするリソースをメモリにロード。
- `promptPrefix` を渡せば「将来の prompt のプレフィックス」もキャッシュ。
- **少なくとも 1 秒前** に呼ぶこと。直後に `respond`/`streamResponse` を呼ぶと意味が薄い。
- バックグラウンドや高負荷時は、必ずしも即時ロードを保証しない。

```swift
let session = LanguageModelSession(instructions: "You are a coach")
// ユーザが入力欄を開いたタイミング等
session.prewarm()

// 数秒後に実際の prompt
let r = try await session.respond(to: "Give me a quote")
```

引用元: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm%28promptprefix%3A%29>

---

### 2.10 エラーハンドリング (`LanguageModelSession.GenerationError`)

```swift
enum LanguageModelSession.GenerationError: Error {
    case assetsUnavailable(Context)
    case decodingFailure(Context)
    case exceededContextWindowSize(Context)
    case guardrailViolation(Context)
    case rateLimited(Context)
    case refusal(Refusal, Context)
    case concurrentRequests(Context)
    case unsupportedGuide(Context)
    case unsupportedLanguageOrLocale(Context)
}

struct Context {
    init(debugDescription: String)
    let debugDescription: String
}
```

主要ケース解説:

| ケース | 意味 / 対処 |
| --- | --- |
| `exceededContextWindowSize` | コンテキストウィンドウ (4,096 tokens) 超過。新セッションで再試行。プロンプト短縮 or `maximumResponseTokens` 制限。 |
| `rateLimited` | 短時間に多すぎ。バックオフ。バックグラウンドでは streaming を避ける。 |
| `assetsUnavailable` | Apple Intelligence OFF or モデル DL 未完了 or ストレージ不足。後で再試行。 |
| `guardrailViolation` | セーフティガードに引っかかった。プロンプトを見直す。 |
| `refusal` | モデルが応答を拒否。 |
| `concurrentRequests` | 同一 session で並列要求。直列化する。 |
| `unsupportedGuide` | `@Guide` の組み合わせが非対応。 |
| `unsupportedLanguageOrLocale` | 指定言語に未対応。 |
| `decodingFailure` | 構造化出力のデコードに失敗。 |

> 単一トークンの長さ目安: 英語/スペイン語/ドイツ語で約 3〜4 文字、日本語/中国語/韓国語で約 1 文字に 1 トークン。
> — Apple Docs ("exceededContextWindowSize")

引用元:
- <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/exceededcontextwindowsize%28_%3A%29>
- <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/assetsunavailable%28_%3A%29>
- <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/unsupportedlanguageorlocale%28_%3A%29>
- <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/context>

---

### 2.11 メモリ要件 / ウォームアップ時間

- **コンテキストウィンドウ**: 4,096 tokens (instructions + prompts + outputs 合計)
- **個別の RAM 消費量, ウォームアップ秒数**: 公式ドキュメント上に具体数値は **未確定**。
  実機で計測すること。
- 経験則:
  - `prewarm()` は ≥1 秒前に呼ぶ。
  - `concurrentRequests` を避けるため、1 セッション = 直列リクエストで運用。
  - 長文を生成する場合は streaming にしてユーザ体感のレイテンシを下げる。
  - バックグラウンド処理は非ストリーミングを使う。

引用元: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/exceededcontextwindowsize%28_%3A%29>

---

### 2.12 ハマりどころ

| 項目 | 内容 |
| --- | --- |
| availability | 必ず `SystemLanguageModel.default.availability` を見ること。`isAvailable` だけだと `.unavailable` の理由が取れない。 |
| 並列リクエスト | 同一 session で同時に複数 `respond` を呼ぶと `concurrentRequests` エラー。 |
| Context window | 4,096 tokens 上限。長会話は適宜新 session に切り替え。 |
| Background streaming | バックグラウンドでは `streamResponse` を使わず `respond` を使うべし (rate limit)。 |
| 言語サポート | 全言語非対応。`unsupportedLanguageOrLocale` を握り潰さない。 |
| prewarm | 直後に `respond` を呼ぶと無意味。最低 1 秒は空ける。 |

---

### 2.13 引用 URL (Section 2)

- Foundation Models top: <https://developer.apple.com/documentation/FoundationModels>
- LanguageModelSession: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession>
- SystemLanguageModel: <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel>
- Generable: <https://developer.apple.com/documentation/FoundationModels/Generable>
- Guide: <https://developer.apple.com/documentation/foundationmodels/guide%28description%3A%29>
- GenerationOptions: <https://developer.apple.com/documentation/foundationmodels/generationoptions/init%28sampling%3Atemperature%3Amaximumresponsetokens%3A%29>
- prewarm: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm%28promptprefix%3A%29>
- GenerationError (Context): <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/context>
- Guided generation guide: <https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation>
- WWDC25 Session 286 (Meet): <https://developer.apple.com/videos/play/wwdc2025/286/>
- WWDC25 Session 301 (Deep dive): <https://developer.apple.com/videos/play/wwdc2025/301/>

---

## 3. Core Audio Process Tap (macOS 14.2+)

### 3.1 概要

macOS 14.2 (Sonoma) で導入された Core Audio Process Tap API は、システム全体または
特定プロセスの音声出力をユーザ空間アプリから安全に「タップ」して取り込む仕組み。
従来必要だった ScreenCaptureKit / AudioServerPlugIn 非依存で実装可能。

- **availability**: macOS 14.2+
- **必要 plist key**: `NSAudioCaptureUsageDescription` (Info.plist)
- **権限種別**: 初回録音時にシステムが System Audio Recording 権限ダイアログを表示
  (※公式ドキュメント上では TCC のサービス名は `NSAudioCaptureUsageDescription` プロンプトと
  しか書かれていない。`kTCCServiceScreenCapture` ではなく、専用の System Audio Recording
  パーミッションを使う。元タスクに記載されている `kTCCServiceScreenCapture` ≠ 正式名であり
  正確な TCC サービス名は **未確定**。)

引用元: <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>

> "Important: To capture audio with a tap, you need to include the `NSAudioCaptureUsageDescription`
> key in your Info.plist file, along with a message that tells the user why the app is requesting
> access to capture audio. The first time you start recording from an aggregate device that
> contains a tap, the system prompts you to grant the app system audio recording permission."
> — Apple Docs

---

### 3.2 主要 C API シグネチャ

```swift
// Process tap の作成
func AudioHardwareCreateProcessTap(
    _ inDescription: CATapDescription!,
    _ outTapID: UnsafeMutablePointer<AudioObjectID>!
) -> OSStatus

// Process tap の破棄
func AudioHardwareDestroyProcessTap(_ tapID: AudioObjectID) -> OSStatus

// Aggregate device の作成 (tap を渡す先)
func AudioHardwareCreateAggregateDevice(
    _ inDescription: CFDictionary,
    _ outDeviceID: UnsafeMutablePointer<AudioObjectID>
) -> OSStatus

// Property listener (block 版)
func AudioObjectAddPropertyListenerBlock(
    _ inObjectID: AudioObjectID,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inDispatchQueue: dispatch_queue_t?,
    _ inListener: AudioObjectPropertyListenerBlock
) -> OSStatus
```

引用元:
- <https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap%28_%3A_%3A%29>
- <https://developer.apple.com/documentation/coreaudio/core-audio-functions>

---

### 3.3 CATapDescription

```swift
class CATapDescription {
    init()
    // 設定可能プロパティ
    var name: String
    var processes: [AudioObjectID]        // 対象プロセス (空配列 + 適切な init で全プロセス)
    var isPrivate: Bool                   // この tap を他プロセスから見えなくする
    var muteBehavior: CATapMuteBehavior   // 元の再生をミュート/しない/未ミュートでタップ
    var isMixdown: Bool                   // multi-stream を 1 つに mixdown するか
    var isMono: Bool                      // mono 化
    var isExclusive: Bool                 // 排他か
    var deviceUID: String?                // 特定 device のみタップする場合
    var stream: Int                       // stream index
}

enum CATapMuteBehavior: UInt32 {
    // 値は public, 具体的なケース名は CATapMuteBehavior enum を参照
    // (例) unmuted (=録音だけする) など
}
```

`CATapDescription` 自体は iOS 15 / macOS 12 から存在するクラスだが、
`AudioHardwareCreateProcessTap` が来たのは **macOS 14.2+**。

引用元:
- <https://developer.apple.com/documentation/coreaudio/catapdescription>
- <https://developer.apple.com/documentation/coreaudio/core-audio-enumerations> (`CATapMuteBehavior`)

#### 3.3.1 ありがちな initializer (Objective-C 由来)

実コードで多用されているのは以下のような Objective-C convenience initializer。
Apple 公式ドキュメント上の Swift シグネチャは少なめだが、ヘッダ (`<CoreAudio/CATapDescription.h>`) で公開されている:

```objc
- (instancetype)initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber *> *)excludedProcesses;
- (instancetype)initMonoGlobalTapButExcludeProcesses:(NSArray<NSNumber *> *)excludedProcesses;
- (instancetype)initStereoMixdownOfProcesses:(NSArray<NSNumber *> *)processes;
- (instancetype)initMonoMixdownOfProcesses:(NSArray<NSNumber *> *)processes;
```

> 注: これらの便利 init は ObjC ヘッダから判明しているもので、Apple Developer Documentation Web 上に
> 直接 Swift シグネチャが掲載されているとは限らない。**個別の引数仕様は未確定** な部分があるため、
> 実装時は SDK ヘッダ (`CoreAudio.framework/Headers/CATapDescription.h`) を直接参照すること。

---

### 3.4 tap 作成 → aggregate device 化 → IO 取得 のフロー

#### 3.4.1 Tap を作る (Swift)

```swift
// Create a tap description.
let description = CATapDescription()
description.name = tapConfiguration.name
description.processes = Array(tapConfiguration.processes)
description.isPrivate = tapConfiguration.isPrivate
description.muteBehavior = CATapMuteBehavior(rawValue: tapConfiguration.mute.rawValue)
    ?? description.muteBehavior
description.isMixdown = tapConfiguration.mixdown == .mono
    || tapConfiguration.mixdown == .stereo
description.isMono = tapConfiguration.mixdown == .mono
description.isExclusive = tapConfiguration.exclusive
description.deviceUID = tapConfiguration.device
description.stream = tapConfiguration.streamIndex

var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(description, &tapID)
```

#### 3.4.2 Tap の UID を取得

```swift
var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var propertySize = UInt32(MemoryLayout<CFString>.stride)
var tapUID: CFString = "" as CFString
_ = withUnsafeMutablePointer(to: &tapUID) {
    AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &propertySize, $0)
}
```

#### 3.4.3 Aggregate device を作る

```swift
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "Sample Aggregate Audio Device",
    kAudioAggregateDeviceUIDKey as String: UUID().uuidString
]
var aggID: AudioObjectID = 0
AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
```

#### 3.4.4 Tap を aggregate device の tap list に追加

```swift
var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioAggregateDevicePropertyTapList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var propertySize: UInt32 = 0
AudioObjectGetPropertyDataSize(aggID, &propertyAddress, 0, nil, &propertySize)

var list: CFArray? = nil
_ = withUnsafeMutablePointer(to: &list) {
    AudioObjectGetPropertyData(aggID, &propertyAddress, 0, nil, &propertySize, $0)
}

if var listAsArray = list as? [CFString] {
    if !listAsArray.contains(tapUID) {
        listAsArray.append(tapUID)
        propertySize += UInt32(MemoryLayout<CFString>.stride)
    }
    list = listAsArray as CFArray
    _ = withUnsafeMutablePointer(to: &list) {
        AudioObjectSetPropertyData(aggID, &propertyAddress, 0, nil, propertySize, $0)
    }
}
```

引用元: <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>

---

### 3.5 IOProc でリアルタイムにバッファを取り出す

`AudioHardwareCreateProcessTap` で作った tap を含む aggregate device を
`AudioDeviceCreateIOProcID(_:)` の対象として、`AudioDeviceIOProc` 経由で
バッファを取り出すのが標準パターン。

```swift
// 1) IOProc を登録 (具体的シグネチャは Core Audio HAL)
var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcID(aggID, ioProc, contextPointer, &procID)

// 2) device を start
AudioDeviceStart(aggID, procID)

// 3) IOProc 本体
let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, _ in
    // inInputData: UnsafePointer<AudioBufferList>
    // ここはリアルタイムスレッド。ロック・malloc・Swift コレクションのコピー禁止。
    return noErr
}
```

> **重要**: IOProc 内は **オーディオリアルタイムスレッド**。
> - ロックを取らない
> - 動的アロケーションしない
> - Swift の `class` 参照カウントが走る操作を避ける
> - `os_unfair_lock`/`atomic` を使い、ring buffer に書き込むだけにする
>
> AsyncStream への橋渡しは **別スレッドのコンシューマ** が ring buffer を読み出してから行う。

#### 3.5.1 AsyncStream への安全な橋渡しパターン (推奨設計)

```swift
final class TapPump {
    // Lock-free SPSC ring buffer
    private let ring: TPCircularBuffer  // or自作 lock-free FIFO

    // 公開 API
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    init() {
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { c = $0 }
        self.continuation = c
        // 別 Task でリング読み出し → continuation.yield
        Task.detached(priority: .userInitiated) {
            for await pcm in self.drainRing() {
                self.continuation.yield(pcm)
            }
        }
    }

    // IOProc 内で呼ぶ (リアルタイムセーフ)
    func push(_ abl: UnsafePointer<AudioBufferList>, frames: UInt32) {
        // ring buffer に raw bytes を書き込むだけ
    }
}
```

> `AVAudioPCMBuffer` の生成は ARC が走るため、リアルタイムスレッドでは行わず
> consumer 側 (通常スレッド) で行うこと。

引用元 (リアルタイム制約は Core Audio 一般ベストプラクティス。Apple 公式の Core Audio Overview を参照): <https://developer.apple.com/documentation/coreaudio>

---

### 3.6 Property Listener でデバイス変更を監視

```swift
let queue = DispatchQueue(label: "audio.tap.listener")
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

let status = AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject),
    &address,
    queue
) { _, _ in
    // デフォルト出力デバイス変更を検知 → tap/aggregate を作り直す等
}
```

引用元: <https://developer.apple.com/documentation/coreaudio/core-audio-functions>

---

### 3.7 必要なエントリ・権限

| 項目 | キー / 値 |
| --- | --- |
| Info.plist | `NSAudioCaptureUsageDescription` (説明文字列) |
| 権限プロンプト | システムが初回録音時に System Audio Recording 権限を要求 |
| 対応 macOS | macOS 14.2+ |
| TCC サービス名 | 正式定数名は公式 Doc に明記なし。**未確定**。 |

引用元: <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>
(Section: "Configure the sample code project")

---

### 3.8 ハマりどころ

| 項目 | 内容 |
| --- | --- |
| TCC | `NSAudioCaptureUsageDescription` が無いと起動時に即クラッシュ。 |
| 初回ダイアログ | tap 単独ではなく **aggregate device 経由で start した瞬間** にプロンプトが出る。 |
| RT スレッド | IOProc は real-time。malloc/lock/ARC NG。Ring buffer 経由でしか外に出さない。 |
| ARC | `AVAudioPCMBuffer` は consumer 側で作成。リアルタイムスレッドで作らない。 |
| Mute behavior | 通常録音はミュートしないので `unmuted` 系を使用。`muteBehavior` の値を間違えると元音声が止まる。 |
| Private tap | デバッグ時に Audio MIDI Setup に出さないなら `isPrivate = true`。 |
| Cleanup | `AudioHardwareDestroyProcessTap` と aggregate device の破棄を必ず実装 (リーク危険)。 |
| Sandbox | アプリ Sandbox では `com.apple.security.device.audio-input` も合わせて要検討 (※マイク向けの entitlement。Process Tap での要否は **未確定** だが、サンプル `AudioCap` は実装上付けている)。 |

参考実装 (Apple Engineer の Guilherme Rambo 氏が GitHub に公開): <https://github.com/insidegui/AudioCap>

---

### 3.9 引用 URL (Section 3)

- Capturing system audio with Core Audio taps (チュートリアル): <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>
- AudioHardwareCreateProcessTap: <https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap%28_%3A_%3A%29>
- CATapDescription: <https://developer.apple.com/documentation/coreaudio/catapdescription>
- Core Audio Functions (一覧): <https://developer.apple.com/documentation/coreaudio/core-audio-functions>
- Core Audio Enumerations (CATapMuteBehavior 等): <https://developer.apple.com/documentation/coreaudio/core-audio-enumerations>
- Sample code (AudioCap): <https://github.com/insidegui/AudioCap>

---

## 4. AVAudioEngine マイク収音

### 4.1 概要

`AVAudioEngine.inputNode` にタップを取り付けて、マイクからの PCM バッファを
コールバック経由で取得する。これは macOS / iOS 共通の標準パターン。

引用元: <https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode>

---

### 4.2 主要 API

```swift
// Input node 取得 (シングルトン)
var inputNode: AVAudioInputNode { get }

// Tap 設置
func installTap(
    onBus bus: AVAudioNodeBus,
    bufferSize: AVAudioFrameCount,
    format: AVAudioFormat?,
    block: @escaping AVAudioNodeTapBlock
)

// Tap 削除
func removeTap(onBus bus: AVAudioNodeBus)

// AVAudioNodeTapBlock シグネチャ
typealias AVAudioNodeTapBlock = (AVAudioPCMBuffer, AVAudioTime) -> Void
```

引用元: <https://developer.apple.com/documentation/avfaudio/avaudionode/installtap>

---

### 4.3 最小サンプル

```swift
import AVFAudio

final class MicCapture {
    private let engine = AVAudioEngine()
    private let bus: AVAudioNodeBus = 0
    private var format: AVAudioFormat!

    func start(handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        format = engine.inputNode.inputFormat(forBus: bus)
        engine.inputNode.installTap(
            onBus: bus,
            bufferSize: 8192,
            format: format
        ) { buffer, time in
            handler(buffer, time)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
    }
}
```

引用元 (パターンは Sound Analysis サンプルから引用): <https://developer.apple.com/documentation/soundanalysis/classifying-sounds-in-an-audio-stream>

---

### 4.4 macOS でのマイク権限

#### 4.4.1 Info.plist

```xml
<key>NSMicrophoneUsageDescription</key>
<string>音声を録音して文字起こしを行うために使用します。</string>
```

> "Apps that access any of the device's microphones must declare their intent to do so.
> You do this by including the `NSMicrophoneUsageDescription` key and a corresponding
> purpose string in your app's Info.plist. ... If an application attempts to access any
> of the device's microphones without a corresponding purpose string, the app exits."
> — Apple Docs

#### 4.4.2 ランタイム権限要求

```swift
import AVFoundation

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    startMic()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted { startMic() }
    }
case .denied, .restricted:
    // 設定アプリに飛ばす
    break
@unknown default:
    break
}
```

(`AVCaptureDevice` ベースの API は macOS で正式に動く。iOS の `AVAudioSession`/`AVAudioApplication.requestRecordPermission` 系は macOS では不要。)

引用元:
- <https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos>
- <https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29> (purpose string 必須の説明)

---

### 4.5 App Sandbox との整合

Sandbox を有効化している場合、Info.plist (NSMicrophoneUsageDescription) に加え、
entitlements で audio input を許可する:

```xml
<!-- App Sandbox + audio input -->
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

> "Audio Input Entitlement: A Boolean value that indicates whether the app may record
> audio using the built-in microphone and access audio input using Core Audio."
> — Hardened Runtime docs

旧来 `com.apple.security.device.microphone` も同等扱いだが、新規プロジェクトでは
`com.apple.security.device.audio-input` を推奨。

引用元:
- <https://developer.apple.com/documentation/Security/app-sandbox>
- <https://developer.apple.com/documentation/bundleresources/security-entitlements>
- <https://developer.apple.com/documentation/security/hardened-runtime>

---

### 4.6 ハマりどころ

| 項目 | 内容 |
| --- | --- |
| Format mismatch | `installTap` の `format:` を `nil` にすると hardware format を勝手に使う。明示するなら `inputFormat(forBus:)` から取得した format を指定。 |
| サンプルレート | macOS のマイクは通常 44.1 kHz / 48 kHz。SpeechAnalyzer に渡す前に `AVAudioConverter` で変換。 |
| Sandbox | `com.apple.security.device.audio-input` (or `.microphone`) を忘れると無音 (zeroed) になる。 |
| Permission denial | denied 後は設定アプリでしか戻せない。ユーザ誘導 UX が必要。 |
| TCC | `NSMicrophoneUsageDescription` 文字列が無いと即終了。 |
| Engine start | `try engine.start()` の前に tap を install しておくこと。 |

---

### 4.7 引用 URL (Section 4)

- AVAudioEngine.inputNode: <https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode>
- installTap: <https://developer.apple.com/documentation/avfaudio/avaudionode/installtap>
- AVAudioPCMBuffer: <https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer>
- AVAudioFormat: <https://developer.apple.com/documentation/avfaudio/avaudioformat>
- AVAudioConverter: <https://developer.apple.com/documentation/avfaudio/avaudioconverter>
- requestRecordPermission (purpose string 必須): <https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29>
- Requesting authorization for media capture on macOS: <https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos>
- App Sandbox entitlements: <https://developer.apple.com/documentation/Security/app-sandbox>
- Security entitlements: <https://developer.apple.com/documentation/bundleresources/security-entitlements>
- Hardened Runtime: <https://developer.apple.com/documentation/security/hardened-runtime>

---

## 5. SwiftData (macOS 26)

### 5.1 概要

SwiftData は WWDC 2023 で導入されたフレームワーク。macOS 26 でも引き続き利用可能で、
基本 API は安定している (新機能は History / Index など)。`@Model` マクロ + `ModelContainer` +
`ModelContext` の 3 点セットで成り立つ。

引用元: <https://developer.apple.com/documentation/SwiftData>

---

### 5.2 @Model マクロ

```swift
import SwiftData

@Model
class Item {
    var name: String
    var createdAt: Date

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}
```

`@Model` は Persistent な class を生成し、`PersistentModel` プロトコルに準拠させる。

引用元: <https://developer.apple.com/documentation/SwiftData>

---

### 5.3 ModelContainer / ModelConfiguration

#### 5.3.1 シンプルな宣言 (App entry)

```swift
import SwiftUI
import SwiftData

@main
struct LocalVoiceRecApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Recording.self, Segment.self])
    }
}
```

#### 5.3.2 細かい設定

```swift
let onDisk = ModelConfiguration(
    "Default",
    schema: Schema([Recording.self, Segment.self]),
    url: URL.applicationSupportDirectory.appending(path: "LocalVoiceRec.sqlite"),
    allowsSave: true,
    cloudKitDatabase: .none
)

let inMemoryForTests = ModelConfiguration(
    isStoredInMemoryOnly: true,
    allowsSave: false
)

let container = try ModelContainer(
    for: Recording.self, Segment.self,
    configurations: onDisk
)
```

主な ModelContainer initializer:

```swift
init(
    for givenSchema: Schema,
    migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
    configurations: [ModelConfiguration]
) throws

convenience init(
    for: any PersistentModel.Type...,
    migrationPlan: (any SchemaMigrationPlan.Type)?,
    configurations: ModelConfiguration...
) throws
```

引用元:
- <https://developer.apple.com/documentation/SwiftData/ModelContainer>
- <https://developer.apple.com/documentation/swiftdata/modelcontainer/init%28for%3Amigrationplan%3Aconfigurations%3A%29-1czix>
- <https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches>

> Sandbox 配下では `URL.applicationSupportDirectory` (= `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`) が
> 既定のドキュメント置き場。`ModelConfiguration` の `url:` パラメータでフル指定する場合も
> このコンテナ内部に置くこと。

---

### 5.4 ModelContext (CRUD)

```swift
import SwiftData

let context = ModelContext(container)
// or SwiftUI: @Environment(\.modelContext) var context

// Create
let item = Recording(title: "Meeting 2026-05-27")
context.insert(item)

// Update (単に property を書き換える)
item.title = "Updated"

// Delete
context.delete(item)

// Save (自動 save が有効な場合は不要なケース多し)
try context.save()
```

引用元:
- <https://developer.apple.com/documentation/SwiftData/ModelContext>
- <https://developer.apple.com/documentation/swiftdata/concurrencysupport>

---

### 5.5 リレーション (One-to-Many)

```swift
@Model
class Recording {
    var title: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Segment.recording)
    var segments: [Segment] = []

    init(title: String) {
        self.title = title
        self.createdAt = .now
    }
}

@Model
class Segment {
    var startSeconds: Double
    var endSeconds: Double
    var text: String

    var recording: Recording?  // inverse

    init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}
```

`@Relationship(deleteRule:)`:
- `.cascade`: 親を消すと子も消す
- `.nullify`: 親を消すと子の参照を nil に
- `.deny`: 子が残っている間は親を消せない
- `.noAction`: 何もしない

引用元: <https://developer.apple.com/documentation/swiftdata> (Section: "Define Model Relationships with SwiftData")

---

### 5.6 Query (SwiftUI 統合)

```swift
import SwiftUI
import SwiftData

struct RecordingList: View {
    @Query(sort: \Recording.createdAt, order: .reverse)
    private var recordings: [Recording]

    var body: some View {
        List(recordings) { rec in
            Text(rec.title)
        }
    }
}
```

詳細条件は `FetchDescriptor`:

```swift
let descriptor = FetchDescriptor<Recording>(
    predicate: #Predicate { $0.createdAt > Date.now.addingTimeInterval(-7*24*3600) },
    sortBy: [.init(\.createdAt, order: .reverse)]
)
let recent = try context.fetch(descriptor)
```

引用元: <https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches>

---

### 5.7 ハマりどころ

| 項目 | 内容 |
| --- | --- |
| Sandbox path | コンテナ外 (例: ユーザの `~/Documents` 直下) に store を置こうとすると EPERM。`URL.applicationSupportDirectory` 系を使う。 |
| Migration | `@Model` のスキーマを変えたら `SchemaMigrationPlan` を実装。さもないと初回起動でクラッシュ。 |
| Concurrency | `ModelContext` は MainActor 紐付け or `@ModelActor` のどちらかにする。スレッド越えに注意。 |
| Inverse relationship | `@Relationship(inverse:)` で必ず inverse を片方明示。 |
| Save | `autosaveEnabled` (デフォルト true on SwiftUI環境) でも、明示的に `try context.save()` する場面はある (バックグラウンド処理後など)。 |
| CloudKit | デフォルトで CloudKit 同期しようとする場合がある。オフライン専用なら `cloudKitDatabase: .none` を指定。 |

---

### 5.8 引用 URL (Section 5)

- SwiftData top: <https://developer.apple.com/documentation/SwiftData>
- ModelContainer: <https://developer.apple.com/documentation/SwiftData/ModelContainer>
- ModelContext: <https://developer.apple.com/documentation/SwiftData/ModelContext>
- Preserving model data across launches: <https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches>
- Concurrency support: <https://developer.apple.com/documentation/swiftdata/concurrencysupport>
- Syncing model data across devices: <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>

---

## 6. MenuBarExtra (SwiftUI)

### 6.1 概要

`MenuBarExtra` は macOS 13+ で導入された SwiftUI Scene。システムメニューバーに常駐する
コントロールを宣言的に書ける。デフォルトは menu スタイル、`.menuBarExtraStyle(.window)` で
任意の SwiftUI View をポップオーバーとして表示できる。

引用元: <https://developer.apple.com/documentation/swiftui/menubarextra>

---

### 6.2 基本シグネチャ

```swift
struct MenuBarExtra<Label: View, Content: View>: Scene {
    init(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        isInserted: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    )
    // 他にも label closure ベース等多数
}

// スタイル変更
extension Scene {
    func menuBarExtraStyle<S: MenuBarExtraStyle>(_ style: S) -> some Scene
}

// 組み込みスタイル
struct MenuBarExtraStyle {
    static var menu: MenuBarExtraMenuStyle
    static var window: MenuBarExtraWindowStyle
}
```

引用元: <https://developer.apple.com/documentation/swiftui/menubarextra>

---

### 6.3 LSUIElement と組み合わせた「メニューバー専用アプリ」

#### 6.3.1 Info.plist

```xml
<key>LSUIElement</key>
<true/>
```

> "A Boolean value indicating whether the app is an agent app that runs in the background
> and doesn't appear in the Dock."
> — Apple Docs

`LSUIElement = YES` でアプリは:
- Dock に出ない
- Cmd+Tab に出ない
- メニューバー (menu bar)・通知 UI は使える

#### 6.3.2 App エントリ

```swift
import SwiftUI

@main
struct LocalVoiceRecApp: App {
    var body: some Scene {
        MenuBarExtra("LocalVoiceRec", systemImage: "mic.fill") {
            MenuBarPanel()
                .frame(width: 360, height: 480)
        }
        .menuBarExtraStyle(.window)

        // 設定ウィンドウを別途持つ場合 (macOS 専用)
        Settings {
            SettingsView()
        }
    }
}
```

`.window` スタイルにすると、メニューアイテムのドロップダウンではなく
SwiftUI View をそのまま表示するポップオーバーになる。

引用元:
- <https://developer.apple.com/documentation/swiftui/menubarextra>
- <https://developer.apple.com/documentation/bundleresources/information-property-list/uimainstoryboardfile> (LSUIElement)
- <https://developer.apple.com/documentation/SwiftUI/Building-and-customizing-the-menu-bar-with-SwiftUI>

---

### 6.4 表示/非表示の動的制御 (`isInserted`)

```swift
@main
struct AppWithMenuBarExtra: App {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        MenuBarExtra(
            "App Menu Bar Extra",
            systemImage: "star",
            isInserted: $showMenuBarExtra
        ) {
            StatusMenu()
        }
    }
}
```

引用元: <https://developer.apple.com/documentation/swiftui/menubarextra>

---

### 6.5 ライフサイクル

`LSUIElement = YES` のアプリは、ウィンドウを全部閉じても終了しない (Dock 非表示なため
通常 macOS の「最後のウィンドウが閉じたら終了」ロジックの対象外)。終了するには:

```swift
Button("Quit") { NSApplication.shared.terminate(nil) }
```

を MenuBarExtra に必ず含めること。

> 既知の制約: SwiftUI のみで `Settings` シーンを開く方法は限られる。
> SwiftUI 単独で settings ウィンドウを開く API は FB10184971 で報告された通り
> macOS の世代によって `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
> や `openSettings` 環境値 (macOS 14+) を使う必要がある。**最新の正式 API は未確定** な場合があるので、
> macOS 26 では `@Environment(\.openSettings)` の動作を確認すること。

引用元: <https://github.com/feedback-assistant/reports/issues/327>

---

### 6.6 App Sandbox との整合

`LSUIElement` 自体は Sandbox と直交。Sandbox を有効化したまま MenuBarExtra アプリを
構築できる。マイク/オーディオ入力など、本アプリで必要になる entitlement は
Section 4 を参照。

---

### 6.7 ハマりどころ

| 項目 | 内容 |
| --- | --- |
| LSUIElement | これを忘れると Dock にアイコンが出てしまう。 |
| Quit ボタン | Dock 無しだとユーザが終了する手段が無い。menu に必須。 |
| Window style | `.menuBarExtraStyle(.window)` を付けないと通常メニュー扱いになり、任意 View が出ない。 |
| frame サイズ | `.window` スタイルでは content view に明示的に `.frame(width: H, height: V)` を付けないと潰れる。 |
| Settings | SwiftUI の `Settings` シーンを開く API は macOS バージョン依存。macOS 26 では `@Environment(\.openSettings)` の存在を確認。 |
| Activation | バックグラウンド常駐中に最前面化したい場合は `NSApp.activate(ignoringOtherApps: true)`。 |

---

### 6.8 引用 URL (Section 6)

- MenuBarExtra: <https://developer.apple.com/documentation/swiftui/menubarextra>
- Building and customizing the menu bar with SwiftUI: <https://developer.apple.com/documentation/SwiftUI/Building-and-customizing-the-menu-bar-with-SwiftUI>
- LSUIElement (Info.plist key): <https://developer.apple.com/documentation/bundleresources/information-property-list/uimainstoryboardfile>
- Scenes overview (MenuBarExtra example): <https://developer.apple.com/documentation/SwiftUI/Scenes>

---

## 補遺: マイク + システム音声の二系統入力アーキテクチャ (Contract への示唆)

本アプリの中核フロー (マイク + システム音声 → 2 系統の SpeechAnalyzer → SwiftData 保存 →
Foundation Models で要約) を支える、各層の整合性を 1 枚にまとめる:

```
┌──────────────────────────────┐       ┌──────────────────────────────┐
│  AVAudioEngine.inputNode     │       │  Core Audio Process Tap      │
│  → installTap → AsyncStream  │       │  → Aggregate Device → IOProc │
│  (44.1/48 kHz Float32 など)  │       │  → ring buffer → AsyncStream │
└──────────────┬───────────────┘       └──────────────┬───────────────┘
               │                                       │
               ▼                                       ▼
   ┌──────────────────────────┐           ┌──────────────────────────┐
   │  AVAudioConverter で     │           │  AVAudioConverter で     │
   │  bestAvailableAudioFormat│           │  bestAvailableAudioFormat│
   │  に合わせて再サンプル    │           │  に合わせて再サンプル    │
   └──────────────┬───────────┘           └──────────────┬───────────┘
                  ▼                                      ▼
   ┌──────────────────────────┐           ┌──────────────────────────┐
   │ SpeechAnalyzer (Mic)     │           │ SpeechAnalyzer (System)  │
   │  + SpeechTranscriber     │           │  + SpeechTranscriber     │
   │   (同一 locale / preset) │  ←共有→   │   (同一 locale / preset) │
   └──────────────┬───────────┘           └──────────────┬───────────┘
                  ▼                                      ▼
        AsyncSequence<Result>                  AsyncSequence<Result>
                  │                                      │
                  └──────────────┬───────────────────────┘
                                 ▼
                ┌────────────────────────────────┐
                │ SwiftData (@Model)             │
                │  Recording 1 ── n Segment      │
                │  (start/end/text/source)       │
                └────────────────┬───────────────┘
                                 ▼
                ┌────────────────────────────────┐
                │ FoundationModels               │
                │  LanguageModelSession          │
                │  respond(generating: Summary)  │
                └────────────────────────────────┘
                                 ▲
                                 │
                ┌────────────────────────────────┐
                │ MenuBarExtra (.window style)   │
                │  LSUIElement = YES             │
                └────────────────────────────────┘
```

### 設計上のキー要件 (公式ドキュメント由来)

1. **2 つの SpeechTranscriber は同一 locale/preset で揃える** → backing engine 共有
   (Source: SpeechTranscriber Overview)
2. **Audio format は `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` で取得**して
   `AVAudioConverter` で変換 (具体 Hz は固定しない)
3. **Process Tap の IOProc は RT スレッド**。AVAudioPCMBuffer 生成は consumer 側で行う
4. **Foundation Models の `prewarm()` は ≥1 秒前**、バックグラウンドは `respond` を使う
   (streaming は前景のみ)
5. **Sandbox**:
   - `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` (マイク)
   - `NSAudioCaptureUsageDescription` (システム音声タップ)
6. **LSUIElement = YES** で Dock を出さず、`MenuBarExtra(.window)` を UI 主舞台に

---

## 全引用 URL (一覧)

### Apple Developer Documentation (公式)

- Speech framework top: <https://developer.apple.com/documentation/speech>
- SpeechAnalyzer: <https://developer.apple.com/documentation/Speech/SpeechAnalyzer>
- SpeechTranscriber: <https://developer.apple.com/documentation/speech/speechtranscriber>
- AnalyzerInput: <https://developer.apple.com/documentation/speech/analyzerinput>
- AssetInventory: <https://developer.apple.com/documentation/speech/assetinventory>
- SpeechModuleResult: <https://developer.apple.com/documentation/speech/speechmoduleresult>
- "Bringing advanced speech-to-text capabilities to your app": <https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app>
- AttributedString.rangeOfAudioTimeRangeAttributes: <https://developer.apple.com/documentation/Foundation/AttributedString>
- FoundationModels top: <https://developer.apple.com/documentation/FoundationModels>
- LanguageModelSession: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession>
- LanguageModelSession.streamResponse: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse%28to%3Aoptions%3A%29>
- LanguageModelSession.respond(schema:): <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/respond%28to%3Aschema%3Aincludeschemainprompt%3Aoptions%3A%29>
- LanguageModelSession.prewarm: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm%28promptprefix%3A%29>
- SystemLanguageModel: <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel>
- GenerationOptions: <https://developer.apple.com/documentation/foundationmodels/generationoptions/init%28sampling%3Atemperature%3Amaximumresponsetokens%3A%29>
- Generable macro: <https://developer.apple.com/documentation/foundationmodels/generable%28description%3A%29>
- Generable macro (representNilExplicitly variant): <https://developer.apple.com/documentation/foundationmodels/generable%28description%3Arepresentnilexplicitlyingeneratedcontent%3A%29>
- Generable (top): <https://developer.apple.com/documentation/FoundationModels/Generable>
- Guide macro: <https://developer.apple.com/documentation/foundationmodels/guide%28description%3A%29>
- Guide macro (regex variant): <https://developer.apple.com/documentation/foundationmodels/guide%28description%3A_%3A%29>
- Guided generation guide: <https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation>
- Generating content with Foundation Models: <https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models>
- Loading a custom adapter: <https://developer.apple.com/documentation/FoundationModels/loading-and-using-a-custom-adapter-with-foundation-models>
- Capturing system audio with Core Audio taps: <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>
- AudioHardwareCreateProcessTap: <https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap%28_%3A_%3A%29>
- CATapDescription: <https://developer.apple.com/documentation/coreaudio/catapdescription>
- Core Audio functions list: <https://developer.apple.com/documentation/coreaudio/core-audio-functions>
- Core Audio enumerations: <https://developer.apple.com/documentation/coreaudio/core-audio-enumerations>
- AVAudioEngine.inputNode: <https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode>
- AVAudioNode.installTap: <https://developer.apple.com/documentation/avfaudio/avaudionode/installtap>
- AVAudioPCMBuffer: <https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer>
- AVAudioFormat: <https://developer.apple.com/documentation/avfaudio/avaudioformat>
- AVAudioConverter: <https://developer.apple.com/documentation/avfaudio/avaudioconverter>
- Requesting authorization for media capture on macOS: <https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos>
- Protected resources: <https://developer.apple.com/documentation/bundleresources/protected-resources>
- AVAudioApplication.requestRecordPermission: <https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29>
- App Sandbox: <https://developer.apple.com/documentation/Security/app-sandbox>
- Security entitlements: <https://developer.apple.com/documentation/bundleresources/security-entitlements>
- Hardened Runtime: <https://developer.apple.com/documentation/security/hardened-runtime>
- SwiftData top: <https://developer.apple.com/documentation/SwiftData>
- ModelContainer: <https://developer.apple.com/documentation/SwiftData/ModelContainer>
- ModelContainer init (1czix): <https://developer.apple.com/documentation/swiftdata/modelcontainer/init%28for%3Amigrationplan%3Aconfigurations%3A%29-1czix>
- ModelContext: <https://developer.apple.com/documentation/SwiftData/ModelContext>
- Preserving your app's model data across launches: <https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches>
- SwiftData concurrency support: <https://developer.apple.com/documentation/swiftdata/concurrencysupport>
- Syncing model data with CloudKit: <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>
- SwiftUI MenuBarExtra: <https://developer.apple.com/documentation/swiftui/menubarextra>
- SwiftUI Scenes: <https://developer.apple.com/documentation/SwiftUI/Scenes>
- Building and customizing the menu bar with SwiftUI: <https://developer.apple.com/documentation/SwiftUI/Building-and-customizing-the-menu-bar-with-SwiftUI>

### WWDC 2025

- Session 277 — Bring advanced speech-to-text to your app with SpeechAnalyzer: <https://developer.apple.com/videos/play/wwdc2025/277/>
- Session 286 — Meet the Foundation Models framework: <https://developer.apple.com/videos/play/wwdc2025/286/>
- Session 301 — Deep dive into the Foundation Models framework: <https://developer.apple.com/videos/play/wwdc2025/301/>
- Session 360 — Discover machine learning & AI frameworks on Apple platforms: <https://developer.apple.com/videos/play/wwdc2025/360/>

### サンプル / コミュニティ

- `insidegui/AudioCap` (Core Audio process tap サンプル, Apple エンジニア発): <https://github.com/insidegui/AudioCap>
- `rudrankriyam/foundation-models-framework-example` (Foundation Models 実例集): <https://github.com/rudrankriyam/foundation-models-framework-example>
- `FluidInference/swift-scribe` (SpeechAnalyzer + Foundation Models フル実装サンプル): <https://github.com/FluidInference/swift-scribe>

---

## 未確定事項まとめ

以下は公式ドキュメントから断定できなかった項目。実機検証必須:

1. **SpeechAnalyzer の正確な必要サンプルレート / ビット深度**
   → `bestAvailableAudioFormat(compatibleWith:)` の戻り値を実機で確認すること。
2. **`SpeechTranscriber.ResultAttributeOption` の個別 case 名 (audioTimeRange 等の正式 case 名)**
   → SDK ヘッダ確認推奨。
3. **2 つの SpeechAnalyzer 同時実行時の追加メモリ量・CPU/ANE 配分**
   → 公式は「engine/model を共有する」と言うのみ。実測値は未公開。
4. **Foundation Models のコールドスタート所要時間・常駐メモリ量**
   → 公式 4,096 tokens 制限以外は未公開。
5. **Core Audio Process Tap の TCC サービス定数名**
   → ドキュメント上は `NSAudioCaptureUsageDescription` プロンプトとしか書かれない。
   `kTCCServiceScreenCapture` は不正確 (画面収録用)。実体は「System Audio Recording」専用の
   別 TCC サービス。正式名は未確定。
6. **macOS 26 における `@Environment(\.openSettings)` の挙動**
   → SwiftUI のバージョン依存。実機確認推奨。
7. **CATapDescription の Swift 公式シグネチャ (initStereoMixdown 系)**
   → Objective-C ヘッダから読めるが、Apple Developer Documentation Web 上の Swift 表記は限定的。
   実装時は `<CoreAudio/CATapDescription.h>` を参照。
