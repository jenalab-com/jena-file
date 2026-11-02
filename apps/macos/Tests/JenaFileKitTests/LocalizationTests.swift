import XCTest
@testable import JenaFileKit

final class LocalizationTests: XCTestCase {
    override func tearDown() { Localization.useEnglish = false }

    /// Every L("…") in the app and kit sources has an English entry with the same
    /// number of %@ — a new Korean sentence without a translation fails here.
    func testEverySourceStringIsTranslated() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var found = 0
        for dir in ["JenaFile", "JenaFileKit"] {
            let files = try FileManager.default.contentsOfDirectory(atPath: sources.appendingPathComponent(dir).path)
            for file in files where file.hasSuffix(".swift") && file != "Localization.swift" {
                let text = try String(contentsOf: sources.appendingPathComponent(dir).appendingPathComponent(file), encoding: .utf8)
                for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let raw = String(text[Range(m.range(at: 1), in: text)!])
                    // Turn the Swift source escapes into the runtime string.
                    let key = raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
                    found += 1
                    guard let en = Localization.english[key] else {
                        XCTFail("\(file): no English for \"\(raw)\"")
                        continue
                    }
                    XCTAssertEqual(en.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count,
                                   "\(file): placeholders differ for \"\(raw)\"")
                }
            }
        }
        XCTAssertGreaterThan(found, 200)
    }

    func testPlaceholdersFillInOrderAndValuesAreNotReparsed() {
        Localization.useEnglish = false
        XCTAssertEqual(L("다운로드 %@개를 대기열에 넣었어요 → %@", "3", "/tmp/%@"), "다운로드 3개를 대기열에 넣었어요 → /tmp/%@")
        Localization.useEnglish = true
        XCTAssertEqual(L("다운로드 %@개를 대기열에 넣었어요 → %@", "3", "/tmp"), "Queued 3 download(s) → /tmp")
        XCTAssertEqual(L("없는 문장 %@", "x"), "없는 문장 x", "unknown keys fall back to Korean")
    }
}
