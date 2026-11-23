import Foundation
import Security

nonisolated struct ShelfSettings: Codable, Sendable {
    var server = ""
    var libraryID = ""
    var libraryName = ""
    var folderID = ""
    var folderName = ""
    var autoUpload = false
    var includePDFs = false

    var destination: ShelfDestination? {
        guard !server.isEmpty, !libraryID.isEmpty, !folderID.isEmpty else { return nil }
        return ShelfDestination(server: server, library: libraryID, folder: folderID)
    }
}

nonisolated struct ShelfDestination: Codable, Equatable, Sendable {
    let server: String
    let library: String
    let folder: String
}

nonisolated struct ShelfLibrary: Decodable, Identifiable, Sendable {
    struct Folder: Decodable, Identifiable, Sendable {
        let id: String
        let fullPath: String
    }

    let id: String
    let name: String
    let mediaType: String
    let folders: [Folder]
}

nonisolated struct ShelfBook: Codable, Sendable {
    let asin: String
    let title: String
    let authors: [String]
    let series: String?
    let audio: [URL]
    let cover: URL?
    let pdf: URL?

    var files: [URL] { audio + [cover, pdf].compactMap { $0 } }

    static func supports(_ url: URL) -> Bool { ["m4b", "m4a", "mp3"].contains(url.pathExtension.lowercased()) }
}

nonisolated enum ShelfError: LocalizedError {
    case serverURL, secureConnection, token, destination, rejected(Int), invalidResponse, noFiles, fileChanged, editionConflict

    var errorDescription: String? {
        switch self {
        case .serverURL: "Enter the base address of your Audiobookshelf server, including http:// or https://."
        case .secureConnection: "Use HTTPS for Audiobookshelf servers outside the local network."
        case .token: "Enter an Audiobookshelf API token for this server."
        case .destination: "Choose an Audiobookshelf library and folder in Settings."
        case .rejected(let status): "Audiobookshelf returned HTTP \(status). Check the server, token and library folder."
        case .invalidResponse: "Audiobookshelf returned an unexpected response."
        case .noFiles: "Choose an audiobook with saved M4B, M4A or MP3 audio."
        case .fileChanged: "A saved file changed. Queue the book again from Library."
        case .editionConflict: "A different edition with this title and author is already in Audiobookshelf."
        }
    }
}

nonisolated struct ShelfFileStamp: Codable, Equatable, Sendable {
    private let size: Int
    private let modified: Date

    init(_ file: URL) throws {
        let values = try URL(filePath: file.path).resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              let modified = values.contentModificationDate else { throw ShelfError.noFiles }
        self.size = size
        self.modified = modified
    }
}

nonisolated enum ShelfCredentials {
    private static let service = DownAudibleIdentity.audibleKeychainService() + ".audiobookshelf"

    static func read(_ server: String) throws -> String? {
        var query = attributes(server)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CocoaError(.fileReadNoPermission) }
        return (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func save(_ token: String, server: String) throws {
        let query = attributes(server)
        let data = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(data) { current, _ in current } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
    }

    static func remove(_ server: String) throws {
        let status = SecItemDelete(attributes(server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CocoaError(.fileWriteNoPermission) }
    }

    private static func attributes(_ server: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
    }
}

nonisolated struct ShelfClient: Sendable {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    let server: URL
    let token: String

    init(server: String, token: String) throws {
        self.server = try Self.serverURL(server)
        guard !token.isEmpty, token.utf8.count <= 8_192, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ShelfError.token
        }
        self.token = token
    }

    static func serverURL(_ address: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil
        else { throw ShelfError.serverURL }
        if scheme == "http", !isLocalHost(host) { throw ShelfError.secureConnection }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let url = components.url else { throw ShelfError.serverURL }
        return url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name == "localhost." { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, name, &ipv4) == 1 {
            return withUnsafeBytes(of: ipv4) { bytes in
                bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                    || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
            }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, name, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            let loopback = bytes.last == 1 && bytes.dropLast().allSatisfy { $0 == 0 }
            return loopback || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
    }

    @concurrent func libraries() async throws -> [ShelfLibrary] {
        struct Response: Decodable { let libraries: [ShelfLibrary] }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let data = try await get(request("api/libraries"), session: session)
        return try JSONDecoder().decode(Response.self, from: data).libraries.filter { $0.mediaType == "book" }
    }

    @concurrent func upload(_ book: ShelfBook, to destination: ShelfDestination, stamps: [ShelfFileStamp]) async throws -> Bool {
        guard !book.audio.isEmpty else { throw ShelfError.noFiles }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        if try await exists(book, in: destination.library, session: session) { return false }

        let boundary = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appending(component: "DownAudible-" + boundary)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let body = temporary.appending(component: "Upload.multipart")
        try buildBody(book, destination: destination, boundary: boundary, stamps: stamps, to: body)

        var upload = request("api/upload")
        upload.httpMethod = "POST"
        upload.timeoutInterval = 900
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: upload, fromFile: body)
        try check(response)
        return true
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ShelfError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ShelfError.rejected(response.statusCode) }
    }

    private func get(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func exists(_ book: ShelfBook, in library: String, session: URLSession) async throws -> Bool {
        struct Metadata: Decodable {
            let asin: String?
            let title: String?
            let authorName: String?
            let authors: [Named]?
            struct Named: Decodable { let name: String }
        }
        struct Media: Decodable { let metadata: Metadata }
        struct Item: Decodable { let media: Media }
        struct Hit: Decodable { let libraryItem: Item }
        struct Results: Decodable { let book: [Hit]? }

        guard library.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw ShelfError.destination
        }
        let base = request("api/libraries/\(library)/search")
        guard let url = base.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ShelfError.serverURL
        }
        let title = normal(book.title)
        let authors = normal(book.authors.joined(separator: ", "))
        var conflictingEdition = false
        for term in [book.asin, book.title] where !term.isEmpty {
            components.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "50")]
            var query = base
            query.url = components.url
            let data = try await get(query, session: session)
            let results = try JSONDecoder().decode(Results.self, from: data)
            for hit in results.book ?? [] {
                let item = hit.libraryItem.media.metadata
                let asin = item.asin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !asin.isEmpty, asin.caseInsensitiveCompare(book.asin) == .orderedSame { return true }
                let remote = item.authorName ?? item.authors?.map(\.name).joined(separator: ", ") ?? ""
                guard item.title.map(normal) == title, normal(remote) == authors else { continue }
                if asin.isEmpty || book.asin.isEmpty { return true }
                conflictingEdition = true
            }
        }
        if conflictingEdition { throw ShelfError.editionConflict }
        return false
    }

    private func normal(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func buildBody(
        _ book: ShelfBook, destination: ShelfDestination, boundary: String, stamps: [ShelfFileStamp], to path: URL
    ) throws {
        guard book.files.count == stamps.count else { throw ShelfError.fileChanged }
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: path)
        defer { try? output.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        var fields = [
            ("library", destination.library), ("folder", destination.folder), ("title", book.title),
            ("author", book.authors.joined(separator: ", ")),
        ]
        if let series = book.series { fields.append(("series", series)) }
        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for (index, file) in book.files.enumerated() {
            try Task.checkCancellation()
            guard try ShelfFileStamp(file) == stamps[index] else { throw ShelfError.fileChanged }
            let filename = file.lastPathComponent.map { character in
                character == "\"" || character == "\\" || character.isNewline ? "_" : String(character)
            }.joined()
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\(index)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
            guard try ShelfFileStamp(file) == stamps[index] else { throw ShelfError.fileChanged }
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n")
    }
}
