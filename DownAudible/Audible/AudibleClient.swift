import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization

nonisolated enum AudibleMarketplace: String, Codable, CaseIterable, Identifiable, Sendable {
    case australia = "au"
    case brazil = "br"
    case canada = "ca"
    case france = "fr"
    case germany = "de"
    case india = "in"
    case italy = "it"
    case japan = "jp"
    case spain = "es"
    case unitedKingdom = "uk"
    case unitedStates = "us"

    var id: String { rawValue }

    var supportsLegacySignIn: Bool {
        [.germany, .unitedKingdom, .unitedStates].contains(self)
    }

    var displayName: String {
        switch self {
        case .australia: "Australia"
        case .brazil: "Brazil"
        case .canada: "Canada"
        case .france: "France"
        case .germany: "Germany"
        case .india: "India"
        case .italy: "Italy"
        case .japan: "Japan"
        case .spain: "Spain"
        case .unitedKingdom: "United Kingdom"
        case .unitedStates: "United States"
        }
    }
}

nonisolated struct AudibleSignIn: Sendable {
    let url: URL
    let marketplace: AudibleMarketplace
    fileprivate let serial: String
    fileprivate let verifier: String
    fileprivate let legacyUsername: Bool
}

nonisolated enum AudibleQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, high, normal

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

nonisolated enum AudibleDownloadFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case preferAAX, aaxOnly, aaxcOnly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .preferAAX: "AAX with fallback"
        case .aaxOnly: "AAX only"
        case .aaxcOnly: "AAXC"
        }
    }
}

nonisolated enum AudiblePodcastMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ignore, showSeries, resolveEpisodes

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ignore: "Hide podcasts"
        case .showSeries: "Show podcast series"
        case .resolveEpisodes: "Show individual episodes"
        }
    }
}

nonisolated enum AudibleChapterStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case tree, flat

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tree: "Nested chapters"
        case .flat: "Flat chapter list"
        }
    }
}

nonisolated struct AudibleAPIOptions: Codable, Equatable, Sendable {
    static let availableCoverSizes = [252, 315, 360, 408, 500, 558, 570, 882, 900, 1215]
    var quality: AudibleQuality = .best
    var format: AudibleDownloadFormat = .preferAAX
    var timeout: Int = 45
    var pageSize: Int = 100
    var purchaseStart: Date?
    var purchaseEnd: Date?
    var podcasts: AudiblePodcastMode = .ignore
    var coverSizes: [Int] = []
    var chapterStyle: AudibleChapterStyle = .tree
    var bytesPerSecond: Int = 0
    private var preferWholeBookDownloads: Bool?

    var prefersWholeBookDownloads: Bool {
        get { preferWholeBookDownloads ?? true }
        set { preferWholeBookDownloads = newValue ? nil : false }
    }
}

nonisolated struct AudibleCLIProfile: Decodable, Identifiable, Sendable {
    let name: String
    let authFile: URL
    let marketplace: AudibleMarketplace?
    let isDefault: Bool
    let requiresPassword: Bool

    var id: String { name }
}

nonisolated struct AudibleBook: Codable, Identifiable, Hashable, Sendable {
    enum DownloadUnavailableReason: String, Codable, Sendable {
        case podcastSeries, offlineRestricted, unpublished
    }

    let asin: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let narrators: [String]
    let series: String?
    let seriesSequence: String?
    let publisher: String?
    let description: String?
    let language: String?
    let genres: [String]?
    let releaseDate: String?
    let purchaseDate: String?
    let dateAdded: String?
    let rating: Double?
    let ratingCount: Int?
    let isFinished: Bool?
    let percentComplete: Double?
    let durationSeconds: Int?
    let coverURL: URL?
    let coverImages: [String: URL]?
    let hasPDF: Bool
    let isDownloadable: Bool
    let downloadUnavailableReason: DownloadUnavailableReason?

    var id: String { asin }
}

nonisolated struct AudibleChapter: Decodable, Sendable {
    let startMilliseconds: Int64
    let durationMilliseconds: Int64
    let title: String
}

