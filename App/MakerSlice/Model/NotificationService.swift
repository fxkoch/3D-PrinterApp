import BackgroundTasks
import Foundation
import PrinterKit
import UserNotifications

/// Local notifications for print events (finished, error, paused, filament problem).
///
/// While the app is open the printers are polled every few seconds and a change shows up at once. In the background
/// iOS only wakes the app now and then (about every 15–30 minutes, decided by iOS); true push messages would need a
/// server and a paid developer account, which a printer in the home network cannot provide.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    static let refreshID = "de.makerslice.refresh"

    /// Set by the app; called when the user taps a notification.
    var onOpen: ((UUID, PrintAlert.Kind) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    func setUp() {
        center.delegate = self
    }

    // MARK: Settings

    var enabled: Bool {
        get { defaults.bool(forKey: "notifyEnabled") }
        set { defaults.set(newValue, forKey: "notifyEnabled") }
    }

    func isOn(_ kind: PrintAlert.Kind) -> Bool {
        defaults.object(forKey: "notify-\(kind.rawValue)") as? Bool ?? (kind != .cancelled)
    }

    func set(_ kind: PrintAlert.Kind, _ on: Bool) {
        defaults.set(on, forKey: "notify-\(kind.rawValue)")
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorized() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    // MARK: Events

    /// Compares the new status with the last one seen (also across app launches) and notifies about what changed.
    func observe(printer: PrinterConnection, status: PrinterStatus) {
        let key = printer.id.uuidString
        var states = defaults.dictionary(forKey: "alertLastState") as? [String: String] ?? [:]
        let old = states[key].flatMap(PrinterStatus.JobState.init(rawValue:))
        states[key] = status.state.rawValue
        defaults.set(states, forKey: "alertLastState")
        guard enabled, let alert = PrintAlert.alert(printer: printer.name, old: old, new: status), isOn(alert.kind) else { return }
        var posted = defaults.stringArray(forKey: "alertPosted") ?? []
        guard !posted.contains(alert.key) else { return }
        posted = Array((posted + [alert.key]).suffix(60))
        defaults.set(posted, forKey: "alertPosted")
        post(alert, printerID: printer.id)
    }

    func post(_ alert: PrintAlert, printerID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.kind == .finished ? .default : .defaultCritical
        content.threadIdentifier = printerID.uuidString
        content.userInfo = ["printer": printerID.uuidString, "kind": alert.kind.rawValue]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "MakerSlice"
        content.body = "So melden sich deine Drucker: Druck fertig, Fehler, Pause oder Filamentproblem."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = (info["printer"] as? String).flatMap(UUID.init), let kind = (info["kind"] as? String).flatMap(PrintAlert.Kind.init(rawValue:)) else { return }
        await MainActor.run { onOpen?(id, kind) }
    }

    // MARK: Background refresh

    /// Registers the handler; must run before the app has finished launching.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in await NotificationService.shared.runBackgroundRefresh(task) }
        }
    }

    func scheduleRefresh() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runBackgroundRefresh(_ task: BGAppRefreshTask) async {
        scheduleRefresh()
        let work = Task { @MainActor in
            let manager = PrinterManager()
            await withTaskGroup(of: Void.self) { group in
                for printer in manager.printers { group.addTask { @MainActor in await manager.refresh(printer) } }
            }
            manager.printers.forEach { manager.driver(for: $0).disconnect() }
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }
}
