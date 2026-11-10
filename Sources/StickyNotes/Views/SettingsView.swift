import AppKit
import SwiftUI

/// Settings window (Cmd+,). Only controls where *new* notes are created;
/// existing notes keep their own paths.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var serverURL = AppSettings.defaultNotesServerURL
    @State private var token = ""
    @State private var tokenStatus = ""
    @State private var tokenStatusIsError = false

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

            Text("Fonts")
                .font(.headline)

            Picker("Note body", selection: noteFontBinding) {
                ForEach(NoteFont.choices, id: \.self) { family in
                    Text(family)
                }
            }

            Picker("Note title", selection: titleFontBinding) {
                ForEach(NoteFont.choices, id: \.self) { family in
                    Text(family)
                }
            }

            Divider()

            Text("Notes Server")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("https://notes.example.com", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveToken() }
            }

            SecureField("API token (nk_…)", text: $token)
                .textFieldStyle(.roundedBorder)

            Text(tokenStatus)
                .font(.callout)
                .foregroundColor(tokenStatusIsError ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("""
            Remote notes are read-only until a token with the `notes` scope is saved here. Tokens are stored in the macOS Keychain, never in the app's settings files. Create one on the server with:

            docker compose exec notes-api node scripts/add-token.ts "mac sticky" --scope notes
            """)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

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
        .onAppear {
            serverURL = settings.notesServerURLString
            refreshTokenStatus()
        }
    }

    private var noteFontBinding: Binding<String> {
        Binding(
            get: { settings.noteFontFamily ?? "System" },
            set: { settings.setNoteFontFamily($0 == "System" ? nil : $0) }
        )
    }

    private var titleFontBinding: Binding<String> {
        Binding(
            get: { settings.titleFontFamily ?? "System" },
            set: { settings.setTitleFontFamily($0 == "System" ? nil : $0) }
        )
    }

    private func saveToken() {
        let base = RemoteCredentials.normalize(serverURL)
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            tokenStatus = "Enter a server URL like https://notes.example.com"
            tokenStatusIsError = true
            return
        }
        serverURL = base
        settings.setNotesServerURL(base)
        RemoteCredentials.setToken(token, for: base)
        token = ""
        refreshTokenStatus()
        NotificationCenter.default.post(name: .remoteTokenChanged, object: nil)
    }

    private func refreshTokenStatus() {
        let base = RemoteCredentials.normalize(serverURL)
        tokenStatusIsError = false
        tokenStatus = RemoteCredentials.token(for: base) == nil
            ? "No token stored for \(base)"
            : "Token stored for \(base)"
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
