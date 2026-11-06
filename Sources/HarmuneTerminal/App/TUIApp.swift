import Darwin
import Foundation
import HarmuneCore

/// The interactive terminal app: raw input → store → coalesced redraws.
@MainActor
public final class TUIApp {
    private let store: AppStore
    private let terminal = TerminalIO()
    private var renderer: Renderer
    private var decoder = KeyDecoder()
    private var sources: [DispatchSourceProtocol] = []
    private var renderScheduled = false
    private var escapeFlush: DispatchWorkItem?
    private var frameCounter = 0
    private var quitContinuation: CheckedContinuation<QuitReason, Never>?

    // Artwork
    private var art: ArtworkSnapshot
    private var kitty: KittyGraphics
    private var inline: InlineGraphics?
    private var lastThemeName = ""
    private var accentPath: String?
    private var focused = true
    private var decoding: Set<ArtworkKey> = []
    private var waiting: [ArtworkKey] = []
    private var missingSince: [String: Date] = [:]
    private static let maxConcurrentDecodes = 4
    private static let maxDecodedImages = 256

    public init(backend: any MusicBackend, theme: Theme,
                reconnect: (@Sendable () async throws -> any MusicBackend)? = nil,
                colorMode: ColorMode = ColorMode.detect(ProcessInfo.processInfo.environment),
                graphics: GraphicsMode? = nil, themes: [Theme] = Theme.all, preferences: Preferences = Preferences(),
                keymap: Keymap = .standard, sequenceTimeout: TimeInterval = 0.6, startRoute: Route = .home,
                historyPath: String? = nil, persist: @escaping (String, String, String) -> Void = { _, _, _ in }) {
        let env = ProcessInfo.processInfo.environment
        store = AppStore(backend: backend, theme: colorMode == .none ? .mono : theme, themes: themes, preferences: preferences,
                         keymap: keymap, sequenceTimeout: sequenceTimeout, startRoute: startRoute,
                         historyPath: historyPath, reconnect: reconnect)
        store.onPersist = persist
        renderer = Renderer(colorMode: colorMode)
        art = ArtworkSnapshot(mode: graphics ?? GraphicsMode.detect(env, colorMode: colorMode))
        kitty = KittyGraphics(transmitByPath: KittyGraphics.canTransmitByPath(env))
        switch art.mode {
        case .iterm2: inline = InlineGraphics(format: .iterm2)
        case .sixel: inline = InlineGraphics(format: .sixel, cellPixels: terminal.cellPixels())
        default: break
        }
        store.setArtwork(art)
    }

    /// The top-level view on screen, saved for `restore_last_view`.
    public var currentRoot: Route { store.state.stack.first ?? .home }

    /// Shows a message once the UI is up (e.g. config warnings).
    public func notify(_ message: String, error: Bool = false) { store.toast(message, error: error) }

