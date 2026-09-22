import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

/// macOS 26 ships a system "Show contextual menu" key equivalent on Control+Return.
/// AppKit offers it to `performKeyEquivalent` before `keyDown`; if the terminal view
/// does not claim it, AppKit pops the view's context menu and the terminal never sees
/// the key. TUIs (Claude Code, for one) bind Ctrl+Enter, so the view must claim it.
@MainActor
final class LibghosttyViewKeyEquivalentTests: AppKitTestCase {
    private var view: LibghosttyView!
    private var surface: KeySurfaceSpy!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        view = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface = KeySurfaceSpy()
        view.bind(surfaceController: surface)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        window.contentView?.addSubview(view)
    }

    override func tearDown() {
        window.close()
        window = nil
        view = nil
        surface = nil
        super.tearDown()
    }

    func test_control_return_key_equivalent_is_sent_to_terminal_not_context_menu() throws {
        XCTAssertTrue(window.makeFirstResponder(view))
        var menuRequested = false
        view.contextMenuBuilder = { _, menu in
            menuRequested = true
            return menu
        }

        let handled = view.performKeyEquivalent(with: try makeKeyEvent(keyCode: 36, modifierFlags: .control))

        XCTAssertTrue(handled)
        XCTAssertEqual(surface.sentKeyCodes, [36])
        XCTAssertFalse(menuRequested)
    }

    func test_control_keypad_enter_key_equivalent_is_sent_to_terminal() throws {
        XCTAssertTrue(window.makeFirstResponder(view))

        let handled = view.performKeyEquivalent(with: try makeKeyEvent(keyCode: 76, modifierFlags: .control))

        XCTAssertTrue(handled)
        XCTAssertEqual(surface.sentKeyCodes, [76])
    }

    func test_control_return_is_not_claimed_when_view_is_not_first_responder() throws {
        let handled = view.performKeyEquivalent(with: try makeKeyEvent(keyCode: 36, modifierFlags: .control))

        XCTAssertFalse(handled)
        XCTAssertEqual(surface.sentKeyCodes, [])
    }

    func test_command_return_and_plain_return_are_left_to_appkit() throws {
        XCTAssertTrue(window.makeFirstResponder(view))

        XCTAssertFalse(view.performKeyEquivalent(with: try makeKeyEvent(keyCode: 36, modifierFlags: [.control, .command])))
        XCTAssertFalse(view.performKeyEquivalent(with: try makeKeyEvent(keyCode: 36, modifierFlags: [])))
        XCTAssertEqual(surface.sentKeyCodes, [])
    }

    private func makeKeyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 1,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}

private final class KeySurfaceSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var sentKeyCodes: [UInt16] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func setOcclusionVisible(_ isVisible: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool {
        sentKeyCodes.append(event.keyCode)
        return true
    }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool { false }
    func sendText(_ text: String) {}
    func setPreedit(_ text: String) {}
    func imeRect() -> CGRect? { nil }
    func submitReturn() {}
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}
