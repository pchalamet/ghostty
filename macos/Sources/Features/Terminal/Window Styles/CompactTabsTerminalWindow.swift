import AppKit
import Darwin
import QuartzCore
import SwiftUI

/// A compact titlebar backed by the same window groups as native tabs.
final class CompactTabsTerminalWindow: TransparentTitlebarTerminalWindow {
    private let tabs = CompactTabStripModel()
    private var tabRefreshTimer: Timer?
    private var tabStrip: CompactTabHostingView?
    private var stripLeading: NSLayoutConstraint?
    private let titlebarDivider = CompactTitlebarDivider()
    private let contentDimmer = CompactContentDimmer()

    private var trafficLights: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { standardWindowButton($0) }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    override var supportsUpdateAccessory: Bool { false }

    deinit {
        tabRefreshTimer?.invalidate()
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        tabbingIdentifier = "GhosttyCompactTabs"
        titleVisibility = .hidden
        // Use the unified toolbar height for the tab row and its vertical insets.
        toolbar = NSToolbar(identifier: "CompactTabToolbar")
        toolbarStyle = .unifiedCompact
        titlebarSeparatorStyle = .none

        let strip = CompactTabHostingView(rootView: CompactTabStrip(
            model: tabs,
            select: { [weak self] in
                guard let self, let target = self.tabWindow(numbered: $0), target !== self else { return }
                self.handOffSelectionHighlight()
                target.makeKeyAndOrderFront(nil)
            },
            add: { [weak self] in self?.terminalController?.newTab(nil) },
            showPalette: { [weak self] in self?.terminalController?.toggleCommandPalette(nil) },
            close: { [weak self] in
                (self?.tabWindow(numbered: $0)?.windowController as? TerminalController)?.closeTab(nil)
            },
            rename: { [weak self] in
                (self?.tabWindow(numbered: $0)?.windowController as? TerminalController)?.promptTabTitle()
            },
            detach: { [weak self] in self?.tabWindow(numbered: $0)?.moveTabToNewWindow(nil) },
            move: { [weak self] in self?.moveTab(numbered: $0, to: $1) ?? false }
        ))
        strip.sizingOptions = []
        strip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip = strip

        // Foreground jobs can change without emitting terminal output or a title.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTabs() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        tabRefreshTimer = timer
    }

    override func update() {
        super.update()
        hideNativeTabBar()
        installTabStrip()
        installContentOverlays()
    }

    override func becomeMain() {
        // Populate the incoming strip before AppKit displays this tab. The
        // destination window may still report itself as hidden at this point.
        refreshTabs(activating: true)
        super.becomeMain()
        hideNativeTabBar()
        installTabStrip()
        installContentOverlays()
    }

    override func becomeKey() {
        showActiveAppearance()
        refreshTabs(activating: true)
        super.becomeKey()
    }

    override func close() {
        let group = tabGroup
        handOffSelectionHighlight()
        super.close()
        (group?.selectedWindow as? CompactTabsTerminalWindow)?.refreshTabs()
    }

    private func showActiveAppearance() {
        if !tabs.isWindowActive { tabs.isWindowActive = true }
        contentDimmer.isHidden = true
    }

