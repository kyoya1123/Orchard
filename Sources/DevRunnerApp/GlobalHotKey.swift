import AppKit
import Carbon.HIToolbox

struct GlobalHotKey: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // Shift alone collides with normal typing; require cmd/opt/ctrl.
        guard carbonModifiers & ~UInt32(shiftKey) != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbonModifiers

        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        display = symbols + Self.keyName(for: event)
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

@MainActor
final class GlobalHotKeyManager {
    var handler: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4456_5252), id: 1) // 'DVRR'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }

                // Carbon dispatches hot key events on the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKeyManager>.fromOpaque(userData)
                        .takeUnretainedValue()
                        .handler?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}

@MainActor
enum MenuBarWindowPresenter {
    /// MenuBarExtra has no public API to open its window, so this clicks the
    /// status item button the same way the user would.
    static func toggle() {
        NSApp.activate(ignoringOtherApps: true)

        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            guard let statusItem = window.value(forKey: "statusItem") as? NSStatusItem,
                  let button = statusItem.button else {
                continue
            }

            button.performClick(nil)
            return
        }
    }
}
