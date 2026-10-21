import AppKit
import SwiftUI

/// The Texto page. Two tabs:
///  - Traduzir e corrigir: Google Translate's two panes (your text → natural English), except that
///    it also teaches: what changed and why, other ways to say it, words worth saving.
///  - Ler em voz alta: karaoke. The text follows you as you read; then every word is graded.
struct TextStudioPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var studio: TextStudio

    var body: some View {
        PageScroll(maxWidth: 980) {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Texto",
                           description: "Traduza ou corrija um texto como no tradutor, entenda cada mudança e depois leia em voz alta: o app acompanha você palavra por palavra.") {
                    EmptyView()
                }
                TabBar(selection: Binding(get: { studio.tab }, set: { studio.tab = $0 }))
                switch studio.tab {
                case .translate: TranslatePane(model: model, studio: studio)
                case .read: ReadingPane(model: model, reading: studio.reading)
                }
            }
        }
    }
}

/// Style page tabs: sand track, the active tab as a white bordered chip.
private struct TabBar: View {
    @Binding var selection: TextStudio.Tab
    var body: some View {
        HStack(spacing: 4) {
            tab(.translate, "Traduzir e corrigir", "character.bubble")
            tab(.read, "Ler em voz alta", "text.word.spacing")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.backgroundTertiary))
    }

    private func tab(_ t: TextStudio.Tab, _ label: String, _ icon: String) -> some View {
        Button { selection = t } label: {
            Label(label, systemImage: icon)
                .font(DS.ui(15, selection == t ? DS.w550 : .regular))
                .foregroundColor(selection == t ? DS.foreground : DS.neutral600)
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(selection == t ? DS.card : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == t ? DS.border : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Translate & improve

private struct TranslatePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var studio: TextStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LanguageBar(studio: studio)
            HStack(alignment: .top, spacing: 12) {
                InputCard(studio: studio, model: model)
                OutputCard(studio: studio, model: model, voice: model.voice)
            }
            .frame(minHeight: 240)

            if let error = studio.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DS.ui(14)).foregroundColor(DS.destructive500)
            }

            if let r = studio.result {
                Insights(model: model, studio: studio, result: r)
                    .opacity(studio.isStale ? 0.5 : 1)
            } else if studio.input.isEmpty {
                Suggestions(studio: studio)
            }

            if !model.texts.isEmpty {
                RecentTexts(model: model, studio: studio)
            }
        }
    }
}

