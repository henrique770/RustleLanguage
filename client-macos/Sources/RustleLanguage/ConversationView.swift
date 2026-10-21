import AppKit
import SwiftUI

/// Conversa, built like RustleApp's Notetaker:
///  - list: "Nova conversa" CTA, scenario cards, live card, conversations grouped by day;
///  - conversation page: title, meta chips, section pills, the conversation itself (each of your
///    lines annotated with corrections, like transcript notes), the report (Notetaker's summary +
///    action items become summary + improvements + vocabulary), and your notepad;
///  - floating footer pill: live waveform + phase, mic, type-to-reply, interrupt; after the
///    conversation, "Pergunte ao tutor" with a chat drawer.
struct ConversationPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let id = model.openSessionID, model.session(id) != nil {
            SessionPage(model: model, id: id) { model.openSessionID = nil }
                .id(id)
        } else {
            SessionList(model: model)
        }
    }
}

// MARK: - List

private struct SessionList: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var searching = false

    private var groups: [(String, [PracticeSession])] {
        let items = query.isEmpty ? model.sessions : model.sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.turns.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [PracticeSession]] = [:]
        for s in items {
            let key = cal.isDateInToday(s.started) ? "Hoje" : cal.isDateInYesterday(s.started) ? "Ontem"
                : s.started.formatted(.dateTime.weekday(.wide).day().month(.wide))
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Conversa",
                           description: "Converse em inglês por voz com um tutor de IA. Ele responde falando, e cada frase sua ganha anotações e melhorias.") {
                    Button { start(.free) } label: {
                        Label(model.activeSessionID == nil ? "Nova conversa" : "Em andamento…", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.activeSessionID != nil)
                }

                if let id = model.activeSessionID, let s = model.session(id) {
                    LiveSessionCard(model: model, live: model.live, session: s)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Escolha um cenário")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Scenario.all) { s in
                            ScenarioCard(scenario: s) { start(s) }
                                .disabled(model.activeSessionID != nil)
                        }
                    }
                }

                if model.sessions.isEmpty {
                    HowItWorks()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            if searching {
                                HubTextField(placeholder: "Buscar conversas", text: $query).frame(maxWidth: 320)
                            } else {
                                SectionLabel(text: "Suas conversas")
                            }
                            Spacer()
                            IconButton(systemName: searching ? "xmark" : "magnifyingglass", help: "Buscar") {
                                searching.toggle(); if !searching { query = "" }
                            }
                        }
                        .padding(.bottom, 8)
                        ForEach(groups, id: \.0) { title, items in
                            SectionLabel(text: title).padding(.top, 16).padding(.bottom, 8)
                            ListCard {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                                    SessionRow(model: model, session: s)
                                    if i < items.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
        }
    }

    private func start(_ s: Scenario) {
        if let id = model.startSession(s) { model.openSessionID = id }
    }
}

