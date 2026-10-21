import AppKit
import AVFoundation
import Speech
import SwiftUI

/// The hub window, same frame as RustleApp: a 216 px sand sidebar and the page as an inset card
/// (radius 24/24/16/16, 1 px border, 8 px right/bottom margin) under a 52 px title-bar strip.
struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page: Page
    @AppStorage(Prefs.onboardingDone) private var onboardingDone = false

    init(model: AppModel, initialPage: Page = .home) {
        self.model = model
        _page = State(initialValue: initialPage)
    }

    enum Page: String, CaseIterable, Identifiable {
        case home, conversation, text, vocabulary, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Início"
            case .conversation: return "Conversa"
            case .text: return "Texto"
            case .vocabulary: return "Vocabulário"
            case .settings: return "Configurações"
            }
        }
        var icon: String {
            switch self {
            case .home: return "square.grid.2x2"
            case .conversation: return "bubble.left.and.text.bubble.right"
            case .text: return "character.bubble"
            case .vocabulary: return "book.closed"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        if onboardingDone {
            hub
        } else {
            OnboardingView(model: model) {
                onboardingDone = true
                page = .home
            }
            .frame(minWidth: 900, minHeight: 600)
            .ignoresSafeArea()
        }
    }

    private var hub: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, page: $page)
            VStack(spacing: 0) {
                Color.clear.frame(height: 52)
                PageCard {
                    switch page {
                    case .home: HomePage(model: model, page: $page)
                    case .conversation: ConversationPage(model: model)
                    case .text: TextStudioPage(model: model, studio: model.studio)
                    case .vocabulary: VocabularyPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .background(DS.backgroundTertiary)
        .foregroundColor(DS.foreground)
        .font(DS.ui(15))
        .frame(minWidth: 960, minHeight: 640)
        .ignoresSafeArea()
        .onChange(of: model.pageRequest) { request in
            guard let request else { return }
            page = request
            model.pageRequest = nil
        }
    }
}

// MARK: - Frame

private struct PageCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 16,
                                           bottomTrailingRadius: 16, topTrailingRadius: 24)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(DS.background))
            .clipShape(shape)
            .overlay(shape.stroke(DS.border, lineWidth: 1))
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var page: MainView.Page

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 28)
            BrandRow().padding(.bottom, 16)
            VStack(spacing: 4) {
                ForEach([MainView.Page.home, .conversation, .text, .vocabulary]) { p in
                    SidebarItem(title: p.title, icon: p.icon, active: page == p,
                                recording: p == .conversation && model.activeSessionID != nil,
                                badge: p == .vocabulary ? model.vocabulary.filter { !$0.mastered }.count : 0) {
                        if p == .conversation && page == .conversation { model.openSessionID = nil }
                        page = p
                    }
                }
            }
            Spacer(minLength: 0)
            if !model.llmReady && model.serverState == .online {
                SidebarNudge(title: "Conecte uma IA", detail: "DeepSeek, OpenAI, Claude, Ollama… para conversar e receber correções.") {
                    page = .settings
                }
            } else if !model.permissions.allGranted {
                SidebarNudge(title: "Conceda as permissões", detail: "Microfone e reconhecimento de fala para conversar e ler em voz alta.") {
                    page = .settings
                }
            }
            Rectangle().fill(DS.border).frame(height: 1).padding(.top, 8)
            VStack(spacing: 4) {
                SidebarItem(title: MainView.Page.settings.title, icon: MainView.Page.settings.icon,
                            active: page == .settings) { page = .settings }
                SidebarItem(title: "Ajuda", icon: "questionmark.circle", active: false) {
                    NSWorkspace.shared.open(Log.url)
                }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 216)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarItem: View {
    let title: String
    let icon: String
    let active: Bool
    var recording = false
    var badge = 0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 20, height: 20)
                Text(title).font(DS.ui(15, DS.w550))
                Spacer(minLength: 0)
                if recording { RecordingDot() }
                if badge > 0 {
                    Text("\(badge)").font(DS.ui(12, DS.w550)).foregroundColor(DS.foregroundTertiary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(active || hover ? DS.neutral200 : DS.backgroundTertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SidebarNudge: View {
    let title: String
    let detail: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.ui(15, .semibold))
                Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.neutral200))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
            .shadow(color: Color(hex: 0x1A1A1A, opacity: 0.1), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var model: AppModel
    @Binding var page: MainView.Page

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(text: model.displayFirstName.isEmpty ? "Bem-vindo de volta" : "Bem-vindo de volta, \(model.displayFirstName)", size: 34)
                    Spacer()
                    StatusChip(model: model)
                }

                HStack(spacing: 36) {
                    Stat(value: "\(model.dayStreak)", label: model.dayStreak == 1 ? "dia seguido" : "dias seguidos")
                    Stat(value: "\(model.minutesSpoken)", label: "min falando")
                    Stat(value: model.averageReadingScore.map { "\($0)" } ?? "—", label: "na leitura")
                    Stat(value: "\(model.vocabulary.count)", label: model.vocabulary.count == 1 ? "palavra" : "palavras")
                }

                PracticeHero(
                    start: {
                        if let id = model.startSession(.free) { model.openSessionID = id; page = .conversation }
                    },
                    read: { model.studio.tab = .read; page = .text },
                    live: model.activeSessionID != nil
                )

                if !model.llmReady && model.serverState == .online {
                    SetupBanner(icon: "sparkles", title: "Conecte uma IA para conversar",
                                detail: "A conversa, as correções e o tradutor usam o modelo que você escolher: DeepSeek, OpenAI, Claude, Groq, Gemini ou um local com Ollama.",
                                button: "Configurar IA") { page = .settings }
                }
                if !model.permissions.allGranted {
                    SetupBanner(icon: "mic", title: "Falta permissão: \(missingPermissions)",
                                detail: "O microfone grava sua voz; o reconhecimento de fala da Apple mostra legendas ao vivo e acompanha sua leitura (karaokê).",
                                button: "Permitir") { model.requestPermissions() }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Cenários")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Scenario.all.prefix(4)) { s in
                            ScenarioCard(scenario: s, compact: true) {
                                if let id = model.startSession(s) { model.openSessionID = id; page = .conversation }
                            }
                            .disabled(model.activeSessionID != nil)
                        }
                    }
                }

                RecentActivity(model: model, page: $page)
            }
        }
    }

    private var missingPermissions: String {
        var m: [String] = []
        if !model.permissions.microphone { m.append("Microfone") }
        if !model.permissions.speech { m.append("Reconhecimento de fala") }
        return m.joined(separator: ", ")
    }
}