/// Google Translate's language bar: source chips, swap, target + tone.
private struct LanguageBar: View {
    @ObservedObject var studio: TextStudio
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                chip("auto", detectedLabel)
                chip("translate", "Português")
                chip("improve", "Meu inglês")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(systemName: "arrow.left.arrow.right", help: "Usar o inglês como texto de entrada") { studio.swap() }
                .disabled(studio.result?.english == nil)
            HStack(spacing: 6) {
                Text(studio.result?.mode == "improve" || studio.mode == "improve" ? "Inglês corrigido" : "Inglês")
                    .font(DS.ui(14, DS.w550))
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(alignment: .bottom) { Rectangle().fill(DS.vast950).frame(height: 2) }
                Spacer()
                Menu {
                    Button("Neutro") { studio.setTone("neutral") }
                    Button("Formal") { studio.setTone("formal") }
                    Button("Casual") { studio.setTone("casual") }
                } label: {
                    Label(toneLabel, systemImage: "slider.horizontal.3").font(DS.ui(13, DS.w550)).foregroundColor(DS.neutral600)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(DS.neutral600)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detectedLabel: String {
        guard studio.mode == "auto", let lang = studio.result?.detectedLanguage else { return "Detectar idioma" }
        let names = ["pt": "Português", "en": "Inglês", "es": "Espanhol", "fr": "Francês", "it": "Italiano", "de": "Alemão"]
        return "\(names[lang] ?? lang.uppercased()) · detectado"
    }

    private var toneLabel: String {
        ["formal": "Tom formal", "casual": "Tom casual"][studio.tone] ?? "Tom neutro"
    }

    private func chip(_ id: String, _ label: String) -> some View {
        Button { studio.setMode(id) } label: {
            Text(label)
                .font(DS.ui(14, studio.mode == id ? DS.w550 : .regular))
                .foregroundColor(studio.mode == id ? DS.foreground : DS.neutral600)
                .padding(.horizontal, 12).frame(height: 30)
                .overlay(alignment: .bottom) { Rectangle().fill(studio.mode == id ? DS.vast950 : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct InputCard: View {
    @ObservedObject var studio: TextStudio
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if studio.input.isEmpty {
                    Text("Digite ou cole um texto em português, ou o seu inglês para corrigir")
                        .font(DS.ui(20)).foregroundColor(DS.vast500)
                        .padding(.horizontal, 5).padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $studio.input)
                    .font(DS.ui(20))
                    .scrollContentBackground(.hidden)
                    .lineSpacing(4)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 4) {
                Text("\(studio.input.count) / 6000").font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
                Spacer()
                if !studio.input.isEmpty {
                    IconButton(systemName: "xmark", help: "Limpar") { studio.clear() }
                }
                Button("Analisar") { studio.analyze() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(studio.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct OutputCard: View {
    @ObservedObject var studio: TextStudio
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let english = studio.result?.english {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(english).font(DS.ui(20)).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let back = studio.result?.backTranslation, !back.isEmpty, studio.result?.detectedLanguage != "pt" || studio.result?.mode == "improve" {
                            Text("Em português: \(back)").font(DS.ui(14)).foregroundColor(DS.foregroundTertiary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                HStack(spacing: 4) {
                    IconButton(systemName: voice.isSpeaking ? "stop.fill" : "speaker.wave.2", help: "Ouvir") {
                        if voice.isSpeaking { voice.stop() } else { Task { await voice.speak(english) } }
                    }
                    CopyButton(text: { english })
                    Spacer()
                    if studio.busy { ProgressView().controlSize(.small) }
                    Button { studio.practice(english) } label: { Label("Praticar leitura", systemImage: "mic") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Text(studio.busy ? "Traduzindo…" : "Tradução")
                    .font(DS.ui(20)).foregroundColor(DS.vast500)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if studio.busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.backgroundTertiary))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// What makes it more than a translator: changes explained, alternatives, words to keep.
private struct Insights: View {
    @ObservedObject var model: AppModel
    @ObservedObject var studio: TextStudio
    let result: TextAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let changes = result.changes, !changes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: result.mode == "improve" ? "O que melhorar (\(changes.count))" : "Escolhas da tradução")
                    ForEach(changes, id: \.self) { c in
                        ChangeCard(original: c.original, suggestion: c.suggestion, explanation: c.explanation, kind: c.kind) {
                            Task { await model.voice.speak(c.suggestion) }
                        }
                    }
                }
            } else if result.mode == "improve" {
                Label("Seu texto já está correto e natural. Muito bem!", systemImage: "checkmark.seal.fill")
                    .font(DS.ui(15, DS.w550)).foregroundColor(DS.success500)
            }

            if let alts = result.alternatives, !alts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Outras formas de dizer")
                    ListCard {
                        ForEach(Array(alts.enumerated()), id: \.offset) { i, a in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(a.text).font(DS.ui(15)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !a.note.isEmpty { Text(a.note).font(DS.ui(12, DS.w550)).foregroundColor(DS.dawn700) }
                                }
                                Spacer()
                                IconButton(systemName: "speaker.wave.2", help: "Ouvir") { Task { await model.voice.speak(a.text) } }
                                IconButton(systemName: "mic", help: "Praticar leitura") { studio.practice(a.text) }
                            }
                            .padding(14)
                            if i < alts.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                        }
                    }
                }
            }

            if let vocab = result.vocabulary, !vocab.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Vocabulário")
                    FlowLayout(spacing: 8) {
                        ForEach(vocab, id: \.self) { v in
                            VocabChip(model: model, item: v, source: .text)
                        }
                    }
                }
            }

            if let tip = result.tip, !tip.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb").foregroundColor(DS.dawn700)
                    Text(tip).font(DS.ui(15)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.dawn100))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.dawn400, lineWidth: 1))
            }
        }
    }
}

