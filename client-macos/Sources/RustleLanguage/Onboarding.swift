import AppKit
import AVFoundation
import Speech
import SwiftUI

/// First-run questionnaire, same structure and look as RustleApp's (centered EB Garamond titles,
/// option cards, a progress tracker of uppercase sections): name → English level → goals →
/// AI provider → permissions → done.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case name, level, goals, ai, permissions, done

        var section: Int {
            switch self {
            case .name: return 0
            case .level, .goals: return 1
            case .ai, .permissions: return 2
            case .done: return 3
            }
        }
    }
    static let sections = ["Começar", "Seu inglês", "Configurar", "Pronto"]

    static let levels: [(id: String, title: String, detail: String)] = [
        ("A2", "Básico", "Entendo frases simples e falo sobre o dia a dia com esforço."),
        ("B1", "Intermediário", "Me viro em conversas comuns, mas travo e erro bastante."),
        ("B2", "Intermediário avançado", "Converso com fluência razoável; quero soar mais natural."),
        ("C1", "Avançado", "Falo bem; quero polir pronúncia, nuances e expressões."),
    ]
    static let goals: [(id: String, label: String)] = [
        ("work", "Trabalho e reuniões"), ("interviews", "Entrevistas de emprego"), ("travel", "Viagens"),
        ("conversation", "Conversar com fluência"), ("pronunciation", "Pronúncia"), ("exams", "Provas (TOEFL, IELTS)"),
        ("study", "Estudar fora"), ("fun", "Séries, música e lazer"),
    ]

    @State private var step: Step = .name
    @State private var first = ""
    @State private var last = ""
    @State private var apiKey = ""
    @AppStorage(Prefs.goals) private var goals = ""
    @FocusState private var nameFocused: Bool

    init(model: AppModel, initialStep: Step = .name, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
        _first = State(initialValue: model.firstName.isEmpty ? AppModel.systemFirstName : model.firstName)
        _last = State(initialValue: model.firstName.isEmpty ? AppModel.systemLastName : model.lastName)
    }

    private var name: String { first.trimmingCharacters(in: .whitespaces) }
    private var provider: LLMProvider { LLMProvider.find(model.serverSettings.llm_provider) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)   // traffic lights
            ProgressTracker(current: step)
            ScrollView {
                VStack(spacing: 24) {
                    content
                }
                .frame(maxWidth: step == .goals || step == .ai ? 680 : 560)
                .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            footer
        }
        .background(DS.background)
        .foregroundColor(DS.foreground)
        .font(DS.ui(15))
        .animation(.easeOut(duration: 0.2), value: step)
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .name:
            BrandMark().frame(width: 72, height: 72).padding(.bottom, 4)
            QuestionTitle(text: "Bem-vindo ao Rustle Language!", subtitle: "Converse, leia e escreva em inglês com um tutor que anota onde você pode melhorar. Primeiro: como você quer ser chamado?")
            VStack(alignment: .leading, spacing: 16) {
                LabeledField(label: "Nome", placeholder: "Seu nome", text: $first)
                    .focused($nameFocused)
                    .onSubmit { if canContinue { next() } }
                LabeledField(label: "Sobrenome (opcional)", placeholder: "Seu sobrenome", text: $last)
                    .onSubmit { if canContinue { next() } }
            }
            .frame(maxWidth: 400)
            .onAppear { nameFocused = true }

        case .level:
            QuestionTitle(text: "Como está seu inglês, \(name)?", subtitle: "O tutor ajusta o vocabulário, a velocidade e as correções. Dá para mudar depois em Configurações.")
            VStack(spacing: 12) {
                ForEach(Self.levels, id: \.id) { l in
                    OptionCard(title: "\(l.title) · \(l.id)", detail: l.detail, selected: model.serverSettings.level == l.id) {
                        model.serverSettings.level = l.id
                    }
                }
            }

        case .goals:
            QuestionTitle(text: "Para que você quer o inglês?", subtitle: "Marque todas que se aplicam. Isso ajuda a sugerir os cenários de conversa.")
            ChoiceGrid(options: Self.goals, selected: goalSet, columns: 2) { id in
                var set = goalSet
                if set.contains(id) { set.remove(id) } else { set.insert(id) }
                goals = set.sorted().joined(separator: ",")
            }

        case .ai:
            QuestionTitle(text: "Escolha a IA do seu tutor", subtitle: "Qualquer modelo serve: o tutor conversa, corrige e traduz com ele. A transcrição da sua voz roda no seu Mac.")
            VStack(spacing: 10) {
                ForEach(LLMProvider.all.filter { $0.id != "custom" }) { p in
                    OptionCard(title: p.name, detail: p.note, selected: provider.id == p.id) { select(p) }
                }
            }
            if provider.needsKey {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Chave da API \(provider.name)").font(DS.ui(13, DS.w550)).foregroundColor(DS.neutral600)
                        Spacer()
                        if let url = provider.keyURL.flatMap(URL.init(string:)) {
                            Button("Obter chave") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                        }
                    }
                    SecureField("", text: $apiKey, prompt: Text(provider.keyPlaceholder).foregroundColor(DS.vast500))
                        .textFieldStyle(.plain).font(DS.ui(17))
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border, lineWidth: 1))
                    Text("Fica no Chaveiro do macOS. Você pode pular e configurar depois.")
                        .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                }
            }

        case .permissions:
            QuestionTitle(text: model.permissions.allGranted ? "Tudo certo com as permissões" : "Dê ao Rustle as permissões do Mac",
                          subtitle: "Sua voz é transcrita no seu computador. O texto das conversas vai só para a IA que você escolheu.")
            VStack(spacing: 12) {
                PermissionCard(title: "Microfone", detail: "Para ouvir você nas conversas e leituras.",
                               granted: model.permissions.microphone) { model.requestPermissions() }
                PermissionCard(title: "Reconhecimento de fala", detail: "Legendas ao vivo e o karaokê que acompanha sua leitura.",
                               granted: model.permissions.speech) { model.requestPermissions() }
            }

        case .done:
            QuestionTitle(text: "Tudo pronto, \(name)!", subtitle: "Comece com uma conversa livre ou leia um texto em voz alta.")
            HStack(spacing: 12) {
                ForEach(["bubble.left.and.bubble.right", "character.bubble", "text.word.spacing"], id: \.self) { icon in
                    Image(systemName: icon).font(.system(size: 20)).foregroundColor(DS.dawn700)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 14).fill(DS.dawn100))
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .name {
                Button("Voltar") { back() }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            if step == .goals || (step == .ai && provider.needsKey && apiKey.isEmpty) {
                Button("Pular") { step = Step(rawValue: step.rawValue + 1) ?? .done }
                    .buttonStyle(.plain).foregroundColor(DS.foregroundTertiary).padding(.horizontal, 8)
            }
            if step == .permissions && !model.permissions.allGranted {
                Button("Fazer depois") { next() }.buttonStyle(.plain).foregroundColor(DS.foregroundTertiary).padding(.horizontal, 8)
            }
            Button(step == .done ? "Começar a praticar" : "Continuar") { next() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.4)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
    }

    private var canContinue: Bool {
        switch step {
        case .name: return !name.isEmpty
        case .ai: return !provider.needsKey || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .permissions: return model.permissions.microphone
        default: return true
        }
    }

    private func next() {
        switch step {
        case .name:
            model.firstName = name
            model.lastName = last.trimmingCharacters(in: .whitespaces)
        case .ai where provider.needsKey && !apiKey.isEmpty:
            Keychain.saveAPIKey(apiKey, account: Keychain.account(for: provider.id))
            model.restartServer()
        case .done:
            onFinish()
            return
        default: break
        }
        step = Step(rawValue: step.rawValue + 1) ?? .done
    }

    private func back() {
        step = Step(rawValue: step.rawValue - 1) ?? .name
    }

    private func select(_ p: LLMProvider) {
        model.serverSettings.llm_provider = p.id
        model.serverSettings.llm_base_url = p.baseURL
        model.serverSettings.llm_model = p.model
        apiKey = Keychain.readAPIKey(Keychain.account(for: p.id)) ?? ""
    }

    private var goalSet: Set<String> { Set(goals.split(separator: ",").map(String.init)) }
}

