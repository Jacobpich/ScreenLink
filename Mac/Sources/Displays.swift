import AppKit
import SwiftUI
import Combine

/// What the menu bar's Displays menu shows: the displays of the session window in front.
final class DisplayMenuModel: ObservableObject {
    static let shared = DisplayMenuModel()

    struct Item: Hashable { let index: Int; let title: String }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selected: Int?
    @Published private(set) var manual = false
    @Published private(set) var manualLayout: [Int]?
    @Published private(set) var hasSession = false
    private(set) weak var session: SessionController?

    func update(from s: SessionController?) {
        session = s
        hasSession = s != nil
        items = s.map { s in s.displays.indices.map { Item(index: $0, title: SessionController.displayTitle($0, s.displays[$0])) } } ?? []
        selected = s?.selectedDisplay
        manual = s?.displayLayoutIsManual ?? false
        manualLayout = s?.manualLayout
    }
}

extension SessionController {
    static func displayTitle(_ i: Int, _ r: CGRect) -> String {
        "Display \(i + 1)  ·  \(Int(r.width))×\(Int(r.height))"
    }
}

/// Menu bar: Displays (same choices as the iPhone's Displays button).
struct DisplaysMenuContent: View {
    @ObservedObject var model = DisplayMenuModel.shared

    private func pick(_ i: Int?) { model.session?.selectDisplay(i) }

    var body: some View {
        Toggle("All Displays", isOn: Binding(get: { model.hasSession && model.selected == nil }, set: { _ in pick(nil) }))
            .keyboardShortcut("0", modifiers: [.command, .option, .control])
            .disabled(!model.hasSession)
        ForEach(model.items, id: \.self) { item in
            Toggle(item.title, isOn: Binding(get: { model.selected == item.index }, set: { _ in pick(item.index) }))
                .keyboardShortcut(item.index < 9 ? KeyEquivalent(Character("\(item.index + 1)")) : "x",
                                  modifiers: item.index < 9 ? [.command, .option, .control] : [])
        }
        if model.hasSession && model.items.isEmpty {
            Text("Only one display found")
        }
        Divider()
        Button("Next Display") { model.session?.stepDisplay(1) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .control])
            .disabled(model.items.count < 2)
        Button("Previous Display") { model.session?.stepDisplay(-1) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .control])
            .disabled(model.items.count < 2)
        Divider()
        Toggle("Detect Displays Automatically", isOn: Binding(get: { model.hasSession && !model.manual },
                                                              set: { _ in model.session?.redetectDisplays() }))
            .disabled(!model.hasSession)
        Menu("Set Layout Manually") {
            ForEach(SessionController.manualLayouts, id: \.title) { l in
                Toggle(l.title, isOn: Binding(get: { model.manualLayout == [l.columns, l.rows] },
                                              set: { _ in model.session?.setManualLayout(columns: l.columns, rows: l.rows) }))
            }
        }
        .disabled(!model.hasSession)
    }
}

extension SessionController {
    static let manualLayouts: [(title: String, columns: Int, rows: Int)] = [
        ("2 Side by Side", 2, 1), ("3 Side by Side", 3, 1), ("2 Stacked", 1, 2),
    ]
}

// MARK: - Session window toolbar: a Displays button like the iPhone's

private let displaysItemID = NSToolbarItem.Identifier("displays")

extension SessionController: NSToolbarDelegate, NSMenuDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, displaysItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, displaysItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == displaysItemID else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Displays")
        item.label = "Displays"
        item.toolTip = "Show one display or all of them"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.showsIndicator = true
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cmdOptCtrl: NSEvent.ModifierFlags = [.command, .option, .control]
        func add(_ title: String, on: Bool = false, key: String = "", enabled: Bool = true,
                 _ action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            item.state = on ? .on : .off
            item.isEnabled = enabled
            if !key.isEmpty { item.keyEquivalent = key; item.keyEquivalentModifierMask = cmdOptCtrl }
            menu.addItem(item)
            return item
        }
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: displays.count > 1 ? "Show" : "Only one display found"))
        _ = add("All Displays", on: selectedDisplay == nil, key: "0") { [weak self] in self?.selectDisplay(nil) }
        for i in displays.indices {
            _ = add(Self.displayTitle(i, displays[i]), on: selectedDisplay == i, key: i < 9 ? "\(i + 1)" : "") { [weak self] in
                self?.selectDisplay(i)
            }
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Layout"))
        _ = add("Detect Displays Automatically", on: !displayLayoutIsManual) { [weak self] in self?.redetectDisplays() }
        let sub = NSMenu()
        sub.autoenablesItems = false
        for l in Self.manualLayouts {
            let item = ClosureMenuItem(title: l.title) { [weak self] in self?.setManualLayout(columns: l.columns, rows: l.rows) }
            item.state = manualLayout == [l.columns, l.rows] ? .on : .off
            sub.addItem(item)
        }
        let manualItem = NSMenuItem(title: "Set Layout Manually", action: nil, keyEquivalent: "")
        manualItem.submenu = sub
        menu.addItem(manualItem)
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// A short message over the picture ("Display 2", "Found 3 displays"), like the iPhone's flash.
final class FlashLabel: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func flash(_ text: String) {
        label.stringValue = text
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}
