import SwiftUI
import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}

protocol CloudProviderService: ObservableObject {
    var provider: CloudProvider { get }
    var account: CloudDriveAccount { get }
    var isAuthenticating: Bool { get }
    var authError: String? { get }

    func authenticate() async throws
    func listFiles(path: String) async throws -> [CloudFileItem]
    func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws
    func uploadFile(from localURL: URL, to path: String) async throws -> CloudFileItem
    func deleteFile(_ file: CloudFileItem) async throws
    func createFolder(named name: String, at path: String) async throws -> CloudFileItem
    func refreshStorageInfo() async throws
}

extension CloudProviderService {
    func uploadFile(from localURL: URL, to path: String) async throws -> CloudFileItem {
        throw CloudServiceError.invalidConfiguration("Uploads aren't implemented for remote cloud browsing yet")
    }

    func deleteFile(_ file: CloudFileItem) async throws {
        throw CloudServiceError.invalidConfiguration("Deletes aren't implemented for remote cloud browsing yet")
    }

    func createFolder(named name: String, at path: String) async throws -> CloudFileItem {
        throw CloudServiceError.invalidConfiguration("Folder creation isn't implemented for remote cloud browsing yet")
    }
}

struct CloudFileItem: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let modified: Date
    let mimeType: String?
    let etag: String?

    var icon: String {
        if isDirectory {
            return "folder.fill"
        }
        switch mimeType {
        case let type where type?.contains("image/") == true:
            return "photo"
        case let type where type?.contains("video/") == true:
            return "video"
        case let type where type?.contains("audio/") == true:
            return "music.note"
        case let type where type?.contains("pdf") == true:
            return "doc.richtext"
        case let type where type?.contains("zip") == true || type?.contains("archive") == true:
            return "doc.zipper"
        default:
            return "doc"
        }
    }
}

