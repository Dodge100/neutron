import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

struct StoredOAuthCredential: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let tokenType: String?
    let scope: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-60) <= Date()
    }
}

struct StoredS3Credential: Codable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
}

final class CloudCredentialStore {
    static let shared = CloudCredentialStore()

    private let service = "com.neutron.cloud.credentials"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func loadOAuthCredential(for accountID: UUID) -> StoredOAuthCredential? {
        loadValue(StoredOAuthCredential.self, account: accountID, key: "oauth-session")
    }

    func saveOAuthCredential(_ credential: StoredOAuthCredential, for accountID: UUID) throws {
        try saveValue(credential, account: accountID, key: "oauth-session")
    }

    func deleteOAuthCredential(for accountID: UUID) throws {
        try deleteValue(account: accountID, key: "oauth-session")
    }

    func loadOAuthClientSecret(for accountID: UUID) -> String? {
        loadString(account: accountID, key: "oauth-client-secret")
    }

    func saveOAuthClientSecret(_ clientSecret: String, for accountID: UUID) throws {
        try saveString(clientSecret, account: accountID, key: "oauth-client-secret")
    }

    func deleteOAuthClientSecret(for accountID: UUID) throws {
        try deleteValue(account: accountID, key: "oauth-client-secret")
    }

    func loadS3Credential(for accountID: UUID) -> StoredS3Credential? {
        loadValue(StoredS3Credential.self, account: accountID, key: "s3-credential")
    }

    func saveS3Credential(_ credential: StoredS3Credential, for accountID: UUID) throws {
        try saveValue(credential, account: accountID, key: "s3-credential")
    }

    func deleteS3Credential(for accountID: UUID) throws {
        try deleteValue(account: accountID, key: "s3-credential")
    }

    private func saveString(_ value: String, account: UUID, key: String) throws {
        try saveData(Data(value.utf8), account: account, key: key)
    }

    private func loadString(account: UUID, key: String) -> String? {
        guard let data = loadData(account: account, key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveValue<T: Encodable>(_ value: T, account: UUID, key: String) throws {
        let data = try encoder.encode(value)
        try saveData(data, account: account, key: key)
    }

    private func loadValue<T: Decodable>(_ type: T.Type, account: UUID, key: String) -> T? {
        guard let data = loadData(account: account, key: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func saveData(_ data: Data, account: UUID, key: String) throws {
        let accountKey = "\(account.uuidString).\(key)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountKey,
        ]

        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudServiceError.unknown("Failed to save cloud credentials to Keychain (\(status))")
        }
    }

    private func loadData(account: UUID, key: String) -> Data? {
        let accountKey = "\(account.uuidString).\(key)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteValue(account: UUID, key: String) throws {
        let accountKey = "\(account.uuidString).\(key)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountKey,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudServiceError.unknown("Failed to delete cloud credentials from Keychain (\(status))")
        }
    }
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

struct OAuthProviderDescriptor {
    let authorizeURL: URL
    let tokenURL: URL
    let scopes: [String]
    let extraAuthorizeItems: [URLQueryItem]
    let extraTokenParameters: [String: String]
}

struct OAuthSessionConfiguration {
    let provider: CloudProvider
    let clientID: String
    let clientSecret: String?
    let descriptor: OAuthProviderDescriptor
}

enum OAuthCoordinatorError: LocalizedError {
    case missingClientID
    case invalidCallback
    case callbackError(String)
    case browserLaunchFailed
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Set an OAuth client ID before connecting this provider"
        case .invalidCallback:
            return "The OAuth callback did not include an authorization code"
        case .callbackError(let message):
            return message
        case .browserLaunchFailed:
            return "Failed to open the system browser for OAuth"
        case .listenerUnavailable:
            return "Port 53682 is unavailable. Close any other Neutron sign-in flow and try again."
        }
    }
}

final class OAuthLoopbackServer {
    static let redirectURI = URL(string: "http://localhost:53682/oauth/callback")!

    private let queue = DispatchQueue(label: "com.neutron.cloud.oauth-loopback")
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<URL, Error>?