struct StatusChip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(DS.ui(13, .medium)).foregroundColor(DS.neutral600)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(DS.backgroundTertiary))
        .help(help)
    }
    private var color: Color {
        switch model.serverState {
        case .online: return model.llmReady ? DS.success500 : DS.glow300
        case .starting: return DS.glow300
        case .offline: return DS.destructive500
        }
    }
    private var text: String {
        switch model.serverState {
        case .online: return model.llmReady ? "Tutor pronto" : "Sem IA conectada"
        case .starting: return "Carregando modelo…"
        case .offline: return "Servidor parado"
        }
    }
    private var help: String {
        if case .offline(let msg) = model.serverState { return msg }
        return ""
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(DS.display(28)).tracking(-1.1)
            Text(label).font(DS.ui(16)).foregroundColor(DS.neutral600)
        }
    }
}

/// Dark hero card, same treatment as RustleApp's hotkey hint (vast-950 background).
private struct PracticeHero: View {
    let start: () -> Void
    let read: () -> Void
    let live: Bool
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pratique inglês conversando")
                    .font(DS.display(26)).tracking(-1).foregroundColor(DS.sand50)
                Text("Fale naturalmente: o tutor responde em voz alta e anota, frase a frase, onde você pode melhorar.")
                    .font(DS.ui(15)).foregroundColor(DS.vast300)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: start) { Label(live ? "Conversa em andamento" : "Começar conversa", systemImage: "mic.fill") }
                        .buttonStyle(DarkButtonStyle(filled: true))
                        .disabled(live)
                    Button(action: read) { Label("Ler um texto em voz alta", systemImage: "text.word.spacing") }
                        .buttonStyle(DarkButtonStyle(filled: false))
                }
                .padding(.top, 6)
            }
            Spacer()
            MiniWave()
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.vast950))
    }
}

