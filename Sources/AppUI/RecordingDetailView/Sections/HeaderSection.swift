import SwiftUI
import Contracts

extension RecordingDetailView {
    // MARK: - Header

    @ViewBuilder
    func header(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                // タイトル本体: 通常時はテキスト + ペンアイコン、編集中は TextField。
                // @State をこの extension の中に持てないため、`RecordingDetailView` の
                // `isEditingTitle` / `draftTitle` を参照する。
                TitleEditableView(
                    viewModel: viewModel,
                    recording: recording,
                    isEditing: $isEditingTitle,
                    draft: $draftTitle
                )
                Spacer()
                Button {
                    FinderReveal.openRecordingFolder(for: recording)
                } label: {
                    Label("Finder で開く", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("録音ファイルが入っているフォルダを Finder で開きます")
                .accessibilityLabel("Finder で録音フォルダを開く")
            }
            HStack(spacing: Theme.Spacing.md) {
                Label {
                    Text(AppFormatters.dateTime.string(from: recording.startedAt))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "calendar")
                }
                Label {
                    Text(AppFormatters.duration(recording.duration))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        // リスト側から「リネーム…」が選ばれたら、対応する録音 ID と
        // 詳細ビューの recording が一致するときだけ編集モードに入る。
        .onChange(of: viewModel.requestRenameRecordingID) { _, newValue in
            guard let newValue, newValue == recording.id else { return }
            draftTitle = recording.title
            isEditingTitle = true
            // 連打しても再起動しないよう即座にクリア
            viewModel.requestRenameRecordingID = nil
        }
    }
}

/// タイトル表示 + インライン編集の共通ビュー。
///
/// 表示モードではタイトルテキストとペンアイコン (ダブルクリックでも編集モード)。
/// 編集モードでは `TextField` を出し、Enter で保存 / Esc で破棄する。
private struct TitleEditableView: View {
    @Bindable var viewModel: AppViewModel
    let recording: Recording
    @Binding var isEditing: Bool
    @Binding var draft: String
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if isEditing {
            TextField("タイトル", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
                .accessibilityLabel("タイトルを編集")
                .onAppear {
                    // 表示直後にフォーカスを当てる (キーボード操作で即入力できるように)
                    fieldFocused = true
                }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(recording.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // ダブルクリックでも編集モードに入れる (HIG: rename と同じ操作感)
                    .onTapGesture(count: 2) { beginEditing() }
                Button {
                    beginEditing()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("タイトルを編集")
                .accessibilityLabel("タイトルを編集")
            }
        }
    }

    private func beginEditing() {
        draft = recording.title
        isEditing = true
    }

    private func commit() {
        let snapshot = draft
        // 編集モードを先に閉じてから永続化処理を投げる (UI の戻りが速い)
        isEditing = false
        // 空白 / 同タイトルは AppViewModel 側で no-op になるが、UI からは破棄扱い
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await viewModel.renameRecording(recording, newTitle: snapshot) }
    }

    private func cancel() {
        isEditing = false
    }
}
