import Foundation

/// Locates the IndexStore DataStore for a given project path.
///
/// Strategy:
///  1. If `indexStorePath` is provided directly, use it.
///  2. Derive the project name from `projectPath` (basename without extension).
///  3. Build an ordered, deduplicated list of base directories to scan:
///     the user's custom `IDECustomDerivedDataLocation` (absolute as-is,
///     relative resolved against the project's directory), followed by the
///     default root (`derivedDataBaseOverride` if given, else
///     `~/Library/Developer/Xcode/DerivedData`).
///  4. Scan each base for entries named exactly `<ProjectName>` (the
///     unhashed form Xcode uses under a relative custom location) or
///     prefixed `<ProjectName>-` (the normal hashed form). A missing or
///     unreadable base is skipped, never fatal.
///  5. Each candidate's `info.plist` records the `WorkspacePath` it was
///     built from. Candidates are classified verified (matches
///     `projectPath`), unknown (no readable provenance), or mismatch
///     (belongs to a different workspace). Verified candidates are
///     preferred over unknown ones; if only mismatches exist, resolution
///     is refused rather than silently picking a sibling checkout's data.
///  6. Among the chosen pool, return the most recently modified candidate
///     with an `Index.noindex/DataStore`.
enum DerivedDataLocator {
    /// How the locator learns the user's `IDECustomDerivedDataLocation`.
    enum CustomLocation {
        /// Production: read from `UserDefaults(suiteName: "com.apple.dt.Xcode")`.
        case readFromXcodeDefaults
        /// Tests: no custom location is configured.
        case none
        /// Tests: a fixed value, as Xcode would store it (absolute or relative).
        case value(String)
    }

    /// - Parameter derivedDataBaseOverride: Override the default DerivedData
    ///   root used for scanning. Defaults to the user's
    ///   ~/Library/Developer/Xcode/DerivedData. Exists so unit tests can
    ///   point at a fixture directory under `$TMPDIR` instead of the real
    ///   one. Scanned alongside (never instead of) any custom location.
    /// - Parameter customLocation: How to learn the user's custom
    ///   DerivedData location. Defaults to reading Xcode's real
    ///   preferences; tests should pass `.none` or `.value(...)` so they
    ///   never depend on the developer's machine state.
    static func indexStorePath(
        projectPath: String?,
        indexStorePath: String?,
        derivedDataBaseOverride: URL? = nil,
        customLocation: CustomLocation = .readFromXcodeDefaults
    ) throws -> String {
        if let explicit = indexStorePath, !explicit.isEmpty {
            return explicit
        }

        guard let projectPath, !projectPath.isEmpty else {
            throw LocatorError.noProjectPath
        }

        let projectURL = URL(fileURLWithPath: projectPath)
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let projectDir = projectURL.deletingLastPathComponent()

        guard !projectName.isEmpty else {
            throw LocatorError.invalidProjectPath(projectPath)
        }

        let bases = resolveBases(
            projectDir: projectDir,
            derivedDataBaseOverride: derivedDataBaseOverride,
            customLocation: customLocation
        )

        let (candidates, scannedBases) = scanCandidates(bases: bases, projectName: projectName)

        guard !candidates.isEmpty else {
            throw LocatorError.noDerivedData(projectName, scannedBases.joined(separator: ", "))
        }

        let pool = try selectPool(candidates: candidates, projectPath: projectPath)

        let sorted = try pool.sorted { lhs, rhs in
            let dateA = try lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let dateB = try rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return dateA > dateB
        }

        guard let newest = sorted.first else {
            throw LocatorError.noDerivedData(projectName, scannedBases.joined(separator: ", "))
        }

        let dataStore = newest.appendingPathComponent("Index.noindex/DataStore")

        guard FileManager.default.fileExists(atPath: dataStore.path) else {
            throw LocatorError.noIndexStore(newest.path)
        }

        return dataStore.path
    }

    /// Scans each base for entries matching `projectName` (exact or
    /// `<projectName>-` prefixed). A missing or unreadable base is
    /// skipped, never fatal. Returns the candidates plus every base path
    /// scanned, for error reporting.
    private static func scanCandidates(bases: [URL], projectName: String) -> (candidates: [URL], scannedBases: [String]) {
        let fm = FileManager.default
        var candidates: [URL] = []
        var scannedBases: [String] = []
        for base in bases {
            scannedBases.append(base.path)
            guard let contents = try? fm.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else {
                continue
            }
            let matches = contents.filter {
                $0.lastPathComponent == projectName || $0.lastPathComponent.hasPrefix("\(projectName)-")
            }
            candidates.append(contentsOf: matches)
        }
        return (candidates, scannedBases)
    }

