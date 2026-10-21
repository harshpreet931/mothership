import Foundation

/// Follows the terminal modes a full-screen program sets (alternate screen, application
/// cursor keys, mouse reporting, bracketed paste, cursor visibility, keypad) by scanning the
/// output stream for `ESC [ ? Pm h/l`, `ESC =`/`ESC >` and `ESC c`.
///
/// After the ring buffer wraps, the sequence that turned a mode on may no longer be in the
/// replay; `restoreSequence(replayStart:)` re-asserts the live state so a reattached vim
/// still gets arrow keys and mouse events, and is on the alternate screen.
public struct TerminalModeTracker: Sendable {
    /// Modes re-asserted with `ESC [ ? n h` when on (idempotent to repeat).
    static let restorable: [Int] = [1, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004]
    static let alternateScreenModes: Set<Int> = [47, 1047, 1049]

    public private(set) var enabled: Set<Int> = []
    public private(set) var cursorHidden = false
    public private(set) var applicationKeypad = false
    /// Stream offset of the sequence that entered the alternate screen, while it's active.
    public private(set) var alternateScreenEnteredAt: UInt64?

    private enum State { case ground, escape, csi, privateParameters }
    private var state = State.ground
    private var parameters: [UInt8] = []
    private var sequenceStart: UInt64 = 0
    private var offset: UInt64 = 0

    public init() {}

    public var isAlternateScreen: Bool { alternateScreenEnteredAt != nil }

    public mutating func feed(_ data: Data) {
        data.withUnsafeBytes { feed($0) }
    }

    public mutating func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        var index = 0
        let count = bytes.count
        while index < count {
            if state == .ground {
                // Skip straight to the next ESC: most output is plain text.
                guard let escape = memchr(base + index, 0x1B, count - index) else {
                    offset += UInt64(count - index)
                    return
                }
                let skipped = base.distance(to: UnsafeRawPointer(escape))
                offset += UInt64(skipped - index)
                index = skipped
            }
            let byte = bytes[index]
            index += 1
            switch state {
            case .ground:
                if byte == 0x1B {
                    state = .escape
                    sequenceStart = offset
                }
            case .escape:
                switch byte {
                case 0x5B: state = .csi  // [
                case 0x3D: applicationKeypad = true; state = .ground  // =
                case 0x3E: applicationKeypad = false; state = .ground  // >
                case 0x63: reset(); state = .ground  // c (RIS)
                case 0x1B: sequenceStart = offset  // ESC ESC: stay
                default: state = .ground
                }
            case .csi:
                if byte == 0x3F {  // ?
                    state = .privateParameters
                    parameters.removeAll(keepingCapacity: true)
                } else {
                    state = byte == 0x1B ? .escape : .ground
                    if byte == 0x1B { sequenceStart = offset }
                }
            case .privateParameters:
                switch byte {
                case 0x30...0x39, 0x3B:  // digits, ;
                    if parameters.count < 64 { parameters.append(byte) }
                case 0x68: apply(set: true); state = .ground  // h
                case 0x6C: apply(set: false); state = .ground  // l
                case 0x1B: state = .escape; sequenceStart = offset
                default: state = .ground  // other final bytes (e.g. ?…$p) aren't modes we track
                }
            }
            offset += 1
        }
    }

    private mutating func apply(set: Bool) {
        let modes = parameters.split(separator: 0x3B).compactMap { Int(String(decoding: $0, as: UTF8.self)) }
        for mode in modes {
            if Self.alternateScreenModes.contains(mode) {
                if set {
                    if alternateScreenEnteredAt == nil { alternateScreenEnteredAt = sequenceStart }
                } else {
                    alternateScreenEnteredAt = nil
                }
            } else if mode == 25 {
                cursorHidden = !set
            } else if set {
                enabled.insert(mode)
            } else {
                enabled.remove(mode)
            }
        }
    }

    private mutating func reset() {
        enabled.removeAll()
        cursorHidden = false
        applicationKeypad = false
        alternateScreenEnteredAt = nil
    }

    /// Bytes to send after replaying output that began at `replayStart`, so the client's
    /// terminal ends in the session's current modes.
    public func restoreSequence(replayStart: UInt64) -> Data {
        var text = ""
        if let entered = alternateScreenEnteredAt, entered < replayStart {
            // The switch scrolled out of the buffer. Entering clears the alternate screen; the
            // host then nudges the program to redraw (SIGWINCH).
            text += "\u{1B}[?1049h"
        }
        for mode in Self.restorable where enabled.contains(mode) {
            text += "\u{1B}[?\(mode)h"
        }
        if cursorHidden { text += "\u{1B}[?25l" }
        if applicationKeypad { text += "\u{1B}=" }
        return Data(text.utf8)
    }
}
