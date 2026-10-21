import BackgroundTasks
import Foundation

/// Background App Refresh and processing tasks. iOS decides when these actually run.
enum BackgroundScheduler {
    static let refreshID = "com.parv.logline.refresh"
    static let processingID = "com.parv.logline.processing"

    static func register() {
        let refresh = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: DispatchQueue.main) { task in
            handle(task, trigger: .backgroundRefresh)
        }
        let processing = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: DispatchQueue.main) { task in
            handle(task, trigger: .backgroundProcessing)
        }
        if !refresh || !processing {
            Log.shared.add("Background task registration failed", level: .error)
        }
    }

    static func scheduleAll() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60)
        submit(processing)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.shared.add("Couldn't schedule \(request.identifier): \(error.localizedDescription)", level: .warning)
        }
    }

    private static func handle(_ task: BGTask, trigger: CheckTrigger) {
        scheduleAll()
        let completion = TaskCompletion(task)
        task.expirationHandler = {
            Log.shared.add("iOS ended a background run early", level: .warning)
            completion.finish(false)
        }
        Task { @MainActor in
            let ok = await AppModel.shared.performBackgroundCheck(trigger: trigger)
            completion.finish(ok)
        }
    }
}

/// Makes sure a background task is completed exactly once.
private final class TaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }

    func finish(_ success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first {
            task.setTaskCompleted(success: success)
        }
    }
}
