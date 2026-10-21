import Foundation

// MARK: - Conversation (modeled on RustleApp's Notetaker meeting)

/// One spoken practice conversation: the transcript (you / tutor), an annotation with corrections
/// under each of your lines, the user's own notepad, and the post-session report (summary,
/// improvements, vocabulary, score), like the Notetaker's summary and action items.
struct PracticeSession: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case live, ready }

    struct Turn: Codable, Identifiable, Hashable {
        enum Role: String, Codable {
            case you, tutor
            var label: String { self == .you ? "Você" : "Tutor" }
        }
        var id = UUID()
        var role: Role
        var text: String
        var date = Date()
        /// Seconds of speech (your lines only); typed lines have none.
        var seconds: Double?
        var feedback: Feedback?
    }

    struct ChatMessage: Codable, Identifiable, Hashable {
        var id = UUID()
        var fromUser: Bool
        var text: String
    }

    var id = UUID()
    var title = ""
    var scenarioID = Scenario.free.id
    var level = "B1"
    var started = Date()
    var ended: Date?
    var status: Status = .live
    var turns: [Turn] = []
    var report: Report?
    var notes = ""
    var chat: [ChatMessage] = []

    var scenario: Scenario { Scenario.find(scenarioID) }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let t = report?.title, !t.isEmpty { return t }
        return "\(scenario.title) · \(started.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    var durationLabel: String {
        let m = Int(duration) / 60
        return m < 1 ? "< 1 min" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    var yourTurns: [Turn] { turns.filter { $0.role == .you } }
    var issues: [Feedback.Issue] { yourTurns.flatMap { $0.feedback?.issues ?? [] } }
    var speakingSeconds: Double { yourTurns.reduce(0) { $0 + ($1.seconds ?? 0) } }

    var transcriptText: String {
        turns.map { "\($0.role.label): \($0.text)" }.joined(separator: "\n")
    }
}

struct Feedback: Codable, Hashable {
    struct Issue: Codable, Hashable {
        var original: String
        var suggestion: String
        var explanation: String
        var kind: String
    }
    var corrected: String
    var ok: Bool
    var issues: [Issue]
    var natural: String

    static func label(for kind: String) -> String {
        switch kind {
        case "grammar": return "Gramática"
        case "vocabulary": return "Vocabulário"
        case "naturalness": return "Naturalidade"
        case "spelling": return "Ortografia"
        case "translation": return "Tradução"
        default: return "Dica"
        }
    }
}

struct Report: Codable, Hashable {
    struct Section: Codable, Hashable { var heading: String; var bullets: [String] }
    var title: String
    var summary: String
    var strengths: [String]
    var improvements: [Section]
    var vocabulary: [VocabSuggestion]
    var score: Int
    var levelEstimate: String
    var engine: String?
}

struct VocabSuggestion: Codable, Hashable {
    var term: String
    var meaning: String
    var example: String
}

/// Conversation scenarios: the tutor plays a role (interviewer, waiter…). `prompt` goes to the LLM.
struct Scenario: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let prompt: String

    static let free = Scenario(id: "free", title: "Conversa livre", detail: "Seu dia, hobbies, planos e opiniões.",
                               icon: "bubble.left.and.bubble.right",
                               prompt: "Free conversation: chat about the learner's day, interests, plans and opinions, like a friendly language-exchange partner.")
    static let all: [Scenario] = [
        free,
        Scenario(id: "interview", title: "Entrevista de emprego", detail: "Perguntas reais de um recrutador.",
                 icon: "briefcase",
                 prompt: "Job interview. You are a friendly hiring manager interviewing the learner for a job in their field. Ask one interview question at a time and react to the answers."),
        Scenario(id: "meeting", title: "Reunião de trabalho", detail: "Status, prazos e bloqueios com um colega.",
                 icon: "person.3",
                 prompt: "A work stand-up meeting with a colleague. Discuss what they're working on, deadlines, blockers and next steps."),
        Scenario(id: "smalltalk", title: "Small talk", detail: "Puxar assunto num evento ou festa.",
                 icon: "cup.and.saucer",
                 prompt: "Small talk with someone the learner just met at a networking event: work, where they're from, weekend plans."),
        Scenario(id: "restaurant", title: "Restaurante", detail: "Pedir, perguntar e pagar a conta.",
                 icon: "fork.knife",
                 prompt: "At a restaurant. You are the server; the learner is a customer. Greet them, take the order, answer questions about the menu, and bring the check."),
        Scenario(id: "travel", title: "Aeroporto e hotel", detail: "Check-in, imigração e hospedagem.",
                 icon: "airplane",
                 prompt: "Travel. You are first an airline check-in agent, then (when that is done) a hotel receptionist. Handle the learner's check-in realistically."),
        Scenario(id: "doctor", title: "Consulta médica", detail: "Explicar sintomas e entender o médico.",
                 icon: "cross.case",
                 prompt: "At the doctor's office. You are the doctor; ask about symptoms, give simple advice."),
        Scenario(id: "shopping", title: "Compras", detail: "Tamanhos, preços, trocas e devoluções.",
                 icon: "bag",
                 prompt: "Shopping in a clothing store. You are the shop assistant helping the learner find, try on, buy or return something."),
    ]

    static func find(_ id: String) -> Scenario { all.first { $0.id == id } ?? free }
}