/// "original → suggestion" with the reason (used by the text studio and the conversation).
struct ChangeCard: View {
    let original: String
    let suggestion: String
    let explanation: String
    let kind: String
    var play: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !original.isEmpty {
                        Text(original).font(DS.ui(15)).foregroundColor(DS.destructive500)
                            .strikethrough(true, color: DS.destructive500.opacity(0.6))
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundColor(DS.foregroundTertiary)
                    }
                    Text(suggestion).font(DS.ui(15, DS.w550)).foregroundColor(Color(hex: 0x2E8B57))
                }
                .fixedSize(horizontal: false, vertical: true)
                if !explanation.isEmpty {
                    Text(explanation).font(DS.ui(14)).foregroundColor(DS.neutral600)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(Feedback.label(for: kind)).font(DS.ui(11, DS.w550)).foregroundColor(DS.foregroundTertiary)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(DS.backgroundTertiary))
            if let play { IconButton(systemName: "speaker.wave.2", help: "Ouvir", action: play) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// A word you can hear and save to your vocabulary (+ / ✓).
struct VocabChip: View {
    @ObservedObject var model: AppModel
    let item: VocabSuggestion
    let source: VocabItem.Source
    @State private var hover = false
    var body: some View {
        let saved = model.hasWord(item.term)
        HStack(spacing: 6) {
            Button { Task { await model.voice.speak(item.term) } } label: {
                Image(systemName: "speaker.wave.2").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(DS.foregroundTertiary)
            Text(item.term).font(DS.ui(14, DS.w550))
            if !item.meaning.isEmpty { Text(item.meaning).font(DS.ui(13)).foregroundColor(DS.neutral600) }
            Button {
                if saved { model.removeWord(item.term) } else { model.addWord(item, source: source) }
            } label: {
                Image(systemName: saved ? "checkmark" : "plus").font(.system(size: 11, weight: .bold))
                    .foregroundColor(saved ? DS.success500 : DS.foreground)
            }
            .buttonStyle(.plain)
            .help(saved ? "Salva no vocabulário (clique para remover)" : "Salvar no vocabulário")
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Capsule().fill(hover ? DS.neutral200 : DS.card))
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
        .help(item.example)
        .onHover { hover = $0 }
    }
}

private struct Suggestions: View {
    @ObservedObject var studio: TextStudio
    private let examples = [
        "Eu gostaria de marcar uma reunião para amanhã de manhã, se você tiver disponibilidade.",
        "I have 30 years and I work with software since 2015.",
        "Pode me dar um desconto se eu pagar à vista?",
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Experimente")
            ForEach(examples, id: \.self) { e in
                Button { studio.input = e; studio.analyze() } label: {
                    HStack {
                        Text(e).font(DS.ui(15)).foregroundColor(DS.foreground)
                        Spacer()
                        Image(systemName: "arrow.up.left").font(.system(size: 11)).foregroundColor(DS.foregroundTertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.backgroundTertiary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct RecentTexts: View {
    @ObservedObject var model: AppModel
    @ObservedObject var studio: TextStudio
    var body: some View {
        let items = Array(model.texts.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Recentes")
            ListCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    RecentTextRow(entry: t, open: { studio.restore(t) }, delete: { model.texts.removeAll { $0.id == t.id } })
                    if i < items.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                }
            }
        }
    }
}

private struct RecentTextRow: View {
    let entry: TextEntry
    let open: () -> Void
    let delete: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Text(entry.input).font(DS.ui(14)).foregroundColor(DS.neutral600).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundColor(DS.foregroundTertiary).padding(.top, 3)
                    Text(entry.result.english ?? "").font(DS.ui(14)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(systemName: "trash", help: "Apagar", action: delete).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover ? DS.backgroundTertiary : Color.clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Read aloud (karaoke)

private struct ReadingPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reading: ReadingController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if reading.phase == .editing {
                ReadingEditor(reading: reading)
            } else {
                KaraokeCard(model: model, reading: reading)
                if let error = reading.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(DS.ui(14)).foregroundColor(DS.glow300)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if reading.phase == .assessing {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Avaliando sua leitura palavra por palavra…").font(DS.ui(15)).foregroundColor(DS.neutral600)
                    }
                }
                if let a = reading.attempt, reading.phase == .done {
                    ReadingResult(model: model, reading: reading, attempt: a)
                }
            }
            if !model.readings.isEmpty && reading.phase != .reading {
                ReadingHistory(model: model, reading: reading)
            }
        }
    }
}

private struct ReadingEditor: View {
    @ObservedObject var reading: ReadingController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topLeading) {
                if reading.draft.isEmpty {
                    Text("Cole aqui um texto em inglês para ler em voz alta")
                        .font(DS.display(24)).foregroundColor(DS.vast500)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reading.draft)
                    .font(DS.display(24))
                    .scrollContentBackground(.hidden)
                    .lineSpacing(6)
            }
            .frame(minHeight: 180)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.border, lineWidth: 1))
            HStack {
                Button("Usar este texto") { reading.load(reading.draft) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(reading.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Ou escolha um texto")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(ReadingController.samples, id: \.title) { s in
                        SampleCard(title: s.title, level: s.level, text: s.text) { reading.load(s.text) }
                    }
                }
            }
        }
    }
}

