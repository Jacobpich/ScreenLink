import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultInputMode") private var defaultInputMode = InputMode.trackpad.rawValue
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.0
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("invertScroll") private var invertScroll = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("syncClipboard") private var syncClipboard = true
    @AppStorage("autoKeyboard") private var autoKeyboard = true
    @AppStorage("showStats") private var showStats = false
    @AppStorage("classicMacModifiers") private var classicMacModifiers = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default mode", selection: $defaultInputMode) {
                        ForEach(InputMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    VStack(alignment: .leading) {
                        Text("Pointer speed")
                        Slider(value: $pointerSpeed, in: 0.4...2.5) {
                            Text("Pointer speed")
                        } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    }
                    VStack(alignment: .leading) {
                        Text("Scroll speed")
                        Slider(value: $scrollSpeed, in: 0.3...4) {
                            Text("Scroll speed")
                        } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    }
                    Toggle("Reverse scroll direction", isOn: $invertScroll)
                    Toggle("Haptic feedback", isOn: $haptics)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Scrolling follows your Mac's own settings: direction comes from Natural scrolling, and the Mac's Mouse → Scrolling speed applies too. Only turn on Reverse if it still feels backwards.")
                }

                Section {
                    Toggle("Show keyboard in text fields", isOn: $autoKeyboard)
                } footer: {
                    Text("Brings up the keyboard when you click where the Mac shows a text cursor (I-beam). Clicking selectable text on a web page can bring it up too.")
                }

                Section {
                    Toggle("Copy Mac clipboard to iPhone", isOn: $syncClipboard)
                } footer: {
                    Text("When you copy text on the Mac, it's placed on this iPhone's clipboard. To send text the other way, use the ⌘ menu → Paste iPhone Clipboard on Mac.")
                }

                Section {
                    Picker("⌘ and ⌥ keys", selection: $classicMacModifiers) {
                        Text("Current macOS (default)").tag(false)
                        Text("Older macOS").tag(true)
                    }
                    Toggle("Show connection stats", isOn: $showStats)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("If ⌘C or ⌘A acts like Option on your Mac (types ç or å), switch ⌘ and ⌥ keys to the other choice.")
                }

                Section("Point & click") {
                    gesture("Move pointer", "One finger (trackpad mode)")
                    gesture("Click", "Tap")
                    gesture("Right-click", "Two-finger tap")
                    gesture("Drag", "Touch and hold, then move")
                    gesture("Look Up", "Three-finger tap")
                }
                Section("Scroll & zoom") {
                    gesture("Scroll", "Two-finger swipe (with momentum)")
                    gesture("Zoom the iPhone view", "Pinch")
                    gesture("Pan when zoomed", "Pointer edges (or one finger in touch mode)")
                }
                Section {
                    gesture("Mission Control", "Three-finger swipe up")
                    gesture("App Exposé", "Three-finger swipe down")
                    gesture("Switch Spaces / full-screen apps", "Three-finger swipe left/right")
                    gesture("Notification Center", "Swipe in from the right edge")
                    gesture("Show Desktop", "Spread four fingers")
                    gesture("Apps", "Pinch four fingers")
                    gesture("Switch displays", "Four-finger swipe left/right")
                    gesture("Keyboard", "Four-finger tap")
                } header: {
                    Text("More gestures")
                } footer: {
                    Text("These match the Mac's default trackpad gestures. If you've changed the Mission Control shortcuts on your Mac, the swipes follow those keyboard shortcuts.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func gesture(_ name: String, _ how: String) -> some View {
        LabeledContent(name) { Text(how).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}
