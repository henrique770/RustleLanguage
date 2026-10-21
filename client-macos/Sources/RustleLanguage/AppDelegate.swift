import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Wires the app together: the hub window, the menu-bar item, the local server, permissions,
/// and the live conversation (ConversationController) behind the actions the window triggers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem!
    private lazy var server = ServerManager(baseURL: Config.serverURL, settingsPath: AppModel.settingsURL.path)
    private lazy var conversation = ConversationController(model: model)
    private var permissionTimer: Timer?
    private var healthTimer: Timer?
    private var conversationMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("RustleLanguage started (server=\(Config.serverURL), bundle=\(Bundle.main.bundlePath))")
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        buildStatusItem()
        wireActions()

        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        showMainWindow()
        Task { await startServer() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHealthCheck() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let id = model.activeSessionID {
            model.updateSession(id) { $0.status = .ready; $0.ended = Date() }
        }
        server.stop()
    }

    // MARK: - Window & menus

    @objc private func showMainWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "Rustle Language"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0xF5 / 255.0, green: 0xF4 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
            w.contentViewController = NSHostingController(rootView: MainView(model: model))
            w.setContentSize(NSSize(width: 1180, height: 780))
            w.minSize = NSSize(width: 960, height: 640)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("RustleLanguageHub")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A regular app needs an Edit menu, or Cmd+C / Cmd+V do nothing in its own text fields.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sobre o Rustle Language", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar Rustle Language", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair do Rustle Language", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar Tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Janela")
        windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Rustle Language")
        statusItem.button?.toolTip = "Rustle Language"
        let menu = NSMenu()
        menu.addItem(item("Abrir Rustle Language", #selector(showMainWindow)))
        let convo = item("Nova conversa", #selector(toggleConversationFromMenu))
        menu.addItem(convo)
        conversationMenuItem = convo
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair do Rustle Language", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleConversationFromMenu() {
        if conversation.isActive {
            stopSession()
        } else if let id = startSession(.free) {
            model.openSessionID = id
            model.pageRequest = .conversation
            showMainWindow()
        }
    }

    private func wireActions() {
        model.relaunch = { [weak self] in self?.relaunch() }
        model.restartServer = { [weak self] in
            guard let self else { return }
            Task { await self.restartServer() }
        }
        model.startSession = { [weak self] scenario in self?.startSession(scenario) }
        model.stopSession = { [weak self] in self?.stopSession() }
        model.sendTyped = { [weak self] text in self?.conversation.sendTyped(text) }
        model.toggleMic = { [weak self] in self?.conversation.toggleMic() }
        model.interruptTutor = { [weak self] in self?.conversation.interrupt() }
        model.generateReport = { [weak self] id in self?.generateReport(id) }
        model.askTutor = { [weak self] id, question in self?.ask(question, about: id) }
        model.requestPermissions = { [weak self] in self?.requestPermissions() }
    }

    // MARK: - Conversation

    private func startSession(_ scenario: Scenario) -> UUID? {
        if model.studio.reading.phase == .reading { model.studio.reading.stop() }
        if !model.permissions.microphone {
            requestPermissions()
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return nil }
        }
        let id = conversation.start(scenario: scenario)
        conversationMenuItem?.title = id == nil ? "Nova conversa" : "Encerrar conversa"
        statusItem.button?.image = NSImage(systemSymbolName: id == nil ? "character.bubble" : "waveform.circle.fill",
                                           accessibilityDescription: "Rustle Language")
        return id
    }

    private func stopSession() {
        conversation.stop()
        conversationMenuItem?.title = "Nova conversa"
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Rustle Language")
    }

    private func generateReport(_ id: UUID) {
        guard let session = model.session(id), !session.yourTurns.isEmpty, !model.busySessionIDs.contains(id) else { return }
        model.busySessionIDs.insert(id)
        let client = model.client
        Task {
            // Annotations still in flight feed the report; give them a moment.
            for _ in 0..<20 where session.yourTurns.contains(where: { model.pendingFeedback.contains($0.id) }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let current = model.session(id) ?? session
            do {
                let report = try await client.report(for: current)
                model.updateSession(id) { $0.report = report }
            } catch {
                Log.info("report failed: \(error.localizedDescription)")
            }
            model.busySessionIDs.remove(id)
        }
    }

    private func ask(_ question: String, about id: UUID) {
        guard let session = model.session(id) else { return }
        model.updateSession(id) { $0.chat.append(.init(fromUser: true, text: question)) }
        model.busySessionIDs.insert(id)
        let client = model.client
        Task {
            let answer: String
            do { answer = try await client.ask(question, about: session) } catch { answer = "Não consegui responder: \(error.localizedDescription)" }
            model.updateSession(id) { $0.chat.append(.init(fromUser: false, text: answer)) }
            model.busySessionIDs.remove(id)
        }
    }

    // MARK: - Server

    private func startServer() async {
        if await server.isOutdated() {
            Log.info("server is outdated; restarting it")
            await restartServer()
            return
        }
        if await server.isHealthy() {
            model.serverState = .online
            await refreshHealth()
            return
        }
        model.serverState = .starting
        if let error = await server.ensureRunning() {
            Log.info("server not ready: \(error)")
            model.serverState = .offline(error)
        } else {
            Log.info("server ready")
            model.serverState = .online
            await refreshHealth()
        }
    }

    private func restartServer() async {
        model.serverState = .starting
        Log.info("restarting server")
        if let error = await server.restart() {
            model.serverState = .offline(error)
        } else {
            model.serverState = .online
            await refreshHealth()
        }
    }

    private func scheduleHealthCheck() {
        Task { await refreshHealth() }
    }

    private func refreshHealth() async {
        guard model.serverState != .starting else { return }
        if let h = await model.client.health() {
            model.llmReady = h.llm
            if model.serverState != .online && h.ok { model.serverState = .online }
        } else if model.serverState == .online {
            model.serverState = .offline("O servidor local parou. Use Reiniciar em Configurações.")
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        let p = AppModel.Permissions(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                     speech: SFSpeechRecognizer.authorizationStatus() == .authorized)
        if p != model.permissions { model.permissions = p }
    }

    /// Asks for whatever is still undecided; for something already refused, opens System Settings.
    private func requestPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in Log.info("microphone access: \(granted)") }
        case .denied, .restricted:
            openPane("Privacy_Microphone")
            return
        default: break
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in Log.info("speech recognition: \(status.rawValue)") }
        case .denied, .restricted:
            openPane("Privacy_SpeechRecognition")
        default: break
        }
    }

    private func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