nonisolated struct AudibleConversionCredentials: Decodable, Sendable {
    var activationBytes: String?
    var contentKey: String?
    var contentIV: String?
}

nonisolated struct AudibleAudioPart: Sendable {
    let audio: URL
    let credentials: AudibleConversionCredentials
    let asin: String
    let originalFilename: String?
}

nonisolated struct AudibleDownload: Sendable {
    let parts: [AudibleAudioPart]

    fileprivate init(parts: [AudibleAudioPart]) throws {
        guard !parts.isEmpty else { throw AudibleError.unavailable }
        self.parts = parts
    }
}

nonisolated struct AudibleExtras: Sendable {
    let covers: [URL]
    let pdf: URL?
    let failed: [String: AudibleError]
    var cover: URL? { covers.first }
}

nonisolated struct AudibleJSONExtras: Sendable {
    let chapters: URL?
    let annotations: URL?
    let failed: [String: AudibleError]
}

nonisolated enum AudibleError: String, Decodable, LocalizedError {
    case activation, activationRequired, authorization, fileAccess, invalidRedirect, keychain, network
    case notSignedIn, service, signInFailed, unavailable, voucherMissing, helperMissing
    case authImport, cliConfig, importPassword, importPasswordIncorrect, importMarketplace, unsupportedLegacySignIn
    case exportPassword, exportFileAccess, helperStart
    case aaxUnavailable, aaxcUnavailable, licenseDenied, licenseEntitlement, licenseThrottled, licenseResponse
    case notFound, notPublished, offlineRestricted, partsUnavailable, requestRejected, podcastSeries, invalidTitle
    case rateLimited, serverUnavailable, timeout, sourceRejected, downloadResponse, incompleteResponse
    case diskFull, stagingFileAccess, extraUnavailable

    var errorDescription: String? {
        switch self {
        case .activation: "Audible could not provide the activation bytes. You can enter them in Convert Files."
        case .activationRequired: "Sign in to Audible or enter your activation bytes in Convert Files."
        case .authorization: "Audible did not accept your saved sign-in. Sign out of this account in Settings > Accounts, then sign in again."
        case .fileAccess: "DownAudible could not open the selected file. Check that it still exists and that you can open it in Finder."
        case .invalidRedirect: "Copy the full address from your browser after signing in to Amazon."
        case .keychain: "DownAudible could not access your credentials in Keychain."
        case .network: "DownAudible lost its connection while contacting Audible. Check your internet connection and retry."
        case .notSignedIn: "Sign in to Audible to continue."
        case .service: "DownAudible could not complete the request. Try again."
        case .signInFailed: "Amazon could not finish signing you in. Start again with a new sign-in link."
        case .unavailable: "Audible did not provide a download for this title."
        case .voucherMissing: "DownAudible could not find a license for this AAXC file. Keep its .voucher file beside it or match it to your Audible library."
        case .helperMissing: "DownAudible’s Audible helper is missing. Reinstall DownAudible and try again."
        case .helperStart: "DownAudible could not start its Audible helper. Reopen DownAudible and try again."
        case .authImport: "DownAudible could not read this Audible CLI authentication file."
        case .cliConfig: "Choose an Audible CLI config.toml that points to at least one existing authentication file."
        case .importPassword: "Enter the password used to encrypt this Audible CLI authentication file."
        case .importPasswordIncorrect: "DownAudible could not unlock this account file. Check the password or export a new copy of the file."
        case .importMarketplace: "Choose the Audible marketplace for this authentication file."
        case .unsupportedLegacySignIn: "Audible username sign-in is available in the United Kingdom, United States and Germany."
        case .exportPassword: "Enter a password to protect the account file."
        case .exportFileAccess: "DownAudible could not save the account file. Choose a folder you can write to in Finder."
        case .aaxUnavailable: "Audible did not provide an AAX download. Choose AAX with fallback or AAXC in Settings > Downloads and retry."
        case .aaxcUnavailable: "Audible did not provide a downloadable AAXC version for this title. If you have a local copy, open it in Convert Files."
        case .licenseDenied: "Audible refused the download license. Check that the title is still available to this account in the Audible app."
        case .licenseEntitlement: "Audible could not confirm download rights for this account. Check whether the title is still in your purchases or subscription."
        case .licenseThrottled: "Audible is limiting download licenses for this account. Wait before retrying. If it continues on individual titles, sign out and sign in again."
        case .licenseResponse: "Audible returned an unreadable download license. Try again later."
        case .notFound: "Audible could not find what DownAudible requested. Check your account and marketplace, then refresh the library."
        case .notPublished: "This title has not been released. Refresh your library after the release date."
        case .offlineRestricted: "Audible does not allow offline downloads of this title for this account. Check that it is still in your purchases or subscription."
        case .partsUnavailable: "Audible did not provide the audio parts for this book. Refresh your library and retry."
        case .podcastSeries: "Choose an individual podcast episode to download."
        case .invalidTitle: "Audible needs a valid title identifier. Refresh the list and choose the title again."
        case .requestRejected: "Audible rejected the request. Check the account and marketplace. If the problem continues, sign out and sign in again."
        case .rateLimited: "Audible received too many requests. Wait before retrying. For a batch, lower Simultaneous downloads in Settings > Jobs."
        case .serverUnavailable: "The Audible service returned a server error. Try again later."
        case .timeout: "The Audible request timed out. Check your connection or increase Request timeout in Settings > Jobs."
        case .sourceRejected: "The download server refused to send the file. Retry or check that it is still available in Audible."
        case .downloadResponse: "The download server sent an unexpected response instead of the requested file. Try again later."
        case .incompleteResponse: "The download arrived incomplete. Use Retry in Downloads to resume any valid partial file."
        case .diskFull: "There is not enough space to write the file. Free up space or choose another destination."
        case .stagingFileAccess: "DownAudible could not access its temporary download files. Reconnect the destination disk or choose a writable folder."
        case .extraUnavailable: "Audible did not list this file for the title."
        }
    }
}

