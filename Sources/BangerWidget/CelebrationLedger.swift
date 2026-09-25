//  CelebrationLedger.swift — one celebration per task per day.
//
//  Un-checking is allowed, because people mis-tap and people change their minds.
//  Re-checking does not pay out twice. A reward you can farm by clicking the same
//  box stops being a reward for finishing things and starts being a slot machine,
//  which is the precise failure mode this app must not have.
//
//  It lives as a small JSON file beside tasks.json rather than in shared
//  UserDefaults, because shared defaults need an App Group and a build with no
//  code-signing identity cannot have one. It is not part of the task list: tasks.json
//  stays a plain hand-editable file with nothing but tasks in it.

import Foundation
import BangerKit

enum CelebrationLedger {

    private struct Ledger: Codable {
        var dayKey: String
        var taskIDs: [String]
    }

    private static var url: URL {
        TaskStore.shared.containerURL.appendingPathComponent("celebrated.json", isDirectory: false)
    }

    /// Records this task as celebrated today. Returns true the first time only.
    /// Fails open: if the file cannot be read or written, celebrate rather than
    /// swallow a real win.
    static func claim(taskID: String, dayKey: String) -> Bool {
        var ledger = Ledger(dayKey: dayKey, taskIDs: [])
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Ledger.self, from: data),
           decoded.dayKey == dayKey {
            ledger = decoded
        }

        guard !ledger.taskIDs.contains(taskID) else { return false }
        ledger.taskIDs.append(taskID)
        ledger.taskIDs.sort()

        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: url, options: .atomic)
        }
        return true
    }
}
