import Foundation

/// Locates the IndexStore DataStore for a given project path.
///
/// Strategy (mirrors Block's xcode-index-mcp approach):
///  1. If `indexStorePath` is provided directly, use it.
///  2. Derive the project name from `projectPath` (basename without extension).
///  3. Scan `~/Library/Developer/Xcode/DerivedData/` for directories whose
///     name begins with `<ProjectName>-`.
///  4. Among matches, return the one most recently modified.
///  5. Append `Index.noindex/DataStore`.
enum DerivedDataLocator {
    /// - Parameter derivedDataBaseOverride: Override the DerivedData
    ///   directory used for scanning. Defaults to the user's Xcode
    ///   preference or ~/Library/Developer/Xcode/DerivedData. Exists so
    ///   unit tests can point at a fixture directory under `$TMPDIR`
    ///   instead of the real one.
    static func indexStorePath(
        projectPath: String?,
        indexStorePath: String?,
        derivedDataBaseOverride: URL? = nil
    ) throws -> String {
        if let explicit = indexStorePath, !explicit.isEmpty {
            return explicit
        }

        guard let projectPath, !projectPath.isEmpty else {
            throw LocatorError.noProjectPath
        }

        let projectURL = URL(fileURLWithPath: projectPath)
        let projectName = projectURL.deletingPathExtension().lastPathComponent

        guard !projectName.isEmpty else {
            throw LocatorError.invalidProjectPath(projectPath)
        }

        let derivedDataBase: URL
        if let override = derivedDataBaseOverride {
            derivedDataBase = override
        } else if let custom = customDerivedDataPath() {
            derivedDataBase = URL(fileURLWithPath: custom)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            derivedDataBase = home
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        }

        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: derivedDataBase,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )

        let prefix = "\(projectName)-"
        let candidates = contents.filter { $0.lastPathComponent.hasPrefix(prefix) }

        guard !candidates.isEmpty else {
            throw LocatorError.noDerivedData(projectName, derivedDataBase.path)
        }

        // Pick the most recently modified candidate
        let sorted = try candidates.sorted { a, b in
            let dateA = try a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let dateB = try b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return dateA > dateB
        }

        let dataStore = sorted[0]
            .appendingPathComponent("Index.noindex/DataStore")

        guard fm.fileExists(atPath: dataStore.path) else {
            throw LocatorError.noIndexStore(sorted[0].path)
        }

        return dataStore.path
    }

    // MARK: - Custom DerivedData path

    /// Reads the user's custom DerivedData path from Xcode preferences, if set.
    private static func customDerivedDataPath() -> String? {
        let defaults = UserDefaults(suiteName: "com.apple.dt.Xcode")
        // Xcode stores this as IDECustomDerivedDataLocation when the user changes it
        return defaults?.string(forKey: "IDECustomDerivedDataLocation")
    }

    // MARK: - Errors

    enum LocatorError: LocalizedError {
        case noProjectPath
        case invalidProjectPath(String)
        case noDerivedData(String, String)
        case noIndexStore(String)

        var errorDescription: String? {
            switch self {
            case .noProjectPath:
                return "Either 'projectPath' or 'indexStorePath' must be provided."
            case .invalidProjectPath(let p):
                return "Could not derive project name from path: \(p)"
            case .noDerivedData(let name, let base):
                return "No DerivedData folder found for '\(name)' under \(base). " +
                    "Build the project in Xcode first."
            case .noIndexStore(let folder):
                return "DerivedData folder '\(folder)' exists but has no " +
                    "Index.noindex/DataStore — build with indexing enabled."
            }
        }
    }
}