enum CloudServiceError: LocalizedError {
    case notAuthenticated
    case networkError(String)
    case fileNotFound(String)
    case accessDenied(String)
    case quotaExceeded
    case invalidConfiguration(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with this cloud provider"
        case .networkError(let message):
            return "Network error: \(message)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .accessDenied(let resource):
            return "Access denied to: \(resource)"
        case .quotaExceeded:
            return "Storage quota exceeded"
        case .invalidConfiguration(let detail):
            return "Invalid configuration: \(detail)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}

class GoogleDriveService: CloudProviderService {
    let provider: CloudProvider = .googleDrive
    let account: CloudDriveAccount
    @Published var isAuthenticating: Bool = false
    @Published var authError: String? = nil

    private var accessToken: String?

    init(account: CloudDriveAccount) {
        self.account = account
    }

    func authenticate() async throws {
        isAuthenticating = true
        defer { isAuthenticating = false }

        throw CloudServiceError.notAuthenticated
    }

    func listFiles(path: String) async throws -> [CloudFileItem] {
        guard accessToken != nil else { throw CloudServiceError.notAuthenticated }
        return []
    }

    func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        guard accessToken != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func uploadFile(from localURL: URL, to path: String) async throws -> CloudFileItem {
        guard accessToken != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func deleteFile(_ file: CloudFileItem) async throws {
        guard accessToken != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func createFolder(named name: String, at path: String) async throws -> CloudFileItem {
        guard accessToken != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func refreshStorageInfo() async throws {
        guard accessToken != nil else { throw CloudServiceError.notAuthenticated }
    }
}

class S3Service: CloudProviderService {
    let provider: CloudProvider = .awsS3
    let account: CloudDriveAccount
    @Published var isAuthenticating: Bool = false
    @Published var authError: String? = nil

    private var accessKeyId: String?
    private var secretAccessKey: String?
    private var sessionToken: String?

    init(account: CloudDriveAccount) {
        self.account = account
    }

    func authenticate() async throws {
        isAuthenticating = true
        defer { isAuthenticating = false }

        throw CloudServiceError.notAuthenticated
    }

    func listFiles(path: String) async throws -> [CloudFileItem] {
        guard accessKeyId != nil else { throw CloudServiceError.notAuthenticated }
        return []
    }

    func downloadFile(_ file: CloudFileItem, to localURL: URL) async throws {
        guard accessKeyId != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func uploadFile(from localURL: URL, to path: String) async throws -> CloudFileItem {
        guard accessKeyId != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func deleteFile(_ file: CloudFileItem) async throws {
        guard accessKeyId != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func createFolder(named name: String, at path: String) async throws -> CloudFileItem {
        guard accessKeyId != nil else { throw CloudServiceError.notAuthenticated }
        throw CloudServiceError.notAuthenticated
    }

    func refreshStorageInfo() async throws {
        guard accessKeyId != nil else { throw CloudServiceError.notAuthenticated }
    }
}

struct CloudDriveAccount: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var provider: CloudProvider
    var rootName: String
    var localRootPath: String?
    var oauthClientID: String?
    var oauthTenant: String?
    var remoteEndpoint: String?
    var storageLimitBytes: Int64
    var usedBytes: Int64
    var isConnected: Bool
    var accentHex: String

    var s3Configuration: S3Configuration?

    struct S3Configuration: Equatable, Codable, Hashable {
        var bucketName: String
        var region: String
        var endpoint: String?

        static let empty = S3Configuration(
            bucketName: "",
            region: "us-east-1",
            endpoint: nil
        )
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        provider: CloudProvider = .googleDrive,
        rootName: String,
        localRootPath: String? = nil,
        oauthClientID: String? = nil,
        oauthTenant: String? = nil,
        remoteEndpoint: String? = nil,
        storageLimitBytes: Int64 = 15 * 1_024 * 1_024 * 1_024,
        usedBytes: Int64 = 0,
        isConnected: Bool = true,
        accentHex: String = "#4F8EF7",
        s3Configuration: S3Configuration? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.rootName = rootName
        self.localRootPath = localRootPath
        self.oauthClientID = oauthClientID
        self.oauthTenant = oauthTenant
        self.remoteEndpoint = remoteEndpoint
        self.storageLimitBytes = storageLimitBytes
        self.usedBytes = usedBytes
        self.isConnected = isConnected
        self.accentHex = accentHex
        self.s3Configuration = s3Configuration
    }

    var availableBytes: Int64 {
        max(storageLimitBytes - usedBytes, 0)
    }

    var usageFraction: Double {
        guard storageLimitBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(storageLimitBytes), 0), 1)
    }

    var localRootURL: URL? {
        guard let localRootPath, !localRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localRootPath)
    }

    var remoteEndpointURL: URL? {
        guard let remoteEndpoint,
              !remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: remoteEndpoint)
    }

    var supportsRemoteBrowsing: Bool {
        switch provider {
        case .iCloudDrive, .sftp, .ftp, .webDav, .smb, .afp, .nfs:
            return false
        case .googleDrive, .dropbox, .oneDrive, .box, .awsS3, .backblazeB2, .rackspaceCloudfiles:
            return true
        }
    }

    var hasRemoteConfiguration: Bool {
        switch provider {
        case .googleDrive, .dropbox, .oneDrive, .box:
            return oauthClientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .awsS3, .backblazeB2, .rackspaceCloudfiles:
            return s3Configuration != nil
        case .sftp, .ftp, .webDav, .smb, .afp, .nfs:
            return remoteEndpointURL != nil
        case .iCloudDrive:
            return false
        }
    }

    var remoteRootURL: URL {
        var components = URLComponents()
        components.scheme = "neutron-cloud"
        components.host = "account"
        components.path = "/\(id.uuidString)"
        components.queryItems = [
            URLQueryItem(name: "path", value: rootName)
        ]
        return components.url!
    }

    var browseURL: URL {
        if supportsRemoteBrowsing && hasRemoteConfiguration {
            return remoteRootURL
        }
        return localRootURL ?? remoteRootURL
    }
}

enum CloudProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    case googleDrive = "Google Drive"
    case dropbox = "Dropbox"
    case oneDrive = "OneDrive"
    case box = "Box"
    case iCloudDrive = "iCloud Drive"
    case awsS3 = "Amazon S3"
    case backblazeB2 = "Backblaze B2"
    case rackspaceCloudfiles = "Rackspace Cloudfiles"
    case sftp = "SFTP"
    case ftp = "FTP"
    case webDav = "WebDAV"
    case smb = "SMB"
    case afp = "AFP"
    case nfs = "NFS"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .googleDrive:
            return "triangle"
        case .dropbox:
            return "shippingbox"
        case .oneDrive:
            return "cloud"
        case .box:
            return "archivebox"
        case .iCloudDrive:
            return "icloud"
        case .awsS3:
            return "externaldrive.connected.to.line.below"
        case .backblazeB2:
            return "shippingbox.circle"
        case .rackspaceCloudfiles:
            return "shippingbox.circle.fill"
        case .sftp:
            return "terminal"
        case .ftp:
            return "antenna.radiowaves.left.and.right"
        case .webDav:
            return "globe"
        case .smb:
            return "network"
        case .afp:
            return "server.rack"
        case .nfs:
            return "externaldrive.connected.to.line.below"
        }
    }

    var description: String {
        switch self {
        case .googleDrive:
            return "Google Drive via sync folder or OAuth-powered remote browsing"
        case .dropbox:
            return "Dropbox sync folder integration or direct API browsing"
        case .oneDrive:
            return "Microsoft OneDrive sync folder integration or direct API browsing"
        case .box:
            return "Box Drive sync folder integration or direct API browsing"
        case .iCloudDrive:
            return "Apple iCloud Drive"
        case .awsS3:
            return "Amazon S3 bucket via signed API requests"
        case .backblazeB2:
            return "Backblaze B2 via S3-compatible endpoint"
        case .rackspaceCloudfiles:
            return "Rackspace Cloudfiles via endpoint-style credentials"
        case .sftp:
            return "Secure File Transfer Protocol remote endpoint"
        case .ftp:
            return "File Transfer Protocol remote endpoint"
        case .webDav:
            return "WebDAV endpoint"
        case .smb:
            return "SMB network share"
        case .afp:
            return "AFP network share"
        case .nfs:
            return "NFS network share"
        }
    }