    func start() throws {
        do {
            let listener = try NWListener(using: .tcp, on: 53682)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.callbackContinuation?.resume(throwing: OAuthCoordinatorError.listenerUnavailable)
                    self?.callbackContinuation = nil
                }
            }
            listener.start(queue: queue)
        } catch {
            throw OAuthCoordinatorError.listenerUnavailable
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = request.split(separator: "\n").first.map(String.init) ?? ""
            let path = firstLine
                .split(separator: " ")
                .dropFirst()
                .first
                .map(String.init)
                ?? "/"

            let responseBody = "<html><body style=\"font-family:-apple-system;padding:24px\"><h2>Neutron connected</h2><p>You can close this tab and return to the app.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"

            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if let url = URL(string: "http://localhost:53682\(path)") {
                self.callbackContinuation?.resume(returning: url)
                self.callbackContinuation = nil
            }
        }
    }
}

final class OAuthCoordinator {
    static let shared = OAuthCoordinator()

    func authorize(_ configuration: OAuthSessionConfiguration) async throws -> StoredOAuthCredential {
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(length: 32)
        let loopback = OAuthLoopbackServer()
        try loopback.start()
        defer { loopback.stop() }

        var components = URLComponents(url: configuration.descriptor.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthLoopbackServer.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        if !configuration.descriptor.scopes.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "scope", value: configuration.descriptor.scopes.joined(separator: " ")))
        }
        components?.queryItems?.append(contentsOf: configuration.descriptor.extraAuthorizeItems)

        guard let authorizationURL = components?.url else {
            throw CloudServiceError.invalidConfiguration("Unable to build OAuth authorization URL")
        }

        guard NSWorkspace.shared.open(authorizationURL) else {
            throw OAuthCoordinatorError.browserLaunchFailed
        }

        let callbackURL = try await loopback.waitForCallback()
        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let callbackState = callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value
        guard callbackState == state else {
            throw CloudServiceError.accessDenied("OAuth state did not match")
        }

        if let error = callbackComponents?.queryItems?.first(where: { $0.name == "error_description" })?.value
            ?? callbackComponents?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw OAuthCoordinatorError.callbackError(error.replacingOccurrences(of: "+", with: " "))
        }

        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthCoordinatorError.invalidCallback
        }

        return try await exchangeCode(
            configuration: configuration,
            code: code,
            codeVerifier: verifier
        )
    }

    func refreshCredential(_ credential: StoredOAuthCredential, configuration: OAuthSessionConfiguration) async throws -> StoredOAuthCredential {
        guard let refreshToken = credential.refreshToken else {
            throw CloudServiceError.notAuthenticated
        }

        var form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ]
        if let clientSecret = configuration.clientSecret, !clientSecret.isEmpty {
            form["client_secret"] = clientSecret
        }
        configuration.descriptor.extraTokenParameters.forEach { form[$0.key] = $0.value }

        return try await fetchToken(configuration: configuration, form: form)
    }

    private func exchangeCode(
        configuration: OAuthSessionConfiguration,
        code: String,
        codeVerifier: String
    ) async throws -> StoredOAuthCredential {
        var form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthLoopbackServer.redirectURI.absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": codeVerifier,
        ]
        if let clientSecret = configuration.clientSecret, !clientSecret.isEmpty {
            form["client_secret"] = clientSecret
        }
        configuration.descriptor.extraTokenParameters.forEach { form[$0.key] = $0.value }

        return try await fetchToken(configuration: configuration, form: form)
    }

    private func fetchToken(
        configuration: OAuthSessionConfiguration,
        form: [String: String]
    ) async throws -> StoredOAuthCredential {
        var request = URLRequest(url: configuration.descriptor.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(($0.value).addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServiceError.invalidConfiguration("Invalid OAuth token response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "OAuth token exchange failed"
            throw CloudServiceError.networkError(body)
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(OAuthTokenResponse.self, from: data)
        return StoredOAuthCredential(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            tokenType: payload.tokenType,
            scope: payload.scope
        )
    }

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

class OAuthBackedCloudService: CloudProviderService {
    let provider: CloudProvider
    let account: CloudDriveAccount
    @Published var isAuthenticating = false
    @Published var authError: String?

    private let credentialStore: CloudCredentialStore
    private var credential: StoredOAuthCredential?

    init(provider: CloudProvider, account: CloudDriveAccount, credentialStore: CloudCredentialStore) {
        self.provider = provider
        self.account = account
        self.credentialStore = credentialStore
        self.credential = credentialStore.loadOAuthCredential(for: account.id)
    }

    func authenticate() async throws {
        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }

        do {
            let session = try oauthSessionConfiguration()
            let newCredential = try await OAuthCoordinator.shared.authorize(session)
            credential = newCredential
            try credentialStore.saveOAuthCredential(newCredential, for: account.id)
        } catch {
            authError = error.localizedDescription
            throw error
        }
    }

    func listFiles(path: String) async throws -> [CloudFileItem] {
        []
    }

    func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {}

    func refreshStorageInfo() async throws {}

    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await validAccessToken()
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServiceError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401, let refreshedCredential = try? await refreshCredential() {
            var retryRequest = request
            retryRequest.setValue("Bearer \(refreshedCredential.accessToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw CloudServiceError.networkError("Invalid response")
            }
            guard (200..<300).contains(retryHTTP.statusCode) else {
                let body = String(data: retryData, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: retryHTTP.statusCode)
                throw CloudServiceError.networkError(body)
            }
            return (retryData, retryHTTP)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw CloudServiceError.networkError(body)
        }

        return (data, httpResponse)
    }

    func validAccessToken() async throws -> String {
        if let credential, !credential.isExpired {
            return credential.accessToken
        }

        if let credential, credential.refreshToken != nil {
            let refreshed = try await refreshCredential()
            return refreshed.accessToken
        }

        if let stored = credentialStore.loadOAuthCredential(for: account.id) {
            credential = stored
            if !stored.isExpired {
                return stored.accessToken
            }
            if stored.refreshToken != nil {
                let refreshed = try await refreshCredential()
                return refreshed.accessToken
            }
        }

        throw CloudServiceError.notAuthenticated
    }

    private func refreshCredential() async throws -> StoredOAuthCredential {
        guard let credential else { throw CloudServiceError.notAuthenticated }
        let refreshed = try await OAuthCoordinator.shared.refreshCredential(credential, configuration: try oauthSessionConfiguration())
        self.credential = refreshed
        try credentialStore.saveOAuthCredential(refreshed, for: account.id)
        return refreshed
    }

    private func oauthSessionConfiguration() throws -> OAuthSessionConfiguration {
        guard let clientID = account.oauthClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else {
            throw OAuthCoordinatorError.missingClientID
        }

        return OAuthSessionConfiguration(
            provider: provider,
            clientID: clientID,
            clientSecret: credentialStore.loadOAuthClientSecret(for: account.id),
            descriptor: try descriptor()
        )
    }

    func descriptor() throws -> OAuthProviderDescriptor {
        throw CloudServiceError.invalidConfiguration("OAuth descriptor missing")
    }
}

final class RemoteGoogleDriveService: OAuthBackedCloudService {
    private struct GoogleListResponse: Decodable {
        let files: [GoogleFile]
    }

    private struct GoogleFile: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let modifiedTime: String?
        let size: String?
        let md5Checksum: String?
    }

    private struct GoogleQuotaResponse: Decodable {
        struct StorageQuota: Decodable {
            let limit: String?
            let usage: String?
        }

        let storageQuota: StorageQuota?
    }

    init(account: CloudDriveAccount, credentialStore: CloudCredentialStore) {
        super.init(provider: .googleDrive, account: account, credentialStore: credentialStore)
    }

    override func descriptor() throws -> OAuthProviderDescriptor {
        OAuthProviderDescriptor(
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: [
                "https://www.googleapis.com/auth/drive.readonly",
            ],
            extraAuthorizeItems: [
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ],
            extraTokenParameters: [:]
        )
    }

    override func listFiles(path: String) async throws -> [CloudFileItem] {
        let parentID = path.isEmpty ? "root" : path
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "'\(parentID)' in parents and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,modifiedTime,size,md5Checksum)"),
            URLQueryItem(name: "orderBy", value: "folder,name"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "pageSize", value: "200"),
        ]

        let request = URLRequest(url: components.url!)
        let (data, _) = try await authorizedData(for: request)
        let payload = try JSONDecoder().decode(GoogleListResponse.self, from: data)

        return payload.files.map {
            CloudFileItem(
                id: $0.id,
                name: $0.name,
                path: $0.id,
                isDirectory: $0.mimeType == "application/vnd.google-apps.folder",
                sizeBytes: Int64($0.size ?? "0") ?? 0,
                modified: ISO8601DateFormatter().date(from: $0.modifiedTime ?? "") ?? .now,
                mimeType: $0.mimeType,
                etag: $0.md5Checksum
            )
        }
    }

    override func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        let downloadURL: URL
        if let mimeType = file.mimeType, mimeType.hasPrefix("application/vnd.google-apps") {
            let exportType = switch mimeType {
            case "application/vnd.google-apps.document": "application/pdf"
            case "application/vnd.google-apps.presentation": "application/pdf"
            case "application/vnd.google-apps.spreadsheet": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            default: "application/pdf"
            }
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(file.id)/export")!
            components.queryItems = [URLQueryItem(name: "mimeType", value: exportType)]
            downloadURL = components.url!
        } else {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(file.id)")!
            components.queryItems = [URLQueryItem(name: "alt", value: "media")]
            downloadURL = components.url!
        }

        let request = URLRequest(url: downloadURL)
        let (data, _) = try await authorizedData(for: request)
        try data.write(to: localURL)
    }

    override func refreshStorageInfo() async throws {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        components.queryItems = [URLQueryItem(name: "fields", value: "storageQuota(limit,usage)")]
        let request = URLRequest(url: components.url!)
        _ = try await authorizedData(for: request)
    }
}

