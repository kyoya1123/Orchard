import OrchardCore
import SwiftUI

struct CleanupPermissionView: View {
    let guidance: CleanupPermissionGuidance
    var alwaysVisible = false

    var body: some View {
        if alwaysVisible || guidance.showsBanner {
            VStack(alignment: .leading, spacing: 8) {
                Label("ウィンドウの自動クローズ", systemImage: guidance.isTrusted ? "checkmark.circle" : "macwindow")
                    .font(.headline)
                if guidance.isTrusted {
                    Text("アクセシビリティは許可済みです。対象ウィンドウの自動クローズが利用できます。")
                        .font(.caption)
                } else {
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
                }
                HStack {
                    if !guidance.isTrusted {
                        Button("許可を設定") { guidance.requestAccess() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("cleanup-permission-request")
                        Button("許可を再確認") { guidance.checkAgain() }
                            .accessibilityIdentifier("cleanup-permission-recheck")
                    }
                    Spacer(minLength: 0)
                    if !alwaysVisible {
                        Button { guidance.dismiss() } label: {
                            if guidance.isTrusted { Text("閉じる") } else { Text("後で") }
                        }
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
