import Foundation

/// Routes decoded requests to the appropriate query function.
///
/// Keeps an open `IndexQuerier` cached by store path so repeated queries
/// against the same project don't re-open the database each time.
final class RequestProcessor {
    private var querierCache: [String: IndexQuerier] = [:]

    func handle(_ request: Request) -> Response {
        switch request.op {
        case "findRefs":
            return handleFindRefs(request)
        default:
            return Response(error: "Unknown op '\(request.op)'")
        }
    }

    // MARK: - findRefs

    private func handleFindRefs(_ request: Request) -> Response {
        guard let symbolName = request.symbolName, !symbolName.isEmpty else {
            return Response(error: "findRefs requires 'symbolName'")
        }

        do {
            let storePath = try DerivedDataLocator.indexStorePath(
                projectPath: request.projectPath,
                indexStorePath: request.indexStorePath
            )
            let querier = try querierForStore(storePath)
            let occurrences = querier.findRefs(symbolName: symbolName)
            return Response(occurrences: occurrences)
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - Querier cache

    private func querierForStore(_ storePath: String) throws -> IndexQuerier {
        if let cached = querierCache[storePath] {
            return cached
        }
        let querier = try IndexQuerier(storePath: storePath)
        querierCache[storePath] = querier
        return querier
    }
}
