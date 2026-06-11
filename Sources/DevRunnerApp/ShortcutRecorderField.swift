import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct ShortcutRecorderField: View {
    let hotKey: GlobalHotKey?
    let onCommit: @MainActor (GlobalHotKey) -> Void

    @State private var isRecording = false
    @State private var keyDownMonitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(isRecording ? "Type shortcut…" : (hotKey?.display ?? "Record Shortcut"))
                .frame(minWidth: 120)
        }
        .help(isRecording ? "Press a key combination. Esc cancels." : "Record a global shortcut")
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated {
                handleRecordingEvent(event)
            }
            return consumed ? nil : event
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return true
        }

        guard let hotKey = GlobalHotKey(event: event) else {
            // Swallow keystrokes without a usable modifier while recording.
            return true
        }

        stopRecording()
        onCommit(hotKey)
        return true
    }

    private func stopRecording() {
        isRecording = false
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        keyDownMonitor = nil
    }
}