private struct HowItWorks: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                PageTitle(text: "Fale. Ouça. Melhore.", size: 26)
                Text("Uma conversa de verdade, em tempo real, com anotações como num caderno de aula.")
                    .font(DS.ui(15)).foregroundColor(DS.neutral600)
            }
            HStack(spacing: 12) {
                Feature(icon: "waveform", title: "Voz em tempo real", detail: "Fale quando quiser; o tutor percebe quando você termina e responde em voz alta.")
                Feature(icon: "text.badge.checkmark", title: "Anotações por frase", detail: "Cada frase sua ganha a versão corrigida e uma forma mais natural.")
                Feature(icon: "chart.line.uptrend.xyaxis", title: "Relatório no fim", detail: "Nota, pontos fortes, o que melhorar e vocabulário para salvar.")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32).padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.backgroundTertiary))
    }

    private struct Feature: View {
        let icon: String
        let title: String
        let detail: String
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(DS.dawn700)
                Text(title).font(DS.ui(15, DS.w550))
                Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var model: AppModel
    let session: PracticeSession
    @State private var hover = false
    @State private var confirmDelete = false

    var body: some View {
        Button { model.openSessionID = session.id } label: {
            HStack(spacing: 12) {
                Image(systemName: session.scenario.icon).font(.system(size: 14)).foregroundColor(DS.foregroundTertiary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.backgroundTertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(DS.ui(15, DS.w550)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.started.formatted(date: .omitted, time: .shortened))
                        Text("•"); Text(session.durationLabel)
                        Text("•"); Text("\(session.yourTurns.count) falas")
                        if !session.issues.isEmpty { Text("•"); Text("\(session.issues.count) correções") }
                    }
                    .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                }
                Spacer(minLength: 8)
                if model.activeSessionID == session.id {
                    HStack(spacing: 6) { RecordingDot(); Text("Ao vivo") }.font(DS.ui(12, DS.w550)).foregroundColor(DS.destructive500)
                } else if model.busySessionIDs.contains(session.id) && session.report == nil {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Gerando relatório") }
                        .font(DS.ui(12, DS.w550)).foregroundColor(DS.foregroundTertiary)
                } else if let score = session.report?.score.nonZero {
                    ScorePill(score: score)
                }
                IconButton(systemName: "trash", help: "Apagar") { confirmDelete = true }.opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hover ? DS.backgroundTertiary : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .confirmationDialog("Apagar esta conversa?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) { model.sessions.removeAll { $0.id == session.id } }
        } message: { Text("A conversa, as anotações e o relatório serão apagados.") }
    }
}

/// Dark live card (Notetaker's LiveMeetingCard).
private struct LiveSessionCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState
    let session: PracticeSession
    var body: some View {
        HStack(spacing: 16) {
            LiveWaveform(live: live)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).font(DS.ui(15, DS.w550)).foregroundColor(DS.sand50).lineLimit(1)
                Text("\(live.phase.label) · \(clock(live.elapsed))").font(DS.ui(13)).foregroundColor(DS.vast300)
            }
            Spacer()
            Button("Abrir") { model.openSessionID = session.id }.buttonStyle(DarkButtonStyle(filled: false))
            Button { model.stopSession() } label: { Label("Encerrar", systemImage: "stop.fill") }
                .buttonStyle(DarkButtonStyle(filled: true))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.vast950))
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

/// White bars from the mic level (.waveformPill).
struct LiveWaveform: View {
    @ObservedObject var live: LiveState
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(live.bars.suffix(compact ? 9 : 15).enumerated()), id: \.offset) { _, v in
                Capsule().fill(Color.white).frame(width: 2.5, height: max(3, v * (compact ? 16 : 22)))
            }
        }
        .frame(height: compact ? 18 : 24)
        .padding(.horizontal, compact ? 0 : 12)
        .frame(height: compact ? nil : 40)
        .background(compact ? nil : Capsule().fill(Color.black))
        .animation(.linear(duration: 0.08), value: live.bars)
    }
}

// MARK: - Session page

private enum SessionSection: String, CaseIterable {
    case conversation, report, corrections, notes
    var title: String {
        switch self {
        case .conversation: return "Conversa"
        case .report: return "Relatório"
        case .corrections: return "Correções"
        case .notes: return "Minhas notas"
        }
    }
    var icon: String {
        switch self {
        case .conversation: return "bubble.left.and.bubble.right"
        case .report: return "sparkles"
        case .corrections: return "checklist"
        case .notes: return "pencil.line"
        }
    }
}

