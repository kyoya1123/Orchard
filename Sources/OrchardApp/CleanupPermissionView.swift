import OrchardCore
import SwiftUI

struct CleanupPermissionView: View {
    let guidance: CleanupPermissionGuidance
    var alwaysVisible = false

    var body: some View {
        if guidance.isTrusted {
            if alwaysVisible {
                Label("アクセシビリティ: 許可済み", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cleanup-permission-granted")
            }
        } else if alwaysVisible || guidance.showsBanner {
            VStack(alignment: .leading, spacing: 8) {
                Label("ウィンドウの自動クローズ", systemImage: "macwindow")
                    .font(.headline)
                Text("Device Hubのウィンドウを自動で閉じるには、Orchardのアクセシビリティ権限が必要です。")
                    .font(.caption)
                if guidance.requestedPrompt {
                    Text("まだ許可されていません。設定でOrchardをオンにして戻ってください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("システム設定 → プライバシーとセキュリティ → アクセシビリティ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if guidance.settingsOpenFailed {
                    Text("設定を開けませんでした。上の場所からOrchardを許可してください。")
                        .font(.caption)
                }
                HStack {
                    Button("許可を設定") { guidance.requestAccess() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("cleanup-permission-request")
                    Button("許可を再確認") { guidance.checkAgain() }
                        .accessibilityIdentifier("cleanup-permission-recheck")
                    Spacer(minLength: 0)
                    if !alwaysVisible {
                        Button("後で") { guidance.dismiss() }
                            .accessibilityIdentifier("cleanup-permission-dismiss")
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("cleanup-permission-guidance")
        }
    }
}
