import Application
import Combine
import Domain
import Foundation

@MainActor
public final class PermissionsViewModel: ObservableObject {
    @Published public private(set) var snapshot: PermissionSnapshot = .empty

    private let permissionService: PermissionService
    private let requestPermissionsUseCase: RequestPermissionsUseCase

    public init(
        permissionService: PermissionService,
        requestPermissionsUseCase: RequestPermissionsUseCase
    ) {
        self.permissionService = permissionService
        self.requestPermissionsUseCase = requestPermissionsUseCase
        snapshot = permissionService.currentSnapshot()
    }

    public func refresh() {
        snapshot = permissionService.currentSnapshot()
    }

    public func requestPermissions() {
        let useCase = requestPermissionsUseCase
        Task { @MainActor in
            snapshot = await useCase.execute()
        }
    }

    public func openSystemSettings(for permission: PermissionKind) {
        permissionService.openSystemSettings(for: permission)
    }
}
