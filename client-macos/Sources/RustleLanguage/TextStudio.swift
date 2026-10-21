import AVFoundation
import Combine
import Foundation

/// State of the Texto page, kept while you switch pages: the translator / corrector (Google
/// Translate-style, but it explains every change) and the read-aloud karaoke.
@MainActor
final class TextStudio: ObservableObject {
    enum Tab: String { case translate, read }

    @Published var tab: Tab = .translate
    /// "auto" (detect), "translate" (my text is in Portuguese) or "improve" (my text is my English).
    @Published var mode = "auto"
    @Published var tone = "neutral"
    @Published var input = "" { didSet { scheduleAnalysis() } }
    @Published private(set) var result: TextAnalysis?
    /// Input the current result belongs to (so a stale result is shown faded while you type).
    @Published private(set) var resultInput = ""
    @Published private(set) var busy = false
    @Published var error: String?
    let reading: ReadingController

    private unowned let model: AppModel
    private var debounce: Task<Void, Never>?
    private var request: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        reading = ReadingController(model: model)
    }

    var isStale: Bool { result != nil && resultInput != input.trimmingCharacters(in: .whitespacesAndNewlines) }

    func setMode(_ m: String) {
        mode = m
        analyze()
    }

    func setTone(_ t: String) {
        tone = t
        analyze()
    }

    /// Like Google Translate: results follow your typing after a short pause.
    private func scheduleAnalysis() {
        debounce?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { result = nil; resultInput = ""; error = nil; request?.cancel(); busy = false; return }
        guard text.count >= 3 else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            self?.analyze()
        }
    }

    func analyze() {
        debounce?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        request?.cancel()
        busy = true
        error = nil
        let client = model.client, mode = mode, tone = tone, level = model.serverSettings.level
        request = Task { [weak self] in
            do {
                let r = try await client.analyze(text, mode: mode, tone: tone, level: level)
                guard let self, !Task.isCancelled else { return }
                self.busy = false
                if let e = r.error, !e.isEmpty {
                    self.error = e
                    return
                }
                self.result = r
                self.resultInput = text
                self.remember(text, r)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.busy = false
                self.error = error.localizedDescription
            }
        }
    }

    func swap() {
        guard let english = result?.english, !english.isEmpty else { return }
        input = english
        mode = "improve"
        analyze()
    }

    func clear() {
        input = ""
        result = nil
        resultInput = ""
        error = nil
    }

    func restore(_ entry: TextEntry) {
        tab = .translate
        debounce?.cancel()
        request?.cancel()
        busy = false
        input = entry.input
        debounce?.cancel()
        result = entry.result
        resultInput = entry.input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func practice(_ text: String) {
        reading.load(text)
        tab = .read
    }

    func reopen(_ attempt: ReadingAttempt) {
        reading.show(attempt)
        tab = .read
    }

    private func remember(_ input: String, _ result: TextAnalysis) {
        // Typing refines the same text: replace the latest entry instead of piling up drafts.
        if let first = model.texts.first, Date().timeIntervalSince(first.date) < 120,
           input.hasPrefix(String(first.input.prefix(12))) {
            model.texts[0] = TextEntry(input: input, result: result)
        } else {
            model.texts.insert(TextEntry(input: input, result: result), at: 0)
        }
        if model.texts.count > 100 { model.texts.removeLast(model.texts.count - 100) }
    }
}

/// Read-aloud karaoke: Apple's on-device recognizer follows you word by word while the mic
/// records; when you stop, Whisper on the server re-hears the whole recording and grades each word.
@MainActor
final class ReadingController: ObservableObject {
    enum Phase: Equatable { case editing, ready, reading, assessing, done }

    @Published private(set) var text = ""
    @Published private(set) var words: [ReadingTracker.Word] = []
    @Published private(set) var progress = ReadingTracker.Progress(statuses: [], heard: [:], position: 0)
    @Published var phase: Phase = .editing
    @Published var draft = ""
    @Published private(set) var attempt: ReadingAttempt?
    @Published var error: String?
    @Published private(set) var elapsed: TimeInterval = 0
    /// Word being spoken by "Ouvir" (macOS voice), for the listening highlight.
    @Published private(set) var listeningIndex: Int?
    @Published private(set) var level: Float = 0

