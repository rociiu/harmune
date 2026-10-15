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

    public init(backend: any MusicBackend, theme: Theme,
                reconnect: (@Sendable () async throws -> any MusicBackend)? = nil,
                colorMode: ColorMode = ColorMode.detect(ProcessInfo.processInfo.environment)) {
        store = AppStore(backend: backend, theme: colorMode == .none ? .mono : theme, reconnect: reconnect)
        renderer = Renderer(colorMode: colorMode)
    }

    /// Runs until the user quits. The terminal is always restored.
    public func run() async throws -> QuitReason {
        try terminal.enter()
        defer { terminal.restore() }

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

        // 10 Hz tick: toasts, key timeouts, progress and animation.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
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
        for key in decoder.feed(bytes) { store.handle(key) }
        // A lone ESC is the Escape key unless more bytes follow quickly.
        escapeFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for key in self.decoder.flushEscape() { self.store.handle(key) }
            }
        }
        escapeFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25), execute: flush)
    }

    private func tick() {
        let wantsFrame = store.tick()
        frameCounter += 1
        let s = store.state
        let animating = s.playback.isPlaying
            && (s.route == .nowPlaying || LayoutClass(columns: terminal.size().columns, rows: terminal.size().rows).showsRightPanel)
        let spinner = s.loading.contains(s.route)
        // Animate at 10 fps; otherwise refresh progress once a second.
        if animating || spinner || (wantsFrame && (!s.playback.isPlaying || frameCounter % 10 == 0)) {
            render()
        }
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
        let canvas = ShellView.render(store.state, columns: columns, rows: rows, selectedIndex: store.selectedIndex)
        TerminalIO.write(renderer.frame(canvas))
    }
}
