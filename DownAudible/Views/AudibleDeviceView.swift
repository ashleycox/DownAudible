import SwiftUI

struct AudibleDeviceView: View {
    let model: WorkspaceModel
    let account: SavedAudibleAccount
    var initialRegistration: AudibleDeviceRegistration? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: AudibleClient.DeviceConfirmation?
    @State private var confirming = false
    @State private var deregistering = false
    @State private var issue: String?

    private var registration: AudibleDeviceRegistration? { confirmation?.registration ?? initialRegistration }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audible Device Registration").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LabeledContent("DownAudible profile", value: account.name)
            LabeledContent("Marketplace", value: account.marketplace.displayName)
            if let registration {
                LabeledContent("Device", value: registration.name ?? registration.typeName)
                if let suffix = registration.serialSuffix { LabeledContent("Serial number ending", value: suffix) }
                Text("Deregistering this device signs this profile out. Saved books, file matches, and transfer history stay on this computer.")
                    .foregroundStyle(.secondary)
            } else if issue == nil {
                ProgressView("Checking saved registration…").controlSize(.small)
            }
            if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            HStack {
                if deregistering { ProgressView("Deregistering…").controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(deregistering)
                Button("Deregister This Device…", role: .destructive) { confirming = true }
                    .disabled(registration == nil || deregistering)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(deregistering)
        .task {
            if initialRegistration != nil { return }
            do { confirmation = try await model.deviceRegistration(for: account) }
            catch is CancellationError {}
            catch { issue = error.localizedDescription }
        }
        .alert("Deregister This Device?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Deregister", role: .destructive, action: deregister)
        } message: {
            Text("Audible will revoke the device registration for \(account.name). Sign in again to use Audible with this profile.")
        }
    }

    private func deregister() {
        guard let confirmation else { return }
        deregistering = true
        issue = nil
        Task {
            defer { deregistering = false }
            do {
                try await model.deregisterDevice(for: account, expected: confirmation)
                dismiss()
            } catch {
                issue = error.localizedDescription
                if error as? AudibleError == .deviceDeregistrationConfirmation { self.confirmation = nil }
            }
        }
    }
}
