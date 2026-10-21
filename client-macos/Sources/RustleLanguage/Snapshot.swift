import AppKit
import SwiftUI

/// `RustleLanguage --snapshot <dir>` renders every page off-screen to PNG with sample data (no
/// Screen Recording permission needed), then exits. Used to check the UI without a display.
@MainActor
enum Snapshot {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: Prefs.onboardingDone)
        let model = AppModel(persist: false)
        model.serverState = .online
        model.llmReady = true
        model.permissions = .init(microphone: true, speech: true)
        model.firstName = "Henrique"
        seed(model)
        let size = NSSize(width: 1180, height: 780)

        render(MainView(model: model, initialPage: .home), size: size, to: dir.appendingPathComponent("home.png"))
        render(MainView(model: model, initialPage: .conversation), size: size, to: dir.appendingPathComponent("conversation-list.png"))
        model.openSessionID = model.sessions.first?.id
        render(MainView(model: model, initialPage: .conversation), size: NSSize(width: 1180, height: 1500),
               to: dir.appendingPathComponent("conversation-report.png"))

        // Live: the same conversation, while you are speaking.
        if let id = model.sessions.first?.id {
            model.activeSessionID = id
            model.live.phase = .hearing
            model.live.caption = "I think the best part of my job is"
            model.live.elapsed = 312
            model.live.bars = (0..<15).map { i in CGFloat([0.2, 0.6, 0.9, 0.4, 0.7][i % 5]) }
            model.pendingFeedback.insert(model.sessions[0].turns.last { $0.role == .you }!.id)
            render(MainView(model: model, initialPage: .conversation), size: size, to: dir.appendingPathComponent("conversation-live.png"))
            model.openSessionID = nil
            render(MainView(model: model, initialPage: .conversation), size: size, to: dir.appendingPathComponent("conversation-list-live.png"))
            model.activeSessionID = nil
            model.pendingFeedback.removeAll()
            model.live.phase = .idle
        }

        model.studio.restore(model.texts[0])
        render(MainView(model: model, initialPage: .text), size: NSSize(width: 1180, height: 1200), to: dir.appendingPathComponent("text-translate.png"))
        model.studio.clear()
        render(MainView(model: model, initialPage: .text), size: size, to: dir.appendingPathComponent("text-empty.png"))

        model.studio.tab = .read
        model.studio.reading.edit()
        render(MainView(model: model, initialPage: .text), size: size, to: dir.appendingPathComponent("read-editor.png"))
        model.studio.reading.load(ReadingController.samples[1].text)
        model.studio.reading.preview(heard: "Next summer I'm planning to travel to Canada with my best friend we want to visit Toronto and Vancouver and maybe sea the")
        render(MainView(model: model, initialPage: .text), size: size, to: dir.appendingPathComponent("read-live.png"))
        model.studio.reading.show(model.readings[0])
        render(MainView(model: model, initialPage: .text), size: NSSize(width: 1180, height: 1300), to: dir.appendingPathComponent("read-result.png"))

        render(MainView(model: model, initialPage: .vocabulary), size: size, to: dir.appendingPathComponent("vocabulary.png"))
        render(MainView(model: model, initialPage: .settings), size: NSSize(width: 1180, height: 1900), to: dir.appendingPathComponent("settings.png"))

        UserDefaults.standard.set(false, forKey: Prefs.onboardingDone)
        for step in OnboardingView.Step.allCases {
            render(OnboardingView(model: model, initialStep: step) {}, size: size,
                   to: dir.appendingPathComponent("onboarding-\(step.rawValue)-\(step).png"))
        }
        UserDefaults.standard.set(true, forKey: Prefs.onboardingDone)

        let icon = ImageRenderer(content: AppIconView())
        icon.scale = 0.5
        if let cg = icon.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("icon.png"))
        }
        print("snapshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func seed(_ model: AppModel) {
        let now = Date()
        var s = PracticeSession(scenarioID: "interview", level: "B1", started: now.addingTimeInterval(-1800),
                                ended: now.addingTimeInterval(-1260), status: .ready)
        s.turns = [
            .init(role: .tutor, text: "Hi, thanks for coming in today! To start, could you tell me a little about yourself and your current role?"),
            .init(role: .you, text: "Yes, of course. I am working as developer since five years in a fintech company.", seconds: 6,
                  feedback: Feedback(corrected: "Yes, of course. I've been working as a developer for five years at a fintech company.", ok: false,
                                     issues: [.init(original: "I am working since five years", suggestion: "I've been working for five years",
                                                    explanation: "Para ações que começaram no passado e continuam, use o present perfect continuous com “for”.", kind: "grammar"),
                                              .init(original: "as developer", suggestion: "as a developer",
                                                    explanation: "Profissões no singular pedem o artigo “a/an”.", kind: "grammar")],
                                     natural: "Sure! I've been a developer at a fintech for the past five years.")),
            .init(role: .tutor, text: "That's great. What would you say is the biggest challenge you've faced in that role?"),
            .init(role: .you, text: "I think the biggest challenge was to migrate our system to the cloud without stopping the service.", seconds: 7,
                  feedback: Feedback(corrected: "I think the biggest challenge was migrating our system to the cloud without any downtime.", ok: false,
                                     issues: [.init(original: "without stopping the service", suggestion: "without any downtime",
                                                    explanation: "“Downtime” é o termo natural para o período em que o sistema fica fora do ar.", kind: "vocabulary")],
                                     natural: "")),
            .init(role: .tutor, text: "Impressive. How did you make sure nothing broke during the migration?"),
            .init(role: .you, text: "We did a lot of tests and we moved one service at a time.", seconds: 4,
                  feedback: Feedback(corrected: "We did a lot of tests and we moved one service at a time.", ok: true, issues: [], natural: "")),
        ]
        s.report = Report(title: "Entrevista para desenvolvedor",
                          summary: "Você se apresentou e falou sobre a migração para a nuvem com boa fluência. Os erros mais comuns foram tempos verbais com “since/for” e alguns artigos.",
                          strengths: ["Respostas claras e bem organizadas", "Bom vocabulário técnico"],
                          improvements: [.init(heading: "Present perfect com for/since",
                                               bullets: ["“I am working since five years” → “I've been working for five years”.", "Use “for” com períodos e “since” com um ponto no tempo."]),
                                         .init(heading: "Artigos", bullets: ["“as developer” → “as a developer”."])],
                          vocabulary: [.init(term: "downtime", meaning: "tempo fora do ar", example: "We migrated without any downtime."),
                                       .init(term: "roll out", meaning: "lançar aos poucos", example: "We rolled out the change gradually."),
                                       .init(term: "bottleneck", meaning: "gargalo", example: "The database was our main bottleneck.")],
                          score: 74, levelEstimate: "B1", engine: "deepseek")
        s.notes = "Revisar present perfect continuous"
        var s2 = PracticeSession(scenarioID: "restaurant", level: "B1", started: now.addingTimeInterval(-90000),
                                 ended: now.addingTimeInterval(-89400), status: .ready)
        s2.turns = [.init(role: .tutor, text: "Good evening! Table for one?"), .init(role: .you, text: "Yes, please. Can I see the menu?", seconds: 2)]
        s2.report = Report(title: "Jantar no restaurante", summary: "", strengths: [], improvements: [], vocabulary: [], score: 88, levelEstimate: "B1")
        model.sessions = [s, s2]

        model.texts = [TextEntry(input: "Eu gostaria de marcar uma reunião para amanhã de manhã, se você tiver disponibilidade.",
                                 result: TextAnalysis(detectedLanguage: "pt", mode: "translate",
                                                      english: "I'd like to schedule a meeting for tomorrow morning, if you're available.",
                                                      backTranslation: "Eu gostaria de agendar uma reunião para amanhã de manhã, se você estiver disponível.",
                                                      changes: [.init(original: "marcar uma reunião", suggestion: "schedule a meeting",
                                                                      explanation: "“Marcar” vira “schedule” ou “set up”; “mark” não é usado para compromissos.", kind: "translation"),
                                                                .init(original: "se você tiver disponibilidade", suggestion: "if you're available",
                                                                      explanation: "Em inglês é mais natural usar o adjetivo “available” do que “availability”.", kind: "translation")],
                                                      alternatives: [.init(text: "Could we set up a meeting tomorrow morning, if that works for you?", note: "mais casual"),
                                                                     .init(text: "Would you be available for a meeting tomorrow morning?", note: "mais formal")],
                                                      vocabulary: [.init(term: "schedule", meaning: "agendar", example: "Let's schedule a call."),
                                                                   .init(term: "available", meaning: "disponível", example: "Are you available on Friday?")],
                                                      tip: "“If that works for you” é uma forma educada e muito comum de propor horários.", engine: "deepseek", error: nil))]

        let text = ReadingController.samples[3].text
        let words = ReadingTracker.words(in: text)
        let statuses: [String: (String, String)] = ["Three": ("close", "tree"), "thin": ("wrong", "tin"), "thirty": ("unclear", "thirty"),
                                                    "thoroughly": ("close", "thoroughly"), "rough": ("wrong", "rug")]
        model.readings = [ReadingAttempt(text: text, words: words.map { w in
            let s = statuses[w.key.capitalized] ?? statuses[w.key] ?? ("correct", "")
            return .init(text: w.display, status: s.0, heard: s.1, probability: 0.9)
        }, score: 81, accuracy: 84, completion: 100, wpm: 118, pauses: 2,
           summary: "Boa leitura! O som do “th” ainda está oscilando: em “three” e “thin” ele virou “t”.",
           tips: [.init(word: "three", ipa: "/θriː/", tip: "Coloque a ponta da língua entre os dentes e sopre: não é “tri”."),
                  .init(word: "rough", ipa: "/rʌf/", tip: "O “gh” final soa como “f”: “râf”."),
                  .init(word: "thoroughly", ipa: "/ˈθɜːroʊli/", tip: "Tônica na primeira sílaba: THUR-oh-lee.")])]

        model.vocabulary = [
            VocabItem(term: "downtime", meaning: "tempo fora do ar", example: "We migrated without any downtime.", source: .conversation),
            VocabItem(term: "schedule", meaning: "agendar", example: "Let's schedule a call.", source: .text),
            VocabItem(term: "thoroughly", meaning: "minuciosamente", example: "They thoroughly thought it through.", source: .reading),
        ]
    }
}
