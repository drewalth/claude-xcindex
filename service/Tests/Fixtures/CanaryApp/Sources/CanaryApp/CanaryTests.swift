// Canary fixture for xcindex tests.
//
// The filename contains "Test" so `blastRadius` classifies this as a
// covering test. It calls UserService to ensure the blast-radius graph
// picks it up as an affected test when UserService.swift changes.
//
// Do not rename this file without updating `IndexQuerierTests.swift`.

struct CanaryTests {
    func testFetchUser() {
        let service = UserService(auth: DefaultAuthManager())
        _ = service.fetchUser(id: "test")
    }
}
