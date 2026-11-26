import AppKit
import CMpv
import Observation

@Observable
final class MPVPlayer {
    static let defaultUserAgent = "VLC/3.0.21 LibVLC/3.0.21"

    // State mirrored from mpv
    var isPaused = false
    var isBuffering = false
    var isIdle = true
    var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 100
    var isMuted = false
    var videoWidth = 0
    var videoHeight = 0
    var videoCodec = ""
    var hwdec = ""
    var fps: Double = 0
    var errorMessage: String?
    var nowPlaying: Channel?
    var isReconnecting = false
    var duration: Double = 0
    @ObservationIgnored private var seekable = false
    @ObservationIgnored private var partiallySeekable = false

    @ObservationIgnored private(set) var handle: OpaquePointer?
    @ObservationIgnored private let eventQueue = DispatchQueue(label: "cornelia.mpv.events")
    @ObservationIgnored private var renderReady = false
    @ObservationIgnored private var pending: Channel?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var playingSince: Date?
    private static let retryDelays: [Double] = [0.2, 0.5, 1, 2, 3, 5, 8, 10]
    @ObservationIgnored lazy var videoView: MPVVideoView = MPVVideoView(player: self)

    init() {
        guard let h = mpv_create() else { fatalError("mpv_create failed") }
        handle = h
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "auto-safe"),
            ("idle", "yes"),
            ("terminal", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("ytdl", "no"),
            ("audio-client-name", "Cornelia"),
            ("user-agent", Self.defaultUserAgent),
            ("network-timeout", "15"),
            ("demuxer-lavf-analyzeduration", "1"),
            ("demuxer-lavf-o", "fflags=+discardcorrupt"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=4"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-max-back-bytes", "16MiB"),
            ("volume", String(Int(volume))),
        ]
        for (k, v) in options { mpv_set_option_string(h, k, v) }
        mpv_request_log_messages(h, debugEnabled ? "v" : "no")
        let rc = mpv_initialize(h)
        if rc < 0 { fatalError("mpv_initialize failed: \(String(cString: mpv_error_string(rc)))") }

        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("core-idle", MPV_FORMAT_FLAG)
        observe("idle-active", MPV_FORMAT_FLAG)
        observe("volume", MPV_FORMAT_DOUBLE)
        observe("mute", MPV_FORMAT_FLAG)
        observe("dwidth", MPV_FORMAT_INT64)
        observe("dheight", MPV_FORMAT_INT64)
        observe("video-codec", MPV_FORMAT_STRING)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("estimated-vf-fps", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("seekable", MPV_FORMAT_FLAG)
        observe("partially-seekable", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(h, { ctx in
            let player = Unmanaged<MPVPlayer>.fromOpaque(ctx!).takeUnretainedValue()
            player.eventQueue.async { player.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Commands

    /// User initiated playback: resets the auto-reconnect budget.
    func play(_ channel: Channel) {
        guard renderReady else { pending = channel; return }
        cancelRetry()
        retryCount = 0
        load(channel)
    }

    private func load(_ channel: Channel) {
        nowPlaying = channel
        errorMessage = nil
        isBuffering = true
        playingSince = nil
        duration = 0
        seekable = false
        partiallySeekable = false
        command(["set", "user-agent", channel.userAgent ?? Self.defaultUserAgent])
        command(["set", "referrer", channel.referrer ?? ""])
        command(["loadfile", channel.url, "replace"])
        if isPaused { command(["set", "pause", "no"]) }
    }

    func retry() { if let c = nowPlaying { play(c) } }

    func stop() {
        cancelRetry()
        command(["stop"])
        nowPlaying = nil
    }

    func togglePause() { command(["cycle", "pause"]) }
    func toggleMute() { command(["cycle", "mute"]) }

    func setVolume(_ v: Double) {
        let clamped = min(130, max(0, v))
        volume = clamped
        UserDefaults.standard.set(clamped, forKey: "volume")
        command(["set", "volume", String(format: "%.0f", clamped)])
        if isMuted && clamped > 0 { command(["set", "mute", "no"]) }
    }

    private func cancelRetry() {
        retryWork?.cancel()
        retryWork = nil
        isReconnecting = false
    }

    /// Live streams often drop the connection; reconnect transparently instead of giving up.
    private func handleEnd(eof: Bool, message: String) {
        guard let channel = nowPlaying else { return }
        // A real VOD file (truly seekable, not just via cache) that played to the end really ended.
        // Live streams are unseekable or only cache-seekable, and their "duration" just grows.
        if eof && seekable && !partiallySeekable && duration > 0 && playingSince != nil {
            isBuffering = false
            isReconnecting = false
            errorMessage = "Stream ended"
            return
        }
        // Stream connected and played before dropping: fresh retry budget.
        if let since = playingSince, Date().timeIntervalSince(since) > 5 { retryCount = 0 }
        playingSince = nil
        guard retryCount < Self.retryDelays.count else {
            isBuffering = false
            isReconnecting = false
            errorMessage = eof ? "Stream ended" : "Stream failed: \(message)"
            return
        }
        let delay = Self.retryDelays[retryCount]
        retryCount += 1
        debugLog("reconnect #\(retryCount) in \(delay)s (\(eof ? "eof" : message))")
        isReconnecting = true
        isBuffering = true
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.nowPlaying?.url == channel.url else { return }
            self.load(channel)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func renderContextReady() {
        renderReady = true
        if let p = pending { pending = nil; play(p) }
    }

    func shutdown() {
        guard let h = handle else { return }
        videoView.videoLayer.freeRenderContext()
        handle = nil
        mpv_terminate_destroy(h)
    }

    // MARK: mpv plumbing

    private func command(_ args: [String]) {
        guard let h = handle else { return }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { ptr in
                _ = mpv_command_async(h, 0, ptr)
            }
        }
        for p in cargs { free(p) }
    }

    private func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(handle, 0, name, format)
    }

    private func drainEvents() {
        while let h = handle {
            guard let ev = mpv_wait_event(h, 0)?.pointee else { return }
            if ev.event_id == MPV_EVENT_NONE { return }
            switch ev.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = ev.data else { break }
                handleProperty(data.assumingMemoryBound(to: mpv_event_property.self).pointee)
            case MPV_EVENT_END_FILE:
                guard let data = ev.data else { break }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                debugLog("end-file reason=\(end.reason.rawValue) error=\(end.error)")
                if end.reason == MPV_END_FILE_REASON_ERROR || end.reason == MPV_END_FILE_REASON_EOF {
                    let eof = end.reason == MPV_END_FILE_REASON_EOF
                    let msg = String(cString: mpv_error_string(end.error))
                    DispatchQueue.main.async { self.handleEnd(eof: eof, message: msg) }
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let d = ev.data {
                    let m = d.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    debugLog("mpv[\(String(cString: m.prefix))] \(String(cString: m.text))".trimmingCharacters(in: .newlines))
                }
            case MPV_EVENT_START_FILE:
                debugLog("start-file")
            case MPV_EVENT_FILE_LOADED:
                debugLog("file-loaded")
                DispatchQueue.main.async {
                    self.errorMessage = nil
                    self.isReconnecting = false
                    self.playingSince = Date()
                }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    private func handleProperty(_ p: mpv_event_property) {
        let name = String(cString: p.name)
        if debugEnabled, let d = p.data {
            switch p.format {
            case MPV_FORMAT_FLAG: debugLog("\(name)=\(d.assumingMemoryBound(to: Int32.self).pointee)")
            case MPV_FORMAT_INT64: debugLog("\(name)=\(d.assumingMemoryBound(to: Int64.self).pointee)")
            case MPV_FORMAT_STRING: if let c = d.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee { debugLog("\(name)=\(String(cString: c))") }
            default: break
            }
        }
        guard let data = p.data else {
            if name == "duration" { DispatchQueue.main.async { self.duration = 0 } }
            if name == "video-codec" || name == "hwdec-current" {
                DispatchQueue.main.async {
                    if name == "video-codec" { self.videoCodec = "" } else { self.hwdec = "" }
                }
            }
            return
        }
        switch p.format {
        case MPV_FORMAT_FLAG:
            let v = data.assumingMemoryBound(to: Int32.self).pointee != 0
            DispatchQueue.main.async {
                switch name {
                case "pause": self.isPaused = v
                case "paused-for-cache": self.isBuffering = v
                case "core-idle": if !v { self.isBuffering = false }
                case "idle-active": self.isIdle = v
                case "mute": self.isMuted = v
                case "seekable": self.seekable = v
                case "partially-seekable": self.partiallySeekable = v
                default: break
                }
            }
        case MPV_FORMAT_DOUBLE:
            let v = data.assumingMemoryBound(to: Double.self).pointee
            DispatchQueue.main.async {
                switch name {
                case "volume": self.volume = v
                case "estimated-vf-fps": self.fps = v
                case "duration": self.duration = v
                default: break
                }
            }
        case MPV_FORMAT_INT64:
            let v = Int(data.assumingMemoryBound(to: Int64.self).pointee)
            DispatchQueue.main.async {
                if name == "dwidth" { self.videoWidth = v } else if name == "dheight" { self.videoHeight = v }
            }
        case MPV_FORMAT_STRING:
            guard let cstr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return }
            let v = String(cString: cstr)
            DispatchQueue.main.async {
                if name == "video-codec" { self.videoCodec = v } else if name == "hwdec-current" { self.hwdec = v }
            }
        default:
            break
        }
    }
}
