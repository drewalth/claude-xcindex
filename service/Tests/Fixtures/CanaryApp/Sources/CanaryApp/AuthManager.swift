// Canary fixture for xcindex tests.
//
// Known symbols this file contributes:
// - `AuthManager` (protocol) — used by `DefaultAuthManager` (conformance)
//   and by `UserService.auth` (type).
// - `DefaultAuthManager` (class) — single conformance of `AuthManager`.
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
