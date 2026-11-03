import Foundation

/// Locates the IndexStore DataStore for a given project path.
///
/// Strategy:
///  1. If `indexStorePath` is provided directly, use it.
///  2. A directory `projectPath` resolves to the .xcworkspace/.xcodeproj
///     inside it; one without a bundle (SwiftPM package) keeps its own name.
///  3. Scan DerivedData for folders named `<ProjectName>-*`.
///  4. Drop folders whose info.plist `WorkspacePath` names a different
///     checkout — worktrees and clones share a project name, and the newest
///     sibling's index is silently wrong rather than missing.
///  5. Prefer an exact `WorkspacePath` match, then the most recently modified.
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

        let projectURL = resolveProjectBundle(URL(fileURLWithPath: projectPath))
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
        let wanted = projectURL.resolvingSymlinksInPath().path
        let owned = contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { (url: $0, owner: workspacePath(of: $0)) }
            .filter { $0.owner == nil || $0.owner == wanted }

        guard !owned.isEmpty else {
            throw LocatorError.noDerivedData(projectName, derivedDataBase.path)
        }

        let exact = owned.filter { $0.owner == wanted }.map(\.url)
        let candidates = exact.isEmpty ? owned.map(\.url) : exact

        let sorted = try candidates.sorted { lhs, rhs in
            let dateA = try lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let dateB = try rhs.resourceValues(forKeys: [.contentModificationDateKey])
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

    // MARK: - Project resolution

    /// Maps a plain directory to the Xcode bundle it contains, preferring a
    /// workspace. Bundles and bundle-less directories pass through unchanged.
    private static func resolveProjectBundle(_ url: URL) -> URL {
        guard !["xcodeproj", "xcworkspace"].contains(url.pathExtension),
              let children = try? FileManager.default.contentsOfDirectory(
                  at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              )
        else { return url }
        for ext in ["xcworkspace", "xcodeproj"] {
            if let match = children.filter({ $0.pathExtension == ext })
                .min(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                return match
            }
        }
        return url
    }

    /// The project Xcode recorded as owning a DerivedData folder, if any.
    private static func workspacePath(of folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let path = (plist as? [String: Any])?["WorkspacePath"] as? String
        else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Custom DerivedData path

    /// Reads the user's custom DerivedData path from Xcode preferences, if set.
    private static func customDerivedDataPath() -> String? {
        // Xcode writes this key only when the user overrides the default location.
        let defaults = UserDefaults(suiteName: "com.apple.dt.Xcode")
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
            case .invalidProjectPath(let path):
                return "Could not derive project name from path: \(path)"
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