private struct SessionPage: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let back: () -> Void
    @State private var chatOpen = false

    private var session: PracticeSession { model.session(id) ?? PracticeSession() }
    private var isLive: Bool { model.activeSessionID == id }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                TopBar(model: model, session: session, back: back)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header(proxy: proxy)
                            if !isLive { ReportSection(model: model, id: id).id(SessionSection.report) }
                            ConversationSection(model: model, live: model.live, id: id, isLive: isLive)
                                .id(SessionSection.conversation)
                            if !session.issues.isEmpty { CorrectionsSection(model: model, session: session).id(SessionSection.corrections) }
                            NotesSection(model: model, id: id).id(SessionSection.notes)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, 40).padding(.top, 12)
                        .padding(.bottom, chatOpen ? 460 : 150)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: session.turns.count) { _ in
                        if isLive { withAnimation { proxy.scrollTo("tail", anchor: .bottom) } }
                    }
                    .onChange(of: model.live.caption) { _ in
                        if isLive { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                }
            }
            SessionFooter(model: model, live: model.live, id: id, isLive: isLive, chatOpen: $chatOpen)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder private func header(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("", text: Binding(get: { session.title }, set: { v in model.updateSession(id) { $0.title = v } }),
                      prompt: Text(session.displayTitle).foregroundColor(DS.sand700), axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.display(34)).tracking(-0.04 * 34)
                .foregroundColor(DS.foreground)
            HStack(spacing: 8) {
                MetaChip(icon: "calendar", text: session.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                MetaChip(icon: session.scenario.icon, text: session.scenario.title)
                MetaChip(icon: "graduationcap", text: "Nível \(session.level)")
                if isLive {
                    LiveClock(live: model.live)
                } else {
                    MetaChip(icon: "clock", text: session.durationLabel)
                }
            }
            HStack(spacing: 6) {
                ForEach(SessionSection.allCases.filter { section in
                    switch section {
                    case .report: return !isLive
                    case .corrections: return !session.issues.isEmpty
                    default: return true
                    }
                }, id: \.self) { s in
                    PillButton(title: s.title, icon: s.icon) { withAnimation { proxy.scrollTo(s, anchor: .top) } }
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct LiveClock: View {
    @ObservedObject var live: LiveState
    var body: some View {
        HStack(spacing: 6) { RecordingDot(); Text(clock(live.elapsed)).monospacedDigit() }
            .font(DS.ui(13, DS.w550)).foregroundColor(DS.destructive500)
    }
}

private struct TopBar: View {
    @ObservedObject var model: AppModel
    let session: PracticeSession
    let back: () -> Void
    @State private var confirmDelete = false
    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Conversas") }
                    .font(DS.ui(14, DS.w550)).foregroundColor(DS.neutral600)
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            CopyButton(text: { session.transcriptText }, help: "Copiar a conversa")
            if model.activeSessionID != session.id {
                IconButton(systemName: "trash", help: "Apagar conversa") { confirmDelete = true }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .confirmationDialog("Apagar esta conversa?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) {
                model.openSessionID = nil
                model.sessions.removeAll { $0.id == session.id }
            }
        }
    }
}

private struct MetaChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(DS.ui(13))
        }
        .foregroundColor(DS.vast700)
        .padding(.horizontal, 8).frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct SectionHeading: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title).font(DS.display(24)).tracking(-0.9)
            Spacer()
            trailing
        }
    }
}

// MARK: Conversation

private struct ConversationSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState
    let id: UUID
    let isLive: Bool
    @AppStorage(Prefs.showCaptions) private var showCaptions = true

    var body: some View {
        let session = model.session(id) ?? PracticeSession()
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Conversa")
            if session.turns.isEmpty && !isLive {
                Text("Nada foi dito nesta conversa.").font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
            }
            ForEach(session.turns) { turn in
                if turn.role == .tutor {
                    TutorBubble(model: model, text: turn.text)
                } else {
                    YouBubble(model: model, turn: turn, pending: model.pendingFeedback.contains(turn.id))
                }
            }
            if isLive {
                VStack(alignment: .trailing, spacing: 8) {
                    if live.phase == .hearing && showCaptions {
                        Text(live.caption.isEmpty ? "…" : live.caption)
                            .font(DS.ui(16)).italic().foregroundColor(DS.neutral600)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.sand700, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    PhaseIndicator(live: live)
                        .frame(maxWidth: .infinity, alignment: live.phase == .speaking || live.phase == .thinking ? .leading : .trailing)
                    if let error = live.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(DS.ui(13)).foregroundColor(DS.destructive500)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .id("tail")
            }
        }
    }
}

private struct PhaseIndicator: View {
    @ObservedObject var live: LiveState
    var body: some View {
        HStack(spacing: 8) {
            switch live.phase {
            case .thinking: ProgressView().controlSize(.mini)
            case .speaking: Image(systemName: "speaker.wave.2.fill").foregroundColor(DS.dawn700)
            case .hearing: RecordingDot()
            case .listening: Image(systemName: live.micMuted ? "mic.slash" : "mic").foregroundColor(DS.foregroundTertiary)
            case .idle: EmptyView()
            }
            Text(live.micMuted && live.phase == .listening ? "Microfone pausado" : live.phase.label)
        }
        .font(DS.ui(13, DS.w550)).foregroundColor(DS.foregroundTertiary)
    }
}

private struct TutorBubble: View {
    @ObservedObject var model: AppModel
    let text: String
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BrandMark().frame(width: 26, height: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(DS.ui(16)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 2) {
                    IconButton(systemName: "speaker.wave.2", help: "Ouvir de novo") { Task { await model.voice.speak(text) } }
                    IconButton(systemName: "text.word.spacing", help: "Praticar leitura desta fala") {
                        model.studio.practice(text)
                        model.pageRequest = .text
                    }
                }
                .opacity(hover ? 1 : 0.0001)
            }
            Spacer(minLength: 60)
        }
        .onHover { hover = $0 }
    }
}