final class RemoteDropboxService: OAuthBackedCloudService {
    private struct DropboxListResponse: Decodable {
        let entries: [DropboxEntry]
    }

    private struct DropboxEntry: Decodable {
        let tag: String
        let id: String?
        let name: String
        let pathDisplay: String?
        let pathLower: String?
        let clientModified: String?
        let serverModified: String?
        let size: Int64?
        let contentHash: String?

        enum CodingKeys: String, CodingKey {
            case tag = ".tag"
            case id
            case name
            case pathDisplay = "path_display"
            case pathLower = "path_lower"
            case clientModified = "client_modified"
            case serverModified = "server_modified"
            case size
            case contentHash = "content_hash"
        }
    }

    init(account: CloudDriveAccount, credentialStore: CloudCredentialStore) {
        super.init(provider: .dropbox, account: account, credentialStore: credentialStore)
    }

    override func descriptor() throws -> OAuthProviderDescriptor {
        OAuthProviderDescriptor(
            authorizeURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.metadata.read", "files.content.read", "account_info.read"],
            extraAuthorizeItems: [
                URLQueryItem(name: "token_access_type", value: "offline"),
            ],
            extraTokenParameters: [:]
        )
    }

    override func listFiles(path: String) async throws -> [CloudFileItem] {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "recursive": false,
            "include_deleted": false,
            "include_mounted_folders": true,
        ])

        let (data, _) = try await authorizedData(for: request)
        let payload = try JSONDecoder.dropbox.decode(DropboxListResponse.self, from: data)
        return payload.entries.map {
            CloudFileItem(
                id: $0.id ?? ($0.pathLower ?? $0.name),
                name: $0.name,
                path: $0.pathLower ?? "",
                isDirectory: $0.tag == "folder",
                sizeBytes: $0.size ?? 0,
                modified: ISO8601DateFormatter().date(from: $0.serverModified ?? $0.clientModified ?? "") ?? .now,
                mimeType: nil,
                etag: $0.contentHash
            )
        }
    }

    override func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("{\"path\":\"\(file.path)\"}", forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, _) = try await authorizedData(for: request)
        try data.write(to: localURL)
    }

    override func refreshStorageInfo() async throws {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_space_usage")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try await authorizedData(for: request)
    }
}

