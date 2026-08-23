import Foundation

public enum CodexUsageParser {
    public static func parse(message: [String: Any], now: Date = Date()) -> CodexUsageSnapshot? {
        let envelope: [String: Any]
        if let result = message["result"] as? [String: Any] {
            envelope = result
        } else if let params = message["params"] as? [String: Any] {
            envelope = params
        } else {
            return nil
        }

        let limits: [String: Any]?
        if let direct = envelope["rateLimits"] as? [String: Any] {
            limits = direct
        } else if let map = envelope["rateLimitsByLimitId"] as? [String: Any] {
            limits = map["codex"] as? [String: Any]
        } else if envelope["primary"] != nil {
            limits = envelope
        } else {
            limits = nil
        }

        guard
            let limits,
            let primary = limits["primary"] as? [String: Any],
            let used = number(primary["usedPercent"])
        else {
            return nil
        }

        let resetDate: Date?
        if let rawReset = number(primary["resetsAt"]) {
            let seconds = rawReset > 10_000_000_000 ? rawReset / 1000 : rawReset
            resetDate = Date(timeIntervalSince1970: seconds)
        } else {
            resetDate = nil
        }

        let credits = limits["credits"] as? [String: Any]
        let balance = number(credits?["balance"])
        let hasCredits = (credits?["hasCredits"] as? Bool) ?? false

        return CodexUsageSnapshot(
            usedPercent: used,
            resetsAt: resetDate,
            planType: limits["planType"] as? String,
            creditsBalance: balance,
            hasCredits: hasCredits,
            capturedAt: now
        )
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }
}
