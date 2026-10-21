import AppKit
import Foundation
import SwiftUI

/// Everything the window shows: conversations, readings, text history and vocabulary (JSON files in
/// Application Support), settings shared with the server through settings.json, live status, and
/// the actions the window can trigger (wired by AppDelegate).
@MainActor
final class AppModel: ObservableObject {
    /// Mirrors server/settings.py `Settings`; the server reloads this file when it changes.
    struct ServerSettings: Codable, Equatable {
        var llm_provider = "deepseek"
        var llm_base_url = "https://api.deepseek.com"
        var llm_model = "deepseek-chat"
        var level = "B1"
        var native_language = "pt"
        var vocabulary: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ServerSettings()
            llm_provider = try c.decodeIfPresent(String.self, forKey: .llm_provider) ?? d.llm_provider
            llm_base_url = try c.decodeIfPresent(String.self, forKey: .llm_base_url) ?? d.llm_base_url
            llm_model = try c.decodeIfPresent(String.self, forKey: .llm_model) ?? d.llm_model
            level = try c.decodeIfPresent(String.self, forKey: .level) ?? d.level
            native_language = try c.decodeIfPresent(String.self, forKey: .native_language) ?? d.native_language
            vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        }
    }

    // MARK: Profile

    @Published var firstName: String = UserDefaults.standard.string(forKey: Prefs.firstName) ?? "" {
        didSet { if persist { UserDefaults.standard.set(firstName.trimmingCharacters(in: .whitespaces), forKey: Prefs.firstName) } }
    }
    @Published var lastName: String = UserDefaults.standard.string(forKey: Prefs.lastName) ?? "" {
        didSet { if persist { UserDefaults.standard.set(lastName.trimmingCharacters(in: .whitespaces), forKey: Prefs.lastName) } }
    }
    static let systemFirstName: String = (NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()).capitalized
    static let systemLastName: String = NSFullUserName().split(separator: " ").dropFirst().joined(separator: " ")
    var displayFirstName: String { firstName.trimmingCharacters(in: .whitespaces) }

    // MARK: Data

    @Published var sessions: [PracticeSession] = [] { didSet { save(sessions, "sessions.json") } }
    @Published var readings: [ReadingAttempt] = [] { didSet { save(readings, "readings.json") } }
    @Published var texts: [TextEntry] = [] { didSet { save(texts, "texts.json") } }
    @Published var vocabulary: [VocabItem] = [] {
        didSet {
            save(vocabulary, "vocabulary.json")
            // The tutor reuses words you are studying.
            let open = vocabulary.filter { !$0.mastered }.map(\.term)
            if serverSettings.vocabulary != open { serverSettings.vocabulary = open }
        }
    }
    @Published var serverSettings = ServerSettings() { didSet { save(serverSettings, "settings.json") } }

    // MARK: Live state

    @Published var activeSessionID: UUID?
    @Published var openSessionID: UUID?
    /// Sessions whose report or tutor answer is being generated.
    @Published var busySessionIDs: Set<UUID> = []
    /// Your lines waiting for their annotation.
    @Published var pendingFeedback: Set<UUID> = []
    /// Navigation requests from outside the window (menu bar) or other pages.
    @Published var pageRequest: MainView.Page?
    /// Live conversation state lives in its own object so the waveform does not redraw every page.
    let live = LiveState()

    enum ServerState: Equatable { case starting, online, offline(String) }

    struct Permissions: Equatable {
        var microphone = false
        var speech = false
        /// Speech recognition only powers live captions and the karaoke; the rest works without it.
        var allGranted: Bool { microphone && speech }
    }

    @Published var serverState: ServerState = .starting
    @Published var permissions = Permissions()
    /// Whether the server reports a usable LLM (provider + key).
    @Published var llmReady = false

    // MARK: Actions (wired by AppDelegate)

    var relaunch: () -> Void = {}
    var restartServer: () -> Void = {}
    /// Starts a live conversation and returns its ID.
    var startSession: (Scenario) -> UUID? = { _ in nil }
    var stopSession: () -> Void = {}
    var sendTyped: (String) -> Void = { _ in }
    var toggleMic: () -> Void = {}
    var interruptTutor: () -> Void = {}
    var generateReport: (UUID) -> Void = { _ in }
    var askTutor: (UUID, String) -> Void = { _, _ in }
    var requestPermissions: () -> Void = {}

    /// Talks to the local server; shared by every page.
    let client = LanguageClient(baseURL: Config.serverURL)
    let voice = VoiceEngine()
    /// The Texto page's state (translator + reading karaoke), kept across page switches.
    lazy var studio = TextStudio(model: self)

    // MARK: Persistence

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RustleLanguage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    private var loading = true
    /// False for throwaway models (snapshots): nothing is written to disk.
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        if persist {
            serverSettings = load("settings.json") ?? ServerSettings()
            sessions = load("sessions.json") ?? []
            readings = load("readings.json") ?? []
            texts = load("texts.json") ?? []
            vocabulary = load("vocabulary.json") ?? []
        }
        // A conversation left live by a crash or quit is finished now.
        for i in sessions.indices where sessions[i].status != .ready {
            sessions[i].status = .ready
            sessions[i].ended = sessions[i].ended ?? sessions[i].turns.last?.date
        }
        loading = false
        if persist, !FileManager.default.fileExists(atPath: Self.settingsURL.path) { save(serverSettings, "settings.json") }
    }

    // MARK: Sessions

    func session(_ id: UUID) -> PracticeSession? { sessions.first { $0.id == id } }

    func updateSession(_ id: UUID, _ change: (inout PracticeSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
    }

    // MARK: Vocabulary

    func hasWord(_ term: String) -> Bool {
        vocabulary.contains { $0.term.caseInsensitiveCompare(term) == .orderedSame }
    }

    func addWord(_ s: VocabSuggestion, source: VocabItem.Source) {
        let term = s.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !hasWord(term) else { return }
        vocabulary.insert(VocabItem(term: term, meaning: s.meaning, example: s.example, source: source), at: 0)
    }

    func removeWord(_ term: String) {
        vocabulary.removeAll { $0.term.caseInsensitiveCompare(term) == .orderedSame }
    }

    // MARK: Stats

    /// Days with any practice (conversation, reading or text), ending today or yesterday.
    var dayStreak: Int {
        let cal = Calendar.current
        let days = Set((sessions.map(\.started) + readings.map(\.date) + texts.map(\.date)).map { cal.startOfDay(for: $0) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    var minutesSpoken: Int {
        let conversation = sessions.reduce(0) { $0 + $1.speakingSeconds }
        return Int((conversation / 60).rounded())
    }

    var averageReadingScore: Int? {
        let recent = readings.prefix(10)
        return recent.isEmpty ? nil : recent.reduce(0) { $0 + $1.score } / recent.count
    }

    var averageSessionScore: Int? {
        let scored = sessions.compactMap { $0.report?.score }.filter { $0 > 0 }.prefix(10)
        return scored.isEmpty ? nil : scored.reduce(0, +) / scored.count
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        let url = Self.directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard !loading, persist else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
    }
}

/// What the live conversation is doing right now (drives the footer pill and captions).
@MainActor
final class LiveState: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for you to speak.
        case listening
        /// You are speaking (voice detected).
        case hearing
        /// Transcribing you and waiting for the tutor's reply.
        case thinking
        /// The tutor is talking.
        case speaking

        var label: String {
            switch self {
            case .idle: return "Pausado"
            case .listening: return "Sua vez, pode falar"
            case .hearing: return "Ouvindo você…"
            case .thinking: return "Pensando…"
            case .speaking: return "Tutor falando"
            }
        }
    }

    @Published var phase: Phase = .idle
    /// Apple's on-device recognition of what you are saying right now.
    @Published var caption = ""
    @Published var bars: [CGFloat] = Array(repeating: 0, count: 15)
    @Published var elapsed: TimeInterval = 0
    @Published var micMuted = false
    @Published var error: String?

    func push(level: Float) {
        let db = 20 * log10(max(level, 1e-5))
        bars.removeFirst()
        bars.append(CGFloat(max(0, min(1, (db + 55) / 45))))
    }
}

/// User preferences that live in UserDefaults (also read by Config / ServerManager).
enum Prefs {
    static let whisperModel = "whisperModel"            // base.en | small.en | medium.en | large-v3-turbo
    static let voiceEngine = "voiceEngine"              // system | voicestudio
    static let systemVoice = "systemVoice"              // AVSpeechSynthesisVoice identifier
    static let voiceStudioURL = "voiceStudioURL"        // http://127.0.0.1:3900
    static let voiceStudioVoice = "voiceStudioVoice"    // voice profile id / preset
    static let voiceStudioModel = "voiceStudioModel"    // engine id, empty = active engine
    static let speechRate = "speechRate"                // 0.8 … 1.2 (1 = normal)
    static let endOfTurnSilence = "endOfTurnSilence"    // seconds of silence that end your turn
    static let bargeIn = "bargeIn"                      // speaking over the tutor interrupts it
    static let showCaptions = "showCaptions"
    static let onboardingDone = "onboardingDone"
    static let firstName = "profileFirstName"
    static let lastName = "profileLastName"
    static let goals = "profileGoals"
}

enum Config {
    static var serverURL: URL {
        URL(string: ProcessInfo.processInfo.environment["RUSTLE_LANGUAGE_SERVER"]
            ?? UserDefaults.standard.string(forKey: "serverURL")
            ?? "http://127.0.0.1:8766")!
    }
}