final class RemoteOneDriveService: OAuthBackedCloudService {
    private struct OneDriveListResponse: Decodable {
        let value: [OneDriveItem]
    }

    private struct OneDriveItem: Decodable {
        struct FolderInfo: Decodable {}
        struct FileInfo: Decodable {}

        let id: String
        let name: String
        let size: Int64?
        let lastModifiedDateTime: String?
        let folder: FolderInfo?
        let file: FileInfo?
    }

    init(account: CloudDriveAccount, credentialStore: CloudCredentialStore) {
        super.init(provider: .oneDrive, account: account, credentialStore: credentialStore)
    }

    override func descriptor() throws -> OAuthProviderDescriptor {
        let tenant = account.oauthTenant?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? account.oauthTenant!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "common"

        return OAuthProviderDescriptor(
            authorizeURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!,
            scopes: ["offline_access", "Files.Read", "User.Read"],
            extraAuthorizeItems: [
                URLQueryItem(name: "response_mode", value: "query"),
            ],
            extraTokenParameters: [:]
        )
    }

    override func listFiles(path: String) async throws -> [CloudFileItem] {
        let urlString: String
        if path.isEmpty {
            urlString = "https://graph.microsoft.com/v1.0/me/drive/root/children?$select=id,name,size,lastModifiedDateTime,folder,file"
        } else {
            urlString = "https://graph.microsoft.com/v1.0/me/drive/items/\(path)/children?$select=id,name,size,lastModifiedDateTime,folder,file"
        }

        let request = URLRequest(url: URL(string: urlString)!)
        let (data, _) = try await authorizedData(for: request)
        let payload = try JSONDecoder().decode(OneDriveListResponse.self, from: data)
        return payload.value.map {
            CloudFileItem(
                id: $0.id,
                name: $0.name,
                path: $0.id,
                isDirectory: $0.folder != nil,
                sizeBytes: $0.size ?? 0,
                modified: ISO8601DateFormatter().date(from: $0.lastModifiedDateTime ?? "") ?? .now,
                mimeType: nil,
                etag: nil
            )
        }
    }

