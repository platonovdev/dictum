import AppKit
import SwiftUI

public struct MainAppView: View {
    @ObservedObject private var viewModel: MainAppViewModel

    public init(viewModel: MainAppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            List(MainAppSection.allCases, selection: $viewModel.selectedSection) { section in
                Label(section.title, systemImage: section.systemImageName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(sidebarBackground)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(detailBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .background(detailBackground)
        .task(id: viewModel.selectedSection) {
            await viewModel.refreshVisibleSection()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selectedSection {
        case .settings:
            ScrollView {
                SettingsView(
                    settingsViewModel: viewModel.settingsViewModel,
                    permissionsViewModel: viewModel.permissionsViewModel
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .history:
            HistoryView(viewModel: viewModel.historyViewModel)
        case .statistics:
            StatisticsView(viewModel: viewModel.statisticsViewModel)
        }
    }

    private var sidebarBackground: Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    private var detailBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