/// Your line, right-aligned, with the coach's annotation under it.
private struct YouBubble: View {
    @ObservedObject var model: AppModel
    let turn: PracticeSession.Turn
    let pending: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Spacer(minLength: 80)
                Text(turn.text).font(DS.ui(16)).lineSpacing(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(DS.sand600))
                    .textSelection(.enabled)
            }
            if pending {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Analisando sua frase…") }
                    .font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
            } else if let f = turn.feedback {
                if f.ok && f.natural.isEmpty {
                    Label("Natural e correto", systemImage: "checkmark.circle.fill")
                        .font(DS.ui(12, DS.w550)).foregroundColor(DS.success500)
                } else {
                    Annotation(model: model, original: turn.text, feedback: f)
                        .frame(maxWidth: 560)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The corrected sentence with the changed words highlighted, the reasons, and a more natural way.
private struct Annotation: View {
    @ObservedObject var model: AppModel
    let original: String
    let feedback: Feedback

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !feedback.ok, normalized(feedback.corrected) != normalized(original) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "pencil.line").font(.system(size: 12)).foregroundColor(Color(hex: 0x2E8B57)).padding(.top, 3)
                    WordDiff.highlighted(original: original, corrected: feedback.corrected)
                        .font(DS.ui(15)).lineSpacing(2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(systemName: "speaker.wave.2", help: "Ouvir a versão corrigida") {
                        Task { await model.voice.speak(feedback.corrected) }
                    }
                }
            }
            ForEach(feedback.issues, id: \.self) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(issue.original).foregroundColor(DS.destructive500).strikethrough(true, color: DS.destructive500.opacity(0.6))
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(DS.foregroundTertiary)
                        Text(issue.suggestion).foregroundColor(Color(hex: 0x2E8B57)).fontWeight(.semibold)
                        Text(Feedback.label(for: issue.kind)).font(DS.ui(11, DS.w550)).foregroundColor(DS.foregroundTertiary)
                    }
                    .font(DS.ui(14))
                    if !issue.explanation.isEmpty {
                        Text(issue.explanation).font(DS.ui(13)).foregroundColor(DS.neutral600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !feedback.natural.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(DS.dawn700).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mais natural").font(DS.ui(11, DS.w550)).foregroundColor(DS.dawn700)
                        Text(feedback.natural).font(DS.ui(15)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    IconButton(systemName: "speaker.wave.2", help: "Ouvir") { Task { await model.voice.speak(feedback.natural) } }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.border, lineWidth: 1))
    }

    private func normalized(_ s: String) -> String {
        ReadingTracker.keys(s).joined(separator: " ")
    }
}

/// Word-level diff: words of the corrected sentence that are new or changed are highlighted.
enum WordDiff {
    static func highlighted(original: String, corrected: String) -> Text {
        let a = ReadingTracker.keys(original)
        let tokens = corrected.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let b = tokens.map { ReadingTracker.key($0) }
        // Longest common subsequence over normalized words.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var keep = Set<Int>()
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { keep.insert(j); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        var out = Text("")
        for (k, token) in tokens.enumerated() {
            let piece = Text(token + (k < tokens.count - 1 ? " " : ""))
            out = out + (keep.contains(k) || b[k].isEmpty ? piece : piece.foregroundColor(Color(hex: 0x2E8B57)).bold())
        }
        return out
    }
}

// MARK: Report

private struct ReportSection: View {
    @ObservedObject var model: AppModel
    let id: UUID

    var body: some View {
        let session = model.session(id) ?? PracticeSession()
        let busy = model.busySessionIDs.contains(id)
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Relatório", trailing: session.yourTurns.isEmpty ? nil : AnyView(
                Button { model.generateReport(id) } label: {
                    Label(session.report == nil ? "Gerar" : "Gerar de novo", systemImage: "arrow.clockwise").font(DS.ui(13, DS.w550))
                }
                .buttonStyle(.plain).foregroundColor(DS.neutral600).disabled(busy)))
            if busy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Escrevendo seu relatório…").font(DS.ui(15, DS.w550))
                        Text("Nota, pontos fortes, o que melhorar e vocabulário.").font(DS.ui(13)).foregroundColor(DS.neutral600)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.backgroundTertiary))
            } else if let r = session.report {
                ReportView(model: model, report: r)
            } else if session.yourTurns.isEmpty {
                Text("Fale pelo menos uma vez para gerar o relatório.").font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
            }
        }
    }
}