nonisolated struct AudibleClient: Sendable {
    private let vault: AudibleKeychain
    private let helperURL: URL?
    private let profileID: UUID?
    let options: AudibleAPIOptions

    init(profileID: UUID? = nil, options: AudibleAPIOptions = .init(), helperURL: URL? = nil) {
        self.init(profileID: profileID, options: options, helperURL: helperURL, vault: AudibleKeychain())
    }

    private init(profileID: UUID?, options: AudibleAPIOptions, helperURL: URL?, vault: AudibleKeychain) {
        self.profileID = profileID
        self.options = options
        self.helperURL = helperURL
        self.vault = vault
    }

    static var defaultCLIConfig: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["AUDIBLE_CONFIG_DIR"]
        let directory: URL
        if let configured, !configured.isEmpty {
            directory = URL(filePath: (configured as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        } else {
            directory = home.appending(path: ".audible", directoryHint: .isDirectory)
        }
        return directory.appending(path: "config.toml", directoryHint: .notDirectory)
    }

    func scoped(to profileID: UUID?, options: AudibleAPIOptions? = nil) -> AudibleClient {
        AudibleClient(profileID: profileID, options: options ?? self.options, helperURL: helperURL, vault: vault)
    }

    @concurrent func beginSignIn(
        marketplace: AudibleMarketplace, legacyUsername: Bool = false
    ) async throws -> AudibleSignIn {
        guard !legacyUsername || marketplace.supportsLegacySignIn else { throw AudibleError.unsupportedLegacySignIn }
        let result: SignInLink = try await run(.init(
            command: .beginSignIn, marketplace: marketplace.rawValue, legacyUsername: legacyUsername
        ))
        return AudibleSignIn(
            url: result.url, marketplace: marketplace, serial: result.serial, verifier: result.verifier,
            legacyUsername: legacyUsername
        )
    }

    @concurrent func completeSignIn(_ attempt: AudibleSignIn, redirectURL: URL) async throws {
        let result: Session = try await run(.init(
            command: .completeSignIn,
            marketplace: attempt.marketplace.rawValue,
            redirect: redirectURL.absoluteString,
            serial: attempt.serial,
            verifier: attempt.verifier,
            legacyUsername: attempt.legacyUsername
        ))
        try Task.checkCancellation()
        try vault.save(Data(result.session.utf8), for: sessionAccount)
    }

    @concurrent func cliProfiles(config: URL) async throws -> [AudibleCLIProfile] {
        try await run(.init(command: .cliProfiles, file: config.path))
    }

    @concurrent func inspectAuthFile(_ url: URL) async throws -> Bool {
        try await run(.init(command: .inspectAuthFile, file: url.path))
    }

    @concurrent func importAuthFile(
        _ url: URL, password: String?, marketplace: AudibleMarketplace? = nil
    ) async throws -> AudibleMarketplace {
        let result: ImportedSession = try await run(.init(
            command: .importAuthFile, marketplace: marketplace?.rawValue, file: url.path, password: password
        ))
        try Task.checkCancellation()
        try vault.save(Data(result.session.utf8), for: sessionAccount)
        return result.marketplace
    }

    func hasSession() throws -> Bool {
        try vault.load(sessionAccount) != nil
    }

    func signOut() throws {
        try vault.remove(sessionAccount)
    }

    @concurrent func library() async throws -> [AudibleBook] {
        try await run(.init(command: .library, session: session()))
    }

    @concurrent func wishlist() async throws -> [AudibleBook] {
        try await run(.init(command: .wishlist, session: session()))
    }

    @concurrent func searchCatalog(_ query: String) async throws -> [AudibleBook] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await run(.init(command: .catalog, session: session(), query: query))
    }

    @concurrent func addToWishlist(_ asins: [String]) async throws -> [String: AudibleError] {
        try await run(.init(command: .wishlistAdd, session: session(), asins: asins))
    }

    @concurrent func removeFromWishlist(_ asins: [String]) async throws -> [String: AudibleError] {
        try await run(.init(command: .wishlistRemove, session: session(), asins: asins))
    }

    @concurrent func activationBytes(refresh: Bool = false) async throws -> String {
        let snapshot = try session()
        let result: Activation = try await run(.init(
            command: .activation, session: snapshot, refreshActivation: refresh
        ))
        try Task.checkCancellation()
        try vault.updateSession(from: Data(snapshot.utf8), to: Data(result.session.utf8), for: sessionAccount)
        return result.activationBytes
    }

    @concurrent func exportEncryptedAuthFile(to destination: URL, password: String) async throws {
        guard !password.isEmpty else { throw AudibleError.exportPassword }
        let contents: String = try await run(.init(command: .exportAuthFile, session: session(), password: password))
        try Task.checkCancellation()
        do {
            try Data(contents.utf8).write(to: destination, options: .atomic)
        } catch CocoaError.fileWriteOutOfSpace {
            throw AudibleError.diskFull
        } catch {
            throw AudibleError.exportFileAccess
        }
    }

    @concurrent func chapters(for book: AudibleBook) async throws -> [AudibleChapter] {
        try await run(.init(command: .chapters, session: session(), asin: book.asin))
    }

    @concurrent func download(
        _ book: AudibleBook,
        to stagingDirectory: URL,
        format: AudibleDownloadFormat? = nil,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> AudibleDownload {
        var downloadOptions = options
        downloadOptions.format = format ?? options.format
        let result: DownloadResponse = try await run(.init(
            command: .download,
            session: session(),
            asin: book.asin,
            directory: stagingDirectory.path,
            options: downloadOptions
        ), progress: progress)
        let parts = try result.parts.map { part in
            try Task.checkCancellation()
            let audio = try stagedFile(part.file, in: stagingDirectory)
            if let key = part.credentials.contentKey, let iv = part.credentials.contentIV {
                try cacheVoucher(KeyAndIV(key: key, iv: iv), for: audio)
            }
            return AudibleAudioPart(
                audio: audio, credentials: part.credentials, asin: part.asin, originalFilename: part.originalFilename
            )
        }
        return try AudibleDownload(parts: parts)
    }

    @concurrent func downloadExtras(
        _ book: AudibleBook,
        to directory: URL,
        pdf: Bool,
        cover: Bool
    ) async throws -> AudibleExtras {
        let getPDF = pdf && book.hasPDF
        let coverURL = cover ? book.coverURL : nil
        guard getPDF || cover else { return AudibleExtras(covers: [], pdf: nil, failed: [:]) }
        let result: ExtrasResponse = try await run(.init(
            command: .extras,
            session: session(),
            asin: book.asin,
            directory: directory.path,
            cover: cover,
            coverURL: coverURL,
            coverImages: cover ? book.coverImages : nil,
            pdf: getPDF
        ))
        return try AudibleExtras(
            covers: result.covers.map { try stagedFile($0, in: directory) },
            pdf: result.pdf.map { try stagedFile($0, in: directory) },
            failed: result.failed
        )
    }

    @concurrent func downloadJSONExtras(
        _ book: AudibleBook, to directory: URL, chapters: Bool, annotations: Bool
    ) async throws -> AudibleJSONExtras {
        guard chapters || annotations else { return AudibleJSONExtras(chapters: nil, annotations: nil, failed: [:]) }
        let result: JSONExtrasResponse = try await run(.init(
            command: .jsonExtras, session: session(), asin: book.asin, directory: directory.path,
            chapters: chapters, annotations: annotations
        ))
        return try AudibleJSONExtras(
            chapters: result.chapters.map { try stagedFile($0, in: directory) },
            annotations: result.annotations.map { try stagedFile($0, in: directory) },
            failed: result.failed
        )
    }

    @concurrent func conversionCredentials(
        for book: AudibleBook?,
        audio: URL,
        partASIN: String? = nil
    ) async throws -> AudibleConversionCredentials {
        switch audio.pathExtension.lowercased() {
        case "aaxc":
            let keychainKey = try voucherID(for: audio)
            if let data = try vault.load(keychainKey),
               let voucher = try? JSONDecoder().decode(KeyAndIV.self, from: data),
               voucher.isValid {
                return voucher.asCredentials
            }
            let sidecar = audio.deletingPathExtension().appendingPathExtension("voucher")
            if let data = try? Data(contentsOf: sidecar),
               let voucher = try? JSONDecoder().decode(LegacyVoucher.self, from: data),
               voucher.contentLicense.licenseResponse.isValid {
                let key = voucher.contentLicense.licenseResponse
                if let encoded = try? JSONEncoder().encode(key) {
                    try? vault.save(encoded, for: keychainKey)
                }
                return key.asCredentials
            }
            if let asin = partASIN ?? book?.asin, try hasSession() {
                let result: AudibleConversionCredentials = try await run(.init(
                    command: .voucher, session: session(), asin: asin
                ))
                if let key = result.contentKey, let iv = result.contentIV {
                    try cacheVoucher(KeyAndIV(key: key, iv: iv), for: audio)
                    return result
                }
            }
            throw AudibleError.voucherMissing
        case "aax":
            do {
                return AudibleConversionCredentials(activationBytes: try await activationBytes())
            } catch AudibleError.notSignedIn {
                throw AudibleError.activationRequired
            }
        default:
            return AudibleConversionCredentials()
        }
    }

    private var sessionAccount: AudibleKeychain.Account { .session(profileID) }

    private func session() throws -> String {
        guard let data = try vault.load(sessionAccount), let session = String(data: data, encoding: .utf8) else {
            throw AudibleError.notSignedIn
        }
        return session
    }

    private func stagedFile(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw AudibleError.service }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    private func cacheVoucher(_ voucher: KeyAndIV, for audio: URL) throws {
        guard voucher.isValid else { throw AudibleError.voucherMissing }
        try vault.save(JSONEncoder().encode(voucher), for: voucherID(for: audio))
    }

    private func voucherID(for audio: URL) throws -> AudibleKeychain.Account {
        let handle = try FileHandle(forReadingFrom: audio)
        defer { try? handle.close() }
        var hash = SHA256()
        hash.update(data: try handle.read(upToCount: 64 * 1024) ?? Data())
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        hash.update(data: Data(String(size).utf8))
        return .voucher(hash.finalize().map { String($0, radix: 16).leftPaddedHex }.joined())
    }

    @concurrent private func run<Result: Decodable & Sendable>(
        _ request: Request,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Result {
        #if arch(x86_64)
        let helperArchitecture = "x86_64"
        #else
        let helperArchitecture = "arm64"
        #endif
        let executable = helperURL ?? Bundle.main.resourceURL?
            .appending(path: "AudibleSupport/\(helperArchitecture)/audible-helper", directoryHint: .notDirectory)
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AudibleError.helperMissing
        }
        var request = request
        request.options = request.options ?? options
        return try await AudibleProcess().run(executable, request: request, progress: progress)
    }
}

private extension String {
    nonisolated var leftPaddedHex: String { count == 1 ? "0" + self : self }
}

private nonisolated struct Request: Encodable, Sendable {
    enum Command: String, Encodable, Sendable {
        case beginSignIn, completeSignIn, library, download, chapters, extras, jsonExtras, activation, voucher
        case cliProfiles, inspectAuthFile, importAuthFile
        case wishlist, catalog, wishlistAdd, wishlistRemove, exportAuthFile
    }

    let command: Command
    var marketplace: String?
    var session: String?
    var query: String?
    var asins: [String]?
    var refreshActivation: Bool?
    var redirect: String?
    var serial: String?
    var verifier: String?
    var legacyUsername: Bool?
    var file: String?
    var password: String?
    var asin: String?
    var directory: String?
    var cover: Bool?
    var coverURL: URL?
    var coverImages: [String: URL]?
    var pdf: Bool?
    var chapters: Bool?
    var annotations: Bool?
    var options: AudibleAPIOptions?
}

private nonisolated struct SignInLink: Decodable, Sendable {
    let url: URL
    let serial: String
    let verifier: String
}

private nonisolated struct Session: Decodable, Sendable {
    let session: String
}

private nonisolated struct ImportedSession: Decodable, Sendable {
    let session: String
    let marketplace: AudibleMarketplace
}

private nonisolated struct Activation: Decodable, Sendable {
    let activationBytes: String
    let session: String
}

private nonisolated struct DownloadResponse: Decodable, Sendable {
    struct Part: Decodable, Sendable {
        let file: String
        let asin: String
        let credentials: AudibleConversionCredentials
        let originalFilename: String?
    }

    let parts: [Part]
}

private nonisolated struct ExtrasResponse: Decodable, Sendable {
    let covers: [String]
    let pdf: String?
    let failed: [String: AudibleError]
}

private nonisolated struct JSONExtrasResponse: Decodable, Sendable {
    let chapters: String?
    let annotations: String?
    let failed: [String: AudibleError]
}

private nonisolated struct KeyAndIV: Codable {
    let key: String
    let iv: String

    var isValid: Bool { [key, iv].allSatisfy { $0.utf8.count == 32 && $0.utf8.allSatisfy(Self.isHex) } }
    var asCredentials: AudibleConversionCredentials { .init(contentKey: key, contentIV: iv) }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

private nonisolated struct LegacyVoucher: Decodable {
    struct ContentLicense: Decodable {
        let licenseResponse: KeyAndIV

        enum CodingKeys: String, CodingKey {
            case licenseResponse = "license_response"
        }
    }

    let contentLicense: ContentLicense

    enum CodingKeys: String, CodingKey {
        case contentLicense = "content_license"
    }
}

private nonisolated final class AudibleProcess: Sendable {
    private let child = Mutex<Process?>(nil)

    @concurrent func run<Result: Decodable & Sendable>(
        _ executable: URL,
        request: Request,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> Result {
        try await withTaskCancellationHandler {
            let process = Process()
            let exit = ProcessExit()
            let input = Pipe()
            let writer = input.fileHandleForWriting
            let output = Pipe()
            let reader = output.fileHandleForReading
            // The helper can exit during cancellation or startup while the request is being written.
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw AudibleError.service }
            process.executableURL = executable
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in exit.signal() }

            let chunks = AsyncStream<Data> { continuation in
                reader.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        continuation.finish()
                    } else {
                        continuation.yield(data)
                    }
                }
                continuation.onTermination = { _ in reader.readabilityHandler = nil }
            }

            defer {
                let didLaunch = child.withLock { active in
                    let launched = active != nil
                    if active?.isRunning == true { active?.terminate() }
                    active = nil
                    return launched
                }
                if didLaunch { await exit.wait() }
                reader.readabilityHandler = nil
                try? reader.close()
                try? writer.close()
            }

            do {
                try child.withLock { active in
                    try Task.checkCancellation()
                    try process.run()
                    active = process
                }
            } catch {
                try Task.checkCancellation()
                throw AudibleError.helperStart
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            do {
                try Task.checkCancellation()
                try writer.write(contentsOf: encoder.encode(request))
                try writer.close()
            } catch {
                try Task.checkCancellation()
                throw AudibleError.service
            }

            let decoder = JSONDecoder()
            var pending = Data()
            for await chunk in chunks {
                try Task.checkCancellation()
                pending.append(chunk)
                while let lineEnd = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<lineEnd]
                    try Task.checkCancellation()
                    guard let message = try? decoder.decode(WireMessage<Result>.self, from: line) else {
                        throw AudibleError.service
                    }
                    if let error = message.error { throw error }
                    if let result = message.result { return result }
                    if let fraction = message.progress { await progress(fraction) }
                    pending.removeSubrange(...lineEnd)
                }
            }
            try Task.checkCancellation()
            throw AudibleError.service
        } onCancel: {
            child.withLock { active in
                if active?.isRunning == true { active?.terminate() }
            }
        }
    }

    private struct WireMessage<Result: Decodable>: Decodable {
        let progress: Double?
        let result: Result?
        let error: AudibleError?
    }
}

