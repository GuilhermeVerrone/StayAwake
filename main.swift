import AppKit
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Preferências
//
// `manualOn` é de propósito NÃO persistido: o app abre no login, mas o motor
// começa parado e só roda quando o usuário ativa (ou quando a agenda manda).

enum Prefs {
    static let idleThreshold = "idleThresholdSeconds"
    static let keepScreenAwake = "keepScreenAwake"
    static let scheduleEnabled = "scheduleEnabled"
    static let scheduleStart = "scheduleStartHour"
    static let scheduleEnd = "scheduleEndHour"
    static let weekdaysOnly = "weekdaysOnly"
}

let thresholdOptions: [(label: String, seconds: TimeInterval)] = [
    ("30 segundos", 30),
    ("1 minuto", 60),
    ("2 minutos", 120),
    ("4 minutos", 240),
]

/// Frequência com que o app reavalia agenda + idle. Não é a frequência de pulso.
let heartbeatSeconds: TimeInterval = 10

// MARK: - Leitura do idle do sistema

/// Segundos desde o último input real de teclado/mouse, direto do IOHIDSystem.
/// É o mesmo valor que o Teams usa para marcar "Ausente".
func systemIdleSeconds() -> TimeInterval {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOHIDSystem"),
                                       &iterator) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }

    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return 0 }
    defer { IOObjectRelease(entry) }

    guard let raw = IORegistryEntryCreateCFProperty(entry,
                                                    "HIDIdleTime" as CFString,
                                                    kCFAllocatorDefault,
                                                    0)?.takeRetainedValue(),
          let nanos = raw as? NSNumber else { return 0 }

    return nanos.doubleValue / 1_000_000_000
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var heartbeat: Timer?
    private var assertionID: IOPMAssertionID = 0
    private var nudgeCount = 0

    /// Ativação manual: vive só nesta execução, nunca é salva.
    private var manualOn = false

    private let defaults = UserDefaults.standard

    private var idleThreshold: TimeInterval {
        get {
            let stored = defaults.double(forKey: Prefs.idleThreshold)
            return stored > 0 ? stored : 120
        }
        set { defaults.set(newValue, forKey: Prefs.idleThreshold) }
    }

    private var keepScreenAwake: Bool {
        get {
            if defaults.object(forKey: Prefs.keepScreenAwake) == nil { return true }
            return defaults.bool(forKey: Prefs.keepScreenAwake)
        }
        set { defaults.set(newValue, forKey: Prefs.keepScreenAwake) }
    }

    private var scheduleEnabled: Bool {
        get { defaults.bool(forKey: Prefs.scheduleEnabled) }
        set { defaults.set(newValue, forKey: Prefs.scheduleEnabled) }
    }

    private var scheduleStart: Int {
        get {
            if defaults.object(forKey: Prefs.scheduleStart) == nil { return 8 }
            return defaults.integer(forKey: Prefs.scheduleStart)
        }
        set { defaults.set(newValue, forKey: Prefs.scheduleStart) }
    }

    private var scheduleEnd: Int {
        get {
            if defaults.object(forKey: Prefs.scheduleEnd) == nil { return 18 }
            return defaults.integer(forKey: Prefs.scheduleEnd)
        }
        set { defaults.set(newValue, forKey: Prefs.scheduleEnd) }
    }

    private var weekdaysOnly: Bool {
        get { defaults.bool(forKey: Prefs.weekdaysOnly) }
        set { defaults.set(newValue, forKey: Prefs.weekdaysOnly) }
    }

    // MARK: Decisão de rodar

    /// A agenda cobre o instante atual? Trata faixa que cruza a meia-noite
    /// (ex.: 22h–6h) e, opcionalmente, pula sábado e domingo.
    private var scheduleActiveNow: Bool {
        guard scheduleEnabled, scheduleStart != scheduleEnd else { return false }
        let parts = Calendar.current.dateComponents([.hour, .weekday], from: Date())
        guard let hour = parts.hour, let weekday = parts.weekday else { return false }
        if weekdaysOnly && (weekday == 1 || weekday == 7) { return false }
        return scheduleStart < scheduleEnd
            ? (hour >= scheduleStart && hour < scheduleEnd)
            : (hour >= scheduleStart || hour < scheduleEnd)
    }

    private var shouldRun: Bool { manualOn || scheduleActiveNow }

    // MARK: Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        let timer = Timer(timeInterval: heartbeatSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseAssertion()
    }

    /// Coração do app: decide se deve rodar e, se sim, só pulsa caso o usuário
    /// esteja de fato parado há mais que o limiar.
    private func tick() {
        if shouldRun {
            if keepScreenAwake { createAssertion() } else { releaseAssertion() }
            if systemIdleSeconds() >= idleThreshold { nudge() }
        } else {
            releaseAssertion()
        }
        refreshUI()
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 100
        menu.addItem(status)

        let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        detail.tag = 104
        menu.addItem(detail)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Ativar agora",
                                action: #selector(toggleManual),
                                keyEquivalent: "a")
        toggle.target = self
        toggle.tag = 101
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Limiar de ociosidade
        let thresholdItem = NSMenuItem(title: "Pulsar após", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for option in thresholdOptions {
            let item = NSMenuItem(title: "\(option.label) sem uso",
                                  action: #selector(selectThreshold(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds
            thresholdMenu.addItem(item)
        }
        thresholdItem.submenu = thresholdMenu
        thresholdItem.tag = 102
        menu.addItem(thresholdItem)

        let screenItem = NSMenuItem(title: "Impedir tela de dormir",
                                    action: #selector(toggleKeepScreenAwake),
                                    keyEquivalent: "")
        screenItem.target = self
        screenItem.tag = 103
        menu.addItem(screenItem)

        menu.addItem(.separator())

        // Agendamento
        let scheduleItem = NSMenuItem(title: "Agendamento", action: nil, keyEquivalent: "")
        let scheduleMenu = NSMenu()

        let scheduleToggle = NSMenuItem(title: "Ativar agendamento",
                                        action: #selector(toggleSchedule),
                                        keyEquivalent: "")
        scheduleToggle.target = self
        scheduleToggle.tag = 200
        scheduleMenu.addItem(scheduleToggle)

        scheduleMenu.addItem(.separator())

        let startItem = NSMenuItem(title: "Começa às", action: nil, keyEquivalent: "")
        startItem.submenu = hourMenu(selector: #selector(selectStartHour(_:)))
        startItem.tag = 201
        scheduleMenu.addItem(startItem)

        let endItem = NSMenuItem(title: "Termina às", action: nil, keyEquivalent: "")
        endItem.submenu = hourMenu(selector: #selector(selectEndHour(_:)))
        endItem.tag = 202
        scheduleMenu.addItem(endItem)

        let weekdaysItem = NSMenuItem(title: "Somente dias de semana",
                                      action: #selector(toggleWeekdaysOnly),
                                      keyEquivalent: "")
        weekdaysItem.target = self
        weekdaysItem.tag = 203
        scheduleMenu.addItem(weekdaysItem)

        scheduleItem.submenu = scheduleMenu
        menu.addItem(scheduleItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Abrir no login",
                                   action: #selector(toggleLoginItem),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.tag = 300
        menu.addItem(loginItem)

        let permissions = NSMenuItem(title: "Verificar permissão de Acessibilidade…",
                                     action: #selector(checkPermissions),
                                     keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func hourMenu(selector: Selector) -> NSMenu {
        let menu = NSMenu()
        for hour in 0..<24 {
            let item = NSMenuItem(title: String(format: "%02dh", hour),
                                  action: selector,
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = hour
            menu.addItem(item)
        }
        return menu
    }

    private func refreshUI() {
        let running = shouldRun
        let symbol = running ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Anti-AFK")
        image?.isTemplate = true
        statusItem.button?.image = image

        guard let menu = statusItem.menu else { return }

        let window = String(format: "%02dh–%02dh", scheduleStart, scheduleEnd)
        let thresholdLabel = thresholdOptions.first { $0.seconds == idleThreshold }?.label
            ?? "\(Int(idleThreshold))s"

        if manualOn {
            menu.item(withTag: 100)?.title = "Ativo (manual)"
        } else if scheduleActiveNow {
            menu.item(withTag: 100)?.title = "Ativo (agenda \(window))"
        } else if scheduleEnabled {
            menu.item(withTag: 100)?.title = "Aguardando agenda (\(window))"
        } else {
            menu.item(withTag: 100)?.title = "Desligado"
        }

        let idle = Int(systemIdleSeconds())
        menu.item(withTag: 104)?.title = running
            ? "Pulsa após \(thresholdLabel) · ocioso há \(idle)s · \(nudgeCount) pulsos"
            : "Pulsa após \(thresholdLabel) sem uso"

        if let toggle = menu.item(withTag: 101) {
            toggle.title = manualOn ? "Desativar agora" : "Ativar agora"
            toggle.state = manualOn ? .on : .off
        }

        if let thresholdMenu = menu.item(withTag: 102)?.submenu {
            for item in thresholdMenu.items {
                item.state = (item.representedObject as? TimeInterval) == idleThreshold ? .on : .off
            }
        }

        menu.item(withTag: 103)?.state = keepScreenAwake ? .on : .off

        if let scheduleMenu = menu.item(withTag: 200)?.menu {
            scheduleMenu.item(withTag: 200)?.state = scheduleEnabled ? .on : .off
            scheduleMenu.item(withTag: 203)?.state = weekdaysOnly ? .on : .off
            scheduleMenu.item(withTag: 201)?.title = String(format: "Começa às %02dh", scheduleStart)
            scheduleMenu.item(withTag: 202)?.title = String(format: "Termina às %02dh", scheduleEnd)
            for item in scheduleMenu.item(withTag: 201)?.submenu?.items ?? [] {
                item.state = (item.representedObject as? Int) == scheduleStart ? .on : .off
            }
            for item in scheduleMenu.item(withTag: 202)?.submenu?.items ?? [] {
                item.state = (item.representedObject as? Int) == scheduleEnd ? .on : .off
            }
        }

        if #available(macOS 13.0, *) {
            menu.item(withTag: 300)?.state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            menu.item(withTag: 300)?.isHidden = true
        }

        statusItem.button?.toolTip = running
            ? "Anti-AFK ativo · \(nudgeCount) pulsos"
            : "Anti-AFK desligado"
    }

    // MARK: Ações

    @objc private func toggleManual() {
        manualOn.toggle()
        if manualOn { requestAccessibilityIfNeeded() }
        tick()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        idleThreshold = seconds
        tick()
    }

    @objc private func toggleKeepScreenAwake() {
        keepScreenAwake.toggle()
        tick()
    }

    @objc private func toggleSchedule() {
        scheduleEnabled.toggle()
        if scheduleEnabled { requestAccessibilityIfNeeded() }
        tick()
    }

    @objc private func selectStartHour(_ sender: NSMenuItem) {
        guard let hour = sender.representedObject as? Int else { return }
        scheduleStart = hour
        tick()
    }

    @objc private func selectEndHour(_ sender: NSMenuItem) {
        guard let hour = sender.representedObject as? Int else { return }
        scheduleEnd = hour
        tick()
    }

    @objc private func toggleWeekdaysOnly() {
        weekdaysOnly.toggle()
        tick()
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(title: "Não foi possível alterar",
                  body: """
                  O macOS recusou a mudança: \(error.localizedDescription)

                  Dá para fazer na mão em Ajustes do Sistema › Geral › Itens de Início.
                  """)
        }
        refreshUI()
    }

    @objc private func checkPermissions() {
        if AXIsProcessTrusted() {
            alert(title: "Permissão concedida",
                  body: "O StayAwake já pode simular atividade. Idle atual: \(Int(systemIdleSeconds()))s.")
        } else {
            requestAccessibilityIfNeeded()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Pulso

    /// Posta um mouseMoved na coordenada exata onde o cursor ja esta: zera o
    /// HIDIdleTime sem deslocar o cursor, sem tecla e sem clique.
    ///
    /// Nao usar F14/F15 (keycodes 107/113) aqui: em teclado Apple sao brilho -/+
    /// e o macOS honra isso, entao cada pulso subia o brilho da tela. A tecla
    /// Clear (71), o "NumLock" do macOS, alterna num lock de verdade.
    private func nudge() {
        let source = CGEventSource(stateID: .hidSystemState)
        let position = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: position,
                mouseButton: .left)?
            .post(tap: .cghidEventTap)
        nudgeCount += 1
    }

    // MARK: Energia

    private func createAssertion() {
        guard assertionID == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAwake" as CFString,
            &assertionID
        )
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    // MARK: Permissões

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        alert(title: "Permissão necessária",
              body: """
              Abra Ajustes do Sistema › Privacidade e Segurança › Acessibilidade \
              e marque o StayAwake. Sem isso o app não consegue simular atividade.
              """)
    }

    private func alert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Entrada
//
// Flags de linha de comando para configurar o login item sem abrir o menu.

let args = CommandLine.arguments
if args.contains("--register-login") || args.contains("--unregister-login") {
    if #available(macOS 13.0, *) {
        do {
            if args.contains("--register-login") {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            print("status=\(SMAppService.mainApp.status.rawValue)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("erro: \(error)\n".utf8))
            exit(1)
        }
    }
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