    var accentHex: String {
        switch self {
        case .googleDrive:
            return "#4285F4"
        case .dropbox:
            return "#0061FF"
        case .oneDrive:
            return "#0F6CBD"
        case .box:
            return "#0061D5"
        case .iCloudDrive:
            return "#4F8EF7"
        case .awsS3:
            return "#FF9900"
        case .backblazeB2:
            return "#FF6900"
        case .rackspaceCloudfiles:
            return "#CC0000"
        case .sftp:
            return "#0A84FF"
        case .ftp:
            return "#64D2FF"
        case .webDav:
            return "#30B0C7"
        case .smb:
            return "#34C759"
        case .afp:
            return "#8E8E93"
        case .nfs:
            return "#BF5AF2"
        }
    }
}

enum S3Regions: String, CaseIterable, Identifiable {
    case usEast1 = "us-east-1"
    case usEast2 = "us-east-2"
    case usWest1 = "us-west-1"
    case usWest2 = "us-west-2"
    case euWest1 = "eu-west-1"
    case euWest2 = "eu-west-2"
    case euWest3 = "eu-west-3"
    case euCentral1 = "eu-central-1"
    case apSoutheast1 = "ap-southeast-1"
    case apSoutheast2 = "ap-southeast-2"
    case apNortheast1 = "ap-northeast-1"
    case apNortheast2 = "ap-northeast-2"
    case apSouth1 = "ap-south-1"
    case saEast1 = "sa-east-1"
    case caCentral1 = "ca-central-1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usEast1: return "US East (N. Virginia)"
        case .usEast2: return "US East (Ohio)"
        case .usWest1: return "US West (N. California)"
        case .usWest2: return "US West (Oregon)"
        case .euWest1: return "EU (Ireland)"
        case .euWest2: return "EU (London)"
        case .euWest3: return "EU (Paris)"
        case .euCentral1: return "EU (Frankfurt)"
        case .apSoutheast1: return "Asia Pacific (Singapore)"
        case .apSoutheast2: return "Asia Pacific (Sydney)"
        case .apNortheast1: return "Asia Pacific (Tokyo)"
        case .apNortheast2: return "Asia Pacific (Seoul)"
        case .apSouth1: return "Asia Pacific (Mumbai)"
        case .saEast1: return "South America (São Paulo)"
        case .caCentral1: return "Canada (Central)"
        }
    }
}

struct CloudDriveChain: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var name: String
    var accountIDs: [UUID]
    var distributeSequentially: Bool

    init(
        id: UUID = UUID(),
        name: String,
        accountIDs: [UUID],
        distributeSequentially: Bool = true
    ) {
        self.id = id
        self.name = name
        self.accountIDs = accountIDs
        self.distributeSequentially = distributeSequentially
    }
}

struct CloudSearchResult: Identifiable, Equatable, Hashable {
    let id = UUID()
    let title: String
    let accountName: String
    let pathDescription: String
    let kind: String
    let sizeBytes: Int64?
    let modified: Date
    let targetURL: URL
}

struct CloudWorkspaceModel: Equatable, Codable {
    var accounts: [CloudDriveAccount]
    var chains: [CloudDriveChain]
    var unifiedSearchEnabled: Bool

    static let empty = CloudWorkspaceModel(
        accounts: [],
        chains: [],
        unifiedSearchEnabled: false
    )

    var chainedAccountIDs: [UUID] {
        Array(Set(chains.flatMap(\.accountIDs)))
    }

    func accounts(for chain: CloudDriveChain) -> [CloudDriveAccount] {
        chain.accountIDs.compactMap { id in
            accounts.first(where: { $0.id == id })
        }
    }
}

@MainActor
final class CloudWorkspaceStore: ObservableObject {
    static let shared = CloudWorkspaceStore()

    @Published var model: CloudWorkspaceModel {
        didSet { save() }
    }

    private let defaultsKey = "cloudWorkspaceModel"
    private let credentialStore = CloudCredentialStore.shared
    private var serviceCache: [UUID: any CloudProviderService] = [:]

    private init() {
        if
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(CloudWorkspaceModel.self, from: data)
        {
            self.model = decoded
        } else {
            let detectedAccounts = CloudProvider.allCases.compactMap { provider in
                Self.discoverSuggestedRoots(for: provider).first.map { root in
                    CloudDriveAccount(
                        displayName: provider.rawValue,
                        provider: provider,
                        rootName: root.lastPathComponent,
                        localRootPath: root.path,
                        isConnected: FileManager.default.fileExists(atPath: root.path),
                        accentHex: provider.accentHex
                    )
                }
            }
            self.model = CloudWorkspaceModel(
                accounts: detectedAccounts,
                chains: detectedAccounts.count > 1
                    ? [CloudDriveChain(name: "Cloud Pool", accountIDs: detectedAccounts.map(\.id))]
                    : [],
                unifiedSearchEnabled: !detectedAccounts.isEmpty
            )
            save()
        }

        refreshAccountConnections()
    }

