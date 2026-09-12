import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyViewIMECommitTests: XCTestCase {
    func test_shift_commit_outside_keyDown_reaches_terminal_immediately() throws {
        let view = LibghosttyView(frame: .zero)
        let surface = IMESurfaceSpy()
        view.bind(surfaceController: surface)
        let range = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("nihao", selectedRange: NSRange(location: 0, length: 5), replacementRange: range)
        let shift = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56
        ))
        NSApp.postEvent(shift, atStart: true)
        _ = NSApp.nextEvent(matching: .flagsChanged, until: Date(), inMode: .default, dequeue: true)
        XCTAssertEqual(NSApp.currentEvent?.type, .flagsChanged)

        view.insertText("你好", replacementRange: range)

        XCTAssertEqual(surface.sentText, ["你好"])
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(surface.preeditUpdates, ["nihao", ""])
        view.insertText(NSAttributedString(string: "a"), replacementRange: range)
        XCTAssertEqual(surface.sentText, ["你好", "a"])
    }
}

private final class IMESurfaceSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    var imeRectValue: CGRect?
    private(set) var preeditUpdates: [String] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func setOcclusionVisible(_ isVisible: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool { false }
    var sentText: [String] = []
    func sendText(_ text: String) { sentText.append(text) }
    func setPreedit(_ text: String) {
        preeditUpdates.append(text)
    }
    func imeRect() -> CGRect? { imeRectValue }
    func submitReturn() {}
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}
