import Foundation

/// HTTP client for rustle-language-server (one POST per request, JSON in and out). Responses use
/// snake_case keys and are decoded into the camelCase models.
struct LanguageClient: Sendable {
    let baseURL: URL

    struct TurnResult: Decodable {
        let userText: String
        let reply: String
        let engine: String
        let error: String?
        let duration: Double?
    }

    struct HistoryLine: Encodable { let role: String; let text: String }

    struct Assessment: Decodable {
        struct Word: Decodable { let text: String; let status: String; let heard: String; let probability: Double }
        let words: [Word]
        let score: Int
        let accuracy: Int
        let completion: Int
        let wpm: Int
        let pauses: Int
        let summary: String
        let tips: [ReadingAttempt.Tip]
        let heardText: String?
    }

    struct LLMTest: Decodable { let ok: Bool; let sample: String?; let error: String?; let latencyMs: Int? }

    struct Health: Decodable { let ok: Bool; let apiVersion: Int; let model: String; let llm: Bool; let llmProvider: String; let llmModel: String }

    func health() async -> Health? {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Self.decoder.decode(Health.self, from: data)
    }

    /// One conversation exchange. `wav` = your spoken turn, `text` = a typed one; neither = the
    /// tutor opens the conversation.
    func turn(wav: Data?, text: String?, history: [PracticeSession.Turn], scenario: Scenario, level: String) async throws -> TurnResult {
        struct Req: Encodable {
            let audioWavB64: String?; let text: String?; let history: [HistoryLine]; let scenario: String; let level: String
        }
        return try await post("v1/conversation/turn",
                              Req(audioWavB64: wav?.base64EncodedString(), text: text,
                                  history: history.map { HistoryLine(role: $0.role.rawValue, text: $0.text) },
                                  scenario: scenario.prompt, level: level),
                              timeout: 90)
    }

    func feedback(for text: String, previous: String, level: String) async throws -> Feedback {
        struct Req: Encodable { let text: String; let previous: String; let level: String }
        return try await post("v1/conversation/feedback", Req(text: text, previous: previous, level: level), timeout: 60)
    }

    func report(for session: PracticeSession) async throws -> Report {
        struct Line: Encodable { let role: String; let text: String; let feedback: Feedback? }
        struct Req: Encodable { let turns: [Line]; let scenario: String; let level: String }
        return try await post("v1/conversation/report",
                              Req(turns: session.turns.map { Line(role: $0.role.rawValue, text: $0.text, feedback: $0.feedback) },
                                  scenario: session.scenario.prompt, level: session.level),
                              timeout: 150)
    }

    func ask(_ question: String, about session: PracticeSession) async throws -> String {
        struct Line: Encodable { let role: String; let text: String }
        struct Req: Encodable { let question: String; let turns: [Line]; let report: Report? }
        struct Res: Decodable { let answer: String }
        let res: Res = try await post("v1/conversation/ask",
                                      Req(question: question, turns: session.turns.map { Line(role: $0.role.rawValue, text: $0.text) },
                                          report: session.report),
                                      timeout: 120)
        return res.answer
    }

    func analyze(_ text: String, mode: String, tone: String, level: String) async throws -> TextAnalysis {
        struct Req: Encodable { let text: String; let mode: String; let tone: String; let level: String }
        return try await post("v1/text/analyze", Req(text: text, mode: mode, tone: tone, level: level), timeout: 150)
    }

    func assess(wav: Data, reference: String) async throws -> Assessment {
        struct Req: Encodable { let audioWavB64: String; let reference: String }
        return try await post("v1/read/assess", Req(audioWavB64: wav.base64EncodedString(), reference: reference), timeout: 180)
    }

    func testLLM() async throws -> LLMTest {
        struct Empty: Encodable {}
        return try await post("v1/llm/test", Empty(), timeout: 45)
    }

    // MARK: - Plumbing

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B, timeout: TimeInterval) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw NSError(domain: "RustleLanguage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Servidor local indisponível (\(error.localizedDescription))"])
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RustleLanguage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Servidor: \(text.prefix(200))"])
        }
        return try Self.decoder.decode(R.self, from: data)
    }
}
