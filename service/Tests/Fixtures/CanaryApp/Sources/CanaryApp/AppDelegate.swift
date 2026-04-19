// Canary fixture for xcindex tests.
//
// Known symbols this file contributes:
// - `AppDelegate.setUp()` — overridden by `SubDelegate.setUp()`.
// - `SubDelegate` — subclass used to test `findOverrides`.
//
// This file also exercises `blastRadius`: it imports/uses symbols from
// UserService.swift and AuthManager.swift, making it a direct dependent
// of both.
//
// Do not rename or restructure without updating the expectations in
// `IndexQuerierTests.swift`.

class AppDelegate {
    func setUp() {
        let service = UserService(auth: DefaultAuthManager())
        _ = service.fetchUser(id: "alice")
    }
}

class SubDelegate: AppDelegate {
    override func setUp() {
        super.setUp()
    }
}
