// Canary fixture for xcindex tests.
//
// Known symbols this file contributes:
// - `AuthManager` (protocol) — used by `DefaultAuthManager` (conformance)
//   and by `UserService.auth` (type).
// - `DefaultAuthManager` (class) — single conformance of `AuthManager`.
// - `DefaultAuthManager.refreshSession()` — extension member, used to
//   exercise the extension_member reason tag.
//
// Do not rename or restructure without updating the expectations in
// `IndexQuerierTests.swift`.

protocol AuthManager {
    func authenticate(user: String) -> Bool
}

class DefaultAuthManager: AuthManager {
    func authenticate(user: String) -> Bool {
        return !user.isEmpty
    }
}

extension DefaultAuthManager {
    func refreshSession() {
        _ = authenticate(user: "canary")
    }
}