    override func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        let request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(file.id)/content")!)
        let (data, _) = try await authorizedData(for: request)
        try data.write(to: localURL)
    }

    override func refreshStorageInfo() async throws {
        let request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive?$select=quota")!)
        _ = try await authorizedData(for: request)
    }
}

final class RemoteBoxService: OAuthBackedCloudService {
    private struct BoxListResponse: Decodable {
        let entries: [BoxItem]
    }

    private struct BoxItem: Decodable {
        let id: String
        let name: String
        let type: String
        let size: Int64?
        let modifiedAt: String?
        let etag: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case type
            case size
            case modifiedAt = "modified_at"
            case etag
        }
    }

    init(account: CloudDriveAccount, credentialStore: CloudCredentialStore) {
        super.init(provider: .box, account: account, credentialStore: credentialStore)
    }

    override func descriptor() throws -> OAuthProviderDescriptor {
        OAuthProviderDescriptor(
            authorizeURL: URL(string: "https://account.box.com/api/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.box.com/oauth2/token")!,
            scopes: [],
            extraAuthorizeItems: [],
            extraTokenParameters: [:]
        )
    }

    override func listFiles(path: String) async throws -> [CloudFileItem] {
        let folderID = path.isEmpty ? "0" : path
        var components = URLComponents(string: "https://api.box.com/2.0/folders/\(folderID)/items")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,type,size,modified_at,etag"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        let request = URLRequest(url: components.url!)
        let (data, _) = try await authorizedData(for: request)
        let payload = try JSONDecoder().decode(BoxListResponse.self, from: data)
        return payload.entries.map {
            CloudFileItem(
                id: $0.id,
                name: $0.name,
                path: $0.id,
                isDirectory: $0.type == "folder",
                sizeBytes: $0.size ?? 0,
                modified: ISO8601DateFormatter().date(from: $0.modifiedAt ?? "") ?? .now,
                mimeType: nil,
                etag: $0.etag
            )
        }
    }

    override func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        let request = URLRequest(url: URL(string: "https://api.box.com/2.0/files/\(file.id)/content")!)
        let (data, _) = try await authorizedData(for: request)
        try data.write(to: localURL)
    }

    override func refreshStorageInfo() async throws {
        let request = URLRequest(url: URL(string: "https://api.box.com/2.0/users/me?fields=space_amount,space_used")!)
        _ = try await authorizedData(for: request)
    }
}

