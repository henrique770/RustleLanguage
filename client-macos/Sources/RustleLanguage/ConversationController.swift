import AVFoundation
import Foundation

/// The live voice conversation loop:
///
///   tutor speaks → you speak (voice activity detection decides when your turn starts and ends)
///   → your audio goes to the server (Whisper → LLM) → tutor's reply is spoken → …
///
/// Your line appears right away (Apple's live caption, then Whisper's text), and its annotation
/// (corrections, a more natural phrasing) arrives a moment later from a separate request, so the
/// reply is never held up by the feedback. While the tutor talks the mic is ignored (no echo
/// cancellation on speakers); with headphones, "Permitir interromper" lets you talk over it.
@MainActor
final class ConversationController {
    private let model: AppModel
    private var live: LiveState { model.live }
    private let mic = MicStream()
    private let captions = LiveSpeech()
    private var sessionID: UUID?
    private var clock: Timer?
    private var started = Date()
    private var replyTask: Task<Void, Never>?

    // Voice activity detection, on 16 kHz PCM16 chunks.
    private var utterance = Data()
    private var preroll = Data()
    private var speechSeconds = 0.0
    private var silenceSeconds = 0.0
    private var bargeSeconds = 0.0
    private var noiseFloor: Float = 0.004
    private static let prerollSeconds = 0.35
    private static let minSpeech = 0.35
    private static let maxUtterance = 45.0

    private var endSilence: Double { UserDefaults.standard.object(forKey: Prefs.endOfTurnSilence) as? Double ?? 1.1 }
    private var bargeIn: Bool { UserDefaults.standard.bool(forKey: Prefs.bargeIn) }

    init(model: AppModel) {
        self.model = model
        mic.onPCM = { [weak self] pcm in
            DispatchQueue.main.async { self?.process(pcm) }
        }
        let captions = captions
        mic.onBuffer = { buffer in captions.append(buffer) }
        captions.onText = { [weak self] text in
            guard let self, self.live.phase == .hearing else { return }
            self.live.caption = text
        }
    }

    var isActive: Bool { sessionID != nil }

    // MARK: Session