    func addAccount(
        provider: CloudProvider,
        displayName: String,
        localRootURL: URL?,
        oauthClientID: String? = nil,
        oauthTenant: String? = nil,
        remoteEndpoint: String? = nil,
        oauthClientSecret: String? = nil,
        s3Configuration: CloudDriveAccount.S3Configuration? = nil,
        s3Credentials: StoredS3Credential? = nil
    ) {
        let account = makeAccount(
            provider: provider,
            displayName: displayName,
            localRootURL: localRootURL,
            oauthClientID: oauthClientID,
            oauthTenant: oauthTenant,
            remoteEndpoint: remoteEndpoint,
            s3Configuration: s3Configuration
        )
        model.accounts.append(account)

        if let oauthClientSecret, !oauthClientSecret.isEmpty {
            try? credentialStore.saveOAuthClientSecret(oauthClientSecret, for: account.id)
        }

        if let s3Credentials {
            try? credentialStore.saveS3Credential(s3Credentials, for: account.id)
        }

        refreshAccountConnections()
    }

    func browseURL(for account: CloudDriveAccount) -> URL {
        account.browseURL
    }

    func service(for account: CloudDriveAccount) -> (any CloudProviderService)? {
        if let cached = serviceCache[account.id] {
            return cached
        }

        let service: (any CloudProviderService)?
        switch account.provider {
        case .googleDrive:
            service = RemoteGoogleDriveService(account: account, credentialStore: credentialStore)
        case .dropbox:
            service = RemoteDropboxService(account: account, credentialStore: credentialStore)
        case .oneDrive:
            service = RemoteOneDriveService(account: account, credentialStore: credentialStore)
        case .box:
            service = RemoteBoxService(account: account, credentialStore: credentialStore)
        case .awsS3, .backblazeB2, .rackspaceCloudfiles:
            service = RemoteS3Service(account: account, credentialStore: credentialStore)
        case .iCloudDrive, .sftp, .ftp, .webDav, .smb, .afp, .nfs:
            service = nil
        }

        if let service {
            serviceCache[account.id] = service
        }

        return service
    }

    func connectAccount(_ accountID: UUID) async throws {
        guard let account = model.accounts.first(where: { $0.id == accountID }) else {
            throw CloudServiceError.fileNotFound("Missing cloud account")
        }

        switch account.provider {
        case .sftp, .ftp, .webDav, .smb, .afp, .nfs:
            guard let endpoint = account.remoteEndpointURL else {
                throw CloudServiceError.invalidConfiguration("Provide endpoint URL first")
            }
            NSWorkspace.shared.open(endpoint)
            refreshAccountConnections()

        default:
            guard let service = service(for: account) else {
                throw CloudServiceError.invalidConfiguration("This provider doesn't support remote authentication")
            }
            try await service.authenticate()
            refreshAccountConnections()
        }
    }

    func signOutAccount(_ accountID: UUID) {
        try? credentialStore.deleteOAuthCredential(for: accountID)
        try? credentialStore.deleteOAuthClientSecret(for: accountID)
        try? credentialStore.deleteS3Credential(for: accountID)
        serviceCache.removeValue(forKey: accountID)
        refreshAccountConnections()
    }

    func authenticationLabel(for account: CloudDriveAccount) -> String {
        switch account.provider {
        case .iCloudDrive:
            return account.localRootURL == nil ? "Local only" : "Local sync folder"
        case .awsS3, .backblazeB2, .rackspaceCloudfiles:
            return credentialStore.loadS3Credential(for: account.id) == nil ? "Needs credentials" : "API connected"
        case .googleDrive, .dropbox, .oneDrive, .box:
            if credentialStore.loadOAuthCredential(for: account.id) != nil {
                return "OAuth connected"
            }
            if account.hasRemoteConfiguration {
                return "Needs sign in"
            }
            if account.localRootURL != nil {
                return "Local sync folder"
            }
            return "Needs OAuth setup"
        case .sftp, .ftp, .webDav, .smb, .afp, .nfs:
            if account.localRootURL != nil {
                return "Mounted"
            }
            return account.remoteEndpointURL == nil ? "Needs endpoint" : "Ready to mount"
        }
    }

    func isRemotelyAuthenticated(_ account: CloudDriveAccount) -> Bool {
        switch account.provider {
        case .googleDrive, .dropbox, .oneDrive, .box:
            return credentialStore.loadOAuthCredential(for: account.id) != nil
        case .awsS3, .backblazeB2, .rackspaceCloudfiles:
            return credentialStore.loadS3Credential(for: account.id) != nil
        case .sftp, .ftp, .webDav, .smb, .afp, .nfs, .iCloudDrive:
            return false
        }
    }

