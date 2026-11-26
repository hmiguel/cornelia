import AppKit
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case all, favorites, recents
    case group(String)
}

struct GroupInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
}

@Observable
final class AppModel {
    let player = MPVPlayer()

    var channels: [Channel] = [] { didSet { rebuildIndex() } }
    var groups: [GroupInfo] = []
    var sidebar: SidebarItem = .all { didSet { refilter() } }
    var search = "" { didSet { refilter() } }
    var filtered: [Channel] = []
    var selectedChannelID: Int?

    var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? []) {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites"); if sidebar == .favorites { refilter() } }
    }
    var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? [] {
        didSet { UserDefaults.standard.set(recents, forKey: "recents"); if sidebar == .recents { refilter() } }
    }

    var source: String? = UserDefaults.standard.string(forKey: "source")
    var isLoading = false
    var loadError: String?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var showInfo = false
    var showOpenURL = false
    var toast: String?

    @ObservationIgnored private var byURL: [String: Channel] = [:]
    @ObservationIgnored private var previousChannelURL: String?
    var isVideoFullscreen = false
    @ObservationIgnored private var fullscreenWindow: NSWindow?
    @ObservationIgnored private weak var mainWindow: NSWindow?
    @ObservationIgnored private var toastWork: DispatchWorkItem?

    private static func cacheURL(for source: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cornelia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var h: UInt64 = 0xcbf29ce484222325
        for b in source.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(String(format: "playlist-%016llx.m3u", h))
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpAdditionalHeaders = ["User-Agent": MPVPlayer.defaultUserAgent]
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    init() {
        if debugEnabled {
            DistributedNotificationCenter.default().addObserver(forName: .init("cornelia.debug.fullscreen"), object: nil, queue: .main) { [weak self] _ in
                self?.toggleFullscreen()
            }
        }
        if let source { Task { await load(source: source, useCache: true) } }
    }

    // MARK: Loading

    func open(source newSource: String) {
        let trimmed = newSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        source = trimmed
        UserDefaults.standard.set(trimmed, forKey: "source")
        Task { await load(source: trimmed, useCache: false) }
    }

    func reload() {
        guard let source else { return }
        Task { await load(source: source, useCache: false) }
    }

    @MainActor
    func load(source: String, useCache: Bool) async {
        debugLog("load start")
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let cacheURL = Self.cacheURL(for: source)
        var cachedText: String?
        if useCache, let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
            cachedText = text
            await apply(text)
        }

        do {
            let text = try await fetch(source)
            if text != cachedText {
                try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
                await apply(text)
            }
            if channels.isEmpty { loadError = "No channels found in playlist" }
        } catch {
            if channels.isEmpty { loadError = error.localizedDescription }
        }
    }

    private func fetch(_ source: String) async throws -> String {
        if source.hasPrefix("http://") || source.hasPrefix("https://"), let url = URL(string: source) {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await Self.session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "Cornelia", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"])
            }
            return String(decoding: data, as: UTF8.self)
        }
        let path = source.hasPrefix("file://") ? (URL(string: source)?.path ?? source) : (source as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private func apply(_ text: String) async {
        let parsed = await Task.detached(priority: .userInitiated) { M3UParser.parse(text) }.value
        let selectedURL = selectedChannelID.flatMap { id in channels.indices.contains(id) ? channels[id].url : nil }
        selectedChannelID = nil
        channels = parsed
        debugLog("applied \(parsed.count) channels, \(groups.count) groups")
        // Restore selection after the list has reloaded.
        DispatchQueue.main.async { [self] in
            var target = selectedURL.flatMap { byURL[$0]?.id }
            if target == nil, player.nowPlaying == nil,
               let last = UserDefaults.standard.string(forKey: "lastChannel") {
                target = byURL[last]?.id
            }
            if let target { selectedChannelID = target }
        }
    }

    // MARK: Indexing and filtering

    private func rebuildIndex() {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var map: [String: Channel] = [:]
        map.reserveCapacity(channels.count)
        for c in channels {
            if counts[c.group] == nil { order.append(c.group) }
            counts[c.group, default: 0] += 1
            if map[c.url] == nil { map[c.url] = c }
        }
        byURL = map
        groups = order.map { GroupInfo(name: $0, count: counts[$0]!) }
        if case .group(let g) = sidebar, counts[g] == nil { sidebar = .all } else { refilter() }
    }

    private func refilter() {
        var base: [Channel]
        switch sidebar {
        case .all: base = channels
        case .group(let g): base = channels.filter { $0.group == g }
        case .favorites: base = channels.filter { favorites.contains($0.url) }
        case .recents: base = recents.compactMap { byURL[$0] }
        }
        let q = M3UParser.searchKey(search.trimmingCharacters(in: .whitespaces))
        if !q.isEmpty {
            let terms = q.split(separator: " ").map(String.init)
            base = base.filter { c in terms.allSatisfy { M3UParser.fastContains(c.searchKey, $0) } }
        }
        filtered = base
    }

    // MARK: Playback

    func channelSelected(_ id: Int?) {
        guard let id, channels.indices.contains(id) else { return }
        let ch = channels[id]
        if player.nowPlaying?.url == ch.url && player.errorMessage == nil { return }
        if let cur = player.nowPlaying?.url, cur != ch.url { previousChannelURL = cur }
        player.play(ch)
        UserDefaults.standard.set(ch.url, forKey: "lastChannel")
        showToast(ch.name)
        DispatchQueue.main.async { [self] in
            var r = recents.filter { $0 != ch.url }
            r.insert(ch.url, at: 0)
            recents = Array(r.prefix(50))
        }
    }

    func step(_ delta: Int) {
        let list = filtered.isEmpty ? channels : filtered
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selectedChannelID } ?? (delta > 0 ? -1 : list.count)
        let next = (idx + delta + list.count) % list.count
        selectedChannelID = list[next].id
    }

    func jumpBack() {
        guard let prev = previousChannelURL, let ch = byURL[prev] else { return }
        selectedChannelID = ch.id
    }

    func playFirstResult() {
        if let first = filtered.first { selectedChannelID = first.id }
    }

    func toggleFavorite(_ ch: Channel? = nil) {
        guard let ch = ch ?? player.nowPlaying else { return }
        if favorites.contains(ch.url) { favorites.remove(ch.url) } else { favorites.insert(ch.url) }
    }

    func isFavorite(_ ch: Channel) -> Bool { favorites.contains(ch.url) }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: Window

    func toggleFullscreen() {
        isVideoFullscreen ? exitVideoFullscreen() : enterVideoFullscreen()
    }

    /// Video-only fullscreen: a borderless window covering the screen, no sidebars or toolbar.
    func enterVideoFullscreen() {
        guard fullscreenWindow == nil else { return }
        let main = NSApp.windows.first { !($0 is FullscreenWindow) && $0.isVisible && $0.canBecomeMain }
        mainWindow = main
        guard let screen = main?.screen ?? NSScreen.main else { return }

        isVideoFullscreen = true
        let window = FullscreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentView = NSHostingView(rootView: PlayerStage(fullscreen: true).environment(self).ignoresSafeArea())
        fullscreenWindow = window

        if main?.styleMask.contains(.fullScreen) != true {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        if let video = window.contentView { window.makeFirstResponder(video) }
    }

    func exitVideoFullscreen() {
        guard let window = fullscreenWindow else { return }
        NSApp.presentationOptions = []
        isVideoFullscreen = false   // main window's surface re-adopts the video view
        DispatchQueue.main.async { [self] in
            window.orderOut(nil)
            window.contentView = nil
            fullscreenWindow = nil
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Keyboard

    /// Returns nil when the key was handled.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return event }
        let responder = event.window?.firstResponder
        if responder is NSText { return event }
        let inList = responder is NSTableView

        switch event.keyCode {
        case 49: player.togglePause(); return nil                     // space
        case 53:                                                       // escape
            if isVideoFullscreen { exitVideoFullscreen(); return nil }
            if event.window?.styleMask.contains(.fullScreen) == true { event.window?.toggleFullScreen(nil); return nil }
            return event
        case 123: player.setVolume(player.volume - 5); showToast("Volume \(Int(player.volume))"); return nil
        case 124: player.setVolume(player.volume + 5); showToast("Volume \(Int(player.volume))"); return nil
        case 125: if inList { return event }; step(1); return nil      // down
        case 126: if inList { return event }; step(-1); return nil     // up
        case 51: jumpBack(); return nil                                // delete
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullscreen(); return nil
        case "m": player.toggleMute(); return nil
        case "i": showInfo.toggle(); return nil
        case "s": toggleFavorite(); if let c = player.nowPlaying { showToast(isFavorite(c) ? "Added to favorites" : "Removed from favorites") }; return nil
        case "r": player.retry(); return nil
        default: return event
        }
    }
}