    override func resignKey() {
        handOffSelectionHighlight()
        super.resignKey()
        // A tab switch resigns the outgoing window just before replacing it.
        // Only dim after AppKit settles, if this window is still on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow, self.isVisible,
                  (self.tabGroup?.selectedWindow ?? self) === self else { return }
            self.tabs.isWindowActive = false
            self.contentDimmer.isHidden = false
        }
    }

    private func handOffSelectionHighlight() {
        guard isKeyWindow, let group = tabGroup,
              let index = tabs.entries.firstIndex(where: \.selected) else { return }
        let origin = CompactTabStripModel.HighlightOrigin(
            index: index,
            count: tabs.entries.count,
            timestamp: CACurrentMediaTime()
        )
        for case let sibling as CompactTabsTerminalWindow in group.windows where sibling !== self {
            sibling.tabs.prepareHighlight(from: origin)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 1,
           let titlebarView, let tabStrip, !tabStrip.isHidden,
           titlebarView.bounds.contains(titlebarView.convert(event.locationInWindow, from: nil)),
           !tabStrip.containsControl(at: tabStrip.convert(event.locationInWindow, from: nil)),
           !trafficLights.contains(where: {
               $0.window === titlebarView.window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
           }),
           !titlebarAccessoryViewControllers.contains(where: {
               !$0.isHidden && !isTabBar($0) && $0.view.window === titlebarView.window &&
                   $0.view.bounds.contains($0.view.convert(event.locationInWindow, from: nil))
           }) {
            // The drag path consumes the mouse-down that normally activates
            // the window. Keep the group's selected tab when restoring focus.
            let selectedWindow = tabGroup?.selectedWindow as? CompactTabsTerminalWindow ?? self
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !selectedWindow.isKeyWindow { selectedWindow.makeKeyAndOrderFront(nil) }
            selectedWindow.showActiveAppearance()
            selectedWindow.performDrag(with: event)
            DispatchQueue.main.async { [weak selectedWindow] in
                guard let selectedWindow, selectedWindow.isKeyWindow,
                      selectedWindow.attachedSheet == nil,
                      let controller = selectedWindow.terminalController,
                      !controller.commandPaletteIsShowing else { return }
                let surface = controller.focusedSurface ?? controller.surfaceTree.max { lhs, rhs in
                    guard let rhsFocus = rhs.focusInstant else { return false }
                    guard let lhsFocus = lhs.focusInstant else { return true }
                    return lhsFocus < rhsFocus
                }
                guard let surface, surface.window === selectedWindow,
                      selectedWindow.makeFirstResponder(surface) else { return }
                // AppKit can keep the same first responder across deactivation,
                // so makeFirstResponder need not call becomeFirstResponder again.
                // Reconcile the controller and renderer even in that case.
                if controller.focusedSurface !== surface {
                    controller.focusedSurfaceDidChange(to: surface)
                } else {
                    controller.syncFocusToSurfaceTree()
                }
            }
            return
        }
        super.sendEvent(event)
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        let nativeTabBar = isTabBar(childViewController)
        if nativeTabBar {
            childViewController.isHidden = !(tabGroup?.isOverviewVisible ?? false)
        }
        super.addTitlebarAccessoryViewController(childViewController)
        if nativeTabBar {
            hideNativeTabBar()
            DispatchQueue.main.async { [weak self] in
                self?.hideNativeTabBar()
                self?.installTabStrip()
                self?.refreshTabs()
            }
        }
    }

    private func hideNativeTabBar() {
        // AppKit can move the bar from the previous tab into an accessory that
        // was installed earlier, without calling addTitlebarAccessoryViewController again.
        let hidden = !(tabGroup?.isOverviewVisible ?? false)
        let nativeBar = tabBarView
        for accessory in titlebarAccessoryViewControllers {
            guard isTabBar(accessory) || nativeBar?.isDescendant(of: accessory.view) == true else { continue }
            if accessory.isHidden != hidden { accessory.isHidden = hidden }
        }
        if let nativeBar, nativeBar.isHidden != hidden { nativeBar.isHidden = hidden }
    }

    private func installTabStrip() {
        guard styleMask.contains(.titled), let titlebarView, let tabStrip else { return }
        if tabStrip.superview !== titlebarView {
            tabStrip.removeFromSuperview()
            titlebarView.addSubview(tabStrip)
            let leading = tabStrip.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor)
            stripLeading = leading
            NSLayoutConstraint.activate([
                leading,
                tabStrip.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor, constant: -10),
                tabStrip.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor),
                tabStrip.heightAnchor.constraint(equalToConstant: CompactTabStrip.height),
            ])
        }

        let trafficLightsRight = trafficLights
            .filter { $0.window === titlebarView.window }
            .map { $0.convert($0.bounds, to: titlebarView).maxX }
            .max() ?? 0
        let leading = trafficLightsRight + 12
        if let stripLeading, stripLeading.constant != leading { stripLeading.constant = leading }
        let hidden = tabGroup?.isOverviewVisible ?? false
        if tabStrip.isHidden != hidden { tabStrip.isHidden = hidden }
    }

    private func installContentOverlays() {
        guard let contentView else { return }
        if titlebarDivider.superview !== contentView {
            titlebarDivider.removeFromSuperview()
            titlebarDivider.wantsLayer = true
            titlebarDivider.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(titlebarDivider, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                titlebarDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                titlebarDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                titlebarDivider.topAnchor.constraint(equalTo: contentView.topAnchor),
                titlebarDivider.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        if contentDimmer.superview !== contentView {
            contentDimmer.removeFromSuperview()
            contentDimmer.wantsLayer = true
            contentDimmer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
            contentDimmer.isHidden = tabs.isWindowActive
            contentDimmer.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(contentDimmer, positioned: .below, relativeTo: titlebarDivider)
            NSLayoutConstraint.activate([
                contentDimmer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                contentDimmer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                contentDimmer.topAnchor.constraint(equalTo: contentView.topAnchor),
                contentDimmer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        let hidden = !styleMask.contains(.titled) || styleMask.contains(.fullScreen) ||
            (tabGroup?.isOverviewVisible ?? false)
        if titlebarDivider.isHidden != hidden { titlebarDivider.isHidden = hidden }
        titlebarDivider.updateColor()
    }

    private func tabWindow(numbered number: Int) -> NSWindow? {
        (tabGroup?.windows ?? [self]).first { $0.windowNumber == number }
    }

    private func moveTab(numbered source: Int, to destination: Int) -> Bool {
        guard let group = tabGroup else { return false }
        let windows = group.windows
        guard let fromIndex = windows.firstIndex(where: { $0.windowNumber == source }),
              let toIndex = windows.firstIndex(where: { $0.windowNumber == destination }),
              fromIndex != toIndex else { return false }

        let draggedWindow = windows[fromIndex]
        let targetWindow = windows[toIndex]
        let selectedWindow = group.selectedWindow
        group.removeWindow(draggedWindow)
        let moved = targetWindow.addTabbedWindowSafely(draggedWindow, ordered: fromIndex < toIndex ? .above : .below)
        if !moved, let neighbor = windows[safe: fromIndex + 1] ?? windows[safe: fromIndex - 1] {
            neighbor.addTabbedWindowSafely(draggedWindow, ordered: fromIndex + 1 < windows.count ? .below : .above)
        }
        selectedWindow?.makeKeyAndOrderFront(nil)
        terminalController?.relabelTabs()
        refreshTabs()
        return moved
    }

    private func refreshTabs(activating: Bool = false) {
        guard activating || (isVisible && !isMiniaturized && (tabGroup?.selectedWindow ?? self) === self) else { return }
        let windows = tabGroup?.windows ?? [self]
        let entries = windows.map { window in
            let controller = window.windowController as? TerminalController
            let surface = controller?.focusedSurface ?? controller?.surfaceTree.max { lhs, rhs in
                guard let rhsFocus = rhs.focusInstant else { return false }
                guard let lhsFocus = lhs.focusInstant else { return true }
                return lhsFocus < rhsFocus
            }
            let pid = surface?.surfaceModel?.foregroundPID.flatMap { pid_t(exactly: $0) }
            let executable = pid.flatMap(Self.executablePath)
            let command = executable.map { ($0 as NSString).lastPathComponent }
            let application = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            let hasCustomTitle = controller?.titleOverride != nil || (window as? TerminalWindow)?.derivedConfig.title != nil
            let title = hasCustomTitle ? window.title : command ?? window.title
            let path = surface?.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
            return CompactTabStripModel.Entry(
                id: window.windowNumber,
                title: title,
                path: path == title ? nil : path,
                symbol: Self.symbol(for: command),
                applicationPath: application?.bundleURL?.path,
                color: (window as? TerminalWindow)?.tabColor.displayColor,
                selected: window === self
            )
        }
        if entries != tabs.entries {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                tabs.entries = entries
            }
        }
    }

    private static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return path.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap(String.init(validatingUTF8:))
        }
    }

    private static func symbol(for command: String?) -> String {
        switch command {
        case "vim", "nvim", "vi", "nano", "emacs": return "pencil"
        case "ssh", "mosh", "sftp": return "network"
        case "git", "hg", "jj": return "arrow.triangle.branch"
        case "docker", "podman", "kubectl": return "shippingbox"
        case "claude", "codex", "gemini": return "sparkles"
        case "bash", "zsh", "fish", "sh", "dash", "ksh", "nu", "pwsh", nil: return "terminal"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

private final class CompactContentDimmer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CompactTitlebarDivider: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Match the rendered RGB values of the Rex divider in the dark titlebar.
            let color = isDark
                ? NSColor(srgbRed: 59.0 / 255, green: 61.0 / 255, blue: 74.0 / 255, alpha: 1)
                : NSColor.labelColor.withAlphaComponent(0.12)
            layer?.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }
}

private final class CompactTabHostingView: NonDraggableHostingView<CompactTabStrip> {
    func containsControl(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let available = CompactTabStrip.availableTabWidth(in: bounds.width)
        let occupied = CompactTabStrip.occupiedTabWidth(available, count: rootView.model.entries.count)
        return point.x < occupied || point.x >= bounds.width - CompactTabStrip.controlsWidth
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsControl(at: convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

private final class CompactTabStripModel: ObservableObject {
    struct HighlightOrigin {
        let index: Int
        let count: Int
        let timestamp: CFTimeInterval
    }

    struct Entry: Equatable, Identifiable {
        let id: Int
        let title: String
        let path: String?
        let symbol: String
        let applicationPath: String?
        let color: NSColor?
        let selected: Bool
    }

    @Published var entries: [Entry] = []
    @Published var isWindowActive = false
    var highlightOrigin: HighlightOrigin?
    weak var highlightView: CompactSelectionHighlight.HighlightView?

    func prepareHighlight(from origin: HighlightOrigin) {
        highlightOrigin = origin
        highlightView?.stage(origin)
    }
}

private struct CompactTabStrip: View {
    static let height: CGFloat = 30
    static let buttonWidth: CGFloat = 27
    static let buttonSpacing: CGFloat = 4
    static let controlsWidth = buttonWidth * 2 + buttonSpacing

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTabID: Int?
    @ObservedObject var model: CompactTabStripModel
    let select: (Int) -> Void
    let add: () -> Void
    let showPalette: () -> Void
    let close: (Int) -> Void
    let rename: (Int) -> Void
    let detach: (Int) -> Void
    let move: (Int, Int) -> Bool

    private var selectedIndex: Int? { model.entries.firstIndex(where: \.selected) }
    private var selectedID: Int? { selectedIndex.map { model.entries[$0].id } }

    private var selectedFill: Color {
        if !model.isWindowActive { return subtleTabFill }
        if colorScheme == .dark {
            return Color(red: 0.32, green: 0.34, blue: 0.42)
        }
        return Color(red: 0.82, green: 0.85, blue: 0.90)
    }

    private var subtleTabFill: Color {
        colorScheme == .dark
            ? Color(red: 56.0 / 255, green: 60.0 / 255, blue: 74.0 / 255)
            : Color(red: 0.90, green: 0.91, blue: 0.94)
    }

    static func availableTabWidth(in width: CGFloat) -> CGFloat {
        max(0, width - controlsWidth - 12)
    }

    static func occupiedTabWidth(_ available: CGFloat, count: Int) -> CGFloat {
        min(available, tabWidth(available, count: count) * CGFloat(count))
    }

    fileprivate static func tabWidth(_ available: CGFloat, count: Int) -> CGFloat {
        min(240, max(126, floor(available / CGFloat(max(1, count)))))
    }

    var body: some View {
        GeometryReader { geometry in
            let available = Self.availableTabWidth(in: geometry.size.width)
            let width = Self.tabWidth(available, count: model.entries.count)
            let overflows = width * CGFloat(model.entries.count) > available
            HStack(spacing: 0) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(model.entries) { entry in
                                tab(entry)
                                    .frame(width: width)
                                    .id(entry.id)
                            }
                        }
                        .frame(minWidth: available, alignment: .leading)
                        .background(alignment: .leading) {
                            if let selectedIndex {
                                CompactSelectionHighlight(
                                    model: model,
                                    index: selectedIndex,
                                    available: available,
                                    fill: NSColor(selectedFill),
                                    stroke: model.isWindowActive ? NSColor(Color.primary.opacity(0.11)) : .clear,
                                    reduceMotion: reduceMotion
                                )
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                    }
                    .onAppear {
                        if overflows, let selectedID { scroll.scrollTo(selectedID) }
                    }
                    .onChange(of: selectedID) { next in
                        if overflows, let next { scroll.scrollTo(next) }
                    }
                }
                .frame(width: available)
                .frame(height: Self.height)

                Spacer(minLength: 0)

                HStack(spacing: Self.buttonSpacing) {
                    titlebarButton("Command Palette", symbol: "command", action: showPalette)
                    titlebarButton("New Tab", symbol: "plus", action: add)
                }
            }
        }
        .accessibilityIdentifier("CompactTabStrip")
        .frame(height: Self.height)
    }

    private func titlebarButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: Self.buttonWidth, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }

    private func tab(_ entry: CompactTabStripModel.Entry) -> some View {
        let isHovered = model.isWindowActive && hoveredTabID == entry.id
        return tabSelectionButton(entry, isHovered: isHovered)
            .overlay(alignment: .trailing) {
                if isHovered {
                    Button {
                        close(entry.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 3)
                    .accessibilityLabel("Close Tab")
                    .accessibilityIdentifier("CompactTabClose")
                    .help("Close Tab")
                }
            }
            .onHover { hovering in
                if hovering {
                    hoveredTabID = entry.id
                } else if hoveredTabID == entry.id {
                    hoveredTabID = nil
                }
            }
    }

    private func tabSelectionButton(_ entry: CompactTabStripModel.Entry, isHovered: Bool) -> some View {
        let isHighlighted = entry.selected || isHovered
        let fill = isHovered ? subtleTabFill : Color.primary.opacity(0.05)
        return Button {
            select(entry.id)
        } label: {
            HStack(spacing: 6) {
                icon(entry)
                    .frame(width: 20, height: 16)
                    .accessibilityHidden(true)

                HStack(spacing: 4) {
                    Text(entry.title)
                        .tracking(-0.12)
                        .foregroundStyle(isHighlighted ? .primary : .secondary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let path = entry.path {
                        Text(path)
                            .tracking(-0.12)
                            .foregroundStyle(.primary.opacity(isHighlighted ? 0.62 : 0.48))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .regular))
            .padding(.leading, 9)
            .padding(.trailing, isHovered ? 29 : 9)
            .frame(height: 28)
            .background {
                if !entry.selected {
                    Capsule().fill(fill).padding(.horizontal, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .accessibilityAddTraits(entry.selected ? .isSelected : [])
        .accessibilityIdentifier(entry.selected ? "CompactTabSelected" : "CompactTab")
        .help([entry.title, entry.path].compactMap { $0 }.joined(separator: " "))
        .draggable("ghostty-tab:\(entry.id)")
        .dropDestination(for: String.self) { items, _ in
            let prefix = "ghostty-tab:"
            guard let item = items.first, item.hasPrefix(prefix),
                  let source = Int(item.dropFirst(prefix.count)) else { return false }
            return move(source, entry.id)
        }
        .contextMenu {
            Button("Rename Tab…") { rename(entry.id) }
            if model.entries.count > 1 {
                Button("Move Tab to New Window") { detach(entry.id) }
            }
            Button("Close Tab") { close(entry.id) }
        }
    }

    @ViewBuilder
    private func icon(_ entry: CompactTabStripModel.Entry) -> some View {
        if let applicationPath = entry.applicationPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: applicationPath))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: entry.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entry.color.map(Color.init(nsColor:)) ?? Color.green.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.linearGradient(
                            colors: [Color(white: 0.29), Color(white: 0.13)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.18))
                }
        }
    }
}

/// One highlight layer per window. AppKit swaps windows when selecting tabs,
/// so the incoming layer starts at the outgoing tab's slot.
private struct CompactSelectionHighlight: NSViewRepresentable {
    let model: CompactTabStripModel
    let index: Int
    let available: CGFloat
    let fill: NSColor
    let stroke: NSColor
    let reduceMotion: Bool

    func makeNSView(context: Context) -> HighlightView {
        let view = HighlightView()
        view.wantsLayer = true
        view.layer?.addSublayer(view.pill)
        model.highlightView = view
        return view
    }

    func updateNSView(_ view: HighlightView, context: Context) {
        view.available = available
        view.reduceMotion = reduceMotion
        let destination = view.frame(index: index, count: model.entries.count)
        let origin = model.highlightOrigin.flatMap {
            CACurrentMediaTime() - $0.timestamp < 0.5 ? $0 : nil
        }
        if model.isWindowActive || origin == nil { model.highlightOrigin = nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.pill.backgroundColor = fill.cgColor
        view.pill.borderColor = stroke.cgColor

        guard !reduceMotion, let origin else {
            view.pill.frame = destination
            if reduceMotion || !model.isWindowActive {
                view.pill.removeAnimation(forKey: "tabSelection")
            }
            return
        }
        let start = view.frame(index: origin.index, count: origin.count)
        // SwiftUI can update the incoming strip before AppKit makes it key.
        // Hold the outgoing position through those updates.
        guard model.isWindowActive else {
            view.pill.frame = start
            return
        }
        view.pill.frame = destination
        guard start != destination else { return }

        let duration: CFTimeInterval = 0.22
        let position = CABasicAnimation(keyPath: "position.x")
        position.duration = duration
        position.fromValue = start.midX
        position.toValue = destination.midX
        let width = CABasicAnimation(keyPath: "bounds.size.width")
        width.duration = duration
        width.fromValue = start.width
        width.toValue = destination.width

        let animation = CAAnimationGroup()
        animation.animations = [position, width]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .backwards
        view.pill.add(animation, forKey: "tabSelection")
    }

    final class HighlightView: NSView {
        let pill = CALayer()
        var available: CGFloat = 0
        var reduceMotion = false

        // An existing hidden window may be displayed with its previous layer
        // before SwiftUI updates it. Seed that layer before the handoff.
        func stage(_ origin: CompactTabStripModel.HighlightOrigin) {
            guard !reduceMotion else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.removeAnimation(forKey: "tabSelection")
            pill.frame = frame(index: origin.index, count: origin.count)
            CATransaction.commit()
        }

        func frame(index: Int, count: Int) -> CGRect {
            let width = CompactTabStrip.tabWidth(available, count: count)
            return CGRect(x: CGFloat(index) * width + 1, y: 1, width: width - 2, height: 28)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            pill.cornerRadius = 14
            pill.borderWidth = 1
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
