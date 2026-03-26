import Foundation
import UIKit
import Observation

nonisolated enum ConcurrencyFactorLevel: String, Codable, Sendable {
    case good = "good"
    case warning = "warning"
    case critical = "critical"

    var color: String {
        switch self {
        case .good: "green"
        case .warning: "yellow"
        case .critical: "red"
        }
    }
}

nonisolated struct ConcurrencyFactorScores: Sendable {
    let memory: ConcurrencyFactorLevel
    let memoryMB: Int
    let network: ConcurrencyFactorLevel
    let networkLatencyMs: Int
    let successRate: Double
    let successLevel: ConcurrencyFactorLevel
    let stability: Double
    let stabilityLevel: ConcurrencyFactorLevel
    let isBackground: Bool
}

nonisolated struct ConcurrencyDecision: Codable, Sendable, Identifiable {
    let id: String
    let timestamp: Date
    let fromConcurrency: Int
    let toConcurrency: Int
    let reasoning: String
    let wasAI: Bool
    let memoryMB: Int
    let successRate: Double
    let stability: Double
    let isBackground: Bool

    var direction: ConcurrencyDirection {
        if toConcurrency > fromConcurrency { return .rampUp }
        if toConcurrency < fromConcurrency { return .rampDown }
        return .hold
    }

    nonisolated enum ConcurrencyDirection: String, Codable, Sendable {
        case rampUp
        case rampDown
        case hold
    }
}

nonisolated struct ConcurrencyHistoryPoint: Sendable {
    let timestamp: Date
    let concurrency: Int
}

@Observable
@MainActor
class AdaptiveConcurrencyEngine {
    static let shared = AdaptiveConcurrencyEngine()

    private(set) var liveConcurrency: Int = 1
    var maxCap: Int = 4
    private(set) var currentReasoning: String = "Initializing..."
    private(set) var factorScores: ConcurrencyFactorScores = ConcurrencyFactorScores(
        memory: .good, memoryMB: 0, network: .good, networkLatencyMs: 0,
        successRate: 0, successLevel: .good, stability: 1.0, stabilityLevel: .good, isBackground: false
    )
    private(set) var decisions: [ConcurrencyDecision] = []
    private(set) var concurrencyHistory: [ConcurrencyHistoryPoint] = []
    private(set) var isActive: Bool = false
    private(set) var isAdjusting: Bool = false

    private let logger = DebugLogger.shared
    private let crashProtection = CrashProtectionService.shared
    private let toolkit = RorkToolkitService.shared

    private var monitorTask: Task<Void, Never>?
    private var aiAnalysisTask: Task<Void, Never>?

    private var outcomeWindow: [SessionOutcomeRecord] = []
    private let maxOutcomeWindow = 50
    private var latencyWindow: [Int] = []
    private let maxLatencyWindow = 30
    private var consecutiveSuccesses: Int = 0
    private var consecutiveFailures: Int = 0
    private var lastRampUpTime: Date = .distantPast
    private var lastAICallTime: Date = .distantPast
    private var batchStartTime: Date = .distantPast

    private let rampUpCooldownSeconds: TimeInterval = 30
    private let aiCallIntervalSeconds: TimeInterval = 30
    private let heuristicCheckIntervalSeconds: TimeInterval = 10
    private let stableSuccessesForRampUp: Int = 4

    private struct SessionOutcomeRecord {
        let timestamp: Date
        let wasConclusive: Bool
        let wasTimeout: Bool
        let wasConnectionFailure: Bool
        let latencyMs: Int
    }

    func start(cap: Int) {
        guard !isActive else { return }
        isActive = true
        liveConcurrency = 1
        maxCap = cap
        currentReasoning = "Starting at 1 — warming up"
        decisions.removeAll()
        concurrencyHistory.removeAll()
        outcomeWindow.removeAll()
        latencyWindow.removeAll()
        consecutiveSuccesses = 0
        consecutiveFailures = 0
        lastRampUpTime = .distantPast
        lastAICallTime = .distantPast
        batchStartTime = Date()

        recordHistoryPoint()
        startMonitoring()
        logger.log("AdaptiveConcurrency: started (cap=\(cap), initial=1)", category: .automation, level: .info)
    }

    func stop() {
        isActive = false
        monitorTask?.cancel()
        monitorTask = nil
        aiAnalysisTask?.cancel()
        aiAnalysisTask = nil
        logger.log("AdaptiveConcurrency: stopped (final=\(liveConcurrency), decisions=\(decisions.count))", category: .automation, level: .info)
    }

