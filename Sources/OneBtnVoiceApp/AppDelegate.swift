import AppKit
import Domain
import Presentation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let container = AppDependencyContainer()

    private lazy var overlayWindowController = OverlayWindowController(viewModel: container.overlayViewModel)
    private lazy var menuBarController = MenuBarController()
    private lazy var mainAppWindowController = MainAppWindowController(viewModel: container.mainAppViewModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        bindSettingsUpdates()
        bindAppLifecycle()

        Task {
            let settings = (try? await container.loadSettingsUseCase.execute()) ?? .default
            registerHotkey(with: settings.hotkey)
            container.transcriptionEngine.updateSettings(
                apiKey: settings.cloudAPIKey,
                baseURL: settings.cloudBaseURL,
                durationThreshold: settings.cloudDurationThreshold
            )
            await container.coordinator.prepare()
            if !container.permissionService.currentSnapshot().missingRequiredPermissions.isEmpty {
                mainAppWindowController.show(section: .settings)
            }
        }

        _ = overlayWindowController
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.hotkeyService.stopListening()
    }

    private func configureMenu() {
        menuBarController.onOpenSettings = {
            self.mainAppWindowController.show(section: .settings)
        }

        menuBarController.onOpenHistory = { [weak self] in
            self?.mainAppWindowController.show(section: .history)
        }

        menuBarController.onOpenStatistics = { [weak self] in
            self?.mainAppWindowController.show(section: .statistics)
        }

        menuBarController.onCopyLastTranscription = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let entries = await self.container.coordinator.loadHistoryEntries()
                guard let latest = entries.sorted(by: { $0.startedAt > $1.startedAt }).first,
                      !latest.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(latest.transcript.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
            }
        }

        menuBarController.onResetSession = { [weak self] in
            guard let self else {
                return
            }

            Task { @MainActor in
                await self.container.coordinator.resetSession()
            }
        }

        menuBarController.onRestartApp = { [weak self] in
            self?.restartApplication()
        }

        menuBarController.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func bindSettingsUpdates() {
        container.settingsViewModel.onSettingsSaved = { [weak self] settings in
            self?.registerHotkey(with: settings.hotkey)
            self?.container.transcriptionEngine.updateSettings(
                apiKey: settings.cloudAPIKey,
                baseURL: settings.cloudBaseURL,
                durationThreshold: settings.cloudDurationThreshold
            )
            Task { @MainActor in
                await self?.container.coordinator.reloadSettings()
            }
        }
    }

    private func registerHotkey(with configuration: HotkeyConfiguration) {
        do {
            try container.hotkeyService.startListening(configuration: configuration) { [weak self] event in
                guard let self else {
                    return
                }

                Task { @MainActor in
                    await self.container.coordinator.handleHotkeyEvent(event)
                }
            }
        } catch {
            Task { @MainActor in
                self.container.permissionsViewModel.requestPermissions()
            }
        }
    }

    private func bindAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.container.permissionsViewModel.refresh()
            }
        }
    }

    private func restartApplication() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
