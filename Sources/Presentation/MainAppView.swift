import AppKit
import SwiftUI

private enum MainAppLayout {
    static let sidebarWidth: CGFloat = 204
    static let titleBarHeight: CGFloat = 52
}

public struct MainAppView: View {
    @ObservedObject private var viewModel: MainAppViewModel
    @State private var hoveredSection: MainAppSection?

    public init(viewModel: MainAppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.65))
                .frame(width: 1)

            detailColumn
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .task(id: viewModel.selectedSection) {
            await viewModel.refreshVisibleSection()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarTitleBar

            Divider()

            VStack(spacing: 4) {
                ForEach(MainAppSection.allCases) { section in
                    navigationButton(for: section)
                }
            }
            .padding(10)

            Spacer(minLength: 0)
        }
        .frame(width: MainAppLayout.sidebarWidth)
        .background(.regularMaterial)
    }

    private var sidebarTitleBar: some View {
        HStack(spacing: 0) {
            // Keep the label clear of the native macOS traffic-light controls.
            Color.clear
                .frame(width: 78)

            Text(L10n.text("Dictator", "Диктатор"))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 12)
        }
        .frame(height: MainAppLayout.titleBarHeight)
        .contentShape(Rectangle())
    }

    private func navigationButton(for section: MainAppSection) -> some View {
        let isSelected = viewModel.selectedSection == section
        let isHovered = hoveredSection == section

        return Button {
            viewModel.selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImageName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(navigationBackground(isSelected: isSelected, isHovered: isHovered))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredSection = isHovering ? section : nil
        }
    }

    private func navigationBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovered {
            return Color(nsColor: .labelColor).opacity(0.07)
        }
        return .clear
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.selectedSection.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: MainAppLayout.titleBarHeight)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
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
                .frame(maxWidth: 760, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .history:
            HistoryView(viewModel: viewModel.historyViewModel)
        case .statistics:
            StatisticsView(viewModel: viewModel.statisticsViewModel)
        }
    }
}