final class RemoteS3Service: ObservableObject, CloudProviderService {
    let provider: CloudProvider = .awsS3
    let account: CloudDriveAccount
    @Published var isAuthenticating = false
    @Published var authError: String?

    private let credentialStore: CloudCredentialStore

    init(account: CloudDriveAccount, credentialStore: CloudCredentialStore) {
        self.account = account
        self.credentialStore = credentialStore
    }

    func authenticate() async throws {
        guard credentialStore.loadS3Credential(for: account.id) != nil else {
            throw CloudServiceError.notAuthenticated
        }
    }

    func listFiles(path: String) async throws -> [CloudFileItem] {
        let credential = try s3Credential()
        let bucket = try bucketName()
        let prefix = path
        let queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "delimiter", value: "/"),
            URLQueryItem(name: "prefix", value: prefix),
        ]
        let request = try signedRequest(
            method: "GET",
            bucket: bucket,
            path: "/",
            queryItems: queryItems,
            credential: credential,
            body: Data()
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudServiceError.networkError(String(data: data, encoding: .utf8) ?? "S3 list request failed")
        }

        let parser = S3ListBucketXMLParser()
        return parser.parse(data: data, currentPrefix: prefix)
    }

    func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        let credential = try s3Credential()
        let bucket = try bucketName()
        let request = try signedRequest(
            method: "GET",
            bucket: bucket,
            path: "/\(file.path.s3PathEncoded())",
            queryItems: [],
            credential: credential,
            body: Data()
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudServiceError.networkError(String(data: data, encoding: .utf8) ?? "S3 download failed")
        }
        try data.write(to: localURL)
    }

    func refreshStorageInfo() async throws {}

    private func bucketName() throws -> String {
        guard let bucket = account.s3Configuration?.bucketName, !bucket.isEmpty else {
            throw CloudServiceError.invalidConfiguration("Missing S3 bucket name")
        }
        return bucket
    }

    private func s3Credential() throws -> StoredS3Credential {
        guard let credential = credentialStore.loadS3Credential(for: account.id) else {
            throw CloudServiceError.notAuthenticated
        }
        return credential
    }

    private func endpointHost(for bucket: String) -> String {
        if let endpoint = account.s3Configuration?.endpoint,
           let endpointURL = URL(string: endpoint),
           let host = endpointURL.host {
            return host
        }

        let region = account.s3Configuration?.region ?? "us-east-1"
        return "\(bucket).s3.\(region).amazonaws.com"
    }

    private func signedRequest(
        method: String,
        bucket: String,
        path: String,
        queryItems: [URLQueryItem],
        credential: StoredS3Credential,
        body: Data
    ) throws -> URLRequest {
        let host = endpointHost(for: bucket)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        components.queryItems = queryItems

        guard let url = components.url else {
            throw CloudServiceError.invalidConfiguration("Unable to build S3 request URL")
        }

        let now = Date()
        let amzDate = now.awsTimestamp
        let dateStamp = now.awsDateStamp
        let hashedPayload = SHA256.hash(data: body).hexDigest
        let canonicalQuery = queryItems
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            .map { "\($0.name.addingPercentEncoding(withAllowedCharacters: .awsURLQueryAllowed) ?? $0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .awsURLQueryAllowed) ?? ($0.value ?? ""))" }
            .joined(separator: "&")

        var headers = [
            "host": host,
            "x-amz-content-sha256": hashedPayload,
            "x-amz-date": amzDate,
        ]
        if let sessionToken = credential.sessionToken, !sessionToken.isEmpty {
            headers["x-amz-security-token"] = sessionToken
        }

        let canonicalHeaders = headers
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value)\n" }
            .joined()
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalRequest = [
            method,
            path,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            hashedPayload,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(account.s3Configuration?.region ?? "us-east-1")/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).hexDigest,
        ].joined(separator: "\n")

        let signingKey = try AWSRequestSigner.signingKey(
            secret: credential.secretAccessKey,
            dateStamp: dateStamp,
            region: account.s3Configuration?.region ?? "us-east-1",
            service: "s3"
        )
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey)).hexDigest
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credential.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }
}

