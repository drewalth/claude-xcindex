// Canary fixture for xcindex tests.
//
// Known symbols this file contributes:
// - `UserService` (class) — referenced from `AppDelegate` and `CanaryTests`.
// - `UserService.fetchUser(id:)` (instance method) — called from two files.
//
// Do not rename or restructure without updating the expectations in
// `IndexQuerierTests.swift`.

class UserService {
    let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
    }

    func fetchUser(id: String) -> String? {
        guard auth.authenticate(user: id) else { return nil }
        return "user-\(id)"
    }
}
