import AppKit
import Foundation
import LifeBoardCore

extension AppStore {
    /// Preview only: replace the Preview planner with the synthetic sample week
    /// after confirmation. The restore path keeps a copy of the previous file.
    func offerSampleWeek() {
        replacePreviewPlanner(with: SampleData.studentWeek(), title: "Load a sample student week?", action: "Load Sample Week")
    }

    /// Preview only: start again with an empty planner (the default subjects).
    func offerEmptyPlanner() {
        var empty = LifeBoardData.seeded()
        empty.settings.hasCompletedOnboarding = true
        replacePreviewPlanner(with: empty, title: "Clear the Preview planner?", action: "Clear Planner")
    }

    private func replacePreviewPlanner(with replacement: LifeBoardData, title: String, action: String) {
        guard LifeBoardEnvironment.isPreview else { return }
        flushPendingDrafts()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "This changes LifeBoard Preview only. Your installed LifeBoard is not touched, and the Preview's current planner is saved in its Backups folder first."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let url = repository.backupDirectory.appendingPathComponent("Preview-Replacement-\(UUID().uuidString).json")
            try repository.export(replacement, to: url)
            replaceWithBackup(url)
            selectedTaskID = nil; selectedEventID = nil
        } catch {
            message = UserMessage(title: "Couldn't Replace Planner", detail: error.localizedDescription)
        }
    }
}
