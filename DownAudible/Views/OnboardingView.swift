import AppKit
import SwiftUI

struct OnboardingView: View {
    enum Destination {
        case app, manual
    }

    private enum Page: Equatable {
        case welcome, settings(SettingsPane), finish

        static var order: [Self] {
            [.welcome] + SettingsPane.allCases.map(Self.settings) + [.finish]
        }
    }

    @Bindable var model: WorkspaceModel
    let softwareUpdater: SoftwareUpdater
    let finish: (Destination) -> Void

    @State private var history: [Page] = [.welcome]

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .welcome:
                overview("Welcome to DownAudible") {
                    Text("Connect your Audible account, then choose where to save your books and how to download and convert them.")
                    Text("You can adjust these choices at any time in Settings.")
                }
            case .settings(let pane):
                settings(pane)
            case .finish:
                overview("You’re Ready to Go") {
                    Text("Open DownAudible to get started, or open the manual for steps and examples.")
                }
            }

            Divider()
            controls
                .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 540)
        .interactiveDismissDisabled()
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
    }

    private var page: Page {
        history.last ?? .welcome
    }

    private func overview(_ title: LocalizedStringKey, @ViewBuilder message: () -> some View) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8, content: message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settings(_ pane: SettingsPane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label(pane.title, systemImage: pane.systemImage)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                let current = (SettingsPane.allCases.firstIndex(of: pane) ?? 0) + 1
                ProgressView(value: Double(current), total: Double(SettingsPane.allCases.count)) {
                    Text("Step \(current) of \(SettingsPane.allCases.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .progressViewStyle(.linear)
                .frame(width: 100)
                .appHelp("Shows which step of the setup assistant you are on.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            pane.content(for: model, softwareUpdater: softwareUpdater)
                .id(pane)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if page != .welcome {
                Button("Back") { history.removeLast() }
                    .keyboardShortcut("b", modifiers: [.control, .shift])
                    .appHelp("Go back to the previous setup step.")
            }
            Spacer()
            switch page {
            case .welcome:
                Button("Skip Setup") { history.append(.finish) }
                    .keyboardShortcut("p", modifiers: [.control, .shift])
                    .appHelp("Go straight to the last setup page.")
                Button("Continue", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .appHelp("Start setup with the first settings page.")
            case .settings(let pane):
                Button("Skip Configuration") { history.append(.finish) }
                    .keyboardShortcut("p", modifiers: [.control, .shift])
                    .appHelp("Finish setup using the settings chosen so far.")
                Button(
                    pane == .accounts && !model.signedIn ? "Continue Without an Account" : "Continue",
                    action: advance
                )
                .keyboardShortcut(.defaultAction)
                .appHelp("Continue to the next setup step.")
            case .finish:
                Button("Open Manual") { finish(.manual) }
                    .keyboardShortcut("m", modifiers: [.control, .shift])
                    .appHelp("Finish setup and open DownAudible Help.")
                Button("Open DownAudible") { finish(.app) }
                    .keyboardShortcut(.defaultAction)
                    .appHelp("Finish setup and open the main window.")
            }
        }
    }

    private func advance() {
        let order = Page.order
        guard let index = order.firstIndex(of: page), index + 1 < order.count else { return }
        history.append(order[index + 1])
    }
}