private struct ReportView: View {
    @ObservedObject var model: AppModel
    let report: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                if report.score > 0 { ScoreRing(score: report.score, size: 76) }
                VStack(alignment: .leading, spacing: 8) {
                    if !report.levelEstimate.isEmpty {
                        Text("Nível demonstrado: \(report.levelEstimate)").font(DS.ui(12, DS.w550)).foregroundColor(DS.dawn700)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(DS.dawn100))
                    }
                    Text(report.summary).font(DS.ui(16)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.strengths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Pontos fortes")
                    ForEach(report.strengths, id: \.self) { s in
                        Label { Text(s).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(DS.success500)
                        }
                        .font(DS.ui(15))
                    }
                }
            }
            ForEach(report.improvements, id: \.self) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.heading).font(DS.ui(16, .semibold))
                    ForEach(section.bullets, id: \.self) { b in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundColor(DS.foregroundTertiary)
                            Text(b).font(DS.ui(15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !report.vocabulary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Vocabulário para levar")
                    ListCard {
                        ForEach(Array(report.vocabulary.enumerated()), id: \.offset) { i, v in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(v.term).font(DS.ui(15, .semibold))
                                        Text(v.meaning).font(DS.ui(14)).foregroundColor(DS.neutral600)
                                    }
                                    if !v.example.isEmpty {
                                        Text("“\(v.example)”").font(DS.display(16)).foregroundColor(DS.vast700)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                IconButton(systemName: "speaker.wave.2", help: "Ouvir") {
                                    Task { await model.voice.speak(v.example.isEmpty ? v.term : "\(v.term). \(v.example)") }
                                }
                                let saved = model.hasWord(v.term)
                                IconButton(systemName: saved ? "checkmark" : "plus", help: saved ? "Salva" : "Salvar no vocabulário") {
                                    if saved { model.removeWord(v.term) } else { model.addWord(v, source: .conversation) }
                                }
                            }
                            .padding(14)
                            if i < report.vocabulary.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.backgroundTertiary))
    }
}

// MARK: Corrections & notes

private struct CorrectionsSection: View {
    @ObservedObject var model: AppModel
    let session: PracticeSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Correções (\(session.issues.count))")
            ForEach(Array(session.issues.enumerated()), id: \.offset) { _, issue in
                ChangeCard(original: issue.original, suggestion: issue.suggestion, explanation: issue.explanation, kind: issue.kind) {
                    Task { await model.voice.speak(issue.suggestion) }
                }
            }
        }
    }
}

private struct NotesSection: View {
    @ObservedObject var model: AppModel
    let id: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Minhas notas")
            ZStack(alignment: .topLeading) {
                if (model.session(id)?.notes ?? "").isEmpty {
                    Text("Anote palavras novas, dúvidas para perguntar ao tutor…")
                        .font(DS.ui(15)).foregroundColor(DS.vast500).padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { model.session(id)?.notes ?? "" },
                                         set: { v in model.updateSession(id) { $0.notes = v } }))
                    .font(DS.ui(15)).scrollContentBackground(.hidden).lineSpacing(3)
                    .frame(minHeight: 90)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.backgroundTertiary))
        }
    }
}

// MARK: - Footer