    func remoteURL(
        for account: CloudDriveAccount,
        itemID: String? = nil,
        displayPath: String? = nil,
        ancestors: [String] = []
    ) -> URL {
        var components = URLComponents()
        components.scheme = "neutron-cloud"
        components.host = "account"
        components.path = "/\(account.id.uuidString)"

        var queryItems: [URLQueryItem] = []
        if let itemID, !itemID.isEmpty {
            queryItems.append(URLQueryItem(name: "item", value: itemID))
        }
        if !ancestors.isEmpty {
            queryItems.append(URLQueryItem(name: "ancestors", value: ancestors.joined(separator: "|")))
        }
        queryItems.append(URLQueryItem(name: "path", value: displayPath ?? account.rootName))
        components.queryItems = queryItems
        return components.url!
    }

    func resolveRemoteLocation(for url: URL) -> (account: CloudDriveAccount, itemID: String?, displayPath: String, ancestors: [String])? {
        if url.scheme == "neutron-cloud",
           url.host == "account" {
            let accountIDString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let accountID = UUID(uuidString: accountIDString),
               let account = model.accounts.first(where: { $0.id == accountID }) {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let itemID = components?.queryItems?.first(where: { $0.name == "item" })?.value
                let displayPath = components?.queryItems?.first(where: { $0.name == "path" })?.value ?? account.rootName
                let ancestors = components?.queryItems?
                    .first(where: { $0.name == "ancestors" })?
                    .value?
                    .split(separator: "|")
                    .map(String.init) ?? []
                return (account, itemID, displayPath, ancestors)
            }
        }

        if url.scheme == "neutron-s3",
           let bucket = url.host,
           let account = model.accounts.first(where: {
               $0.provider == .awsS3 && $0.s3Configuration?.bucketName == bucket
           }) {
            return (account, nil, account.rootName, [])
        }

        if url.scheme == "neutron-cloud",
           let account = model.accounts.first(where: { $0.rootName == url.lastPathComponent || $0.provider.rawValue == url.host }) {
            return (account, nil, account.rootName, [])
        }

        return nil
    }

    func parentRemoteURL(for url: URL) -> URL? {
        guard let location = resolveRemoteLocation(for: url) else { return nil }
        let displayPath = location.displayPath
        guard displayPath != location.account.rootName else { return nil }

        let components = displayPath.split(separator: "/").map(String.init)
        let parentPath = components.dropLast().joined(separator: "/")
        let parentItemID = location.ancestors.last
        let parentAncestors = Array(location.ancestors.dropLast())
        return remoteURL(
            for: location.account,
            itemID: parentItemID,
            displayPath: parentPath.isEmpty ? location.account.rootName : parentPath,
            ancestors: parentAncestors
        )
    }

    func refreshCurrentService(_ accountID: UUID) {
        serviceCache.removeValue(forKey: accountID)
    }

    func displayLocation(for account: CloudDriveAccount) -> String {
        account.localRootURL?.path ?? account.rootName
    }

    func suggestedRoots(for provider: CloudProvider) -> [URL] {
        Self.discoverSuggestedRoots(for: provider)
    }

    private static func discoverSuggestedRoots(for provider: CloudProvider) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let documents = home.appendingPathComponent("Library/Mobile Documents")

        let candidates: [URL]
        switch provider {
        case .googleDrive:
            candidates = Self.urls(in: cloudStorage, matchingPrefixes: ["GoogleDrive", "Google Drive"])
                + [home.appendingPathComponent("Google Drive")]
        case .dropbox:
            candidates = Self.urls(in: cloudStorage, matchingPrefixes: ["Dropbox"])
                + [home.appendingPathComponent("Dropbox")]
        case .oneDrive:
            candidates = Self.urls(in: cloudStorage, matchingPrefixes: ["OneDrive"])
                + [home.appendingPathComponent("OneDrive")]
        case .box:
            candidates = Self.urls(in: cloudStorage, matchingPrefixes: ["Box"])
                + [home.appendingPathComponent("Box")]
        case .iCloudDrive:
            candidates = [documents.appendingPathComponent("com~apple~CloudDocs")]
        case .awsS3:
            candidates = Self.urls(in: cloudStorage, matchingPrefixes: ["S3", "AWS", "Amazon S3"])
        }