private struct MiniWave: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array([8.0, 16, 24, 14, 28, 18, 10, 20, 12].enumerated()), id: \.offset) { _, h in
                Capsule().fill(DS.sand50).frame(width: 3, height: h)
            }
        }
        .frame(width: 73, height: 30)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(DS.vast900, lineWidth: 1))
    }
}

struct SetupBanner: View {
    let icon: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(DS.glow300).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(DS.ui(15, DS.w550))
                Text(detail).font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFDF3EA)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xFACDA1), lineWidth: 1))
    }
}

/// Scenario tile (Notetaker's feature cards: white, 1 px border, radius 12, dawn icon).
struct ScenarioCard: View {
    let scenario: Scenario
    var compact = false
    let start: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: scenario.icon).font(.system(size: 16)).foregroundColor(DS.dawn700)
                Text(scenario.title).font(DS.ui(15, DS.w550)).foregroundColor(DS.foreground)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if !compact {
                    Text(scenario.detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: compact ? 84 : 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? DS.dawn100 : DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? DS.dawn400 : DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Conversations, readings and texts, newest first (RustleApp's history list style).
private struct RecentActivity: View {
    @ObservedObject var model: AppModel
    @Binding var page: MainView.Page

    private struct Item: Identifiable {
        let id: UUID
        let date: Date
        let icon: String
        let title: String
        let detail: String
        let score: Int?
        let open: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = []
        for s in model.sessions {
            all.append(Item(id: s.id, date: s.started, icon: s.scenario.icon, title: s.displayTitle,
                            detail: "Conversa · \(s.durationLabel) · \(s.yourTurns.count) falas",
                            score: s.report?.score.nonZero, open: { model.openSessionID = s.id; page = .conversation }))
        }
        for r in model.readings {
            all.append(Item(id: r.id, date: r.date, icon: "text.word.spacing", title: r.title,
                            detail: "Leitura · \(r.wpm) palavras/min", score: r.score,
                            open: { model.studio.reopen(r); page = .text }))
        }
        for t in model.texts {
            all.append(Item(id: t.id, date: t.date, icon: "character.bubble", title: String(t.input.prefix(80)),
                            detail: t.result.mode == "improve" ? "Texto corrigido" : "Texto traduzido", score: nil,
                            open: { model.studio.restore(t); page = .text }))
        }
        return Array(all.sorted { $0.date > $1.date }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Atividade recente")
            if items.isEmpty {
                EmptyState(icon: "waveform", title: "Nenhuma prática ainda",
                           detail: "Comece uma conversa ou leia um texto em voz alta. Tudo o que você praticar aparece aqui.")
            } else {
                ListCard {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        ActivityRow(icon: item.icon, title: item.title, detail: item.detail, date: item.date,
                                    score: item.score, open: item.open)
                        if i < items.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let icon: String
    let title: String
    let detail: String
    let date: Date
    let score: Int?
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(DS.foregroundTertiary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.backgroundTertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.ui(15, DS.w550)).lineLimit(1)
                    Text("\(date.formatted(.relative(presentation: .named))) · \(detail)")
                        .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let score { ScorePill(score: score) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hover ? DS.backgroundTertiary : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ScorePill: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(DS.ui(12, DS.w550)).monospacedDigit()
            .foregroundColor(ScoreRing.color(score))
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(ScoreRing.color(score).opacity(0.12)))
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Vocabulary

private struct VocabularyPage: View {
    @ObservedObject var model: AppModel
    @State private var adding = false
    @State private var term = ""
    @State private var meaning = ""
    @State private var example = ""
    @State private var query = ""
    @State private var filter = "learning"

    private var items: [VocabItem] {
        model.vocabulary.filter { item in
            (filter == "all" || (filter == "mastered") == item.mastered)
                && (query.isEmpty || item.term.localizedCaseInsensitiveContains(query) || item.meaning.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Vocabulário",
                           description: "Palavras e expressões salvas das conversas, textos e leituras. O tutor tenta usá-las nas próximas conversas.") {
                    Button("Adicionar") { adding = true }.buttonStyle(PrimaryButtonStyle())
                }
                if adding {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            HubTextField(placeholder: "Palavra ou expressão em inglês", text: $term)
                            HubTextField(placeholder: "Significado", text: $meaning)
                        }
                        HubTextField(placeholder: "Exemplo (opcional)", text: $example, onSubmit: add)
                        HStack {
                            Button("Salvar", action: add).buttonStyle(PrimaryButtonStyle())
                            Button("Cancelar") { adding = false }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                HStack(spacing: 8) {
                    HubTextField(placeholder: "Buscar no seu vocabulário", text: $query)
                    ForEach([("learning", "Aprendendo"), ("mastered", "Dominadas"), ("all", "Todas")], id: \.0) { id, label in
                        PillButton(title: label, active: filter == id) { filter = id }
                    }
                }
                if items.isEmpty {
                    EmptyState(icon: "book.closed",
                               title: model.vocabulary.isEmpty ? "Seu vocabulário está vazio" : "Nada aqui",
                               detail: model.vocabulary.isEmpty
                                   ? "Salve palavras com o + nos relatórios das conversas, no tradutor e nas leituras."
                                   : "Nenhuma palavra com esse filtro.")
                } else {
                    ListCard {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            VocabRow(model: model, item: item)
                            if i < items.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addWord(VocabSuggestion(term: term, meaning: meaning, example: example), source: .manual)
        term = ""; meaning = ""; example = ""; adding = false
    }
}

private struct VocabRow: View {
    @ObservedObject var model: AppModel
    let item: VocabItem
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.term).font(DS.ui(16, .semibold)).strikethrough(item.mastered, color: DS.foregroundTertiary)
                    Text(item.source.label).font(DS.ui(11, DS.w550)).foregroundColor(DS.foregroundTertiary)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(DS.backgroundTertiary))
                }
                if !item.meaning.isEmpty { Text(item.meaning).font(DS.ui(15)).foregroundColor(DS.neutral600) }
                if !item.example.isEmpty {
                    Text("“\(item.example)”").font(DS.display(17)).foregroundColor(DS.vast700)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                IconButton(systemName: "speaker.wave.2", help: "Ouvir") {
                    Task { await model.voice.speak(item.example.isEmpty ? item.term : "\(item.term). \(item.example)") }
                }
                IconButton(systemName: item.mastered ? "arrow.uturn.backward" : "checkmark", help: item.mastered ? "Voltar a estudar" : "Já domino") {
                    if let i = model.vocabulary.firstIndex(where: { $0.id == item.id }) { model.vocabulary[i].mastered.toggle() }
                }
                IconButton(systemName: "trash", help: "Apagar") { model.vocabulary.removeAll { $0.id == item.id } }
                    .opacity(hover ? 1 : 0)
            }
        }
        .padding(16)
        .background(hover ? DS.backgroundTertiary : Color.clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @AppStorage(Prefs.whisperModel) private var whisperModel = "small.en"
    @AppStorage(Prefs.voiceEngine) private var voiceEngine = "system"
    @AppStorage(Prefs.systemVoice) private var systemVoice = ""
    @AppStorage(Prefs.voiceStudioURL) private var studioURL = "http://127.0.0.1:3900"
    @AppStorage(Prefs.voiceStudioVoice) private var studioVoice = ""
    @AppStorage(Prefs.voiceStudioModel) private var studioModel = ""
    @AppStorage(Prefs.speechRate) private var speechRate = 1.0
    @AppStorage(Prefs.endOfTurnSilence) private var endSilence = 1.1
    @AppStorage(Prefs.bargeIn) private var bargeIn = false
    @AppStorage(Prefs.showCaptions) private var showCaptions = true
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var llmTest: String?
    @State private var testing = false
    @State private var studioVoices: [VoiceEngine.StudioVoice] = []
    @State private var studioStatus: String?

    private var provider: LLMProvider { LLMProvider.find(model.serverSettings.llm_provider) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 12) {
                    PageTitle(text: "Configurações")
                    Text("Seu nível, a IA do tutor, a voz e o reconhecimento de fala.")
                        .font(DS.ui(15)).foregroundColor(DS.neutral600)
                }

                SettingsSection(title: "Perfil") {
                    SettingsCard {
                        SettingsRow(label: "Nome", description: "Aparece na tela de início.") {
                            ProfileField(placeholder: "Nome", text: $model.firstName)
                        }
                        SettingsRow(label: "Seu nível de inglês", description: "O tutor ajusta vocabulário, velocidade e correções ao nível (CEFR).") {
                            Picker("", selection: $model.serverSettings.level) {
                                ForEach(OnboardingView.levels, id: \.id) { Text("\($0.id) · \($0.title)").tag($0.id) }
                            }.labelsHidden()
                        }
                        SettingsRow(label: "Questionário inicial", description: "Refaça as perguntas da primeira abertura.") {
                            Button("Refazer") { UserDefaults.standard.set(false, forKey: Prefs.onboardingDone) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                SettingsSection(title: "IA do tutor") {
                    SettingsCard {
                        SettingsRow(label: "Provedor", description: provider.note) {
                            Picker("", selection: Binding(get: { model.serverSettings.llm_provider }, set: selectProvider)) {
                                ForEach(LLMProvider.all) { Text($0.name).tag($0.id) }
                            }.labelsHidden()
                        }
                        if provider.id != "anthropic" {
                            SettingsRow(label: "Endereço da API", description: "Base compatível com OpenAI (a app chama …/chat/completions).", width: 300) {
                                ProfileField(placeholder: "https://…/v1", text: $model.serverSettings.llm_base_url)
                            }
                        }
                        SettingsRow(label: "Modelo", description: "Nome exato do modelo no provedor.", width: 300) {
                            ProfileField(placeholder: provider.model.isEmpty ? "nome-do-modelo" : provider.model, text: $model.serverSettings.llm_model)
                        }
                        if provider.needsKey {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Chave da API \(provider.name)").font(DS.ui(15, DS.w550))
                                    Spacer()
                                    if let url = provider.keyURL.flatMap(URL.init(string:)) {
                                        Button("Obter chave") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                                    }
                                }
                                HStack(spacing: 8) {
                                    SecureField("", text: $apiKey, prompt: Text(provider.keyPlaceholder).foregroundColor(DS.vast500))
                                        .textFieldStyle(.plain).font(DS.ui(15))
                                        .padding(.horizontal, 12).frame(height: 36)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(DS.card))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
                                        .onChange(of: apiKey) { _ in keySaved = false }
                                    Button(keySaved ? "Salva ✓" : "Salvar") {
                                        keySaved = Keychain.saveAPIKey(apiKey, account: Keychain.account(for: provider.id))
                                        model.restartServer()
                                    }.buttonStyle(PrimaryButtonStyle())
                                }
                                Text("Guardada no Chaveiro do macOS (uma por provedor). Salvar reinicia o servidor local.")
                                    .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                            }
                        }
                        HStack(spacing: 10) {
                            Button(testing ? "Testando…" : "Testar conexão") { test() }
                                .buttonStyle(SecondaryButtonStyle()).disabled(testing)
                            if let llmTest {
                                Text(llmTest).font(DS.ui(13)).foregroundColor(llmTest.hasPrefix("✓") ? DS.success500 : DS.destructive500)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                SettingsSection(title: "Voz do tutor") {
                    SettingsCard {
                        SettingsRow(label: "Motor de voz", description: "VoiceStudio gera vozes naturais (e a sua voz clonada) no seu Mac. A voz do macOS funciona sempre e destaca cada palavra no karaokê.") {
                            Picker("", selection: $voiceEngine) {
                                Text("Voz do macOS").tag("system")
                                Text("VoiceStudio").tag("voicestudio")
                            }.labelsHidden()
                        }
                        if voiceEngine == "voicestudio" {
                            SettingsRow(label: "Endereço do VoiceStudio", description: "A API local do VoiceStudio (porta 3900 por padrão). Abra o app VoiceStudio antes.", width: 300) {
                                ProfileField(placeholder: "http://127.0.0.1:3900", text: $studioURL)
                            }
                            SettingsRow(label: "Voz", description: studioStatus ?? "Perfis e vozes do VoiceStudio (GET /v1/audio/voices).", width: 300) {
                                HStack(spacing: 6) {
                                    Picker("", selection: $studioVoice) {
                                        Text("Padrão").tag("")
                                        ForEach(studioVoices) { Text($0.name).tag($0.id) }
                                        if !studioVoice.isEmpty && !studioVoices.contains(where: { $0.id == studioVoice }) {
                                            Text(studioVoice).tag(studioVoice)
                                        }
                                    }.labelsHidden()
                                    IconButton(systemName: "arrow.clockwise", help: "Atualizar vozes") { loadStudioVoices() }
                                }
                            }
                            SettingsRow(label: "Motor (opcional)", description: "Id do motor de TTS (ex.: kittentts, pockettts, omnivoice). Vazio usa o motor ativo.", width: 300) {
                                ProfileField(placeholder: "motor ativo", text: $studioModel)
                            }
                        } else {
                            SettingsRow(label: "Voz do macOS", description: "Baixe vozes “Premium” em Ajustes → Acessibilidade → Conteúdo Falado para soar mais natural.", width: 300) {
                                Picker("", selection: $systemVoice) {
                                    Text("Automática (inglês EUA)").tag("")
                                    ForEach(VoiceEngine.englishVoices(), id: \.identifier) { Text(VoiceEngine.label($0)).tag($0.identifier) }
                                }.labelsHidden()
                            }
                        }
                        SettingsRow(label: "Velocidade", description: "Fale mais devagar enquanto se acostuma com o sotaque.") {
                            Picker("", selection: $speechRate) {
                                Text("Devagar").tag(0.8)
                                Text("Normal").tag(1.0)
                                Text("Rápida").tag(1.2)
                            }.labelsHidden()
                        }
                        HStack(spacing: 10) {
                            Button("Ouvir exemplo") {
                                Task { await model.voice.speak("Hi! I'm your English tutor. Let's practice together. How was your day?") }
                            }.buttonStyle(SecondaryButtonStyle())
                            if let err = model.voice.lastError {
                                Text(err).font(DS.ui(13)).foregroundColor(DS.destructive500).lineLimit(2)
                            }
                        }
                    }
                }

                SettingsSection(title: "Conversa") {
                    SettingsCard {
                        SettingsRow(label: "Fim da sua fala", description: "Quanto silêncio encerra a sua vez. Aumente se o tutor responde antes de você terminar.") {
                            Picker("", selection: $endSilence) {
                                Text("Curto (0,8 s)").tag(0.8)
                                Text("Normal (1,1 s)").tag(1.1)
                                Text("Longo (1,6 s)").tag(1.6)
                                Text("Bem longo (2,2 s)").tag(2.2)
                            }.labelsHidden()
                        }
                        SettingsRow(label: "Interromper o tutor falando", description: "Use com fones de ouvido: sem fones o microfone ouve o próprio tutor.") {
                            Toggle("", isOn: $bargeIn).toggleStyle(.switch).labelsHidden()
                        }
                        SettingsRow(label: "Legendas ao vivo", description: "Mostra o que você está dizendo enquanto fala (reconhecimento da Apple, no dispositivo).") {
                            Toggle("", isOn: $showCaptions).toggleStyle(.switch).labelsHidden()
                        }
                    }
                }

                SettingsSection(title: "Reconhecimento de fala") {
                    SettingsCard {
                        SettingsRow(label: "Modelo Whisper (local)", description: "Transcreve suas falas e avalia a leitura no seu Mac. Os “.en” são só inglês: mais rápidos e precisos. Trocar reinicia o servidor.") {
                            Picker("", selection: $whisperModel) {
                                Text("base.en (rápido)").tag("base.en")
                                Text("small.en (recomendado)").tag("small.en")
                                Text("medium.en (preciso)").tag("medium.en")
                                Text("large-v3-turbo").tag("large-v3-turbo")
                            }
                            .labelsHidden()
                            .onChange(of: whisperModel) { _ in model.restartServer() }
                        }
                        SettingsRow(label: "Servidor local", description: serverDescription) {
                            Button("Reiniciar") { model.restartServer() }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                SettingsSection(title: "Permissões") {
                    SettingsCard {
                        PermissionRow(label: "Microfone", description: "Grava sua voz nas conversas e leituras.",
                                      ok: model.permissions.microphone) { model.requestPermissions() }
                        PermissionRow(label: "Reconhecimento de fala", description: "Legendas ao vivo e o karaokê da leitura.",
                                      ok: model.permissions.speech) { model.requestPermissions() }
                        HStack(spacing: 8) {
                            Button("Reiniciar app") { model.relaunch() }.buttonStyle(SecondaryButtonStyle())
                            Spacer()
                            Button("Abrir log") { NSWorkspace.shared.open(Log.url) }.buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onAppear {
            apiKey = Keychain.readAPIKey(Keychain.account(for: provider.id)) ?? ""
            keySaved = !apiKey.isEmpty
            if voiceEngine == "voicestudio" { loadStudioVoices() }
        }
        .onChange(of: voiceEngine) { v in if v == "voicestudio" { loadStudioVoices() } }
    }

    private func selectProvider(_ id: String) {
        let p = LLMProvider.find(id)
        model.serverSettings.llm_provider = p.id
        model.serverSettings.llm_base_url = p.baseURL
        model.serverSettings.llm_model = p.model
        apiKey = Keychain.readAPIKey(Keychain.account(for: p.id)) ?? ""
        keySaved = !apiKey.isEmpty
        llmTest = nil
    }

    private func test() {
        testing = true
        llmTest = nil
        Task {
            // Give the server a moment to reload settings.json after an edit.
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                let r = try await model.client.testLLM()
                llmTest = r.ok ? "✓ \(r.sample ?? "") (\(r.latencyMs ?? 0) ms)" : "✗ \(r.error ?? "falhou")"
                model.llmReady = r.ok
            } catch {
                llmTest = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func loadStudioVoices() {
        studioStatus = "Procurando o VoiceStudio…"
        Task {
            do {
                studioVoices = try await VoiceEngine.studioVoices()
                studioStatus = "Conectado: \(studioVoices.count) vozes."
            } catch {
                studioVoices = []
                studioStatus = "VoiceStudio não encontrado em \(VoiceEngine.studioURL.absoluteString). Abra o app ou confira o endereço."
            }
        }
    }

    private var serverDescription: String {
        switch model.serverState {
        case .online: return "Online em \(Config.serverURL.host ?? "127.0.0.1"):\(Config.serverURL.port ?? 8766)."
        case .starting: return "Iniciando e carregando o modelo…"
        case .offline(let msg): return msg
        }
    }
}

struct ProfileField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(DS.vast500))
            .textFieldStyle(.plain).font(DS.ui(15))
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(DS.ui(15, .semibold))
            content
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    let description: String
    var width: CGFloat = 200
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(DS.ui(15, DS.w550))
                Text(description).font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control.frame(width: width, alignment: .trailing)
        }
    }
}

private struct PermissionRow: View {
    let label: String
    let description: String
    let ok: Bool
    /// Asks macOS (or opens System Settings when the answer was already "no").
    let request: () -> Void
    var body: some View {
        SettingsRow(label: label, description: description) {
            if ok {
                Label("Concedida", systemImage: "checkmark.circle.fill")
                    .font(DS.ui(14, .medium)).foregroundColor(DS.success500)
            } else {
                Button("Conceder", action: request).buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
