import AVFoundation
import Speech

/// The microphone, converted to 16 kHz mono PCM16 (what Whisper on the server expects), with the
/// raw buffers also handed to Apple's recognizer for live captions and the karaoke.
final class MicStream {
    /// PCM16 chunks, on the audio thread.
    var onPCM: ((Data) -> Void)?
    /// Raw input buffers, on the audio thread (for SFSpeechRecognizer).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false
    private let engine = AVAudioEngine()

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "RustleLanguage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nenhum microfone disponível"])
        }
        let converter = PCM16Converter(from: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
            if let pcm = converter.convert(buffer) { self?.onPCM?(pcm) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    static func rms(_ pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { let f = Float(s) / 32768; sum += f * f }
        }
        return (sum / Float(count)).squareRoot()
    }

    static func wav(pcm16: Data, sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm16.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}

/// Converts any PCM buffer to 16 kHz mono PCM16 (same as RustleApp's converter).
final class PCM16Converter {
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter?
    /// Voice-processed input can arrive as 3+ identical channels with no layout, which
    /// AVAudioConverter downmixes to silence; for those, channel 0 is copied into a mono buffer first.
    private let mono: AVAudioFormat?

    init(from format: AVAudioFormat) {
        if format.channelCount > 2, format.commonFormat == .pcmFormatFloat32 {
            mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
            converter = mono.flatMap { AVAudioConverter(from: $0, to: Self.target) }
        } else {
            mono = nil
            converter = AVAudioConverter(from: format, to: Self.target)
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter, buffer.frameLength > 0 else { return nil }
        var source = buffer
        if let mono {
            guard let src = buffer.floatChannelData,
                  let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
                  let dst = m.floatChannelData else { return nil }
            m.frameLength = buffer.frameLength
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<Int(buffer.frameLength) { dst[0][i] = src[0][i * stride] }
            source = m
        }
        let ratio = Self.target.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }
}

/// Apple's speech recognizer (en-US, on-device when available) for text that must appear while
/// you speak: conversation captions and the reading karaoke. Whisper on the server stays the
/// authoritative transcript; this is only fast.
///
/// A recognition request ends on its own after a pause or about a minute, so when one finishes
/// while we still listen, its text is kept and a new request continues where it stopped.
final class LiveSpeech: @unchecked Sendable {
    /// Full text so far (committed + current partial), on the main queue.
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var partial = ""
    private var active = false
    private var generation = 0

    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    var isAvailable: Bool { Self.authorized && (recognizer?.isAvailable ?? false) }

    func start() {
        lock.lock()
        committed = ""
        partial = ""
        active = true
        lock.unlock()
        begin()
    }

    /// Thread-safe; called from the audio tap.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }

    func stop() {
        lock.lock()
        active = false
        generation += 1
        let r = request, t = task
        request = nil
        task = nil
        lock.unlock()
        r?.endAudio()
        t?.cancel()
    }

    private func begin() {
        guard let recognizer, Self.authorized, recognizer.isAvailable else { return }
        lock.lock(); let stillActive = active; lock.unlock()
        guard stillActive else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        lock.lock()
        generation += 1
        let gen = generation
        request = r
        lock.unlock()
        let t = recognizer.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            guard gen == self.generation else { self.lock.unlock(); return }
            if let result { self.partial = result.bestTranscription.formattedString }
            let finished = (result?.isFinal ?? false) || error != nil
            if finished {
                if !self.partial.isEmpty { self.committed = [self.committed, self.partial].filter { !$0.isEmpty }.joined(separator: " ") }
                self.partial = ""
            }
            let text = [self.committed, self.partial].filter { !$0.isEmpty }.joined(separator: " ")
            let restart = finished && self.active
            self.lock.unlock()
            DispatchQueue.main.async { self.onText?(text) }
            // A short delay so a recognizer that fails right away cannot spin.
            if restart { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.begin() } }
        }
        lock.lock(); task = t; lock.unlock()
    }
}
