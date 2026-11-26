import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 320)
        } content: {
            ChannelListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            PlayerPane()
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search channels")
        .onSubmit(of: .search) { model.playFirstResult() }
        .toolbar {
            ToolbarItemGroup {
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Label("Reload Playlist", systemImage: "arrow.clockwise") }
                    .disabled(model.source == nil)
                    .help("Reload playlist")
            }
        }
        .sheet(isPresented: $model.showOpenURL) { OpenURLSheet() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.open(source: url.path) } }
            }
            return true
        }
        .frame(minWidth: 760, minHeight: 440)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section("Library") {
                row("All Channels", "tv", model.channels.count).tag(SidebarItem.all)
                row("Favorites", "star", model.favorites.count).tag(SidebarItem.favorites)
                row("Recent", "clock", model.recents.count).tag(SidebarItem.recents)
            }
            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups) { g in
                        row(g.name, "folder", g.count).tag(SidebarItem.group(g.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ icon: String, _ count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit().font(.caption)
            }
        } icon: { Image(systemName: icon) }
    }
}

struct ChannelListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.source == nil && model.channels.isEmpty {
                EmptyPlaylistView()
            } else if let err = model.loadError, model.channels.isEmpty {
                ContentUnavailableView {
                    Label("Could not load playlist", systemImage: "exclamationmark.triangle")
                } description: { Text(err) } actions: {
                    Button("Retry") { model.reload() }
                    Button("Open Another…") { model.showOpenURL = true }
                }
            } else if model.filtered.isEmpty && !model.isLoading {
                ContentUnavailableView.search(text: model.search)
            } else {
                List(model.filtered, selection: $model.selectedChannelID) { ch in
                    ChannelRow(channel: ch, isFavorite: model.isFavorite(ch),
                               isPlaying: model.player.nowPlaying?.url == ch.url)
                        .contextMenu {
                            Button(model.isFavorite(ch) ? "Remove from Favorites" : "Add to Favorites") {
                                model.toggleFavorite(ch)
                            }
                            Button("Copy Stream URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ch.url, forType: .string)
                            }
                        }
                }
                .listStyle(.inset)
                .onChange(of: model.selectedChannelID) { _, id in model.channelSelected(id) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(model.filtered.count) channels")
    }

    private var title: String {
        switch model.sidebar {
        case .all: "All Channels"
        case .favorites: "Favorites"
        case .recents: "Recent"
        case .group(let g): g
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let isFavorite: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            LogoView(url: channel.logo, name: channel.name)
            Text(channel.name).lineLimit(1)
            Spacer(minLength: 4)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
            }
            if isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            }
        }
        .padding(.vertical, 1)
    }
}

struct EmptyPlaylistView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No playlist", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Open an M3U file or paste a playlist URL. You can also drop a file here.")
        } actions: {
            Button("Open File…") { openPlaylistFile(model) }
            Button("Open URL…") { model.showOpenURL = true }
        }
    }
}

@MainActor
func openPlaylistFile(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .data, UTType(filenameExtension: "m3u8") ?? .data, .plainText]
    panel.allowsOtherFileTypes = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url { model.open(source: url.path) }
}

struct OpenURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Playlist URL").font(.headline)
            TextField("http://provider.example/get.php?…&type=m3u_plus", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 460)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Load", action: submit).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if let s = model.source, s.hasPrefix("http") { text = s }
            else if let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("http") { text = clip }
        }
    }

    private func submit() {
        model.open(source: text)
        dismiss()
    }
}

// MARK: Player

/// Video plus overlays. Used in the window and in video-only fullscreen.
struct PlayerStage: View {
    @Environment(AppModel.self) private var model
    let fullscreen: Bool

    var body: some View {
        let player = model.player
        ZStack {
            Color.black
            VideoSurface(player: player, active: fullscreen == model.isVideoFullscreen) { model.toggleFullscreen() }

            if player.nowPlaying == nil {
                VStack(spacing: 8) {
                    Image(systemName: "play.tv").font(.system(size: 40))
                    Text("Pick a channel").font(.title3)
                    Text("↑ ↓ zap  ·  space pause  ·  F fullscreen  ·  M mute  ·  S favorite  ·  ⌫ previous")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.5))
                .allowsHitTesting(false)
            } else if let err = player.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 32))
                    Text(err).multilineTextAlignment(.center)
                    Button("Retry") { player.retry() }
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(24)
            } else if player.isBuffering {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    if player.isReconnecting {
                        Text("Reconnecting…").font(.callout).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .allowsHitTesting(false)
            }

            VStack {
                HStack(alignment: .top) {
                    if let toast = model.toast {
                        Text(toast)
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                            .transition(.opacity)
                    }
                    Spacer()
                    if model.showInfo, player.nowPlaying != nil { InfoPanel(player: player) }
                }
                Spacer()
                if player.isMuted || player.isPaused {
                    HStack(spacing: 12) {
                        if player.isPaused { Image(systemName: "pause.fill") }
                        if player.isMuted { Image(systemName: "speaker.slash.fill") }
                    }
                    .font(.title2)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.white)
                }
            }
            .padding(16)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: model.toast)
        }
    }
}

struct PlayerPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        PlayerStage(fullscreen: false)
        .navigationTitle(player.nowPlaying?.name ?? "Cornelia")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let ch = player.nowPlaying {
                    Button { model.toggleFavorite(ch) } label: {
                        Label("Favorite", systemImage: model.isFavorite(ch) ? "star.fill" : "star")
                    }
                    .help("Toggle favorite (S)")
                }
                Button { player.toggleMute() } label: {
                    Label("Mute", systemImage: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...130)
                    .frame(width: 90)
                    .help("Volume (← →)")
            }
        }
    }
}

struct InfoPanel: View {
    let player: MPVPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if player.videoWidth > 0 { Text("\(player.videoWidth)×\(player.videoHeight)") }
            if !player.videoCodec.isEmpty { Text(player.videoCodec) }
            Text("hwdec: \(player.hwdec.isEmpty ? "off" : player.hwdec)")
            if player.fps > 0 { Text(String(format: "%.2f fps", player.fps)) }
            Text("volume \(Int(player.volume))")
        }
        .font(.caption.monospaced())
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: MPVPlayer
    /// Only the active surface hosts the single persistent video view.
    let active: Bool
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        adopt(into: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        adopt(into: nsView)
    }

    private func adopt(into container: NSView) {
        guard active else { return }
        let video = player.videoView
        video.onDoubleClick = onDoubleClick
        guard video.superview !== container else { return }
        video.removeFromSuperview()
        video.translatesAutoresizingMaskIntoConstraints = true
        video.autoresizingMask = [.width, .height]
        video.frame = container.bounds
        container.addSubview(video)
        video.videoLayer.setNeedsDisplay()
    }
}

/// Borderless window that can take key focus, used for video-only fullscreen.
final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