    func start(scenario: Scenario) -> UUID? {
        if let id = sessionID { return id }
        var session = PracticeSession(scenarioID: scenario.id, level: model.serverSettings.level)
        session.started = Date()
        do {
            try mic.start()
        } catch {
            live.error = error.localizedDescription
            Log.info("conversation: mic failed: \(error.localizedDescription)")
            return nil
        }
        model.sessions.insert(session, at: 0)
        model.activeSessionID = session.id
        sessionID = session.id
        started = Date()
        live.elapsed = 0
        live.error = nil
        live.caption = ""
        live.micMuted = false
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.live.elapsed = Date().timeIntervalSince(self.started)
            }
        }
        Log.info("conversation started: \(scenario.id)")
        // The tutor opens the conversation.
        exchange(wav: nil, text: nil, seconds: nil)
        return session.id
    }

    func stop() {
        guard let id = sessionID else { return }
        replyTask?.cancel()
        model.voice.stop()
        captions.stop()
        mic.stop()
        clock?.invalidate()
        clock = nil
        sessionID = nil
        live.phase = .idle
        live.caption = ""
        model.activeSessionID = nil
        model.updateSession(id) { $0.status = .ready; $0.ended = Date() }
        Log.info("conversation stopped")
        if model.session(id)?.yourTurns.isEmpty == false { model.generateReport(id) }
    }

    func toggleMic() {
        live.micMuted.toggle()
        if live.micMuted, live.phase == .hearing { resetUtterance(); live.phase = .listening }
    }

    /// Stops the tutor mid-sentence and gives you the floor.
    func interrupt() {
        guard live.phase == .speaking || live.phase == .thinking else { return }
        replyTask?.cancel()
        model.voice.stop()
        listen()
    }

    func sendTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, sessionID != nil else { return }
        model.voice.stop()
        resetUtterance()
        exchange(wav: nil, text: t, seconds: nil)
    }

    // MARK: Turn detection

    private func process(_ pcm: Data) {
        guard sessionID != nil else { return }
        let level = MicStream.rms(pcm)
        live.push(level: live.micMuted ? 0 : level)
        let seconds = Double(pcm.count / 2) / 16_000
        let threshold = max(0.012, noiseFloor * 3.2)

        switch live.phase {
        case .listening:
            guard !live.micMuted else { return }
            if level > threshold {
                speechSeconds += seconds
                utterance.append(pcm)
                if speechSeconds >= 0.12 {
                    live.phase = .hearing
                    live.caption = ""
                    captions.start()
                }
            } else {
                // Quiet: learn the room's noise, keep a short pre-roll so the first syllable isn't cut.
                noiseFloor = noiseFloor * 0.97 + level * 0.03
                speechSeconds = 0
                preroll.append(utterance)
                preroll.append(pcm)
                utterance.removeAll(keepingCapacity: true)
                let keep = Int(Self.prerollSeconds * 16_000) * 2
                if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
            }

        case .hearing:
            utterance.append(pcm)
            if level > threshold * 0.8 {
                speechSeconds += seconds
                silenceSeconds = 0
            } else {
                silenceSeconds += seconds
            }
            let total = Double(utterance.count / 2) / 16_000
            if silenceSeconds >= endSilence || total >= Self.maxUtterance {
                finishUtterance()
            }

        case .speaking where bargeIn && !live.micMuted:
            // With headphones: talking over the tutor (well above the room noise) takes the floor.
            bargeSeconds = level > max(0.03, noiseFloor * 6) ? bargeSeconds + seconds : 0
            if bargeSeconds > 0.3 {
                Log.info("conversation: barge-in")
                bargeSeconds = 0
                interrupt()
            }

        default:
            break
        }
    }

    private func finishUtterance() {
        captions.stop()
        let audio = preroll + utterance
        let spoken = speechSeconds
        resetUtterance()
        guard spoken >= Self.minSpeech else {
            // A cough or a click: keep listening.
            live.phase = .listening
            live.caption = ""
            return
        }
        exchange(wav: MicStream.wav(pcm16: audio), text: nil, seconds: Double(audio.count / 2) / 16_000)
    }

    private func resetUtterance() {
        utterance.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        speechSeconds = 0
        silenceSeconds = 0
    }

    private func listen() {
        guard sessionID != nil else { return }
        resetUtterance()
        live.caption = ""
        live.phase = .listening
    }

    // MARK: Exchange

    /// Sends your turn (audio, typed text, or nothing for the opening line) and speaks the reply.
    private func exchange(wav: Data?, text: String?, seconds: Double?) {
        guard let id = sessionID, let session = model.session(id) else { return }
        live.phase = .thinking
        let caption = live.caption
        let client = model.client
        // Show your line at once (typed text, or the live caption until Whisper's text arrives).
        var pendingTurnID: UUID?
        if let text {
            let turn = PracticeSession.Turn(role: .you, text: text)
            model.updateSession(id) { $0.turns.append(turn) }
            pendingTurnID = turn.id
        } else if wav != nil, !caption.isEmpty {
            let turn = PracticeSession.Turn(role: .you, text: caption, seconds: seconds)
            model.updateSession(id) { $0.turns.append(turn) }
            pendingTurnID = turn.id
        }
        // The server adds your current line itself (typed, or transcribed from the audio).
        let history = (model.session(id)?.turns ?? session.turns).filter { $0.id != pendingTurnID }
        let level = session.level
        let scenario = session.scenario

        replyTask?.cancel()
        replyTask = Task { [weak self] in
            do {
                let result = try await client.turn(wav: wav, text: text, history: history, scenario: scenario, level: level)
                guard let self, !Task.isCancelled, self.sessionID == id else { return }
                if wav != nil {
                    if result.userText.isEmpty {
                        // Nothing intelligible: drop the caption line and keep listening.
                        if let pid = pendingTurnID { self.model.updateSession(id) { $0.turns.removeAll { $0.id == pid } } }
                        self.listen()
                        return
                    }
                    if let pid = pendingTurnID {
                        self.model.updateSession(id) { s in
                            if let i = s.turns.firstIndex(where: { $0.id == pid }) { s.turns[i].text = result.userText }
                        }
                    } else {
                        let turn = PracticeSession.Turn(role: .you, text: result.userText, seconds: seconds)
                        self.model.updateSession(id) { $0.turns.append(turn) }
                        pendingTurnID = turn.id
                    }
                }
                if let pid = pendingTurnID { self.annotate(turn: pid, in: id) }
                guard !result.reply.isEmpty else {
                    self.live.error = result.error.flatMap { $0.isEmpty ? nil : "IA: \($0)" }
                        ?? "Configure um provedor de IA em Configurações → IA."
                    self.listen()
                    return
                }
                self.live.error = nil
                let reply = PracticeSession.Turn(role: .tutor, text: result.reply)
                self.model.updateSession(id) { $0.turns.append(reply) }
                self.live.phase = .speaking
                self.bargeSeconds = 0
                await self.model.voice.speak(result.reply)
                guard !Task.isCancelled, self.sessionID == id, self.live.phase == .speaking else { return }
                self.listen()
            } catch {
                guard let self, !Task.isCancelled, self.sessionID == id else { return }
                self.live.error = error.localizedDescription
                Log.info("conversation turn failed: \(error.localizedDescription)")
                self.listen()
            }
        }
    }

    /// Corrections for one of your lines, shown under it when they arrive.
    private func annotate(turn turnID: UUID, in id: UUID) {
        guard let session = model.session(id), let i = session.turns.firstIndex(where: { $0.id == turnID }) else { return }
        let text = session.turns[i].text
        let previous = session.turns[..<i].last { $0.role == .tutor }?.text ?? ""
        let client = model.client
        let level = session.level
        model.pendingFeedback.insert(turnID)
        Task { [weak self] in
            let feedback = try? await client.feedback(for: text, previous: previous, level: level)
            guard let self else { return }
            self.model.pendingFeedback.remove(turnID)
            guard let feedback else { return }
            self.model.updateSession(id) { s in
                if let j = s.turns.firstIndex(where: { $0.id == turnID }) { s.turns[j].feedback = feedback }
            }
        }
    }
}
