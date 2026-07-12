import AppKit
import SwiftUI

public struct MainAppView: View {
    @ObservedObject private var viewModel: MainAppViewModel

    public init(viewModel: MainAppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(detailBackground)
        }
        .background(detailBackground)
        .task(id: viewModel.selectedSection) {
            await viewModel.refreshVisibleSection()
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 30, height: 30)

            Text("Dictum")
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            Spacer()

            Picker("Section", selection: $viewModel.selectedSection) {
                ForEach(MainAppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImageName)
                        .tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 330)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var detailBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