    /// Runs until the user quits. The terminal is always restored.
    public func run() async throws -> QuitReason {
        try terminal.enter()
        defer {
            if art.mode == .kitty { TerminalIO.write(kitty.clearAll()) }
            terminal.restore()
        }

        store.onChange = { [weak self] in self?.scheduleRender() }
        store.onQuit = { [weak self] reason in
            self?.quitContinuation?.resume(returning: reason)
            self?.quitContinuation = nil
        }

        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readInput() } }
        input.resume()
        sources.append(input)

        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resize.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.render() } }
        resize.resume()
        sources.append(resize)

        // Toasts, key timeouts, progress and animation.
        let interval = 1000 / max(1, min(60, store.state.prefs.maxFPS))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        sources.append(timer)

        render()
        await store.start()
        render()

        let reason = await withCheckedContinuation { quitContinuation = $0 }
        sources.forEach { $0.cancel() }
        sources.removeAll()
        return reason
    }

    private func readInput() {
        let bytes = terminal.readAvailable()
        guard !bytes.isEmpty else { return }
        for key in decoder.feed(bytes) { handle(key) }
        // A lone ESC is the Escape key unless more bytes follow quickly.
        escapeFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for key in self.decoder.flushEscape() { self.handle(key) }
            }
        }
        escapeFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25), execute: flush)
    }

    private func handle(_ key: Key) {
        switch key {
        case .focusIn: focused = true
        case .focusOut: focused = false
        case .ctrl("z") where store.state.mode == .normal: suspend()
        default: store.handle(key)
        }
    }

    /// Ctrl+Z: hands the terminal back to the shell until `fg`.
    private func suspend() {
        if art.mode == .kitty { TerminalIO.write(kitty.clearAll()) }
        terminal.restore()
        signal(SIGTSTP, SIG_DFL)
        raise(SIGTSTP)  // returns after SIGCONT
        try? terminal.enter()
        renderer.invalidate()
        render()
    }

    private func tick() {
        let dirty = store.tick()
        frameCounter += 1
        let s = store.state
        let size = terminal.size()
        let showsVisualizer = s.route == .nowPlaying || LayoutClass(columns: size.columns, rows: size.rows).showsRightPanel
        // Nobody is watching an unfocused window, so only animate in a focused one.
        let animating = s.playback.isPlaying && focused && s.prefs.showVisualizer && !s.prefs.reducedMotion && showsVisualizer
        let spinner = s.loading.contains(s.route) && frameCounter % max(1, s.prefs.maxFPS / 10) == 0
        // Otherwise refresh progress about once a second.
        let progress = s.playback.isPlaying && frameCounter % max(1, s.prefs.maxFPS) == 0
        if animating || spinner || dirty && !s.playback.isPlaying || progress {
            render()
        }
    }

    /// Takes a decorative accent from the current cover when the track changes.
    private func updateDynamicAccent() {
        let s = store.state
        let path = s.prefs.dynamicColors && s.art.enabled ? s.playback.track?.artwork?.path : nil
        guard path != accentPath else { return }
        accentPath = path
        guard let path else {
            store.setDynamicAccent(nil)
            return
        }
        let background = s.theme.background
        Task.detached(priority: .utility) { [weak self] in
            let accent = PixelGrid.load(path: path, width: 24, height: 24).flatMap { DynamicColor.accent(from: $0, on: background) }
            await self?.finishAccent(path: path, accent)
        }
    }

    private func finishAccent(path: String, _ accent: TermColor?) {
        guard path == accentPath else { return }
        store.setDynamicAccent(accent)
        scheduleRender()
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.renderScheduled = false
                self?.render()
            }
        }
    }

    private func render() {
        let (columns, rows) = terminal.size()
        let layout = ShellLayout(columns: columns, rows: rows)
        let hasHeader = screen(for: store.state.route, in: store.state).header != nil
        let height = layout.listHeight(hasHeader: hasHeader)
        if store.listHeight != height { store.listHeight = height }
        store.terminalRows = rows
        updateDynamicAccent()
        store.gridColumns = ShellView.gridColumns(for: store.state, layout: layout)
        let canvas = ShellView.render(store.state, columns: columns, rows: rows, selectedIndex: store.selectedIndex)
        // Inline images were painted over the old theme's cells.
        if inline != nil, store.state.theme.name != lastThemeName { renderer.invalidate() }
        lastThemeName = store.state.theme.name
        inline?.removed(canvas.imagePlacements).forEach { renderer.damage($0) }
        var out = renderer.frame(canvas)
        if art.mode == .kitty { out += kitty.sync(canvas.imagePlacements, fullRedraw: renderer.lastFrameWasFull) }
        if inline != nil {
            if renderer.lastFrameWasFull { inline?.reset() }
            out += inline?.place(canvas.imagePlacements) ?? ""
        }
        TerminalIO.write(out)
        request(canvas.artworkRequests)
    }

    // MARK: - Artwork loading

    private func request(_ keys: Set<ArtworkKey>) {
        let now = Date()
        for key in keys where !decoding.contains(key) && !waiting.contains(key) {
            if let since = missingSince[key.path], now.timeIntervalSince(since) < 2 { continue }
            waiting.append(key)
        }
        startDecodes()
    }

    private func startDecodes() {
        while decoding.count < Self.maxConcurrentDecodes, !waiting.isEmpty {
            let key = waiting.removeFirst()
            decoding.insert(key)
            let mode = art.mode
            Task.detached(priority: .userInitiated) { [weak self] in
                // Kitty only needs to know the file exists; half-block needs pixels.
                let exists = FileManager.default.fileExists(atPath: key.path)
                let grid = mode == .halfblock && exists ? PixelGrid.load(path: key.path, width: key.columns, height: key.rows * 2) : nil
                await self?.finishDecode(key, exists: exists, grid: grid)
            }
        }
    }

    private func finishDecode(_ key: ArtworkKey, exists: Bool, grid: PixelGrid?) {
        decoding.remove(key)
        if exists {
            missingSince[key.path] = nil
            if art.mode.usesPlacements { art.available.insert(key.path) }
            if let grid {
                if art.decoded.count >= Self.maxDecodedImages { art.decoded.removeAll() }
                art.decoded[key] = grid
            }
            store.setArtwork(art)
            scheduleRender()
        } else {
            // Not generated yet (demo) or missing: retry in a couple of seconds.
            missingSince[key.path] = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRender() }
            }
        }
        startDecodes()
    }
}
