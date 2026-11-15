// swift-tools-version:5.9
// ScreenLink for Mac: controls a Windows PC (ScreenLink Receiver) or another Mac from this Mac.
// Shares the protocol code with the iPhone app. Build the .app with Mac/build.sh.
import PackageDescription

let package = Package(
    name: "ScreenLinkMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenLinkMac",
            path: ".",
            exclude: ["build", "Receiver", "Tools", "Downloads", "ScreenLink.xcodeproj", "Info.plist", "README.md",
                      "ScreenLink/App", "ScreenLink/Views", "ScreenLink/Assets.xcassets",
                      "ScreenLink/Models/TailscaleAPI.swift", "ScreenLink/Session/DisplayDetector.swift",
                      "ScreenLink/Session/KeyboardViews.swift", "ScreenLink/Session/RemoteViewController.swift",
                      "ScreenLink/Session/SessionOverlay.swift", "Mac/build.sh", "Mac/Info.plist"],
            sources: [
                "Mac/Sources",
                "ScreenLink/VNC",
                "ScreenLink/Models/ConnLog.swift",
                "ScreenLink/Models/HostStore.swift",
                "ScreenLink/Session/ScreenRenderer.swift",
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
    ]
)
