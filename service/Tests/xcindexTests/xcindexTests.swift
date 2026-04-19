// Top-level test file for the `xcindex` test target.
//
// Suites are split into dedicated files alongside this one:
//   - FreshnessTests.swift         — unit tests for the hook-contract module.
//   - DerivedDataLocatorTests.swift — unit tests for the resolver.
//   - IndexQuerierTests.swift      — integration tests against a real
//                                     IndexStore built from the canary
//                                     fixture (Tests/Fixtures/CanaryApp).
//
// Run the whole suite with:
//   cd service && swift test --parallel
//
// See CONTRIBUTING.md for the "happy path + freshness" coverage policy.
