import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet { if let model, let url = pendingOpen { pendingOpen = nil; model.open(source: url.path) } }
    }
    private var pendingOpen: URL?
    private var keyMonitor: Any?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { model.open(source: url.path) } else { pendingOpen = url }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.model?.handleKey(event) ?? event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.player.shutdown()
    }
}

@main
struct CorneliaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Must run before AppModel reads its stored settings.
        LegacyMigration.run()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Cornelia", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Playlist File…") { openPlaylistFile(model) }.keyboardShortcut("o")
                Button("Open Playlist URL…") { model.showOpenURL = true }.keyboardShortcut("l")
                Button("Reload Playlist") { model.reload() }.keyboardShortcut("r")
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { model.player.togglePause() }.keyboardShortcut("p")
                Button("Next Channel") { model.step(1) }.keyboardShortcut(.downArrow)
                Button("Previous Channel") { model.step(-1) }.keyboardShortcut(.upArrow)
                Button("Last Watched Channel") { model.jumpBack() }.keyboardShortcut(.delete)
                Divider()
                Button("Mute") { model.player.toggleMute() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Volume Up") { model.player.setVolume(model.player.volume + 5) }.keyboardShortcut(.rightArrow)
                Button("Volume Down") { model.player.setVolume(model.player.volume - 5) }.keyboardShortcut(.leftArrow)
                Divider()
                Button("Toggle Favorite") { model.toggleFavorite() }.keyboardShortcut("d")
                Button("Stream Info") { model.showInfo.toggle() }.keyboardShortcut("i")
                Button("Retry Stream") { model.player.retry() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop") { model.player.stop() }.keyboardShortcut(".")
            }
        }
    }
}

/// One-time import of settings from earlier names of the app (IPTV, then ZipZip).
enum LegacyMigration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacy") else { return }
        defaults.set(true, forKey: "migratedLegacy")
        // Newest first, so the most recent settings win.
        for domain in ["local.zipzip.player", "local.iptv.player"] {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for key in ["source", "favorites", "recents", "lastChannel", "volume"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = base.appendingPathComponent("Cornelia")
        for name in ["ZipZip", "IPTV"] {
            let oldDir = base.appendingPathComponent(name)
            if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
                try? fm.moveItem(at: oldDir, to: newDir)
            }
        }
    }
}
