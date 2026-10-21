import AVFoundation
import Foundation

/// Speaks English: the tutor's replies, the "Ouvir" buttons and pronunciation models.
///
/// Two engines:
///  - VoiceStudio (github.com/debpalash/VoiceStudio), a local voice studio that serves an
///    OpenAI-compatible `POST /v1/audio/speech` on :3900 (OmniVoice, KittenTTS, PocketTTS… and your
///    own cloned voices), listed by `GET /v1/audio/voices`. Natural voices, all on your Mac.
///  - The macOS voices (AVSpeechSynthesizer): always available, and the only one that reports
///    which word is being spoken, which the karaoke uses to highlight while you listen.
/// VoiceStudio failures fall back to the macOS voice, so the tutor never goes silent.
@MainActor
final class VoiceEngine: NSObject, ObservableObject {
    enum Engine: String { case system, voicestudio }

    struct StudioVoice: Identifiable, Hashable { let id: String; let name: String }

    @Published private(set) var isSpeaking = false
    /// Range of the word being spoken in the current text (macOS voice only).
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var lastError: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    /// Bumped by every speak/stop, so a finished or cancelled older request never touches the new one.
    private var token = 0
    private var currentUtterance: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var engine: Engine { Engine(rawValue: UserDefaults.standard.string(forKey: Prefs.voiceEngine) ?? "") ?? .system }
    private var rate: Double { UserDefaults.standard.object(forKey: Prefs.speechRate) as? Double ?? 1.0 }

    /// Speaks and returns when finished (or stopped). `forceSystem` keeps word highlighting.
    func speak(_ text: String, forceSystem: Bool = false) async {
        stop()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let mine = token
        isSpeaking = true
        lastError = nil
        if engine == .voicestudio && !forceSystem {
            do {
                let audio = try await Self.studioSpeech(text, speed: rate)
                guard mine == token else { return }   // stopped while generating
                try await play(audio)
                if mine == token { isSpeaking = false }
                return
            } catch {
                guard mine == token else { return }
                lastError = "VoiceStudio: \(error.localizedDescription). Usando a voz do macOS."
                Log.info("VoiceStudio failed: \(error.localizedDescription); falling back to the system voice")
            }
        }
        await speakSystem(text)
        if mine == token {
            isSpeaking = false
            spokenRange = nil
        }
    }

    func stop() {
        token += 1
        currentUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
        isSpeaking = false
        spokenRange = nil
        finish()
    }

    // MARK: macOS voice

    private func speakSystem(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.selectedSystemVoice()
        // AVSpeechUtterance's default rate (0.5) is a natural pace; scale it by the user's setting.
        utterance.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, 0.25), 0.7))
        currentUtterance = ObjectIdentifier(utterance)
        await withCheckedContinuation { c in
            continuation = c
            synthesizer.speak(utterance)
        }
    }

    private func finish() {
        let c = continuation
        continuation = nil
        c?.resume()
    }

    /// English voices installed on this Mac, best first (premium, enhanced, then default quality).
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-") }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                if ($0.language == "en-US") != ($1.language == "en-US") { return $0.language == "en-US" }
                return $0.name < $1.name
            }
    }

    static func selectedSystemVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Prefs.systemVoice), let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return englishVoices().first { $0.language == "en-US" } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let accent = ["en-US": "EUA", "en-GB": "Reino Unido", "en-AU": "Austrália", "en-IE": "Irlanda",
                      "en-IN": "Índia", "en-ZA": "África do Sul"][v.language] ?? v.language
        let quality = v.quality == .premium ? " · premium" : v.quality == .enhanced ? " · aprimorada" : ""
        return "\(v.name) (\(accent))\(quality)"
    }

    // MARK: VoiceStudio

    static var studioURL: URL {
        let raw = UserDefaults.standard.string(forKey: Prefs.voiceStudioURL) ?? ""
        return URL(string: raw.isEmpty ? "http://127.0.0.1:3900" : raw) ?? URL(string: "http://127.0.0.1:3900")!
    }

    /// OpenAI-compatible speech request; WAV needs no encoder on VoiceStudio's side.
    static func studioSpeech(_ text: String, speed: Double) async throws -> Data {
        struct Req: Encodable {
            let model: String?; let input: String; let voice: String; let response_format: String; let speed: Double; let language: String
        }
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: Prefs.voiceStudioModel) ?? ""
        let voice = defaults.string(forKey: Prefs.voiceStudioVoice) ?? ""
        var req = URLRequest(url: studioURL.appendingPathComponent("v1/audio/speech"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(model: model.isEmpty ? "tts-1" : model, input: text,
                                                     voice: voice.isEmpty ? "default" : voice,
                                                     response_format: "wav", speed: speed, language: "en"))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RustleLanguage", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(160))"])
        }
        return data
    }

    /// `GET /v1/audio/voices` (VoiceStudio extension): your cloned profiles plus engine presets.
    static func studioVoices() async throws -> [StudioVoice] {
        var req = URLRequest(url: studioURL.appendingPathComponent("v1/audio/voices"))
        req.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "RustleLanguage", code: 5, userInfo: [NSLocalizedDescriptionKey: "VoiceStudio não respondeu"])
        }
        let json = try JSONSerialization.jsonObject(with: data)
        let list = (json as? [String: Any])?["voices"] as? [[String: Any]] ?? (json as? [[String: Any]]) ?? []
        return list.compactMap { v in
            guard let id = (v["voice_id"] ?? v["id"]) as? String else { return nil }
            return StudioVoice(id: id, name: (v["name"] as? String) ?? id)
        }
    }

    private func play(_ audio: Data) async throws {
        let p = try AVAudioPlayer(data: audio)
        p.delegate = self
        player = p
        await withCheckedContinuation { c in
            continuation = c
            if !p.play() { finish() }
        }
    }
}

extension VoiceEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if self.currentUtterance == id { self.spokenRange = characterRange } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if self.currentUtterance == id { self.finish() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if self.currentUtterance == id { self.finish() } }
    }
}

extension VoiceEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if let p = self.player, ObjectIdentifier(p) == id { self.finish() } }
    }
}