// MARK: - Pieces

/// Section names over 48x4 bars; the current section is in foreground color.
private struct ProgressTracker: View {
    let current: OnboardingView.Step
    var body: some View {
        HStack(spacing: 32) {
            ForEach(Array(OnboardingView.sections.enumerated()), id: \.offset) { i, title in
                VStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(DS.ui(12, .semibold)).tracking(12 * 0.075)
                        .foregroundColor(i <= current.section ? DS.foreground : DS.vast300)
                    HStack(spacing: 4) {
                        let steps = OnboardingView.Step.allCases.filter { $0.section == i }
                        ForEach(steps, id: \.self) { s in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(s.rawValue <= current.rawValue ? DS.vast900 : DS.neutral200)
                                .frame(width: 48 / CGFloat(max(1, steps.count)) * (steps.count == 1 ? 1 : 1.4), height: 4)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// .questionTitle: EB Garamond 36/40, letter-spacing -0.04em, centered.
private struct QuestionTitle: View {
    let text: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(DS.display(36)).tracking(-0.04 * 36)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(DS.ui(15)).foregroundColor(DS.neutral600)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }
}

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DS.ui(13, DS.w550)).foregroundColor(DS.neutral600)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(DS.vast500))
                .textFieldStyle(.plain)
                .font(DS.ui(17))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

/// .optionCard: padding 20 24, radius 12, 1px border; hover neutral-400; selected 2px dawn-700.
private struct OptionCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(DS.ui(16, DS.w550))
                    Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(selected ? DS.dawn700 : DS.sand700)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? DS.dawn100 : DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? DS.dawn700 : (hover ? DS.vast300 : DS.border), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ChoiceGrid: View {
    let options: [(id: String, label: String)]
    let selected: Set<String>
    let columns: Int
    let toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(options, id: \.id) { option in
                ChoiceChip(label: option.label, selected: selected.contains(option.id)) { toggle(option.id) }
            }
        }
    }
}

private struct ChoiceChip: View {
    let label: String
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            Text(label)
                .font(DS.ui(14, selected ? DS.w550 : .regular))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(selected ? DS.dawn100 : DS.card))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? DS.dawn700 : (hover ? DS.vast300 : DS.border), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.ui(16, DS.w550))
                Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
            }
            Spacer()
            if granted {
                Label("Permitido", systemImage: "checkmark.circle.fill")
                    .font(DS.ui(14, .medium)).foregroundColor(DS.success500)
            } else {
                Button("Permitir", action: request).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(granted ? DS.success500.opacity(0.5) : DS.border, lineWidth: 1))
    }
}
