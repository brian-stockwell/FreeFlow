import Foundation

struct ClaudeUsage: Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
}

enum ClaudePricing {
    /// USD per million tokens: (input, output, cacheRead, cacheWrite)
    static func rates(for model: String) -> (Double, Double, Double, Double) {
        if model.hasPrefix("claude-haiku-5-5") { return (0.10, 0.50, 0.01, 0.125) }
        if model.hasPrefix("claude-sonnet-5-5") { return (2.0, 10.0, 0.20, 2.5) }
        if model.hasPrefix("claude-sonnet-5") { return (2.0, 10.0, 0.20, 2.5) }
        if model.hasPrefix("claude-opus-5-5") { return (4.0, 20.0, 0.20, 5.0) }
        if model.hasPrefix("claude-opus") { return (5.0, 25.0, 0.50, 6.25) }
        if model.hasPrefix("claude-haiku-4-5") { return (1.0, 5.0, 0.10, 1.25) }
        return (2.0, 10.0, 0.20, 2.5)
    }
    static func cost(model: String, usage: ClaudeUsage) -> Double {
        let r = rates(for: model)
        return (Double(usage.inputTokens) * r.0 + Double(usage.outputTokens) * r.1
                + Double(usage.cacheReadTokens) * r.2 + Double(usage.cacheWriteTokens) * r.3) / 1_000_000
    }
}

enum ClaudeError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case refusal(String)
    case emptyResponse
    case network(Error)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Claude API key set. Add it in FreeFlow → Settings."
        case .http(let code, let msg): return "Claude API error \(code): \(msg)"
        case .refusal(let why): return "Claude declined this request: \(why)"
        case .emptyResponse: return "Claude returned an empty response."
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .timeout: return "Claude took too long to respond."
        }
    }
}

struct ClaudeResponse: Sendable {
    var text: String
    var usage: ClaudeUsage
    var stopReason: String
}

/// Minimal Messages API client (raw HTTP; there is no official Swift SDK).
final class ClaudeClient: Sendable {
    static let shared = ClaudeClient()
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct Request: Sendable {
        var model: String
        var system: String
        var userContent: String
        var maxTokens: Int = 2048
        var effort: String = "low"
        var disableThinking: Bool = true
        var jsonSchema: [String: Any]? = nil
        var timeout: TimeInterval = 15
        var cacheSystem: Bool = true
    }

    /// The `thinking` value that turns thinking off on `model`, or nil to leave the field out (adaptive thinking).
    /// Sonnet 5.5 rejects `disabled` and spells it `between_tools`; Opus 5.5 and Fable can't turn thinking off at all,
    /// so low effort is the only lever; Haiku 5.5 and Opus 5 accept `disabled` only at effort high or below.
    static func thinkingOff(model: String, effort: String) -> [String: Any]? {
        let highOrBelow = effort != "xhigh" && effort != "max"
        if model.hasPrefix("claude-sonnet-5-5") { return highOrBelow ? ["type": "between_tools"] : nil }
        if model.hasPrefix("claude-opus-5-5") || model.hasPrefix("claude-fable") || model.hasPrefix("claude-mythos") { return nil }
        if model.hasPrefix("claude-haiku-5-5") || model.hasPrefix("claude-opus-5") { return highOrBelow ? ["type": "disabled"] : nil }
        return ["type": "disabled"]
    }

    func send(_ r: Request, feature: String) async throws -> ClaudeResponse {
        let key = Settings.shared.apiKey
        guard !key.isEmpty else { throw ClaudeError.noAPIKey }

        var body: [String: Any] = [
            "model": r.model,
            "max_tokens": r.maxTokens,
            "system": [[
                "type": "text",
                "text": r.system,
            ] as [String: Any]].map { block -> [String: Any] in
                var b = block
                if r.cacheSystem { b["cache_control"] = ["type": "ephemeral"] }
                return b
            },
            "messages": [["role": "user", "content": r.userContent]],
        ]
        var outputConfig: [String: Any] = ["effort": r.effort]
        if let schema = r.jsonSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        body["output_config"] = outputConfig
        if !r.disableThinking {
            body["thinking"] = ["type": "adaptive"]
        } else if let off = Self.thinkingOff(model: r.model, effort: r.effort) {
            body["thinking"] = off
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = r.timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, resp) = try await URLSession.shared.data(for: req)
                data = d
                http = resp as! HTTPURLResponse
            } catch let e as URLError where e.code == .timedOut {
                throw ClaudeError.timeout
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)); continue }
                throw ClaudeError.network(error)
            }

            if http.statusCode == 429 || http.statusCode >= 500 {
                if attempt < 3 {
                    let retryAfter = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 1.0
                    try? await Task.sleep(for: .seconds(min(retryAfter, 3)))
                    continue
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String } ?? String(data: data, encoding: .utf8) ?? ""
                throw ClaudeError.http(http.statusCode, msg)
            }

            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let stop = json["stop_reason"] as? String ?? ""
            var usage = ClaudeUsage()
            if let u = json["usage"] as? [String: Any] {
                usage.inputTokens = u["input_tokens"] as? Int ?? 0
                usage.outputTokens = u["output_tokens"] as? Int ?? 0
                usage.cacheReadTokens = u["cache_read_input_tokens"] as? Int ?? 0
                usage.cacheWriteTokens = u["cache_creation_input_tokens"] as? Int ?? 0
            }
            Database.shared.recordUsage(feature: feature, model: r.model, usage: usage)

            if stop == "refusal" {
                let why = (json["stop_details"] as? [String: Any])?["explanation"] as? String ?? "safety policy"
                throw ClaudeError.refusal(why)
            }
            let text = ((json["content"] as? [[String: Any]]) ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            guard !text.isEmpty else { throw ClaudeError.emptyResponse }
            return ClaudeResponse(text: text, usage: usage, stopReason: stop)
        }
    }

    /// Cheap connectivity/key check used by Settings.
    func validateKey() async -> String? {
        do {
            _ = try await send(Request(model: "claude-haiku-5-5", system: "Reply with OK.", userContent: "ping",
                                       maxTokens: 8, cacheSystem: false), feature: "keycheck")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
