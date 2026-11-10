import AppKit
import SwiftUI

/// Settings window (Cmd+,).
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLogin: LaunchAtLogin

    @State private var serverURL = AppSettings.defaultNotesServerURL
    @State private var token = ""
    @State private var tokenStatus = ""
    @State private var tokenStatusIsError = false
    @State private var tokenStored = false

    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                Form { sections }
                    .formStyle(.grouped)
            } else {
                Form { sections }
            }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            serverURL = settings.notesServerURLString
            refreshTokenStatus()
            launchAtLogin.refresh()
        }
        .onChange(of: serverURL) { _ in
            refreshTokenStatus()
        }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            Text(settings.defaultFolderPath ?? "No folder selected")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Choose Folder…") { chooseFolder() }
                if !settings.documentsNotesFolderExists {
                    Button("Create Folder in Documents") {
                        settings.createDefaultFolderInDocuments()
                    }
                }
                Spacer()
                Button("Reveal in Finder") {
                    settings.revealDefaultFolder()
                }
                .disabled(settings.defaultFolderURL == nil)
            }

            Text("""
            Each sticky note is a Markdown file in this folder. Changes are saved \
            directly to the file, so notes can live in an Obsidian vault or any \
            other folder you already use. Changing the folder only affects new \
            notes; open notes keep their current files.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Notes Folder")
        }

        Section {
            Picker("Note body", selection: noteFontBinding) {
                ForEach(NoteFont.choices, id: \.self) { family in
                    Text(family)
                }
            }
            .pickerStyle(.menu)

            Picker("Note title", selection: titleFontBinding) {
                ForEach(NoteFont.choices, id: \.self) { family in
                    Text(family)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Fonts")
        }

        Section {
            HStack(spacing: 8) {
                TextField("https://notes.example.com", text: $serverURL)
                Button("Save") { saveServerURL() }
            }

            if tokenStored {
                HStack(spacing: 8) {
                    Text("Token stored for \(RemoteCredentials.normalize(serverURL))")
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Clear Token") { clearToken() }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API token (nk_…)", text: $token)
                    Button("Save Token") { saveToken() }
                }
            }

            Text(tokenStatus)
                .font(.caption)
                .foregroundStyle(tokenStatusIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .lineLimit(2)

            Picker("Check the server every", selection: pollBinding) {
                ForEach(AppSettings.inboxPollChoices, id: \.self) { minutes in
                    Text(minutes == 1 ? "1 minute" : "\(minutes) minutes")
                }
            }
            .pickerStyle(.menu)

            Text("""
            Remote notes and the notes inbox need an API token. Tokens are stored \
            in the macOS Keychain, never in the app's settings files. Create one \
            on the server with:

            npm run add-token -- "mac sticky"
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Notes Server")
        }

        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(launchAtLogin.isChanging || !LaunchAtLogin.isSupported)

            if launchAtLogin.isChanging {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating login item…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if launchAtLogin.needsApproval {
                Label(
                    "Approval is needed in System Settings → General → Login Items.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Open Login Items Settings") {
                    launchAtLogin.openSystemSettings()
                }
            }

            if let error = launchAtLogin.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Text(LaunchAtLogin.isSupported
                ? "Starts Sticky Notes when you log in. The app must be installed in Applications."
                : "Launch at login requires macOS 13 or later.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Startup")
        }
    }

    private var pollBinding: Binding<Int> {
        Binding(
            get: { settings.inboxPollMinutes },
            set: { settings.setInboxPollMinutes($0) }
        )
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

    private func saveServerURL() {
        let base = RemoteCredentials.normalize(serverURL)
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            tokenStatus = "Enter a server URL like https://notes.example.com"
            tokenStatusIsError = true
            return
        }
        serverURL = base
        settings.setNotesServerURL(base)
        refreshTokenStatus()
    }

    private func saveToken() {
        let base = RemoteCredentials.normalize(serverURL)
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            tokenStatus = "Enter a server URL like https://notes.example.com"
            tokenStatusIsError = true
            return
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tokenStatus = "Paste the API token first."
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

    private func clearToken() {
        let base = RemoteCredentials.normalize(serverURL)
        RemoteCredentials.setToken(nil, for: base)
        refreshTokenStatus()
        NotificationCenter.default.post(name: .remoteTokenChanged, object: nil)
    }

    private func refreshTokenStatus() {
        let base = RemoteCredentials.normalize(serverURL)
        tokenStored = RemoteCredentials.token(for: base) != nil
        tokenStatusIsError = false
        tokenStatus = tokenStored
            ? "The token stays in the Keychain; the app never shows it again."
            : "No token stored for \(base)"
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
