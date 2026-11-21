import Foundation
import Security

// The production service selects a fresh random Keychain namespace whenever
// LIFEBOARD_DATA_PATH is set. Require a disposable directory before touching it.
guard let path = ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"],
      path.hasPrefix("/tmp/lifeboard-audit-tests.") || path.hasPrefix("/private/tmp/lifeboard-audit-tests.") else {
    fatalError("Credential policy regression requires an isolated audit-test data path")
}
let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
guard !FileManager.default.fileExists(atPath: SyncService.credentialsURL.path) else {
    fatalError("Refusing to read any existing legacy credentials")
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS " + message)
}
func interactionAllowed() -> Bool {
    var allowed = DarwinBoolean(false)
    expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
           "Security API reads this process's interaction policy")
    return allowed.boolValue
}

// These APIs affect this test process, not another application or Keychain ACL.
expect(SecKeychainSetUserInteractionAllowed(true) == errSecSuccess,
       "Synthetic test process can begin with interaction enabled")
expect(interactionAllowed(), "Synthetic process initially permits interaction")
expect(SyncService.secret("device") == nil, "Missing isolated credentials return no device secret")
expect(!interactionAllowed(), "Background credential read disables login-Keychain interaction")
expect(SyncService.secret("pairing") == nil, "Repeated missing isolated read returns no pairing secret")
expect(!interactionAllowed(), "Repeated background read keeps interaction disabled")

var rejectedMissingCredentials = false
do { try SyncService.requestCredentialAccess() }
catch SyncFailure.credentialsUnavailable { rejectedMissingCredentials = true }
expect(rejectedMissingCredentials, "Explicit access reports missing isolated credentials")
expect(!interactionAllowed(), "Explicit access restores disabled interaction after failure")
expect(!FileManager.default.fileExists(atPath: SyncService.credentialsURL.path),
       "Policy checks create no legacy credential file")
print("LifeBoard isolated native credential interaction regression passed")