private enum AWSRequestSigner {
    static func signingKey(secret: String, dateStamp: String, region: String, service: String) throws -> SymmetricKey {
        let kDate = hmac(data: Data(dateStamp.utf8), key: SymmetricKey(data: Data(("AWS4" + secret).utf8)))
        let kRegion = hmac(data: Data(region.utf8), key: SymmetricKey(data: kDate))
        let kService = hmac(data: Data(service.utf8), key: SymmetricKey(data: kRegion))
        let kSigning = hmac(data: Data("aws4_request".utf8), key: SymmetricKey(data: kService))
        return SymmetricKey(data: kSigning)
    }

    private static func hmac(data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }
}

private final class S3ListBucketXMLParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var contents: [CloudFileItem] = []
    private var commonPrefixes: [String] = []
    private var currentPrefixValue: String?
    private var currentKey: String?
    private var currentSize: Int64 = 0
    private var currentModified: Date = .now
    private var currentETag: String?
    private var insideContents = false
    private var insideCommonPrefix = false

    func parse(data: Data, currentPrefix: String) -> [CloudFileItem] {
        contents = []
        commonPrefixes = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        let folders = commonPrefixes.map { prefix in
            let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
            return CloudFileItem(
                id: prefix,
                name: name,
                path: prefix,
                isDirectory: true,
                sizeBytes: 0,
                modified: .now,
                mimeType: nil,
                etag: nil
            )
        }

        let files = contents.filter { $0.path != currentPrefix }
        return (folders + files).sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" {
            insideContents = true
            currentKey = nil
            currentSize = 0
            currentModified = .now
            currentETag = nil
        }
        if elementName == "CommonPrefixes" {
            insideCommonPrefix = true
            currentPrefixValue = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideContents {
            switch elementName {
            case "Key":
                currentKey = value.removingPercentEncoding ?? value
            case "Size":
                currentSize = Int64(value) ?? 0
            case "LastModified":
                currentModified = ISO8601DateFormatter().date(from: value) ?? .now
            case "ETag":
                currentETag = value.replacingOccurrences(of: "\"", with: "")
            case "Contents":
                if let currentKey {
                    contents.append(
                        CloudFileItem(
                            id: currentKey,
                            name: currentKey.split(separator: "/").last.map(String.init) ?? currentKey,
                            path: currentKey,
                            isDirectory: false,
                            sizeBytes: currentSize,
                            modified: currentModified,
                            mimeType: nil,
                            etag: currentETag
                        )
                    )
                }
                insideContents = false
            default:
                break
            }
        }

        if insideCommonPrefix {
            switch elementName {
            case "Prefix":
                currentPrefixValue = value.removingPercentEncoding ?? value
            case "CommonPrefixes":
                if let currentPrefixValue {
                    commonPrefixes.append(currentPrefixValue)
                }
                insideCommonPrefix = false
            default:
                break
            }
        }
    }
}

private extension Date {
    var awsTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: self)
    }

    var awsDateStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: self)
    }
}

private extension Digest {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension CharacterSet {
    static let awsURLQueryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return set
    }()
}

private extension String {
    func s3PathEncoded() -> String {
        split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .awsURLQueryAllowed) ?? String($0) }
            .joined(separator: "/")
    }
}

private extension JSONDecoder {
    static var dropbox: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
