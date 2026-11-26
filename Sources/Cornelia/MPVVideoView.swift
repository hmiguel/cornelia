import AppKit
import CMpv
import OpenGL.GL3

private func glProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

let debugEnabled = ProcessInfo.processInfo.environment["CORNELIA_DEBUG"] != nil
func debugLog(_ s: String) { if debugEnabled { FileHandle.standardError.write((String(format: "[cornelia %.3f] ", CACurrentMediaTime()) + s + "\n").data(using: .utf8)!) } }

/// OpenGL layer that pulls frames from libmpv's render API.
final class MPVLayer: CAOpenGLLayer {
    private unowned let player: MPVPlayer
    private var renderContext: OpaquePointer?
    private var cglContext: CGLContextObj?

    init(player: MPVPlayer) {
        self.player = player
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        let other = layer as! MPVLayer
        player = other.player
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var pix: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attrs, &pix, &count)
        return pix!
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLSetCurrentContext(ctx)
        cglContext = ctx
        createRenderContext()
        return ctx
    }

    private func createRenderContext() {
        guard renderContext == nil, let mpv = player.handle else { return }
        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(get_proc_address: glProcAddress, get_proc_address_ctx: nil)
        withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(),
            ]
            if mpv_render_context_create(&renderContext, mpv, &params) < 0 {
                NSLog("Cornelia: failed to create mpv render context")
                return
            }
        }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let layer = Unmanaged<MPVLayer>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.main.async { self.player.renderContextReady() }
    }

    private var lastSample: CFTimeInterval = 0
    private func debugSample(fbo: GLint, w: GLint, h: GLint) {
        let now = CACurrentMediaTime()
        guard now - lastSample > 1 else { return }
        lastSample = now
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(fbo))
        var out = ""
        for (fx, fy) in [(0.25, 0.25), (0.5, 0.5), (0.75, 0.75), (0.3, 0.6), (0.6, 0.3)] {
            var px: [UInt8] = [0, 0, 0, 0]
            glReadPixels(GLint(Double(w) * fx), GLint(Double(h) * fy), 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &px)
            out += " \(px[0]),\(px[1]),\(px[2])"
        }
        debugLog("render \(w)x\(h) fbo=\(fbo) px:" + out)
    }

    func freeRenderContext() {
        guard let rc = renderContext else { return }
        if let ctx = cglContext { CGLSetCurrentContext(ctx) }
        mpv_render_context_set_update_callback(rc, nil, nil)
        mpv_render_context_free(rc)
        renderContext = nil
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        guard let rc = renderContext else { glFlush(); return }

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &target) { targetPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(targetPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(rc, &params)
            }
        }
        if debugEnabled { debugSample(fbo: fbo, w: viewport[2], h: viewport[3]) }
        glFlush()
        mpv_render_context_report_swap(rc)
    }
}

/// Persistent NSView hosting the mpv layer. One instance per player, reused by SwiftUI.
final class MPVVideoView: NSView {
    let videoLayer: MPVLayer
    var onDoubleClick: (() -> Void)?
    private var hideCursorWork: DispatchWorkItem?

    init(player: MPVPlayer) {
        videoLayer = MPVLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hideCursorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let w = self.window, w is FullscreenWindow || w.styleMask.contains(.fullScreen) else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideCursorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