/// Floating pill (.meetingFooter / .pillElevated) like the Notetaker's.
private struct SessionFooter: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState
    let id: UUID
    let isLive: Bool
    @Binding var chatOpen: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if chatOpen && !isLive {
                TutorChat(model: model, id: id, busy: model.busySessionIDs.contains(id), ask: send) {
                    withAnimation(.easeOut(duration: 0.2)) { chatOpen = false }
                }
                .frame(height: 360)
                Rectangle().fill(DS.border).frame(height: 1)
            }
            HStack(spacing: 8) {
                if isLive {
                    Button { model.stopSession() } label: {
                        HStack(spacing: 8) {
                            LiveWaveform(live: live, compact: true)
                            RoundedRectangle(cornerRadius: 2).fill(DS.vast950).frame(width: 8, height: 8)
                                .frame(width: 20, height: 20).background(Circle().fill(DS.sand50))
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(Capsule().fill(Color.black))
                        .overlay(Capsule().strokeBorder(DS.vast900, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Encerrar a conversa")
                    FooterToggle(icon: live.micMuted ? "mic.slash.fill" : "mic.fill", label: live.micMuted ? "Ligar o microfone" : "Pausar o microfone",
                                 active: live.micMuted) { model.toggleMic() }
                } else if model.activeSessionID == nil {
                    Button {
                        if let newID = model.startSession(model.session(id)?.scenario ?? .free) { model.openSessionID = newID }
                    } label: {
                        HStack(spacing: 6) { Image(systemName: "mic.fill").font(.system(size: 11)); Text("Nova conversa").font(DS.ui(13, DS.w550)) }
                            .foregroundColor(DS.sand50)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(Capsule().fill(Color.black))
                    }
                    .buttonStyle(.plain)
                }
                TextField("", text: $draft, prompt: Text(isLive ? "Ou digite sua resposta em inglês…" : "Pergunte ao tutor sobre esta conversa")
                    .foregroundColor(DS.vast500))
                    .textFieldStyle(.plain)
                    .font(DS.ui(15))
                    .focused($focused)
                    .onSubmit { send(draft) }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 6)
                if !draft.isEmpty {
                    Button { send(draft) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(DS.sand50)
                            .frame(width: 28, height: 28).background(Circle().fill(DS.vast950))
                    }
                    .buttonStyle(.plain)
                }
                if isLive {
                    if live.phase == .speaking || live.phase == .thinking {
                        FooterToggle(icon: "hand.raised.fill", label: "Interromper o tutor (sua vez)", active: false) { model.interruptTutor() }
                    }
                } else {
                    FooterToggle(icon: "bubble.left.and.text.bubble.right", label: "Chat com o tutor", active: chatOpen) {
                        withAnimation(.easeOut(duration: 0.2)) { chatOpen.toggle() }
                    }
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: chatOpen && !isLive ? 20 : 32).fill(DS.background))
        .clipShape(RoundedRectangle(cornerRadius: chatOpen && !isLive ? 20 : 32))
        .overlay(RoundedRectangle(cornerRadius: chatOpen && !isLive ? 20 : 32).strokeBorder(DS.neutral200, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)
        .animation(.easeOut(duration: 0.2), value: chatOpen)
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        if isLive {
            model.sendTyped(t)
        } else {
            model.askTutor(id, t)
            withAnimation(.easeOut(duration: 0.2)) { chatOpen = true }
        }
    }
}

private struct FooterToggle: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? DS.foreground : DS.neutral600)
                .frame(width: 36, height: 36)
                .background(Circle().fill(active || hover ? DS.neutral200 : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
    }
}

private struct TutorChat: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let busy: Bool
    let ask: (String) -> Void
    let minimize: () -> Void
    private static let prompts = ["Qual foi meu erro mais comum?", "Como eu poderia dizer isso de forma mais natural?",
                                  "Me dê 5 frases para praticar", "Explique a gramática que eu errei"]

    var body: some View {
        let chat = model.session(id)?.chat ?? []
        VStack(spacing: 0) {
            HStack {
                Text("Chat com o tutor").font(DS.ui(14, DS.w550))
                Spacer()
                IconButton(systemName: "chevron.down", help: "Minimizar", action: minimize)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Pergunte qualquer coisa sobre esta conversa").font(DS.ui(15, DS.w550))
                                FlowLayout(spacing: 8) {
                                    ForEach(Self.prompts, id: \.self) { p in
                                        Button { ask(p) } label: {
                                            Text(p).font(DS.ui(13, DS.w550)).foregroundColor(DS.foreground)
                                                .padding(.horizontal, 12).frame(height: 30)
                                                .background(Capsule().fill(DS.backgroundTertiary))
                                                .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.top, 12)
                        }
                        ForEach(chat) { msg in
                            if msg.fromUser {
                                HStack {
                                    Spacer(minLength: 60)
                                    Text(msg.text).font(DS.ui(15))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(DS.sand600))
                                        .textSelection(.enabled)
                                }
                            } else {
                                Text(msg.text).font(DS.ui(15)).lineSpacing(3).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if busy {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Pensando…") }
                                .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                }
                .onChange(of: chat.count) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: busy) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
    }
}