// MARK: - Text studio & reading

struct TextAnalysis: Codable, Hashable {
    struct Change: Codable, Hashable { var original: String; var suggestion: String; var explanation: String; var kind: String }
    struct Alternative: Codable, Hashable { var text: String; var note: String }
    var detectedLanguage: String?
    var mode: String?
    var english: String?
    var backTranslation: String?
    var changes: [Change]?
    var alternatives: [Alternative]?
    var vocabulary: [VocabSuggestion]?
    var tip: String?
    var engine: String?
    var error: String?
}

struct TextEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var input: String
    var result: TextAnalysis
}

/// One read-aloud attempt, assessed by the server (Whisper word timings + alignment).
struct ReadingAttempt: Codable, Identifiable, Hashable {
    struct Word: Codable, Hashable {
        var text: String
        /// correct | close | wrong | missed | unclear | pending
        var status: String
        var heard: String
        var probability: Double
    }
    struct Tip: Codable, Hashable { var word: String; var ipa: String; var tip: String }

    var id = UUID()
    var date = Date()
    var text: String
    var words: [Word]
    var score: Int
    var accuracy: Int
    var completion: Int
    var wpm: Int
    var pauses: Int
    var summary: String
    var tips: [Tip]

    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return first.count > 70 ? String(first.prefix(70)) + "…" : first
    }
}

// MARK: - Vocabulary

struct VocabItem: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case conversation, text, reading, manual
        var label: String {
            switch self {
            case .conversation: return "Conversa"
            case .text: return "Texto"
            case .reading: return "Leitura"
            case .manual: return "Manual"
            }
        }
    }
    var id = UUID()
    var term: String
    var meaning: String
    var example: String
    var source: Source
    var added = Date()
    var mastered = false
}

// MARK: - AI providers

/// Presets for "any LLM": almost every provider speaks OpenAI's chat-completions protocol, so a
/// base URL + model (+ key) is enough. Anthropic is called through its own Messages API.
struct LLMProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let needsKey: Bool
    let keyPlaceholder: String
    let keyURL: String?
    let note: String

    static let all: [LLMProvider] = [
        LLMProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat",
                    needsKey: true, keyPlaceholder: "sk-…", keyURL: "https://platform.deepseek.com/api_keys",
                    note: "Barato e bom em conversa. deepseek-chat responde rápido."),
        LLMProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
                    needsKey: true, keyPlaceholder: "sk-…", keyURL: "https://platform.openai.com/api-keys",
                    note: "Troque o modelo pelo que preferir."),
        LLMProvider(id: "anthropic", name: "Claude (Anthropic)", baseURL: "", model: "claude-opus-5-5",
                    needsKey: true, keyPlaceholder: "sk-ant-…", keyURL: "https://console.anthropic.com/settings/keys",
                    note: "API de Mensagens da Anthropic."),
        LLMProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "deepseek/deepseek-chat",
                    needsKey: true, keyPlaceholder: "sk-or-…", keyURL: "https://openrouter.ai/keys",
                    note: "Uma chave para centenas de modelos (use o nome do modelo do OpenRouter)."),
        LLMProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile",
                    needsKey: true, keyPlaceholder: "gsk_…", keyURL: "https://console.groq.com/keys",
                    note: "Respostas muito rápidas, ótimo para conversa por voz."),
        LLMProvider(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                    model: "gemini-2.5-flash", needsKey: true, keyPlaceholder: "AIza…", keyURL: "https://aistudio.google.com/apikey",
                    note: "Pelo endpoint compatível com OpenAI."),
        LLMProvider(id: "ollama", name: "Ollama (local)", baseURL: "http://127.0.0.1:11434/v1", model: "llama3.1",
                    needsKey: false, keyPlaceholder: "", keyURL: nil,
                    note: "Roda no seu Mac, sem chave. Rode `ollama pull llama3.1` antes."),
        LLMProvider(id: "custom", name: "Outro (compatível com OpenAI)", baseURL: "", model: "",
                    needsKey: true, keyPlaceholder: "opcional", keyURL: nil,
                    note: "LM Studio, vLLM, Together, Mistral… qualquer endpoint /chat/completions."),
    ]

    static func find(_ id: String) -> LLMProvider { all.first { $0.id == id } ?? all[0] }
}
