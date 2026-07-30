import Foundation

public enum MainAppSection: String, CaseIterable, Identifiable, Hashable {
    case settings
    case history
    case statistics

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .settings:
            return L10n.text("Settings", "Настройки")
        case .history:
            return L10n.text("History", "История")
        case .statistics:
            return L10n.text("Statistics", "Статистика")
        }
    }

    var systemImageName: String {
        switch self {
        case .settings:
            return "slider.horizontal.3"
        case .history:
            return "text.badge.clock"
        case .statistics:
            return "chart.bar"
        }
    }
}

@MainActor
public final class MainAppViewModel: ObservableObject {
    @Published public var selectedSection: MainAppSection = .settings

    public let settingsViewModel: SettingsViewModel
    public let permissionsViewModel: PermissionsViewModel
    public let historyViewModel: HistoryViewModel
    public let statisticsViewModel: StatisticsViewModel

    public init(
        settingsViewModel: SettingsViewModel,
        permissionsViewModel: PermissionsViewModel,
        historyViewModel: HistoryViewModel,
        statisticsViewModel: StatisticsViewModel
    ) {
        self.settingsViewModel = settingsViewModel
        self.permissionsViewModel = permissionsViewModel
        self.historyViewModel = historyViewModel
        self.statisticsViewModel = statisticsViewModel
    }

    public func open(section: MainAppSection) async {
        let previousSection = selectedSection
        selectedSection = section
        if previousSection == section {
            await refreshVisibleSection()
        }
    }

    public func refreshVisibleSection() async {
        switch selectedSection {
        case .settings:
            permissionsViewModel.refresh()
            await settingsViewModel.load()
        case .history:
            await historyViewModel.reload()
        case .statistics:
            await statisticsViewModel.reload()
        }
    }
}