        var seen = Set<String>()
        return candidates.filter {
            FileManager.default.fileExists(atPath: $0.path)
                && seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    func refreshAccountConnections() {
        for index in model.accounts.indices {
            let account = model.accounts[index]
            let localConnected = account.localRootURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let remoteConnected: Bool = switch account.provider {
            case .googleDrive, .dropbox, .oneDrive, .box:
                credentialStore.loadOAuthCredential(for: account.id) != nil
            case .awsS3:
                credentialStore.loadS3Credential(for: account.id) != nil
            case .iCloudDrive:
                false
            }
            model.accounts[index].isConnected = localConnected || remoteConnected
        }
    }

    func removeAccount(_ accountID: UUID) {
        model.accounts.removeAll { $0.id == accountID }
        serviceCache.removeValue(forKey: accountID)
        try? credentialStore.deleteOAuthCredential(for: accountID)
        try? credentialStore.deleteOAuthClientSecret(for: accountID)
        try? credentialStore.deleteS3Credential(for: accountID)
        model.chains = model.chains.compactMap { chain in
            var updated = chain
            updated.accountIDs.removeAll { $0 == accountID }
            return updated.accountIDs.isEmpty ? nil : updated
        }
    }

    func toggleChainMembership(accountID: UUID, chainID: UUID) {
        guard let index = model.chains.firstIndex(where: { $0.id == chainID }) else { return }
        if model.chains[index].accountIDs.contains(accountID) {
            model.chains[index].accountIDs.removeAll { $0 == accountID }
        } else {
            model.chains[index].accountIDs.append(accountID)
        }
    }

    func createChain(named name: String, accountIDs: [UUID]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !accountIDs.isEmpty else { return }
        model.chains.append(
            CloudDriveChain(name: trimmed, accountIDs: accountIDs)
        )
    }

    func removeChain(_ chainID: UUID) {
        model.chains.removeAll { $0.id == chainID }
    }

    func setUnifiedSearch(_ enabled: Bool) {
        model.unifiedSearchEnabled = enabled
    }

    func unifiedSearchResults(for query: String) -> [CloudSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.unifiedSearchEnabled, !trimmed.isEmpty else { return [] }

        let maxResultsPerAccount = 20

        return model.accounts.compactMap { account -> [CloudSearchResult]? in
            guard account.isConnected, let rootURL = account.localRootURL else { return nil }

            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            var matches: [CloudSearchResult] = []
            while let url = enumerator?.nextObject() as? URL, matches.count < maxResultsPerAccount {
                guard url.lastPathComponent.localizedCaseInsensitiveContains(trimmed) else { continue }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let kind = isDirectory ? "Folder" : (url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased())
                let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")

                matches.append(
                    CloudSearchResult(
                        title: url.lastPathComponent,
                        accountName: account.displayName,
                        pathDescription: "\(account.rootName)/\(relativePath)",
                        kind: kind,
                        sizeBytes: isDirectory ? nil : Int64(values?.fileSize ?? 0),
                        modified: values?.contentModificationDate ?? .now,
                        targetURL: url
                    )
                )
            }

            return matches
        }
        .flatMap { $0 }
        .sorted { $0.modified > $1.modified }
    }

    private func makeAccount(
        provider: CloudProvider,
        displayName: String? = nil,
        localRootURL: URL?,
        oauthClientID: String? = nil,
        oauthTenant: String? = nil,
        remoteEndpoint: String? = nil,
        s3Configuration: CloudDriveAccount.S3Configuration? = nil
    ) -> CloudDriveAccount {
        let resolvedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootName = localRootURL?.lastPathComponent
            ?? s3Configuration?.bucketName
            ?? provider.rawValue
        let storageLimitBytes: Int64 = localRootURL == nil ? 0 : 15 * 1_024 * 1_024 * 1_024
        return CloudDriveAccount(
            displayName: resolvedDisplayName?.isEmpty == false ? resolvedDisplayName! : provider.rawValue,
            provider: provider,
            rootName: rootName,
            localRootPath: localRootURL?.path,
            oauthClientID: oauthClientID,
            oauthTenant: oauthTenant,
            remoteEndpoint: remoteEndpoint,
            storageLimitBytes: storageLimitBytes,
            isConnected: localRootURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true,
            accentHex: provider.accentHex,
            s3Configuration: s3Configuration
        )
    }

    private static func urls(in directory: URL, matchingPrefixes prefixes: [String]) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { url in
            prefixes.contains { prefix in
                url.lastPathComponent.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(model) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct CloudDriveManagementView: View {
    @ObservedObject var store: CloudWorkspaceStore
    @State private var newAccountName = ""
    @State private var newProviderType: CloudProvider = .googleDrive
    @State private var newOAuthClientID = ""
    @State private var newOAuthClientSecret = ""
    @State private var newOAuthTenant = "common"
    @State private var newS3Bucket = ""
    @State private var newS3Region: S3Regions = .usEast1
    @State private var newS3AccessKeyID = ""
    @State private var newS3SecretAccessKey = ""
    @State private var newS3SessionToken = ""
    @State private var selectedRootURL: URL?
    @State private var showRootPicker = false
    @State private var newChainName = "New Chain"
    @State private var selectedAccountIDsForNewChain: Set<UUID> = []

    init(store: CloudWorkspaceStore? = nil) {
        self.store = store ?? CloudWorkspaceStore.shared
    }

    var body: some View {
        HSplitView {
            accountList
                .frame(minWidth: 280, idealWidth: 320)

            VStack(spacing: 16) {
                addAccountSection
                chainSection
                unifiedSearchSection
            }
            .frame(minWidth: 340)
        }
        .onAppear {
            store.refreshAccountConnections()
            if selectedRootURL == nil {
                selectedRootURL = store.suggestedRoots(for: newProviderType).first
            }
        }
        .onChange(of: newProviderType) { _, provider in
            selectedRootURL = store.suggestedRoots(for: provider).first
        }
        .fileImporter(
            isPresented: $showRootPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                selectedRootURL = urls.first
            }
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Accounts")
                .font(.title3)
                .fontWeight(.semibold)

            List {
                ForEach(store.model.accounts) { account in
                    CloudAccountRowView(account: account, store: store) {
                        store.removeAccount(account.id)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding()
    }

    private var addAccountSection: some View {
        GroupBox("Add Cloud Account") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $newProviderType) {
                    ForEach(CloudProvider.allCases) { provider in
                        Label(provider.rawValue, systemImage: provider.systemImage)
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Display name", text: $newAccountName)
                    .textFieldStyle(.roundedBorder)

                let suggestedRoots = store.suggestedRoots(for: newProviderType)

                HStack(spacing: 8) {
                    Button("Choose Sync Folder...") {
                        showRootPicker = true
                    }

                    if !suggestedRoots.isEmpty {
                        Menu("Use Suggested Root") {
                            ForEach(suggestedRoots, id: \.self) { root in
                                Button(root.path) {
                                    selectedRootURL = root
                                }
                            }
                        }
                    }
                }

                Text(selectedRootURL?.path ?? "No sync folder selected. You can still add the account and link it later.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if newProviderType == .googleDrive || newProviderType == .dropbox || newProviderType == .oneDrive || newProviderType == .box {
                    TextField("OAuth client ID", text: $newOAuthClientID)
                        .textFieldStyle(.roundedBorder)

                    SecureField("OAuth client secret (optional for PKCE/public clients)", text: $newOAuthClientSecret)
                        .textFieldStyle(.roundedBorder)

                    if newProviderType == .oneDrive {
                        TextField("Tenant", text: $newOAuthTenant)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("Register the redirect URI `http://localhost:53682/oauth/callback` with your provider app, then click Connect on the account after adding it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if newProviderType == .awsS3 {
                    TextField("Bucket name", text: $newS3Bucket)
                        .textFieldStyle(.roundedBorder)

                    Picker("Region", selection: $newS3Region) {
                        ForEach(S3Regions.allCases, id: \.self) { region in
                            Text(region.rawValue).tag(region)
                        }
                    }

                    TextField("Access key ID", text: $newS3AccessKeyID)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Secret access key", text: $newS3SecretAccessKey)
                        .textFieldStyle(.roundedBorder)

                    TextField("Session token (optional)", text: $newS3SessionToken)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Add \(newProviderType.rawValue) Account") {
                    addNewAccount()
                }
                .disabled(!canAddAccount)
            }
            .padding(.vertical, 4)
        }
    }

    private var canAddAccount: Bool {
        let nameValid = !newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if newProviderType == .awsS3 {
            return nameValid
                && !newS3Bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !newS3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !newS3SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if newProviderType == .googleDrive || newProviderType == .dropbox || newProviderType == .oneDrive || newProviderType == .box {
            return nameValid && (!newOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRootURL != nil)
        }
        return nameValid
    }

    private func addNewAccount() {
        let trimmed = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var s3Config: CloudDriveAccount.S3Configuration? = nil
        if newProviderType == .awsS3 {
            let bucket = newS3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            s3Config = CloudDriveAccount.S3Configuration(
                bucketName: bucket,
                region: newS3Region.rawValue,
                endpoint: nil
            )
        }

        let trimmedClientID = newOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTenant = newOAuthTenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = newOAuthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let s3Credentials = newProviderType == .awsS3 ? StoredS3Credential(
            accessKeyID: newS3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: newS3SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionToken: newS3SessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newS3SessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        ) : nil

        store.addAccount(
            provider: newProviderType,
            displayName: trimmed,
            localRootURL: selectedRootURL,
            oauthClientID: trimmedClientID.isEmpty ? nil : trimmedClientID,
            oauthTenant: trimmedTenant.isEmpty ? nil : trimmedTenant,
            oauthClientSecret: trimmedClientSecret.isEmpty ? nil : trimmedClientSecret,
            s3Configuration: s3Config,
            s3Credentials: s3Credentials
        )

        newAccountName = ""
        newOAuthClientID = ""
        newOAuthClientSecret = ""
        newOAuthTenant = "common"
        newS3Bucket = ""
        newS3Region = .usEast1
        newS3AccessKeyID = ""
        newS3SecretAccessKey = ""
        newS3SessionToken = ""
        selectedRootURL = store.suggestedRoots(for: newProviderType).first
    }

    private var chainSection: some View {
        GroupBox("Chained Drives") {
            VStack(alignment: .leading, spacing: 12) {
                if store.model.chains.isEmpty {
                    Text("No chains configured yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.model.chains) { chain in
                        CloudChainRowView(
                            chain: chain,
                            accounts: store.model.accounts(for: chain),
                            onDelete: { store.removeChain(chain.id) }
                        )
                    }
                }

                Divider()

                Text("Create Chain")
                    .font(.headline)

                TextField("Chain name", text: $newChainName)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.model.accounts) { account in
                        Toggle(isOn: Binding(
                            get: { selectedAccountIDsForNewChain.contains(account.id) },
                            set: { enabled in
                                if enabled {
                                    selectedAccountIDsForNewChain.insert(account.id)
                                } else {
                                    selectedAccountIDsForNewChain.remove(account.id)
                                }
                            }
                        )) {
                            Label(account.displayName, systemImage: account.provider.systemImage)
                        }
                    }
                }

                Button("Create Chain") {
                    store.createChain(
                        named: newChainName,
                        accountIDs: Array(selectedAccountIDsForNewChain)
                    )
                    selectedAccountIDsForNewChain.removeAll()
                    newChainName = "New Chain"
                }
                .disabled(selectedAccountIDsForNewChain.isEmpty || newChainName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.vertical, 4)
        }
    }

    private var unifiedSearchSection: some View {
        GroupBox("Unified Search") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable unified search across cloud drives", isOn: Binding(
                    get: { store.model.unifiedSearchEnabled },
                    set: { store.setUnifiedSearch($0) }
                ))

                Text("Unified search still scans connected local sync folders. Remote API browsing works even without those sync apps, but remote search is intentionally kept separate for now.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

struct CloudAccountRowView: View {
    let account: CloudDriveAccount
    @ObservedObject var store: CloudWorkspaceStore
    var onDelete: () -> Void

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(account.displayName, systemImage: account.provider.systemImage)
                    .font(.headline)
                Spacer()
                Text(store.authenticationLabel(for: account))
                    .font(.caption)
                    .foregroundColor(account.isConnected ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.rootName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let localRootURL = account.localRootURL {
                    Text(localRootURL.path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if account.provider == .awsS3, let config = account.s3Configuration {
                    HStack(spacing: 4) {
                        Text(config.bucketName)
                        Text("•")
                        Text(config.region)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }

                if let oauthClientID = account.oauthClientID, !oauthClientID.isEmpty {
                    HStack(spacing: 4) {
                        Text("Client ID")
                        Text("•")
                        Text(oauthClientID)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            }

            if account.storageLimitBytes > 0 {
                ProgressView(value: account.usageFraction)
                    .tint(Color(hex: account.accentHex) ?? .accentColor)

                HStack {
                    Text(byteFormatter.string(fromByteCount: account.usedBytes))
                    Text("used of")
                    Text(byteFormatter.string(fromByteCount: account.storageLimitBytes))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            HStack {
                if let localRootURL = account.localRootURL,
                   FileManager.default.fileExists(atPath: localRootURL.path) {
                    Button("Reveal") {
                        NSWorkspace.shared.open(localRootURL)
                    }
                    .buttonStyle(.borderless)
                }

                if account.supportsRemoteBrowsing && account.hasRemoteConfiguration {
                    Button(store.isRemotelyAuthenticated(account) ? "Reconnect" : "Connect") {
                        Task {
                            try? await store.connectAccount(account.id)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                if account.provider == .awsS3 && !account.isConnected {
                    Text("Credentials are stored securely in Keychain.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()
                Button("Remove", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CloudChainRowView: View {
    let chain: CloudDriveChain
    let accounts: [CloudDriveAccount]
    var onDelete: () -> Void

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    private var totalLimit: Int64 {
        accounts.reduce(0) { $0 + $1.storageLimitBytes }
    }

    private var totalUsed: Int64 {
        accounts.reduce(0) { $0 + $1.usedBytes }
    }

    private var usageFraction: Double {
        guard totalLimit > 0 else { return 0 }
        return min(max(Double(totalUsed) / Double(totalLimit), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(chain.name, systemImage: "link")
                    .font(.headline)
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
            }

            Text(accounts.map(\.displayName).joined(separator: " → "))
                .font(.caption)
                .foregroundColor(.secondary)

            ProgressView(value: usageFraction)
                .tint(.accentColor)

            Text("\(byteFormatter.string(fromByteCount: totalUsed)) used of \(byteFormatter.string(fromByteCount: totalLimit))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct CloudUnifiedSearchResultsView: View {
    let query: String
    let results: [CloudSearchResult]

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Search")
                .font(.title3)
                .fontWeight(.semibold)

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Start typing to search across connected cloud drives.")
                    .foregroundColor(.secondary)
            } else if results.isEmpty {
                ContentUnavailableView(
                    "No Cloud Results",
                    systemImage: "magnifyingglass",
                    description: Text("No cloud items matched "\(query)".")
                )
            } else {
                List(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.headline)
                        Text(result.pathDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Text(result.accountName)
                            Text("•")
                            Text(result.kind)
                            if let sizeBytes = result.sizeBytes {
                                Text("•")
                                Text(byteFormatter.string(fromByteCount: sizeBytes))
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding()
    }
}

#Preview("Cloud Drive Management") {
    CloudDriveManagementView()
}

#Preview("Cloud Search Results") {
    CloudUnifiedSearchResultsView(
        query: "design",
        results: CloudWorkspaceStore.shared.unifiedSearchResults(for: "design")
    )
}
