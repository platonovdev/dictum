import Application
import Domain
import Foundation
import ServiceManagement

@MainActor
public final class SystemLaunchAtLoginService: LaunchAtLoginService {
    public init() {}

    public func isEnabled() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw AppError.launchAtLoginFailed(error.localizedDescription)
        }
    }
}
