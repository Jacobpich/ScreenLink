import SwiftUI

@main
struct ScreenLinkApp: App {
    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(HostStore.shared)
                .tint(Color("AccentColor"))
        }
    }
}

enum SessionPresenter {
    @MainActor
    static func present(_ host: SavedHost, password: String) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = RemoteViewController(host: host, password: password)
        top.present(vc, animated: true)
    }
}
