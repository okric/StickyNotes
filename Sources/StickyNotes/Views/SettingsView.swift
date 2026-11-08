import AppKit
import SwiftUI

/// Settings window (Cmd+,). Only controls where *new* notes are created;
/// existing notes keep their own paths.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notes Folder")
                .font(.headline)

            Text(settings.defaultFolderPath ?? "No folder selected")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

            HStack(spacing: 8) {
                Button("Choose Folder…") { chooseFolder() }
                Button("Create Folder in Documents") {
                    settings.createDefaultFolderInDocuments()
                }
                Spacer()
                Button("Reveal in Finder") {
                    settings.revealDefaultFolder()
                }
                .disabled(settings.defaultFolderURL == nil)
            }

            Divider()

            Text("""
            Each sticky note is a Markdown file in this folder. Changes are saved \
            directly to the file, so notes can live in an Obsidian vault or any \
            other folder you already use.

            Changing the folder only affects new notes; open notes keep their \
            current files.
            """)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 540)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder where new notes are saved"
        if let current = settings.defaultFolderURL {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.setDefaultFolder(url)
        }
    }
}