    private unowned let model: AppModel
    private let mic = MicStream()
    private let speech = LiveSpeech()
    private let recording = PCMBuffer()
    private var started = Date()
    private var clock: Timer?
    private var finishTimer: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        let speech = speech
        mic.onBuffer = { buffer in speech.append(buffer) }
        let recording = recording
        mic.onPCM = { [weak self] data in
            recording.append(data)
            let level = MicStream.rms(data)
            DispatchQueue.main.async { self?.level = level }
        }
        speech.onText = { [weak self] heard in self?.follow(heard) }
    }

    static let samples: [(title: String, level: String, text: String)] = [
        ("Uma manhã comum", "A2", "Every morning I wake up at seven o'clock. I drink a cup of coffee and read the news on my phone. Then I take the bus to work. I like my job because my colleagues are friendly."),
        ("Planos de viagem", "B1", "Next summer, I'm planning to travel to Canada with my best friend. We want to visit Toronto and Vancouver, and maybe see the Rocky Mountains. I've already booked the flights, but we still need to find a hotel."),
        ("Reunião de trabalho", "B2", "Thanks for joining the meeting, everyone. Before we dive into the numbers, I'd like to quickly go over what we accomplished this quarter. Overall, the team has made significant progress, although we're still behind schedule on a couple of key deliverables."),
        ("Trava-línguas", "C1", "Three thin thinkers were thinking thirty thoughtful thoughts through the thick of Thursday. Although the weather was rather rough, they thoroughly thought it through, then went their separate ways."),
    ]

    var canRead: Bool { !words.isEmpty && model.activeSessionID == nil }

    func load(_ newText: String) {
        stopListening()
        cancelReading()
        text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = text
        words = ReadingTracker.words(in: text)
        progress = ReadingTracker.track(reference: words, heardText: "")
        attempt = nil
        error = nil
        phase = words.isEmpty ? .editing : .ready
    }

    func edit() {
        cancelReading()
        draft = text
        phase = .editing
    }

    /// Shows a saved attempt (from the history) with its graded words.
    func show(_ a: ReadingAttempt) {
        load(a.text)
        attempt = a
        apply(a)
        phase = .done
    }

    func start() {
        guard canRead else { return }
        stopListening()
        model.voice.stop()
        _ = recording.take()
        progress = ReadingTracker.track(reference: words, heardText: "")
        attempt = nil
        error = nil
        do {
            try mic.start()
        } catch {
            self.error = error.localizedDescription
            return
        }
        speech.start()
        if !LiveSpeech.authorized {
            error = "Sem a permissão de reconhecimento de fala o texto não acompanha você ao vivo, mas a avaliação no fim funciona."
        }
        started = Date()
        elapsed = 0
        phase = .reading
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
            }
        }
    }

    /// Stops recording and asks the server for the graded result.
    func stop() {
        guard phase == .reading else { return }
        finishTimer?.cancel()
        speech.stop()
        mic.stop()
        clock?.invalidate()
        level = 0
        let audio = recording.take()
        guard audio.count > 16_000 else {   // under half a second
            phase = .ready
            return
        }
        phase = .assessing
        let client = model.client, reference = text
        Task { [weak self] in
            do {
                let r = try await client.assess(wav: MicStream.wav(pcm16: audio), reference: reference)
                guard let self, self.phase == .assessing else { return }
                let a = ReadingAttempt(text: reference,
                                       words: r.words.map { .init(text: $0.text, status: $0.status, heard: $0.heard, probability: $0.probability) },
                                       score: r.score, accuracy: r.accuracy, completion: r.completion, wpm: r.wpm,
                                       pauses: r.pauses, summary: r.summary, tips: r.tips)
                self.attempt = a
                self.apply(a)
                self.phase = .done
                self.model.readings.insert(a, at: 0)
                if self.model.readings.count > 200 { self.model.readings.removeLast() }
            } catch {
                guard let self else { return }
                self.error = "Não consegui avaliar: \(error.localizedDescription)"
                self.phase = .done
            }
        }
    }

    func reset() {
        cancelReading()
        progress = ReadingTracker.track(reference: words, heardText: "")
        attempt = nil
        error = nil
        phase = words.isEmpty ? .editing : .ready
    }

    /// Reads the text with the macOS voice, highlighting each word as it is spoken.
    func listen() {
        if listeningIndex != nil || model.voice.isSpeaking {
            stopListening()
            return
        }
        listenTask = Task { [weak self] in
            guard let self else { return }
            let voice = self.model.voice
            let observer = voice.$spokenRange.sink { [weak self] range in
                guard let self, let range else { return }
                self.listeningIndex = ReadingTracker.wordIndex(at: range, in: self.words)
            }
            self.listeningIndex = 0
            await voice.speak(self.text, forceSystem: true)
            observer.cancel()
            self.listeningIndex = nil
        }
    }

    /// Snapshots: show the karaoke mid-reading without a microphone.
    func preview(heard: String) {
        phase = .reading
        elapsed = 14
        progress = ReadingTracker.track(reference: words, heardText: heard)
    }

    func speakWord(_ word: String) {
        Task { await model.voice.speak(word, forceSystem: true) }
    }

    private func stopListening() {
        listenTask?.cancel()
        if listeningIndex != nil { model.voice.stop() }
        listeningIndex = nil
    }

    private func cancelReading() {
        finishTimer?.cancel()
        if phase == .reading {
            speech.stop()
            mic.stop()
            clock?.invalidate()
        }
        level = 0
    }

    private func follow(_ heard: String) {
        guard phase == .reading else { return }
        progress = ReadingTracker.track(reference: words, heardText: heard)
        // Reached the last word: wrap up on our own after a short grace period.
        if progress.position >= words.count {
            finishTimer?.cancel()
            finishTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    private func apply(_ a: ReadingAttempt) {
        guard a.words.count == words.count else { return }
        var heard: [Int: String] = [:]
        let statuses: [ReadingTracker.Status] = a.words.enumerated().map { i, w in
            if !w.heard.isEmpty && w.status != "correct" { heard[i] = w.heard }
            return ReadingTracker.Status(rawValue: w.status) ?? .pending
        }
        progress = ReadingTracker.Progress(statuses: statuses, heard: heard,
                                           position: statuses.lastIndex { $0 != .pending }.map { $0 + 1 } ?? 0)
    }
}

/// PCM appended from the audio thread and drained on the main actor.
final class PCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        let out = data
        data.removeAll()
        return out
    }
}
