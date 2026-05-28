import Foundation
import Testing
@testable import AppUI
import Contracts

/// `ActionItemsBlock.markdownLine(_:)` の整形ロジック検証。
@Suite("ActionItemsBlock.markdownLine")
struct ActionItemsBlockMarkdownLineTests {

    @Test("両方あり: title / 担当 / 期限 が ' / ' 区切りで並ぶ")
    func bothAssigneeAndDue() {
        let due = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let item = ActionItem(title: "予算案を作る", assignee: "田中", dueDate: due)
        let line = ActionItemsBlock.markdownLine(item)
        #expect(line.contains("予算案を作る"))
        #expect(line.contains("担当: 田中"))
        #expect(line.contains("期限:"))
        // ' / ' で 3 つに分割される
        let parts = line.components(separatedBy: " / ")
        #expect(parts.count == 3)
    }

    @Test("assignee のみ: 担当部だけ追加され期限は無い")
    func assigneeOnly() {
        let item = ActionItem(title: "資料準備", assignee: "山田", dueDate: nil)
        let line = ActionItemsBlock.markdownLine(item)
        #expect(line.contains("資料準備"))
        #expect(line.contains("担当: 山田"))
        #expect(line.contains("期限:") == false)
        let parts = line.components(separatedBy: " / ")
        #expect(parts.count == 2)
    }

    @Test("dueDate のみ: 期限部だけ追加され担当は無い")
    func dueOnly() {
        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ActionItem(title: "レビュー", assignee: nil, dueDate: due)
        let line = ActionItemsBlock.markdownLine(item)
        #expect(line.contains("レビュー"))
        #expect(line.contains("担当:") == false)
        #expect(line.contains("期限:"))
        let parts = line.components(separatedBy: " / ")
        #expect(parts.count == 2)
    }

    @Test("両方 nil: title のみ")
    func neitherAssigneeNorDue() {
        let item = ActionItem(title: "次回テーマを決める", assignee: nil, dueDate: nil)
        let line = ActionItemsBlock.markdownLine(item)
        #expect(line == "次回テーマを決める")
    }

    @Test("空の assignee は無視される (担当文を出さない)")
    func emptyAssigneeIsSkipped() {
        let item = ActionItem(title: "案件", assignee: "", dueDate: nil)
        let line = ActionItemsBlock.markdownLine(item)
        #expect(line == "案件")
    }
}
