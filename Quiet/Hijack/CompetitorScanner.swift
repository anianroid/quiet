import AppKit
import Foundation

struct CompetitorScanner: Sendable {
    let catalog: CompetitorCatalog

    func scan() -> [InstalledCompetitor] {
        let running = NSWorkspace.shared.runningApplications
        var found: [InstalledCompetitor] = []

        for entry in catalog.entries {
            var matchedBundleId: String?
            var matchedPath: String?
            var isRunning = false

            for bundleId in entry.bundleIds {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    matchedBundleId = bundleId
                    matchedPath = url.path
                    break
                }
            }

            if matchedPath == nil {
                matchedPath = locateByAppNameHints(entry.appNameHints)
            }

            for app in running {
                if let bid = app.bundleIdentifier, entry.bundleIds.contains(bid) {
                    isRunning = true
                    matchedBundleId = matchedBundleId ?? bid
                    matchedPath = matchedPath ?? app.bundleURL?.path
                }
                if let name = app.localizedName,
                   NameTokenMatcher.name(name, matchesAnyOf: entry.helperProcessNames + entry.appNameHints) {
                    isRunning = true
                    matchedPath = matchedPath ?? app.bundleURL?.path
                }
            }

            // Meeting hosts (Zoom/Chrome) with policy ignore still show in "We'll handle"
            // for notification Layer B — only if installed.
            let installed = matchedPath != nil || isRunning
            guard installed else { continue }

            found.append(
                InstalledCompetitor(
                    entry: entry,
                    matchedBundleId: matchedBundleId,
                    matchedAppPath: matchedPath,
                    isRunning: isRunning
                )
            )
        }

        return found.sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
    }

    private func locateByAppNameHints(_ hints: [String]) -> String? {
        let roots = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications"
        ]

        for root in roots {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let name = (item as NSString).deletingPathExtension
                if NameTokenMatcher.name(name, matchesAnyOf: hints) {
                    return root + "/" + item
                }
            }
        }
        return nil
    }
}
