import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalClipboardTests: XCTestCase {
    func test_image_upload_content_rejects_oversized_raw_image_data() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data(count: TerminalClipboardImagePolicy.maxImageByteCount + 1), forType: .png)

        switch TerminalClipboard.imageUploadContent(from: pasteboard) {
        case .imageTooLarge:
            break
        case let content:
            XCTFail("Expected imageTooLarge, got \(content)")
        }
    }

    func test_file_urls_returns_file_urls_for_any_file_type_in_drop_order() {
        let pasteboard = makeTestPasteboard()
        let pdfURL = URL(fileURLWithPath: "/tmp/Quarterly Report.pdf")
        let movieURL = URL(fileURLWithPath: "/tmp/demo.mov")
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([pdfURL as NSURL, movieURL as NSURL])

        XCTAssertEqual(TerminalClipboard.fileURLs(from: pasteboard), [pdfURL, movieURL])
    }

    func test_pasted_string_returns_plain_text() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("echo hello world", forType: .string)

        XCTAssertEqual(TerminalClipboard.pastedString(from: pasteboard), "echo hello world")
    }

    func test_pasted_string_ignores_file_urls() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/screenshot.png") as NSURL])

        XCTAssertNil(TerminalClipboard.pastedString(from: pasteboard))
    }

    func test_pasted_string_ignores_file_urls_even_when_string_representation_exists() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL, .string], owner: nil)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/screenshot.png") as NSURL])
        pasteboard.setString("/tmp/screenshot.png", forType: .string)

        XCTAssertNil(TerminalClipboard.pastedString(from: pasteboard))
    }

    func test_pasted_string_ignores_non_text_types() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.png], owner: nil)

        XCTAssertNil(TerminalClipboard.pastedString(from: pasteboard))
    }

    func test_markdown_copy_replaces_rich_formats_and_preserves_links() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.string, .html, .rtf], owner: nil)
        pasteboard.setString("# Resources\n\nRead [the docs](https://example.com/docs)\nfor details.", forType: .string)
        pasteboard.setString("<p>Read the docs</p>", forType: .html)
        pasteboard.setData(Data("rich text".utf8), forType: .rtf)

        XCTAssertEqual(TerminalClipboard.reformatMarkdown(in: pasteboard), true)

        XCTAssertEqual(pasteboard.string(forType: .string),
                       "# Resources\n\nRead [the docs](https://example.com/docs) for details.")
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    func test_markdown_copy_clears_html_even_when_markdown_is_unchanged() {
        let pasteboard = makeTestPasteboard()
        let text = "# Resources\n\n[Docs](https://example.com/docs)"
        pasteboard.declareTypes([.string, .html], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("<h1>Resources</h1><p>Docs</p>", forType: .html)

        XCTAssertEqual(TerminalClipboard.reformatMarkdown(in: pasteboard), true)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    func test_markdown_copy_preserves_link_only_selection_as_plain_text() {
        let pasteboard = makeTestPasteboard()
        let text = "[Docs](https://example.com/docs)"
        pasteboard.declareTypes([.string, .html], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("<p>Docs</p>", forType: .html)

        XCTAssertEqual(TerminalClipboard.reformatMarkdown(in: pasteboard), false)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    func test_markdown_copy_leaves_non_text_clipboard_untouched() {
        let pasteboard = makeTestPasteboard()
        let data = Data([1, 2, 3])
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(data, forType: .png)
        let changeCount = pasteboard.changeCount

        XCTAssertNil(TerminalClipboard.reformatMarkdown(in: pasteboard))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
    }

    private func makeTestPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }
}
