import Foundation

final class CompetitorCatalog: Sendable {
    let entries: [CompetitorEntry]

    init(entries: [CompetitorEntry]) {
        self.entries = entries
    }

    static func loadBundled() -> CompetitorCatalog {
        guard let url = Bundle.main.url(forResource: "Competitors", withExtension: "json") else {
            return CompetitorCatalog(entries: [])
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([CompetitorEntry].self, from: data)
            return CompetitorCatalog(entries: decoded)
        } catch {
            return CompetitorCatalog(entries: [])
        }
    }

    var dismissPatterns: [String] {
        let titles = entries.flatMap(\.notificationTitlePatterns)
        let bodies = entries.flatMap(\.notificationBodyPatterns)
        return Array(Set(titles + bodies))
    }
}
