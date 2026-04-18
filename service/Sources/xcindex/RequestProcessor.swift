import Foundation

/// Routes decoded requests to the appropriate query function.
///
/// Keeps an open `IndexQuerier` cached by store path so repeated queries
/// against the same project don't re-open the database each time.
actor RequestProcessor {
    private var querierCache: [String: IndexQuerier] = [:]

    func handle(_ request: Request) -> Response {
        switch request.op {
        case "findRefs":
            return handleFindRefs(request)
        case "findSymbol":
            return handleFindSymbol(request)
        case "findDefinition":
            return handleFindDefinition(request)
        case "findOverrides":
            return handleFindOverrides(request)
        case "findConformances":
            return handleFindConformances(request)
        case "blastRadius":
            return handleBlastRadius(request)
        case "status":
            return handleStatus(request)
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
            let querier = try makeQuerier(request)
            return Response(occurrences: querier.findRefs(symbolName: symbolName))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findSymbol

    private func handleFindSymbol(_ request: Request) -> Response {
        guard let symbolName = request.symbolName, !symbolName.isEmpty else {
            return Response(error: "findSymbol requires 'symbolName'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(symbols: querier.findSymbol(symbolName: symbolName))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findDefinition

    private func handleFindDefinition(_ request: Request) -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "findDefinition requires 'usr'")
        }
        do {
            let querier = try makeQuerier(request)
            if let occ = querier.findDefinition(usr: usr) {
                return Response(occurrences: [occ])
            } else {
                return Response(occurrences: [])
            }
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findOverrides

    private func handleFindOverrides(_ request: Request) -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "findOverrides requires 'usr'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(occurrences: querier.findOverrides(usr: usr))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findConformances

    private func handleFindConformances(_ request: Request) -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "findConformances requires 'usr'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(occurrences: querier.findConformances(usr: usr))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - blastRadius

    private func handleBlastRadius(_ request: Request) -> Response {
        guard let filePath = request.filePath, !filePath.isEmpty else {
            return Response(error: "blastRadius requires 'filePath'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(blastRadius: querier.blastRadius(filePath: filePath))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - status

    private func handleStatus(_ request: Request) -> Response {
        do {
            let storePath = try DerivedDataLocator.indexStorePath(
                projectPath: request.projectPath,
                indexStorePath: request.indexStorePath
            )
            let querier = try querierForStore(storePath)
            return Response(status: querier.status(storePath: storePath))
        } catch {
            // Status should be informative even when the index doesn't exist
            return Response(status: StatusResult(
                indexStorePath: request.indexStorePath ?? "(unknown)",
                indexMtime: nil,
                staleFileCount: 0,
                staleFiles: [],
                summary: error.localizedDescription
            ))
        }
    }

    // MARK: - Helpers

    private func makeQuerier(_ request: Request) throws -> IndexQuerier {
        let storePath = try DerivedDataLocator.indexStorePath(
            projectPath: request.projectPath,
            indexStorePath: request.indexStorePath
        )
        return try querierForStore(storePath)
    }

    private func querierForStore(_ storePath: String) throws -> IndexQuerier {
        if let cached = querierCache[storePath] {
            return cached
        }
        let querier = try IndexQuerier(storePath: storePath)
        querierCache[storePath] = querier
        return querier
    }
}
