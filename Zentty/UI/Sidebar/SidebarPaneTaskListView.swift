import AppKit

/// Quote-style list of an agent pane's task items, rendered under the pane
/// status line once the task progress indicator is clicked (or always shown
/// via `AppConfig.AgentLists`). The left rule borrows the progress ring's
/// color so the list reads as belonging to that indicator.
///
///     │ □ Review directory
///     │ ◐ Identify main language
///     │ ■ Suggest one improvement
@MainActor
final class SidebarPaneTaskListView: NSView {
    private enum Layout {
        static let ruleWidth: CGFloat = 2
        static let ruleSpacing: CGFloat = 8
        static let glyphSpacing: CGFloat = 5
        static let maximumRowCount = 12
        static let ruleAlpha: CGFloat = 0.6
    }

    private struct RowContent: Equatable {
        let symbolName: String?
        let title: String
        let status: PaneAgentTaskItemStatus?
    }

    private struct LineViews {
        let glyph: NSImageView
        let title: SidebarStaticLabel
    }

    private let ruleView = NSView()
    private var lines: [LineViews] = []
    private var rows: [RowContent] = []
    private var primaryColor: NSColor = .labelColor
    private var secondaryColor: NSColor = .secondaryLabelColor
    private var ruleColor: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated static func displayedRowCount(forItemCount count: Int) -> Int {
        min(max(0, count), Layout.maximumRowCount)
    }

    nonisolated static func height(forItemCount count: Int) -> CGFloat {
        CGFloat(displayedRowCount(forItemCount: count)) * ShellMetrics.sidebarDetailLineHeight
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(forItemCount: rows.count))
    }

    override func layout() {
        super.layout()
        layoutLines()
    }

    var lineTextsForTesting: [(glyph: String, title: String)] {
        rows.map { ($0.symbolName ?? "", $0.title) }
    }

    var ruleColorForTesting: NSColor {
        ruleColor.withAlphaComponent(Layout.ruleAlpha)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        ruleView.wantsLayer = true
        ruleView.layer?.cornerRadius = Layout.ruleWidth / 2
        addSubview(ruleView)
        isHidden = true
    }

    func configure(items: [PaneAgentTaskItem]?) {
        let items = items ?? []
        rows = Self.rowContents(for: items)
        ensureCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            let line = lines[index]
            line.title.stringValue = row.title
            line.glyph.image = row.symbolName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(
                        .init(pointSize: Self.glyphPointSize, weight: .regular)
                    )
            }
            line.title.font = row.status == .inProgress
                ? Self.inProgressFont
                : Self.detailFont
            line.glyph.isHidden = row.symbolName == nil
            line.title.isHidden = false
        }
        for line in lines.dropFirst(rows.count) {
            line.glyph.isHidden = true
            line.title.isHidden = true
        }
        isHidden = rows.isEmpty
        let doneCount = items.filter { $0.status == .done }.count
        setAccessibilityLabel(rows.isEmpty ? "" : "Tasks, \(doneCount) of \(items.count) done")
        applyColors()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyColors(primary: NSColor, secondary: NSColor, ruleColor: NSColor) {
        primaryColor = primary
        secondaryColor = secondary
        self.ruleColor = ruleColor
        applyColors()
    }

    private func applyColors() {
        ruleView.layer?.backgroundColor = ruleColor.withAlphaComponent(Layout.ruleAlpha).cgColor
        for (index, line) in lines.enumerated() {
            let status = rows.indices.contains(index) ? rows[index].status : nil
            let color = status == .pending || status == .inProgress ? primaryColor : secondaryColor
            line.glyph.contentTintColor = color
            line.title.textColor = color
        }
    }

    private static func rowContents(for items: [PaneAgentTaskItem]) -> [RowContent] {
        if items.count <= Layout.maximumRowCount {
            return items.map {
                RowContent(symbolName: symbolName(for: $0.status), title: $0.title, status: $0.status)
            }
        }

        let shown = items.prefix(Layout.maximumRowCount - 1).map {
            RowContent(symbolName: symbolName(for: $0.status), title: $0.title, status: $0.status)
        }
        return shown + [
            RowContent(
                symbolName: nil,
                title: "… +\(items.count - shown.count) more",
                status: nil
            ),
        ]
    }

    private static func symbolName(for status: PaneAgentTaskItemStatus) -> String {
        switch status {
        case .pending: "square"
        case .inProgress: "square.lefthalf.filled"
        case .done: "square.fill"
        }
    }

    private static var detailFont: NSFont { ShellMetrics.sidebarDetailFont() }
    private static var inProgressFont: NSFont {
        .monospacedSystemFont(ofSize: detailFont.pointSize, weight: .medium)
    }
    private static var glyphPointSize: CGFloat { detailFont.capHeight }

    private func ensureCapacity(_ count: Int) {
        while lines.count < count {
            let glyph = NSImageView()
            glyph.translatesAutoresizingMaskIntoConstraints = true
            glyph.imageScaling = .scaleProportionallyDown
            addSubview(glyph)

            let title = SidebarStaticLabel()
            title.font = Self.detailFont
            title.maximumNumberOfLines = 1
            title.cell?.usesSingleLineMode = true
            title.cell?.wraps = false
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = true
            addSubview(title)

            lines.append(LineViews(glyph: glyph, title: title))
        }
    }

    private func layoutLines() {
        let lineHeight = ShellMetrics.sidebarDetailLineHeight
        ruleView.frame = NSRect(x: 0, y: 1, width: Layout.ruleWidth, height: max(0, bounds.height - 2))
        let leading = Layout.ruleWidth + Layout.ruleSpacing
        let glyphSide = ceil(Self.glyphPointSize)

        for (index, line) in lines.prefix(rows.count).enumerated() {
            // Flipped coordinates are not used here: first item sits at the top.
            let y = bounds.height - lineHeight * CGFloat(index + 1)
            var x = leading
            if rows[index].symbolName != nil {
                line.glyph.frame = NSRect(
                    x: x,
                    y: y + (lineHeight - glyphSide) / 2,
                    width: glyphSide,
                    height: glyphSide
                )
                x += glyphSide + Layout.glyphSpacing
            }
            line.title.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x), height: lineHeight)
        }
    }
}