private struct SampleCard: View {
    let title: String
    let level: String
    let text: String
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(DS.ui(15, DS.w550))
                    Spacer()
                    Text(level).font(DS.ui(11, DS.w550)).foregroundColor(DS.dawn700)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(DS.dawn100))
                }
                Text(text).font(DS.ui(13)).foregroundColor(DS.neutral600).lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? DS.dawn100 : DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? DS.dawn400 : DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The karaoke itself: every word colored by how it was read, the next word underlined.
private struct KaraokeCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reading: ReadingController
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FlowLayout(spacing: 7, lineSpacing: 10) {
                ForEach(reading.words) { w in
                    word(w)
                }
            }
            .animation(.easeOut(duration: 0.15), value: reading.progress)

            if reading.phase == .reading || reading.phase == .done {
                ProgressBar(fraction: reading.progress.reachedFraction)
            }

            HStack(spacing: 10) {
                MicButton(recording: reading.phase == .reading, level: reading.level) {
                    reading.phase == .reading ? reading.stop() : reading.start()
                }
                .disabled(reading.phase == .assessing || (!reading.canRead && reading.phase != .reading))
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(DS.ui(15, DS.w550))
                    Text(statusDetail).font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                }
                Spacer()
                if reading.phase != .reading {
                    Button { reading.listen() } label: {
                        Label(reading.listeningIndex != nil ? "Parar" : "Ouvir modelo", systemImage: reading.listeningIndex != nil ? "stop.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if reading.phase == .done {
                        Button { reading.reset() } label: { Label("Ler de novo", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    IconButton(systemName: "pencil", help: "Trocar o texto") { reading.edit() }
                }
            }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 20).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(reading.phase == .reading ? DS.vast950 : DS.border,
                                                                 lineWidth: reading.phase == .reading ? 1.5 : 1))
    }

    private var statusTitle: String {
        switch reading.phase {
        case .reading: return "Lendo… \(reading.progress.position)/\(reading.words.count) palavras"
        case .assessing: return "Avaliando…"
        case .done: return reading.attempt.map { "Nota \($0.score)" } ?? "Leitura encerrada"
        default: return model.activeSessionID != nil ? "Encerre a conversa para ler" : "Clique no microfone e leia em voz alta"
        }
    }

    private var statusDetail: String {
        switch reading.phase {
        case .reading:
            let s = Int(reading.elapsed)
            return String(format: "%02d:%02d · precisão %d%% · clique para terminar", s / 60, s % 60, reading.progress.accuracy)
        case .done: return "Passe o mouse numa palavra colorida para ver o que foi ouvido; clique para ouvir."
        default: return "O texto acompanha você em tempo real, como num karaokê."
        }
    }

    @ViewBuilder private func word(_ w: ReadingTracker.Word) -> some View {
        let status = reading.progress.statuses.indices.contains(w.id) ? reading.progress.statuses[w.id] : .pending
        let listening = reading.listeningIndex == w.id
        Text(w.display)
            .font(DS.display(26))
            .foregroundColor(color(status, listening: listening))
            .strikethrough(status == .missed, color: DS.destructive500.opacity(0.5))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(background(status, listening: listening)))
            .overlay(alignment: .bottom) {
                if status == .current && reading.phase == .reading {
                    Capsule().fill(DS.vast950).frame(height: 2.5).offset(y: 3)
                }
            }
            .help(help(w.id, status))
            .onTapGesture { reading.speakWord(w.key) }
    }

    private func color(_ s: ReadingTracker.Status, listening: Bool) -> Color {
        if listening { return DS.foreground }
        switch s {
        case .pending: return reading.phase == .reading || reading.phase == .done ? DS.vast300 : DS.foreground
        case .current: return DS.foreground
        case .correct: return reading.phase == .done ? Color(hex: 0x2E8B57) : DS.foreground
        case .close, .unclear: return Color(hex: 0xB86E00)
        case .wrong, .missed: return DS.destructive500
        }
    }

    private func background(_ s: ReadingTracker.Status, listening: Bool) -> Color {
        if listening { return DS.dawn400 }
        switch s {
        case .current where reading.phase == .reading: return DS.dawn100
        case .close, .unclear: return Color(hex: 0xFFF4E0)
        case .wrong: return Color(hex: 0xFDECEC)
        default: return .clear
        }
    }

    private func help(_ i: Int, _ s: ReadingTracker.Status) -> String {
        let heard = reading.progress.heard[i].map { "Ouvido: “\($0)”" }
        switch s {
        case .wrong: return heard ?? "Palavra diferente"
        case .close: return (heard.map { $0 + " · " } ?? "") + "Quase lá"
        case .missed: return "Pulada"
        case .unclear: return "Pouco clara: articule melhor"
        default: return ""
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.neutral200)
                Capsule().fill(DS.vast950).frame(width: g.size.width * min(1, fraction))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

/// Round black mic button; a ring grows with your voice while recording.
struct MicButton: View {
    let recording: Bool
    var level: Float = 0
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                if recording {
                    Circle().fill(DS.destructive500.opacity(0.18))
                        .frame(width: 52 + CGFloat(min(1, level * 12)) * 18, height: 52 + CGFloat(min(1, level * 12)) * 18)
                        .animation(.linear(duration: 0.08), value: level)
                }
                Circle().fill(recording ? DS.destructive500 : DS.vast950).frame(width: 52, height: 52)
                Image(systemName: recording ? "stop.fill" : "mic.fill").font(.system(size: 19, weight: .semibold))
                    .foregroundColor(DS.sand50)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Terminar a leitura" : "Começar a ler")
    }
}