    func recordOutcome(conclusive: Bool, timeout: Bool = false, connectionFailure: Bool = false, latencyMs: Int = 0) {
        guard isActive else { return }

        let record = SessionOutcomeRecord(
            timestamp: Date(), wasConclusive: conclusive, wasTimeout: timeout,
            wasConnectionFailure: connectionFailure, latencyMs: latencyMs
        )
        outcomeWindow.append(record)
        if outcomeWindow.count > maxOutcomeWindow {
            outcomeWindow.removeFirst(outcomeWindow.count - maxOutcomeWindow)
        }

        if latencyMs > 0 {
            latencyWindow.append(latencyMs)
            if latencyWindow.count > maxLatencyWindow {
                latencyWindow.removeFirst(latencyWindow.count - maxLatencyWindow)
            }
        }

        if conclusive && !timeout && !connectionFailure {
            consecutiveSuccesses += 1
            consecutiveFailures = 0
        } else if timeout || connectionFailure {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            if consecutiveFailures >= 3 {
                immediateRampDown(reason: "3+ consecutive failures detected — reducing immediately")
            }
        }
    }

    private func immediateRampDown(reason: String) {
        guard liveConcurrency > 1 else { return }
        let drop = consecutiveFailures >= 5 ? 2 : 1
        let newConcurrency = max(1, liveConcurrency - drop)
        if newConcurrency != liveConcurrency {
            applyDecision(newConcurrency: newConcurrency, reasoning: reason, wasAI: false)
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                try? await Task.sleep(for: .seconds(self.heuristicCheckIntervalSeconds))
                guard !Task.isCancelled, self.isActive else { return }
                await self.runHeuristicCheck()
            }
        }

