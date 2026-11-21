import Foundation
import Security
import LocalAuthentication
import LifeBoardCore

struct SyncEnvelope: Decodable {
    let revision: Int
    let data: LifeBoardData?
    private enum CodingKeys: String, CodingKey { case revision, data }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(SyncRevision.self, forKey: .revision).value
        data = try values.decodeIfPresent(LifeBoardData.self, forKey: .data)
    }
}

struct SyncSaveReceipt: Decodable {
    let revision: Int
    private enum CodingKeys: String, CodingKey { case revision }
    init(from decoder: Decoder) throws {
        revision = try decoder.container(keyedBy: CodingKeys.self).decode(SyncRevision.self, forKey: .revision).value
    }
}

private struct SyncRevision: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let field = try decoder.singleValueContainer()
        if let number = try? field.decode(Int.self) { value = number; return }
        if let raw = try? field.decode(String.self), let number = Int(raw) { value = number; return }
        throw DecodingError.dataCorruptedError(in: field, debugDescription: "Invalid sync revision")
    }
}

struct SyncBaseline: Codable {
    let revision: Int
    let data: LifeBoardData
}

enum SyncService {
    private struct Credentials: Codable {
        let device: String
        let pairing: String
    }
    private static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] { return URL(fileURLWithPath: path).deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LifeBoard")
    }
    static var credentialsURL: URL { directory.appendingPathComponent("SyncCredentials.json") }
    static var configurationURL: URL { directory.appendingPathComponent("SyncEndpoint.txt") }
    static var baselineURL: URL { directory.appendingPathComponent("SyncBaseline.json") }
    static var workspaceIdentityURL: URL { directory.appendingPathComponent("WorkspaceIdentity.txt") }

    static func endpoint() -> URL? {
        guard let value = try? String(contentsOf: configurationURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static let keychainService = ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil ? "app.lifeboard.mac.sync" : "app.lifeboard.mac.sync.test." + UUID().uuidString
    private static let credentialLock = NSLock()
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "workspace-credentials"]
    }

    private static func readCredentials(allowInteraction: Bool = false) throws -> Credentials? {
        // LAContext controls data-protection authentication, but the macOS
        // login Keychain has a separate ACL prompt. Disable that process-local
        // UI too, so an ad hoc rebuild cannot block the app's background sync.
        // Only the explicit Retry Keychain access action may enable it.
        guard SecKeychainSetUserInteractionAllowed(allowInteraction) == errSecSuccess else {
            throw SyncFailure.credentialsUnavailable
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(false) }
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data else { throw SyncFailure.credentialsUnavailable }
        return try JSONDecoder().decode(Credentials.self, from: bytes)
    }

    // Background sync never opens security prompts. A user can explicitly
    // authorise the existing connection when an updated signature needs access.
    static func requestCredentialAccess() throws {
        credentialLock.lock(); defer { credentialLock.unlock() }
        guard try readCredentials(allowInteraction: true) != nil else { throw SyncFailure.credentialsUnavailable }
    }

    private static func writeCredentials(_ credentials: Credentials) throws {
        let bytes = try JSONEncoder().encode(credentials)
        var query = keychainQuery
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let existing = try readCredentials()
        let status: OSStatus
        if existing == nil { status = SecItemAdd(query as CFDictionary, nil) }
        else { status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: bytes] as CFDictionary) }
        guard status == errSecSuccess,
              let verified = try readCredentials(), verified.device == credentials.device,
              verified.pairing == credentials.pairing else { throw SyncFailure.credentialsUnavailable }
    }

    // Never fall back to plaintext when Keychain denies access. Delete legacy
    // credentials only after a successful write and byte-equivalent readback.
    static func secret(_ account: String) -> String? {
        credentialLock.lock(); defer { credentialLock.unlock() }
        do {
            let credentials: Credentials
            if let stored = try readCredentials() { credentials = stored }
            else {
                guard FileManager.default.fileExists(atPath: credentialsURL.path) else { return nil }
                let legacy = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: credentialsURL))
                try writeCredentials(legacy)
                credentials = legacy
            }
            if FileManager.default.fileExists(atPath: credentialsURL.path) {
                // Recheck the migrated file, so an unrelated/new file is not removed.
                let legacy = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: credentialsURL))
                if legacy.device == credentials.device && legacy.pairing == credentials.pairing {
                    try FileManager.default.removeItem(at: credentialsURL)
                }
            }
            return account == "device" ? credentials.device : account == "pairing" ? credentials.pairing : nil
        } catch { return nil }
    }

    static func installCredentials(deviceToken: String) throws {
        guard !deviceToken.isEmpty, deviceToken.count <= 512 else { throw SyncFailure.credentialsUnavailable }
        credentialLock.lock(); defer { credentialLock.unlock() }
        try writeCredentials(Credentials(device: deviceToken, pairing: ""))
    }

    // Connect only a fresh installation. Replacing existing credentials requires
    // an explicit disconnect; this prevents inviting a tester from switching the
    // owner's current workspace and uploading its data to a different workspace.
    static func configureWorkspace(endpoint: URL, deviceToken: String) throws {
        guard endpoint.scheme == "https", endpoint.host != nil,
              endpoint.path == "/api/snapshot", endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw SyncFailure.unavailable }
        guard secret("device") == nil,
              !FileManager.default.fileExists(atPath: baselineURL.path),
              !FileManager.default.fileExists(atPath: credentialsURL.path) else { throw SyncFailure.alreadyConnected }
        // A denied Keychain item must not look like a fresh installation.
        credentialLock.lock()
        do { _ = try readCredentials(); credentialLock.unlock() }
        catch { credentialLock.unlock(); throw error }
        try installCredentials(deviceToken: deviceToken)
        let folder = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try endpoint.absoluteString.data(using: .utf8)!.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

    static func disconnect() throws {
        credentialLock.lock(); defer { credentialLock.unlock() }
        // Ensure an inaccessible existing item is reported rather than hidden.
        _ = try readCredentials()
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncFailure.credentialsUnavailable }
        if FileManager.default.fileExists(atPath: credentialsURL.path) { try FileManager.default.removeItem(at: credentialsURL) }
        if FileManager.default.fileExists(atPath: baselineURL.path) { try FileManager.default.removeItem(at: baselineURL) }
        if FileManager.default.fileExists(atPath: configurationURL.path) { try FileManager.default.removeItem(at: configurationURL) }
    }

    struct ConnectedDevice: Decodable, Identifiable {
        let id: String
        let name: String
        let createdAt: String
        let expiresAt: String
        let managesDevices: Bool
    }
    struct PairingChallenge: Decodable { let code: String; let expiresAt: String }
    struct WorkspaceInvitation: Decodable { let workspaceID: String; let deviceToken: String }
    private struct DeviceList: Decodable { let devices: [ConnectedDevice] }

    private static func managementRequest(endpoint: URL, token: String, route: String, method: String, body: [String: String]? = nil) async throws -> Data {
        guard endpoint.scheme == "https", let url = URL(string: route, relativeTo: endpoint)?.absoluteURL else { throw SyncFailure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncFailure.credentialsUnavailable }
        guard (200...299).contains(http.statusCode) else { throw SyncFailure.unavailable }
        return bytes
    }
    static func listDevices(from endpoint: URL, token: String) async throws -> [ConnectedDevice] {
        let bytes = try await managementRequest(endpoint: endpoint, token: token, route: "/api/devices", method: "GET")
        return try JSONDecoder().decode(DeviceList.self, from: bytes).devices
    }
    static func revokeDevice(id: String, from endpoint: URL, token: String) async throws {
        _ = try await managementRequest(endpoint: endpoint, token: token, route: "/api/devices", method: "DELETE", body: ["id": id])
    }
    static func createChallenge(from endpoint: URL, token: String, deviceName: String = "Phone") async throws -> PairingChallenge {
        let bytes = try await managementRequest(endpoint: endpoint, token: token, route: "/api/challenge", method: "POST", body: ["deviceName": deviceName])
        return try JSONDecoder().decode(PairingChallenge.self, from: bytes)
    }
    struct InvitationFile: Decodable { let endpoint: URL; let workspaceID: String; let deviceToken: String }
    private struct SessionIdentity: Decodable { let workspaceID: String }
    static func verifyInvitation(_ invitation: InvitationFile) async throws {
        guard UUID(uuidString: invitation.workspaceID) != nil,
              invitation.deviceToken.count >= 32, invitation.deviceToken.count <= 256,
              invitation.endpoint.scheme == "https", invitation.endpoint.path == "/api/snapshot",
              invitation.endpoint.user == nil, invitation.endpoint.password == nil,
              invitation.endpoint.query == nil, invitation.endpoint.fragment == nil else { throw SyncFailure.unavailable }
        let bytes = try await managementRequest(endpoint: invitation.endpoint, token: invitation.deviceToken, route: "/api/session", method: "GET")
        guard try JSONDecoder().decode(SessionIdentity.self, from: bytes).workspaceID == invitation.workspaceID else { throw SyncFailure.unavailable }
    }
    // Admin invitations are handed to separate tester installations. Never install
    // this returned token over the owner's existing workspace or sync baseline.
    static func provisionWorkspace(from endpoint: URL, adminToken: String) async throws -> WorkspaceInvitation {
        let bytes = try await managementRequest(endpoint: endpoint, token: adminToken, route: "/api/workspaces", method: "POST")
        return try JSONDecoder().decode(WorkspaceInvitation.self, from: bytes)
    }

    static func baseline() -> SyncBaseline? {
        guard let bytes = try? Data(contentsOf: baselineURL) else { return nil }
        let decoder = LifeBoardJSON.decoder()
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let raw = object["data"], let dataBytes = try? JSONSerialization.data(withJSONObject: raw),
              (try? LifeBoardValidation.decode(dataBytes)) != nil else { return nil }
        return try? decoder.decode(SyncBaseline.self, from: bytes)
    }

    static func saveBaseline(_ baseline: SyncBaseline) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(baseline)
        try bytes.write(to: baselineURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: baselineURL.path)
    }

    static func fetch(from endpoint: URL, token: String) async throws -> SyncEnvelope {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SyncFailure.unavailable }
        let decoder = LifeBoardJSON.decoder()
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SyncFailure.unavailable }
        if let raw = object["data"], !(raw is NSNull) {
            _ = try LifeBoardValidation.decode(JSONSerialization.data(withJSONObject: raw))
        }
        return try decoder.decode(SyncEnvelope.self, from: bytes)
    }

    static func save(_ data: LifeBoardData, revision: Int, to endpoint: URL, token: String) async throws -> Int? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        let payload = try encoder.encode(data)
        _ = try LifeBoardValidation.decode(payload)
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(revision), forHTTPHeaderField: "If-Match")
        request.timeoutInterval = 20
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.unavailable }
        if http.statusCode == 409 { return nil }
        guard http.statusCode == 200 else { throw SyncFailure.unavailable }
        return try JSONDecoder().decode(SyncSaveReceipt.self, from: bytes).revision
    }
}

enum SyncFailure: Error { case unavailable, credentialsUnavailable, alreadyConnected }
