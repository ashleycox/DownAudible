import SwiftUI

struct AudibleSignInView: View {
    private enum Method: String, CaseIterable {
        case browser = "Web Browser"
        case credentials = "Enter Credentials"
        case androidBrowser = "Android Browser (Advanced)"
    }

    private enum Field: Hashable {
        case address, username, answer
    }

    private struct PendingChallenge {
        let challenge: AudibleSignInChallenge
        let response: CheckedContinuation<String, any Error>

        var instructions: String {
            switch challenge.kind {
            case .otp: "Enter the one-time password from your authenticator app or verification message."
            case .cvf: "Enter the verification code Amazon sent to your email address or phone."
            case .captcha: "Enter the characters in the image. You can cancel and use Web Browser if you need another way to verify."
            case .approval: "Approve the sign-in in Amazon’s notification, then click Continue."
            }
        }

        var answerLabel: String {
            switch challenge.kind {
            case .otp: "One-time password"
            case .cvf: "Verification code"
            case .captcha: "Characters in the image"
            case .approval: ""
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let model: WorkspaceModel
    let addingAccount: Bool
    private let androidAccount: SavedAudibleAccount?

    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var challengeFocused: Bool
    @AccessibilityFocusState private var issueFocused: Bool
    @State private var method: Method = .browser
    @State private var marketplace: AudibleMarketplace
    @State private var accountName: String
    @State private var legacyUsername = false
    @State private var attempt: AudibleSignIn?
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var answer = ""
    @State private var pendingChallenge: PendingChallenge?
    @State private var credentialTask: Task<Void, Never>?
    @State private var issue: WorkspaceModel.Notice?
    private let reconnecting: Bool

    init(model: WorkspaceModel, addingAccount: Bool = false, androidAccount: SavedAudibleAccount? = nil) {
        self.model = model
        self.addingAccount = addingAccount
        self.androidAccount = androidAccount
        let account = androidAccount ?? model.activeAccount
        reconnecting = !addingAccount && account != nil
        _marketplace = State(initialValue: account?.marketplace ?? model.marketplace)
        _accountName = State(initialValue: addingAccount ? (androidAccount.map { $0.name + " (Android)" } ?? "") : (account?.name ?? ""))
        _method = State(initialValue: androidAccount == nil ? .browser : .androidBrowser)
    }

    #if HELP_SCREENSHOTS
    init(model: WorkspaceModel, demoCredentials: Bool, demoAndroid: Bool = false, attempt: AudibleSignIn? = nil) {
        self.init(model: model, addingAccount: true)
        _attempt = State(initialValue: attempt)
        if demoCredentials {
            _method = State(initialValue: .credentials)
            _accountName = State(initialValue: "Demo Account")
            _username = State(initialValue: "email@example.com")
            _password = State(initialValue: "password12345")
        } else if demoAndroid {
            _method = State(initialValue: .androidBrowser)
        }
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(signInTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if let pendingChallenge {
                challengeForm(pendingChallenge)
            } else if let attempt {
                browserForm(attempt)
                    .disabled(model.signInBusy)
            } else {
                accountForm
                    .disabled(model.signInBusy || credentialTask != nil)
            }

            if let issue {
                Label(issue.message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(issue.title). \(issue.message)")
                    .accessibilityFocused($issueFocused)
                    .onAppear { issueFocused = true }
            }

            HStack {
                if model.signInBusy && pendingChallenge == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Signing in")
                        .appHelp("DownAudible is waiting for the sign-in request.")
                }
                if attempt != nil {
                    Button("Start Again", action: resetBrowser)
                        .keyboardShortcut("n", modifiers: [.control, .shift])
                        .disabled(model.signInBusy)
                        .appHelp("Clear the browser address and return to the sign-in options.")
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.signInBusy && credentialTask == nil)
                    .appHelp("Close the sign-in sheet.")

                signInButton
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(model.signInBusy)
        .onChange(of: method) {
            password = ""
            issue = nil
            if method == .credentials { focusedField = .username }
        }
        .onDisappear {
            resetBrowser()
            cancelCredentials()
        }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if reconnecting {
                LabeledContent("Account", value: accountName)
                LabeledContent("Marketplace", value: marketplace.displayName)
            } else {
                LabeledContent("Account name") {
                    TextField("Account name", text: $accountName, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .appHelp("Enter a label that will identify this account in DownAudible.")
                }
                if androidAccount != nil {
                    LabeledContent("Marketplace", value: marketplace.displayName)
                } else {
                    Picker("Marketplace", selection: $marketplace) {
                        ForEach(AudibleMarketplace.allCases) { marketplace in
                            Text(marketplace.displayName).tag(marketplace)
                        }
                    }
                    .appHelp("Select the Audible store where this account’s library is held.")
                }
            }
            if marketplace.supportsLegacySignIn && method != .androidBrowser {
                Toggle("Sign in with a legacy Audible username", isOn: $legacyUsername)
                    .toggleStyle(.checkbox)
                    .appHelp("Use an older Audible username account when the marketplace supports it.")
            }

            if androidAccount == nil {
                Picker("Sign-in method", selection: $method) {
                    ForEach(reconnecting ? [.browser, .credentials] : Method.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .appHelp("Choose where to enter your sign-in details.")
            }

            if method == .androidBrowser {
                Text(androidInstructions).foregroundStyle(.secondary)
            }

            if method == .credentials {
                let usernameLabel = usesLegacyUsername ? "Audible username" : "Amazon email or phone"
                TextField(usernameLabel, text: $username)
                    .accessibilityLabel(usernameLabel)
                    .textContentType(.username)
                    .focused($focusedField, equals: .username)
                SecureField("Password", text: $password)
                    .accessibilityLabel("Password")
                    .textContentType(.password)
            }
        }
    }

    private var signInTitle: String {
        guard androidAccount != nil else { return "Sign In to Audible" }
        return addingAccount ? "Add Separate Android Profile" : "Reconnect as Android"
    }

    private var androidInstructions: String {
        if let androidAccount {
            return addingAccount
                ? "Sign in to the same Audible account as \(androidAccount.name) to add a separate DownAudible profile. Widevine starts off."
                : "Sign in to the same Audible account to keep this DownAudible profile and its file matches. Widevine starts off."
        }
        return "Use your Amazon sign-in to create a compatible Android registration. You can enable Widevine separately in Accounts."
    }

    private func browserForm(_ attempt: AudibleSignIn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in through your browser. A blank page or a “Page Not Found” message at the end is expected.")
            Text("Copy the full address of that page from your browser’s address bar and paste it into **Browser address** below.")
            Button("Open Sign-In Page", systemImage: "safari") {
                focusedField = .address
                openURL(attempt.url)
            }
            .keyboardShortcut("b", modifiers: [.control, .shift])
            .appHelp("Open the Audible sign-in page in your default browser.")

            SecureField("Browser address", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Browser address")
                .focused($focusedField, equals: .address)
                .appHelp("Paste the full address of the final browser page, even if it says Page Not Found.")
        }
    }

    private func challengeForm(_ pending: PendingChallenge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.instructions)
                .accessibilityFocused($challengeFocused)
            if let imageURL = pending.challenge.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().accessibilityLabel("Loading verification image")
                    case .success(let image):
                        image.resizable().scaledToFit().frame(maxHeight: 100)
                            .accessibilityLabel("Verification image")
                    case .failure:
                        Text("The verification image could not be loaded.")
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            if pending.challenge.kind != .approval {
                SecureField(pending.answerLabel, text: $answer)
                    .accessibilityLabel(pending.answerLabel)
                    .focused($focusedField, equals: .answer)
            }
        }
        .onAppear {
            if pending.challenge.kind == .approval {
                challengeFocused = true
            } else {
                focusedField = .answer
            }
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        if let pendingChallenge {
            Button("Continue", action: submitAnswer)
                .disabled(pendingChallenge.challenge.kind != .approval && trimmed(answer).isEmpty)
        } else if let attempt {
            Button("Sign In") { finish(attempt) }
                .disabled(model.signInBusy || trimmed(address).isEmpty)
                .appHelp("Finish connecting the account with the address from your browser.")
        } else if method == .credentials {
            Button("Sign In", action: signInWithCredentials)
                .disabled(model.signInBusy || credentialTask != nil || trimmed(username).isEmpty || password.isEmpty)
        } else {
            Button("Continue", action: beginBrowser)
                .disabled(model.signInBusy || credentialTask != nil)
                .appHelp("Prepare the browser sign-in page for the selected marketplace.")
        }
    }

    private var usesLegacyUsername: Bool {
        method != .androidBrowser && legacyUsername && marketplace.supportsLegacySignIn
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginBrowser() {
        issue = nil
        Task {
            guard model.signIn == nil else {
                issue = WorkspaceModel.Notice(
                    title: "Sign-in already open",
                    message: "Finish signing in from the other window."
                )
                return
            }
            await model.beginSignIn(
                marketplace: marketplace, name: accountName,
                legacyUsername: usesLegacyUsername, addingAccount: addingAccount,
                deviceProfile: method == .androidBrowser ? .android : nil, matching: androidAccount
            )
            attempt = model.signIn
            if attempt == nil { readIssue() }
        }
    }

    private func finish(_ attempt: AudibleSignIn) {
        issue = nil
        Task {
            if await model.finishSignIn(attempt, redirect: address) {
                address = ""
                dismiss()
            } else {
                if model.signIn == nil {
                    self.attempt = nil
                    address = ""
                }
                readIssue()
            }
        }
    }

    private func signInWithCredentials() {
        guard credentialTask == nil else { return }
        issue = nil
        let submittedPassword = password
        password = ""
        credentialTask = Task {
            defer { credentialTask = nil }
            do {
                try Task.checkCancellation()
                try await model.signInWithCredentials(
                    marketplace: marketplace, name: accountName, legacyUsername: usesLegacyUsername,
                    addingAccount: addingAccount, username: trimmed(username), password: submittedPassword
                ) { challenge in
                    try await requestAnswer(for: challenge)
                }
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                issue = WorkspaceModel.Notice(title: "Couldn’t sign in", message: error.localizedDescription)
            }
        }
    }

    private func requestAnswer(for challenge: AudibleSignInChallenge) async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { response in
            pendingChallenge = PendingChallenge(challenge: challenge, response: response)
        }
    }

    private func submitAnswer() {
        guard let pendingChallenge else { return }
        let response = pendingChallenge.challenge.kind == .approval ? "" : trimmed(answer)
        answer = ""
        self.pendingChallenge = nil
        pendingChallenge.response.resume(returning: response)
    }

    private func cancel() {
        cancelCredentials()
        dismiss()
    }

    private func cancelCredentials() {
        credentialTask?.cancel()
        pendingChallenge?.response.resume(throwing: CancellationError())
        pendingChallenge = nil
        password = ""
        answer = ""
    }

    private func resetBrowser() {
        if let attempt { model.cancelBrowserSignIn(attempt) }
        attempt = nil
        address = ""
        issue = nil
    }

    private func readIssue() {
        issue = model.notice
        model.notice = nil
    }
}