        aiAnalysisTask?.cancel()
        aiAnalysisTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                if Date().timeIntervalSince(self.lastAICallTime) >= self.aiCallIntervalSeconds {
                    await self.runAIAnalysis()
                    self.lastAICallTime = Date()
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func runHeuristicCheck() async {
        let memMB = crashProtection.currentMemoryUsageMB()
        let isDeathSpiral = crashProtection.isMemoryDeathSpiral
        let growthRate = crashProtection.currentGrowthRateMBPerSec
        let isBackground = UIApplication.shared.applicationState != .active

        let successRate = computeSuccessRate()
        let avgLatency = computeAverageLatency()
        let timeoutRate = computeTimeoutRate()
        let connectionFailureRate = computeConnectionFailureRate()

        let memoryLevel = computeMemoryLevel(memMB: memMB, isDeathSpiral: isDeathSpiral, growthRate: growthRate)
        let networkLevel = computeNetworkLevel(avgLatency: avgLatency, timeoutRate: timeoutRate, connectionFailureRate: connectionFailureRate)
        let successLevel = computeSuccessLevel(successRate: successRate)
        let stability = computeStabilityScore(memMB: memMB, growthRate: growthRate, isDeathSpiral: isDeathSpiral, successRate: successRate, timeoutRate: timeoutRate, connectionFailureRate: connectionFailureRate, isBackground: isBackground)
        let stabilityLevel: ConcurrencyFactorLevel = stability > 0.7 ? .good : (stability > 0.4 ? .warning : .critical)

        factorScores = ConcurrencyFactorScores(
            memory: memoryLevel, memoryMB: memMB,
            network: networkLevel, networkLatencyMs: avgLatency,
            successRate: successRate, successLevel: successLevel,
            stability: stability, stabilityLevel: stabilityLevel,
            isBackground: isBackground
        )
        recordHistoryPoint()

        if isDeathSpiral || memMB > 3000 {
            if liveConcurrency > 1 {
                applyDecision(newConcurrency: 1, reasoning: "EMERGENCY: Memory death spiral (\(memMB)MB) — dropping to 1", wasAI: false)
            }
            return
        }

        if memMB > 2000 && liveConcurrency > 2 {
            applyDecision(newConcurrency: 2, reasoning: "High memory (\(memMB)MB) — capping at 2", wasAI: false)
            return
        }

        if isBackground && liveConcurrency > 2 {
            applyDecision(newConcurrency: max(1, liveConcurrency - 1), reasoning: "App in background — reducing concurrency", wasAI: false)
            return
        }

        if timeoutRate > 0.4 && liveConcurrency > 1 {
            applyDecision(newConcurrency: max(1, liveConcurrency - 1), reasoning: "High timeout rate (\(Int(timeoutRate * 100))%) — reducing", wasAI: false)
            return
        }

        if connectionFailureRate > 0.3 && liveConcurrency > 1 {
            applyDecision(newConcurrency: max(1, liveConcurrency - 1), reasoning: "Connection failures (\(Int(connectionFailureRate * 100))%) — reducing", wasAI: false)
            return
        }

        let canRampUp = liveConcurrency < maxCap
            && consecutiveSuccesses >= stableSuccessesForRampUp
            && Date().timeIntervalSince(lastRampUpTime) >= rampUpCooldownSeconds
            && stability > 0.65
            && !isBackground
            && memMB < 1500
            && timeoutRate < 0.1
            && connectionFailureRate < 0.1

        if canRampUp {
            let newConcurrency = min(maxCap, liveConcurrency + 1)
            applyDecision(
                newConcurrency: newConcurrency,
                reasoning: "Stable: \(consecutiveSuccesses) successes, memory \(memMB)MB, stability \(String(format: "%.0f", stability * 100))% — ramping to \(newConcurrency)",
                wasAI: false
            )
            lastRampUpTime = Date()
            consecutiveSuccesses = 0
            return
        }

        if outcomeWindow.count >= 3 {
            let reasonParts: [String] = [
                "\(liveConcurrency)/\(maxCap) workers",
                "mem \(memMB)MB",
                "success \(Int(successRate * 100))%",
                isBackground ? "background" : "foreground"
            ]
            currentReasoning = "Monitoring: " + reasonParts.joined(separator: " · ")
        }
    }

    private func runAIAnalysis() async {
        guard outcomeWindow.count >= 3 else { return }

        let memMB = crashProtection.currentMemoryUsageMB()
        let growthRate = crashProtection.currentGrowthRateMBPerSec
        let isBackground = UIApplication.shared.applicationState != .active
        let successRate = computeSuccessRate()
        let avgLatency = computeAverageLatency()
        let timeoutRate = computeTimeoutRate()
        let connectionFailureRate = computeConnectionFailureRate()
        let elapsedSeconds = Int(Date().timeIntervalSince(batchStartTime))

        let context: [String: Any] = [
            "currentConcurrency": liveConcurrency,
            "maxCap": maxCap,
            "memoryMB": memMB,
            "memoryGrowthRateMBPerSec": String(format: "%.1f", growthRate),
            "isMemoryDeathSpiral": crashProtection.isMemoryDeathSpiral,
            "isBackground": isBackground,
            "successRate": String(format: "%.0f%%", successRate * 100),
            "avgLatencyMs": avgLatency,
            "timeoutRate": String(format: "%.0f%%", timeoutRate * 100),
            "connectionFailureRate": String(format: "%.0f%%", connectionFailureRate * 100),
            "consecutiveSuccesses": consecutiveSuccesses,
            "consecutiveFailures": consecutiveFailures,
            "totalOutcomes": outcomeWindow.count,
            "elapsedSeconds": elapsedSeconds,
            "secondsSinceLastRampUp": Int(Date().timeIntervalSince(lastRampUpTime)),
            "recentDecisions": decisions.prefix(5).map { ["from": $0.fromConcurrency, "to": $0.toConcurrency, "reasoning": $0.reasoning] }
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: context),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You manage adaptive concurrency for a dual-site login testing system on iOS. \
        The system ALWAYS starts at 1 concurrent session and ramps up cautiously. \
        Analyze the provided metrics and recommend a concurrency level. \
        RULES: \
        1. Never exceed maxCap. \
        2. Only increase by 1 at a time when conditions are stable for 30+ seconds. \
        3. Decrease aggressively (can drop by 2+) if problems detected. \
        4. If app is in background, prefer lower concurrency (max 2). \
        5. Memory above 2000MB = max 2. Death spiral = force 1. \
        6. High timeout or connection failure rates = reduce immediately. \
        7. Prioritize app stability over throughput. \
        Return ONLY JSON: {"concurrency":N,"reasoning":"brief explanation"}
        """

        isAdjusting = true

        guard let response = await toolkit.generateText(systemPrompt: systemPrompt, userPrompt: "Current session metrics:\n\(jsonStr)") else {
            isAdjusting = false
            return
        }

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aiConcurrency = json["concurrency"] as? Int else {
            isAdjusting = false
            return
        }

        let reasoning = (json["reasoning"] as? String) ?? "AI analysis"
        let clamped = max(1, min(maxCap, aiConcurrency))

        if clamped > liveConcurrency && clamped - liveConcurrency > 1 {
            let conservative = liveConcurrency + 1
            applyDecision(newConcurrency: conservative, reasoning: "AI: \(reasoning) (capped ramp to +1)", wasAI: true)
        } else if clamped != liveConcurrency {
            applyDecision(newConcurrency: clamped, reasoning: "AI: \(reasoning)", wasAI: true)
        } else {
            currentReasoning = "AI: \(reasoning) — holding at \(liveConcurrency)"
        }

        if clamped > liveConcurrency {
            lastRampUpTime = Date()
            consecutiveSuccesses = 0
        }

        isAdjusting = false
    }

    private func applyDecision(newConcurrency: Int, reasoning: String, wasAI: Bool) {
        let old = liveConcurrency
        let clamped = max(1, min(maxCap, newConcurrency))
        guard clamped != old else { return }

        liveConcurrency = clamped
        currentReasoning = reasoning

        let decision = ConcurrencyDecision(
            id: UUID().uuidString,
            timestamp: Date(),
            fromConcurrency: old,
            toConcurrency: clamped,
            reasoning: reasoning,
            wasAI: wasAI,
            memoryMB: crashProtection.currentMemoryUsageMB(),
            successRate: computeSuccessRate(),
            stability: factorScores.stability,
            isBackground: UIApplication.shared.applicationState != .active
        )
        decisions.insert(decision, at: 0)
        if decisions.count > 200 {
            decisions = Array(decisions.prefix(200))
        }

        recordHistoryPoint()

        let level: DebugLogLevel = clamped < old ? .warning : .info
        logger.log("AdaptiveConcurrency: \(old) → \(clamped) [\(wasAI ? "AI" : "heuristic")] — \(reasoning)", category: .automation, level: level)
    }

    private func recordHistoryPoint() {
        concurrencyHistory.append(ConcurrencyHistoryPoint(timestamp: Date(), concurrency: liveConcurrency))
        if concurrencyHistory.count > 120 {
            concurrencyHistory.removeFirst(concurrencyHistory.count - 120)
        }
    }

    private func computeSuccessRate() -> Double {
        let recent = outcomeWindow.suffix(20)
        guard !recent.isEmpty else { return 0 }
        return Double(recent.filter(\.wasConclusive).count) / Double(recent.count)
    }

    private func computeAverageLatency() -> Int {
        guard !latencyWindow.isEmpty else { return 0 }
        return latencyWindow.reduce(0, +) / latencyWindow.count
    }

    private func computeTimeoutRate() -> Double {
        let recent = outcomeWindow.suffix(15)
        guard !recent.isEmpty else { return 0 }
        return Double(recent.filter(\.wasTimeout).count) / Double(recent.count)
    }

    private func computeConnectionFailureRate() -> Double {
        let recent = outcomeWindow.suffix(15)
        guard !recent.isEmpty else { return 0 }
        return Double(recent.filter(\.wasConnectionFailure).count) / Double(recent.count)
    }

    private func computeMemoryLevel(memMB: Int, isDeathSpiral: Bool, growthRate: Double) -> ConcurrencyFactorLevel {
        if isDeathSpiral || memMB > 2500 { return .critical }
        if memMB > 1500 || growthRate > 20 { return .warning }
        return .good
    }

    private func computeNetworkLevel(avgLatency: Int, timeoutRate: Double, connectionFailureRate: Double) -> ConcurrencyFactorLevel {
        if connectionFailureRate > 0.3 || timeoutRate > 0.3 { return .critical }
        if avgLatency > 25000 || timeoutRate > 0.15 || connectionFailureRate > 0.1 { return .warning }
        return .good
    }

    private func computeSuccessLevel(successRate: Double) -> ConcurrencyFactorLevel {
        if successRate < 0.3 { return .critical }
        if successRate < 0.6 { return .warning }
        return .good
    }

    private func computeStabilityScore(memMB: Int, growthRate: Double, isDeathSpiral: Bool, successRate: Double, timeoutRate: Double, connectionFailureRate: Double, isBackground: Bool) -> Double {
        var score = 1.0

        if isDeathSpiral { score -= 0.5 }
        else if memMB > 2500 { score -= 0.3 }
        else if memMB > 1500 { score -= 0.15 }
        else if memMB > 800 { score -= 0.05 }

        if growthRate > 30 { score -= 0.2 }
        else if growthRate > 15 { score -= 0.1 }

        score -= (1.0 - successRate) * 0.2
        score -= timeoutRate * 0.15
        score -= connectionFailureRate * 0.15

        if isBackground { score -= 0.1 }

        return max(0.0, min(1.0, score))
    }
}
