import OrchardCore
import SwiftUI

struct RegisteredRepositoriesView: View {
    let repositories: [RegisteredRepository]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projects from CLI")
                .font(.headline)
            if repositories.isEmpty {
                Text("Projects appear here when you use the Orchard CLI. No folder setup is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(repositories) { repository in
                            Label(repository.directoryPath, systemImage: "folder")
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(repository.directoryPath)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }
}
