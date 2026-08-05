import Foundation
import os.log

final class CompetitorCatalog: Sendable {
    let entries: [CompetitorEntry]

    private static let logger = Logger(subsystem: "notes.quiet.app", category: "CompetitorCatalog")

    init(entries: [CompetitorEntry]) {
        self.entries = entries
    }

    static func loadBundled() -> CompetitorCatalog {
        guard let url = Bundle.main.url(forResource: "Competitors", withExtension: "json") else {
            // An empty catalog silently turns the whole guardian off — log loudly.
            logger.fault("Competitors.json missing from bundle — catalog is empty")
            return CompetitorCatalog(entries: [])
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([CompetitorEntry].self, from: data)
            logger.info("Loaded \(decoded.count) competitor entries")
            return CompetitorCatalog(entries: decoded)
        } catch {
            // An empty catalog silently turns the whole guardian off — log loudly.
            logger.fault("Competitors.json failed to decode: \(error.localizedDescription, privacy: .public)")
            return CompetitorCatalog(entries: [])
        }
    }

    var dismissPatterns: [String] {
        let titles = entries.flatMap(\.notificationTitlePatterns)
        let bodies = entries.flatMap(\.notificationBodyPatterns)
        return Array(Set(titles + bodies))
    }
}