private nonisolated final class ProcessExit: Sendable {
    private enum State {
        case running
        case waiting(CheckedContinuation<Void, Never>)
        case exited
    }

    private let state = Mutex(State.running)

    func signal() {
        let previous = state.withLock { state in
            let previous = state
            state = .exited
            return previous
        }
        if case .waiting(let continuation) = previous {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyExited = state.withLock { state in
                if case .exited = state { return true }
                state = .waiting(continuation)
                return false
            }
            if alreadyExited { continuation.resume() }
        }
    }
}

private nonisolated final class AudibleKeychain: Sendable {
    private let mutex = Mutex(())
    private let service = DownAudibleIdentity.audibleKeychainService()

    enum Account {
        case session(UUID?)
        case voucher(String)

        var name: String {
            switch self {
            case .session(let id): id.map { "Audible session " + $0.uuidString } ?? "Audible session"
            case .voucher(let digest): "AAXC voucher " + digest
            }
        }
    }

    func load(_ account: Account) throws -> Data? {
        try mutex.withLock { _ in try read(account) }
    }

    func save(_ data: Data, for account: Account) throws {
        try mutex.withLock { _ in try write(data, account: account) }
    }

    func remove(_ account: Account) throws {
        try mutex.withLock { _ in
            let status = SecItemDelete(query(for: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AudibleError.keychain }
        }
    }

    func updateSession(from old: Data, to new: Data, for account: Account) throws {
        guard new != old else { return }
        try mutex.withLock { _ in
            if try read(account) == old {
                try write(new, account: account)
            }
        }
    }

    private func query(for account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.name
        ]
    }

    private func read(_ account: Account) throws -> Data? {
        var item = query(for: account)
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AudibleError.keychain }
        return data
    }

    private func write(_ data: Data, account: Account) throws {
        let item = query(for: account)
        let values = [kSecValueData as String: data]
        let updated = SecItemUpdate(item as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw AudibleError.keychain }
        let added = SecItemAdd(item.merging(values) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw AudibleError.keychain }
    }
}