private struct ReadingResult: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reading: ReadingController
    let attempt: ReadingAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                ScoreRing(score: attempt.score, size: 84)
                VStack(alignment: .leading, spacing: 10) {
                    Text(attempt.summary).font(DS.ui(16)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        Metric(value: "\(attempt.accuracy)%", label: "precisão")
                        Metric(value: "\(attempt.completion)%", label: "do texto")
                        Metric(value: "\(attempt.wpm)", label: "palavras/min")
                        Metric(value: "\(attempt.pauses)", label: attempt.pauses == 1 ? "pausa longa" : "pausas longas")
                    }
                }
            }
            Legend()
            if !attempt.tips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Palavras para praticar")
                    ListCard {
                        ForEach(Array(attempt.tips.enumerated()), id: \.offset) { i, t in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(t.word).font(DS.ui(16, .semibold))
                                        if !t.ipa.isEmpty { Text(t.ipa).font(DS.ui(14)).foregroundColor(DS.dawn700) }
                                    }
                                    Text(t.tip).font(DS.ui(14)).foregroundColor(DS.neutral600)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                IconButton(systemName: "speaker.wave.2", help: "Ouvir") { reading.speakWord(t.word) }
                                VocabSaveButton(model: model, term: t.word, meaning: t.ipa, example: t.tip)
                            }
                            .padding(14)
                            if i < attempt.tips.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.backgroundTertiary))
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(DS.display(22)).tracking(-0.8)
            Text(label).font(DS.ui(13)).foregroundColor(DS.neutral600)
        }
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(Color(hex: 0x2E8B57), "certa")
            item(Color(hex: 0xB86E00), "quase / pouco clara")
            item(DS.destructive500, "errada / pulada")
        }
        .font(DS.ui(12)).foregroundColor(DS.neutral600)
    }
    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }
}

struct VocabSaveButton: View {
    @ObservedObject var model: AppModel
    let term: String
    var meaning = ""
    var example = ""
    var body: some View {
        let saved = model.hasWord(term)
        IconButton(systemName: saved ? "checkmark" : "plus", help: saved ? "Salva no vocabulário" : "Salvar no vocabulário") {
            if saved { model.removeWord(term) } else {
                model.addWord(VocabSuggestion(term: term, meaning: meaning, example: example), source: .reading)
            }
        }
    }
}

private struct ReadingHistory: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reading: ReadingController
    var body: some View {
        let items = Array(model.readings.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Suas leituras")
            ListCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                    Button { reading.show(r) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(DS.ui(15, DS.w550)).lineLimit(1)
                                Text("\(r.date.formatted(.relative(presentation: .named))) · \(r.accuracy)% de precisão · \(r.wpm) palavras/min")
                                    .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                            }
                            Spacer()
                            ScorePill(score: r.score)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < items.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                }
            }
        }
    }
}
