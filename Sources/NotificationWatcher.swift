import Foundation
import SQLite3

/// Reads macOS's notification database (needs Full Disk Access) so each ding can be matched
/// to the notification that caused it: which app, which website, and what it said.
@MainActor
final class NotificationWatcher {
    static let databasePath = NSHomeDirectory()
        + "/Library/Group Containers/group.com.apple.usernoted/db2/db"

    private let store: DingStore
    private var db: OpaquePointer?
    private var lastRec: Int64 = 0
    private var isBackfill = true
    private var timer: Timer?
    private let queue = DispatchQueue(label: "ding.notifications", qos: .utility)

    init(store: DingStore) {
        self.store = store
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        if db == nil {
            guard openDatabase() else {
                store.notificationAccess = false
                return
            }
            store.notificationAccess = true
        }
        if lastRec == 0 {
            // Backfill the last 12 hours so the catalogue has something in it right away.
            let since = Date().addingTimeInterval(-12 * 3600).timeIntervalSinceReferenceDate
            lastRec = scalar("SELECT IFNULL(MIN(rec_id) - 1, (SELECT IFNULL(MAX(rec_id), 0) FROM record)) FROM record WHERE delivered_date >= \(since)")
        }
        let notes = fetch(after: lastRec)
        // A long-lived read-only connection can get stuck on an old snapshot of usernoted's
        // WAL database, so reopen it every poll.
        sqlite3_close(db)
        db = nil
        lastRec = notes.map(\.rec).max() ?? lastRec
        for note in notes {
            store.recordNotification(note, announceIfMatched: !isBackfill)
        }
        isBackfill = false
    }

    private func openDatabase() -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(Self.databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logOnce("open failed: \(String(cString: sqlite3_errmsg(handle)))")
            sqlite3_close(handle)
            return false
        }
        // Opening succeeds lazily; a real query tells us whether TCC lets us read it.
        var statement: OpaquePointer?
        let ok = sqlite3_prepare_v2(handle, "SELECT rec_id FROM record LIMIT 1", -1, &statement, nil) == SQLITE_OK
            && sqlite3_step(statement) != SQLITE_ERROR
        if !ok { logOnce("query failed: \(String(cString: sqlite3_errmsg(handle)))") }
        sqlite3_finalize(statement)
        guard ok else { sqlite3_close(handle); return false }
        if lastRec == 0 { debugLog("notification database opened") }
        db = handle
        return true
    }

    private var lastError: String?
    private func logOnce(_ message: String) {
        guard message != lastError else { return }
        lastError = message
        debugLog("notifications: \(message)")
    }

    private func scalar(_ sql: String) -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func fetch(after rec: Int64) -> [IncomingNotification] {
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date
            FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 500
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil   // reopen next time
            return []
        }
        sqlite3_bind_int64(statement, 1, rec)

        var results: [IncomingNotification] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recID = sqlite3_column_int64(statement, 0)
            let identifier = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
            let delivered = sqlite3_column_double(statement, 3)
            var request: [String: Any] = [:]
            if let bytes = sqlite3_column_blob(statement, 2) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    request = plist["req"] as? [String: Any] ?? [:]
                }
            }
            results.append(IncomingNotification(
                rec: recID,
                bundleID: identifier,
                date: delivered > 0 ? Date(timeIntervalSinceReferenceDate: delivered) : Date(),
                title: request["titl"] as? String,
                subtitle: request["subt"] as? String,
                body: request["body"] as? String))
        }
        return results
    }
}
