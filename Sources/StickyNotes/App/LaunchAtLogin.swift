import Foundation
import ServiceManagement
import Combine

/// "Launch at login" backed by `SMAppService.mainApp` (macOS 13+).
///
/// The system, not this app, owns the registration. `refresh()` reads it after
/// every change and on Settings open, so a toggle flipped in System Settings
/// shows up here too.
final class LaunchAtLogin: ObservableObject {

    /// `SMAppService` is macOS 13+; the app still deploys to macOS 12.
    static let isSupported: Bool = {
        if #available(macOS 13.0, *) { return true }
        return false
    }()

    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        guard #available(macOS 13.0, *) else {
            isEnabled = false
            needsApproval = false
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            needsApproval = false
        case .requiresApproval:
            isEnabled = true
            needsApproval = true
        case .notRegistered, .notFound:
            isEnabled = false
            needsApproval = false
        @unknown default:
            isEnabled = false
            needsApproval = false
        }
    }

    /// Register or unregister the main app as a login item.
    func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        guard !isChanging else { return }

        isChanging = true
        errorMessage = nil
        Task { @MainActor in
            defer {
                isChanging = false
                refresh()
            }
            do {
                if enabled {
                    if SMAppService.mainApp.status == .notRegistered {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openSystemSettings() {
        guard #available(macOS 13.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