    /// Classifies candidates by provenance and returns the pool to sort
    /// and select from: verified candidates if any exist, else unknown
    /// ones. Throws when only mismatching candidates remain.
    private static func selectPool(candidates: [URL], projectPath: String) throws -> [URL] {
        var verified: [URL] = []
        var unknown: [URL] = []
        var mismatched: [URL] = []
        for candidate in candidates {
            switch classifyProvenance(of: candidate, projectPath: projectPath) {
            case .verified: verified.append(candidate)
            case .unknown: unknown.append(candidate)
            case .mismatch: mismatched.append(candidate)
            }
        }

        if !verified.isEmpty {
            return verified
        }
        if !unknown.isEmpty {
            return unknown
        }
        throw LocatorError.noMatchingWorkspace(projectPath, mismatched.map(\.path))
    }

    // MARK: - Base directory resolution

    /// Builds the ordered, deduplicated (by standardized path) list of
    /// directories to scan: the custom location (if any) first, then the
    /// default root.
    private static func resolveBases(
        projectDir: URL,
        derivedDataBaseOverride: URL?,
        customLocation: CustomLocation
    ) -> [URL] {
        var bases: [URL] = []
        var seenStandardized = Set<String>()
        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seenStandardized.insert(key).inserted {
                bases.append(url)
            }
        }

        let customValue: String? = switch customLocation {
        case .readFromXcodeDefaults: customDerivedDataPath()
        case .none: nil
        case .value(let value): value
        }

        if let customValue, !customValue.isEmpty {
            if customValue.hasPrefix("/") {
                add(URL(fileURLWithPath: customValue))
            } else {
                add(projectDir.appendingPathComponent(customValue))
            }
        }

        if let override = derivedDataBaseOverride {
            add(override)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            add(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        }

        return bases
    }

    // MARK: - Custom DerivedData path

    /// Reads the user's custom DerivedData path from Xcode preferences, if set.
    private static func customDerivedDataPath() -> String? {
        // Xcode writes this key only when the user overrides the default location.
        let defaults = UserDefaults(suiteName: "com.apple.dt.Xcode")
        return defaults?.string(forKey: "IDECustomDerivedDataLocation")
    }

    // MARK: - Provenance

    private enum Provenance {
        case verified
        case unknown
        case mismatch
    }

    /// Classifies a candidate DerivedData container against `projectPath`
    /// using the `WorkspacePath` recorded in its `info.plist`.
    private static func classifyProvenance(of candidate: URL, projectPath: String) -> Provenance {
        let plistURL = candidate.appendingPathComponent("info.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let workspacePath = plist["WorkspacePath"] as? String
        else {
            return .unknown
        }

        let standardizedWorkspace = standardizedPath(workspacePath)
        let standardizedProject = standardizedPath(projectPath)

        if standardizedWorkspace == standardizedProject {
            return .verified
        }

        // A bare .xcodeproj build records the bundle-internal workspace.
        let bundledWorkspaceSuffix = "/project.xcworkspace"
        if standardizedWorkspace.hasSuffix(bundledWorkspaceSuffix) {
            let owningProject = String(standardizedWorkspace.dropLast(bundledWorkspaceSuffix.count))
            if owningProject == standardizedProject {
                return .verified
            }
        }

        return .mismatch
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Errors

    enum LocatorError: LocalizedError {
        case noProjectPath
        case invalidProjectPath(String)
        case noDerivedData(String, String)
        case noMatchingWorkspace(String, [String])
        case noIndexStore(String)

        var errorDescription: String? {
            switch self {
            case .noProjectPath:
                return "Either 'projectPath' or 'indexStorePath' must be provided."
            case .invalidProjectPath(let path):
                return "Could not derive project name from path: \(path)"
            case .noDerivedData(let name, let base):
                return "No DerivedData folder found for '\(name)' under \(base). " +
                    "Build the project in Xcode first."
            case .noMatchingWorkspace(let projectPath, let mismatched):
                let names = mismatched.joined(separator: ", ")
                return "Found DerivedData for this project name, but every candidate " +
                    "belongs to a different workspace than \(projectPath): \(names). " +
                    "Build this project in Xcode to create its own DerivedData, or pass " +
                    "indexStorePath explicitly."
            case .noIndexStore(let folder):
                return "DerivedData folder '\(folder)' exists but has no " +
                    "Index.noindex/DataStore — build with indexing enabled."
            }
        }
    }
}
