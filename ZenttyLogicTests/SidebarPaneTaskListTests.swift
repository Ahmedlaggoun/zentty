import AppKit
import XCTest

@testable import Zentty

@MainActor
final class SidebarPaneTaskListTests: AppKitTestCase {
    private var rowWidthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]

    private let paneID = PaneID("worklane-main-agent")

    private var threeTasks: PaneAgentTaskProgress {
        PaneAgentTaskProgress(items: [
            PaneAgentTaskItem(title: "Review directory", status: .done),
            PaneAgentTaskItem(title: "Identify main language", status: .inProgress),
            PaneAgentTaskItem(title: "Suggest one improvement", status: .pending),
        ])!
    }

    // MARK: - SidebarPaneTaskListView

    func test_list_view_renders_one_row_per_item_in_order() throws {
        let list = SidebarPaneTaskListView()
        list.frame = NSRect(x: 0, y: 0, width: 220, height: 60)
        list.configure(items: threeTasks.items)
        list.layoutSubtreeIfNeeded()

        XCTAssertFalse(list.isHidden)
        XCTAssertEqual(
            list.lineTextsForTesting.map(\.title),
            ["Review directory", "Identify main language", "Suggest one improvement"]
        )
        XCTAssertEqual(
            list.lineTextsForTesting.map(\.glyph),
            ["square.fill", "square.lefthalf.filled", "square"]
        )
        XCTAssertEqual(
            list.intrinsicContentSize.height,
            SidebarPaneTaskListView.height(forItemCount: 3),
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarPaneTaskListView.height(forItemCount: 3),
            3 * ShellMetrics.sidebarDetailLineHeight,
            accuracy: 0.001
        )
    }

    func test_list_view_caps_at_twelve_rows_with_overflow_line() throws {
        let items = (1...15).map {
            PaneAgentTaskItem(title: "Task \($0)", status: $0 <= 5 ? .done : .pending)
        }
        let list = SidebarPaneTaskListView()
        list.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
        list.configure(items: items)
        list.layoutSubtreeIfNeeded()

        XCTAssertEqual(list.lineTextsForTesting.count, 12)
        XCTAssertEqual(list.lineTextsForTesting.last?.glyph, "")
        XCTAssertEqual(list.lineTextsForTesting.last?.title, "… +4 more")
        XCTAssertEqual(
            list.intrinsicContentSize.height,
            12 * ShellMetrics.sidebarDetailLineHeight,
            accuracy: 0.001
        )
    }

    func test_list_view_hides_for_empty_items() {
        let list = SidebarPaneTaskListView()
        list.configure(items: threeTasks.items)
        XCTAssertFalse(list.isHidden)
        list.configure(items: nil)
        XCTAssertTrue(list.isHidden)
        list.configure(items: [])
        XCTAssertTrue(list.isHidden)
    }

    func test_list_view_rule_uses_progress_ring_color() {
        let list = SidebarPaneTaskListView()
        list.configure(items: threeTasks.items)
        list.applyColors(
            primary: .labelColor,
            secondary: .secondaryLabelColor,
            ruleColor: NSColor(srgbRed: 0.1, green: 0.9, blue: 0.2, alpha: 1)
        )

        let resolved = list.ruleColorForTesting.usingColorSpace(.sRGB)
        XCTAssertEqual(resolved?.alphaComponent ?? 0, 0.6, accuracy: 0.01)
        XCTAssertEqual(resolved?.greenComponent ?? 0, 0.9, accuracy: 0.01)
    }

    // MARK: - Layout & presentation

    func test_layout_adds_task_list_row_only_for_toggled_item_bearing_panes() {
        let untoggled = SidebarWorklaneRowLayout(summary: makeSummary(taskProgress: threeTasks))
        XCTAssertFalse(untoggled.visibleTextRows.contains(.paneTaskList(0)))

        let toggled = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: threeTasks),
            toggledTaskListPaneIDs: [paneID]
        )
        XCTAssertTrue(toggled.visibleTextRows.contains(.paneTaskList(0)))
    }

    func test_layout_task_list_sits_above_subagent_list() {
        let subagents = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
        ])
        let layout = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: threeTasks, subagents: subagents),
            toggledSubagentPaneIDs: [paneID],
            toggledTaskListPaneIDs: [paneID]
        )
        let rows = layout.visibleTextRows
        let taskIndex = rows.firstIndex(of: .paneTaskList(0))
        let subagentIndex = rows.firstIndex(of: .paneSubagents(0))
        XCTAssertNotNil(taskIndex)
        XCTAssertNotNil(subagentIndex)
        if let taskIndex, let subagentIndex {
            XCTAssertLessThan(taskIndex, subagentIndex)
        }
    }

    func test_layout_never_shows_task_list_for_counts_only_progress() throws {
        let countsOnly = try XCTUnwrap(PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
        let layout = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: countsOnly),
            toggledTaskListPaneIDs: [paneID],
            agentLists: AppConfig.AgentLists(alwaysShowTaskLists: true, alwaysShowSubagentLists: false)
        )
        XCTAssertFalse(layout.visibleTextRows.contains(.paneTaskList(0)))
    }

    func test_always_show_task_lists_expands_without_toggle_and_toggle_collapses() {
        let alwaysShow = AppConfig.AgentLists(alwaysShowTaskLists: true, alwaysShowSubagentLists: false)

        let expanded = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: threeTasks),
            agentLists: alwaysShow
        )
        XCTAssertTrue(expanded.visibleTextRows.contains(.paneTaskList(0)))

        let collapsed = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: threeTasks),
            toggledTaskListPaneIDs: [paneID],
            agentLists: alwaysShow
        )
        XCTAssertFalse(collapsed.visibleTextRows.contains(.paneTaskList(0)))
    }

    func test_always_show_subagent_lists_flips_toggle_polarity() {
        let subagents = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
        ])
        let alwaysShow = AppConfig.AgentLists(alwaysShowTaskLists: false, alwaysShowSubagentLists: true)

        let expanded = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: nil, subagents: subagents),
            agentLists: alwaysShow
        )
        XCTAssertTrue(expanded.visibleTextRows.contains(.paneSubagents(0)))

        let collapsed = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: nil, subagents: subagents),
            toggledSubagentPaneIDs: [paneID],
            agentLists: alwaysShow
        )
        XCTAssertFalse(collapsed.visibleTextRows.contains(.paneSubagents(0)))
    }

    func test_task_list_contributes_rows_times_line_height_to_layout_height() {
        let collapsed = SidebarWorklaneRowLayout(summary: makeSummary(taskProgress: threeTasks))
        let expanded = SidebarWorklaneRowLayout(
            summary: makeSummary(taskProgress: threeTasks),
            toggledTaskListPaneIDs: [paneID]
        )
        XCTAssertEqual(
            expanded.rowHeight - collapsed.rowHeight,
            3 * ShellMetrics.sidebarDetailLineHeight + ShellMetrics.sidebarRowInterlineSpacing,
            accuracy: 0.001
        )
    }

    // MARK: - Row button & click target

    func test_ring_click_toggles_task_list_without_selecting_pane() throws {
        let row = makeRow()
        var selectedPaneIDs: [PaneID] = []
        row.onPaneSelected = { selectedPaneIDs.append($0) }
        row.configure(
            with: makeSummary(taskProgress: threeTasks),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()
        let collapsedHeight = row.intrinsicContentSize.height

        row.performDebugInteractionForTesting(.firstPaneTaskListClick)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(selectedPaneIDs, [])
        XCTAssertEqual(row.toggledTaskListPaneIDsForTesting, [paneID])
        XCTAssertEqual(
            row.debugSnapshotForTesting.paneTaskListTexts.map { $0.map(\.title) },
            [["Review directory", "Identify main language", "Suggest one improvement"]]
        )
        XCTAssertEqual(
            row.intrinsicContentSize.height,
            collapsedHeight + 3 * ShellMetrics.sidebarDetailLineHeight + ShellMetrics.sidebarRowInterlineSpacing,
            accuracy: 0.001
        )

        row.performDebugInteractionForTesting(.firstPaneTaskListClick)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.toggledTaskListPaneIDsForTesting, [])
        XCTAssertTrue(row.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))
        XCTAssertEqual(row.intrinsicContentSize.height, collapsedHeight, accuracy: 0.001)
    }

    func test_counts_only_progress_has_no_click_target_and_plain_tooltip() throws {
        let row = makeRow()
        var selectedPaneIDs: [PaneID] = []
        row.onPaneSelected = { selectedPaneIDs.append($0) }
        let countsOnly = try XCTUnwrap(PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
        row.configure(
            with: makeSummary(taskProgress: countsOnly),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        let statusRow = try XCTUnwrap(row.debugAccessForTesting.paneStatusRows.first)
        XCTAssertNil(statusRow.taskProgressFrame(in: row))
        XCTAssertEqual(statusRow.progressToolTipForTesting, "1/3 tasks")

        row.performDebugInteractionForTesting(.firstPaneTaskListClick)
        XCTAssertEqual(row.toggledTaskListPaneIDsForTesting, [])
    }

    func test_ring_tooltip_invites_click_when_items_exist() throws {
        let row = makeRow()
        row.configure(
            with: makeSummary(taskProgress: threeTasks),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        let statusRow = try XCTUnwrap(row.debugAccessForTesting.paneStatusRows.first)
        XCTAssertEqual(statusRow.progressToolTipForTesting, "1/3 tasks\nClick for details")
        XCTAssertNotNil(statusRow.taskProgressFrame(in: row))
    }

    func test_task_list_collapses_once_items_are_gone() throws {
        let row = makeRow()
        row.configure(
            with: makeSummary(taskProgress: threeTasks),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()
        row.performDebugInteractionForTesting(.firstPaneTaskListClick)
        XCTAssertEqual(row.toggledTaskListPaneIDsForTesting, [paneID])

        let countsOnly = try XCTUnwrap(PaneAgentTaskProgress(doneCount: 2, totalCount: 3))
        row.configure(
            with: makeSummary(taskProgress: countsOnly),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.toggledTaskListPaneIDsForTesting, [])
        XCTAssertTrue(row.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))
    }

    /// Flipping `agentLists` must re-render even when the sidebar summaries are
    /// identical — both `SidebarView.render` and `SidebarWorklaneRowButton.configure`
    /// guard on it, otherwise a Settings switch would only take effect on the
    /// next unrelated sidebar update.
    func test_agent_lists_change_re_renders_identical_summaries() throws {
        var agentLists = AppConfig.AgentLists.default
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebar.agentListsProvider = { agentLists }
        let summary = makeSummary(taskProgress: threeTasks)
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(summaries: [summary], theme: theme)
        sidebar.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(sidebar.debugAccessForTesting.worklaneButtons.first)
        XCTAssertTrue(button.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))

        agentLists = AppConfig.AgentLists(alwaysShowTaskLists: true, alwaysShowSubagentLists: false)
        sidebar.render(summaries: [summary], theme: theme)
        sidebar.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            button.debugSnapshotForTesting.paneTaskListTexts.map { $0.map(\.title) },
            [["Review directory", "Identify main language", "Suggest one improvement"]]
        )

        agentLists = AppConfig.AgentLists.default
        sidebar.render(summaries: [summary], theme: theme)
        sidebar.layoutSubtreeIfNeeded()

        XCTAssertTrue(button.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))
    }

    /// Toggled pane IDs invert meaning when an always-show flag flips
    /// (shown = alwaysShow != toggled), so the row resets the set for the
    /// changed flag: a list the user opened stays open when always-show turns
    /// on, still collapses on click, and does not spring back when always-show
    /// turns off again.
    func test_agent_lists_flag_change_resets_toggle_semantics() throws {
        var agentLists = AppConfig.AgentLists.default
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebar.agentListsProvider = { agentLists }
        let summary = makeSummary(taskProgress: threeTasks)
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(summaries: [summary], theme: theme)
        sidebar.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(sidebar.debugAccessForTesting.worklaneButtons.first)

        // Toggle the list open while always-show is off.
        button.performDebugInteractionForTesting(.firstPaneTaskListClick)
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.toggledTaskListPaneIDsForTesting, [paneID])
        XCTAssertFalse(button.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))

        // Enabling always-show keeps the list open instead of inverting it.
        agentLists = AppConfig.AgentLists(alwaysShowTaskLists: true, alwaysShowSubagentLists: false)
        sidebar.render(summaries: [summary], theme: theme)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.toggledTaskListPaneIDsForTesting, [])
        XCTAssertFalse(button.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))

        // A click still collapses the pane under always-show.
        button.performDebugInteractionForTesting(.firstPaneTaskListClick)
        button.layoutSubtreeIfNeeded()
        XCTAssertTrue(button.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))

        // Turning always-show back off hides the list rather than revealing it.
        agentLists = AppConfig.AgentLists.default
        sidebar.render(summaries: [summary], theme: theme)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.toggledTaskListPaneIDsForTesting, [])
        XCTAssertTrue(button.debugSnapshotForTesting.paneTaskListTexts.allSatisfy(\.isEmpty))
    }

    // MARK: - Visual evidence

    /// Renders the task list (done / in progress / pending) above a subagent
    /// list the way a pane row stacks them, in both appearances, for visual
    /// review of issue #99's sidebar detail.
    func test_render_task_list_for_visual_review() throws {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            let theme = ZenttyTheme.fallback(for: appearance)
            let container = opaqueContainer(width: 220, appearance: appearance, theme: theme)

            let taskList = SidebarPaneTaskListView()
            taskList.configure(items: threeTasks.items)
            taskList.applyColors(
                primary: .labelColor,
                secondary: .secondaryLabelColor,
                ruleColor: theme.statusRunning
            )
            let subagentList = SidebarPaneSubagentListView()
            subagentList.configure(
                summary: PaneAgentSubagentSummary(entries: [
                    PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
                    PaneAgentSubagentEntry(id: "b", agentType: "general-purpose", model: "claude-opus-5"),
                    PaneAgentSubagentEntry(id: "c", agentType: "codex-review", model: "claude-sonnet-5"),
                ])
            )
            subagentList.applyColors(primary: .labelColor, secondary: .secondaryLabelColor)

            let taskHeight = SidebarPaneTaskListView.height(forItemCount: threeTasks.items.count)
            let subagentHeight = SidebarPaneSubagentListView.height(forGroupCount: 2)
            container.frame.size.height = taskHeight + subagentHeight + 8
            taskList.frame = NSRect(
                x: 8,
                y: subagentHeight + 8,
                width: container.bounds.width - 16,
                height: taskHeight
            )
            subagentList.frame = NSRect(
                x: 8,
                y: 0,
                width: container.bounds.width - 16,
                height: subagentHeight
            )
            container.addSubview(taskList)
            container.addSubview(subagentList)

            try renderPNG(container, to: "/tmp/zentty-99-tasklist-\(name).png")
        }
    }

    /// Renders a full worklane pane row — primary line, status line with the
    /// task progress ring, expanded task list, then subagent list — on the
    /// sidebar background so the tinted rule under the ring is visible.
    func test_render_full_pane_row_for_visual_review() throws {
        let subagents = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "b", agentType: "codex-review", model: "claude-sonnet-5"),
        ])

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            let theme = ZenttyTheme.fallback(for: appearance)
            let container = opaqueContainer(width: 240, appearance: appearance, theme: theme)

            let row = SidebarWorklaneRowButton(
                worklaneID: WorklaneID("worklane-main"),
                reducedMotionProvider: { true }
            )
            row.agentListsProvider = {
                AppConfig.AgentLists(alwaysShowTaskLists: true, alwaysShowSubagentLists: true)
            }
            row.frame = NSRect(x: 4, y: 4, width: 232, height: 200)
            row.configure(
                with: makeSummary(taskProgress: threeTasks, subagents: subagents),
                theme: theme,
                animated: false
            )
            row.layoutSubtreeIfNeeded()
            let rowHeight = row.intrinsicContentSize.height
            row.frame.size.height = rowHeight
            container.frame.size.height = rowHeight + 8
            container.addSubview(row)
            container.layoutSubtreeIfNeeded()

            try renderPNG(container, to: "/tmp/zentty-99-taskrow-\(name).png")
        }
    }

    // MARK: - Helpers

    private func opaqueContainer(
        width: CGFloat,
        appearance: NSAppearance?,
        theme: ZenttyTheme
    ) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        container.appearance = appearance
        container.wantsLayer = true
        // sidebarBackground is a translucent glass tint — composite it over the
        // opaque window background so the PNG is readable on its own.
        container.layer?.backgroundColor =
            theme.sidebarBackground.composited(over: theme.windowBackground)
            .withAlphaComponent(1).cgColor
        return container
    }

    /// Always renders (so the offscreen path is exercised); only writes the PNG
    /// when `ZENTTY_VISUAL_REVIEW=1` so regular runs leave nothing in /tmp.
    private func renderPNG(_ view: NSView, to path: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        guard ProcessInfo.processInfo.environment["ZENTTY_VISUAL_REVIEW"] == "1" else { return }
        try png.write(to: URL(fileURLWithPath: path))
    }

    private func makeRow(width: CGFloat = 220, height: CGFloat = 90) -> SidebarWorklaneRowButton {
        let row = SidebarWorklaneRowButton(
            worklaneID: WorklaneID("worklane-main"),
            reducedMotionProvider: { true }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let widthConstraint = row.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        rowWidthConstraints[ObjectIdentifier(row)] = widthConstraint
        return row
    }

    private func makeSummary(
        taskProgress: PaneAgentTaskProgress?,
        subagents: PaneAgentSubagentSummary? = nil
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
            badgeText: "1",
            primaryText: "agent",
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: paneID,
                    primaryText: "1Password pane focus",
                    trailingText: nil,
                    detailText: "…/zentty",
                    statusText: "Running",
                    attentionState: .running,
                    isFocused: true,
                    isWorking: true,
                    taskProgress: taskProgress,
                    subagents: subagents
                ),
            ],
            isWorking: true,
            isActive: true
        )
    }
}
