import Darwin
import Foundation

/// Raw-mode terminal session on stdin/stdout.
///
/// Uses the alternate screen, hides the cursor and disables line wrap.
/// `restore()` is idempotent and is also registered for fatal signals so
/// the user's terminal is never left broken.
public final class TerminalIO: @unchecked Sendable {
    nonisolated(unsafe) private static var savedTermios: termios?
    private var active = false

    public init() {}

    public static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    public func enter() throws {
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else {
            throw NSError(domain: "harmune", code: 1, userInfo: [NSLocalizedDescriptionKey: "stdin is not a terminal"])
        }
        Self.savedTermios = t
        var raw = t
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cflag |= tcflag_t(CS8)
        // ISIG off: Ctrl+C/Ctrl+Z arrive as keys and are handled by the app.
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        Self.write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[?1004h")
        active = true

        for sig in [SIGTERM, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS] {
            signal(sig) { s in
                TerminalIO.restoreTerminal()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    public func restore() {
        guard active else { return }
        active = false
        Self.restoreTerminal()
    }

    static func restoreTerminal() {
        write("\u{1B}[?1004l\u{1B}[?7h\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        if var t = savedTermios { tcsetattr(STDIN_FILENO, TCSAFLUSH, &t) }
    }

    public func size() -> (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    /// Size of one cell in pixels. Terminals that don't report it get a
    /// typical size, which only makes Sixel covers a little soft.
    public func cellPixels() -> (width: Int, height: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0, ws.ws_xpixel > 0, ws.ws_ypixel > 0 {
            return (Int(ws.ws_xpixel) / Int(ws.ws_col), Int(ws.ws_ypixel) / Int(ws.ws_row))
        }
        return (10, 20)
    }

    public static func write(_ s: String) {
        var data = Array(s.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress! + offset, $0.count - offset) }
            if n > 0 { offset += n } else if errno != EINTR && errno != EAGAIN { return }
        }
    }

    /// Reads whatever bytes are available without blocking.
    public func readAvailable() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
        return n > 0 ? Array(buf[0..<n]) : []
    }
}
