import AppKit
import Combine
import Darwin
import IOKit.pwr_mgt
import LocalAuthentication
import SwiftUI

// MARK: - Helper root (instalado con install-helper.sh)

enum Helper {
    static let base = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/openfortibar", isDirectory: true)
    static let executable = base.appendingPathComponent("vpn-helper")
    static let logURL = base.appendingPathComponent("run/vpn.log")
    static let openfortivpn = base.appendingPathComponent("bin/openfortivpn")
    /// Perfiles originales; install-helper.sh los copia a la carpeta protegida.
    static var sourceProfiles: URL { ConfigDir.profiles }

    static let installCommand = "sudo /Applications/OpenFortiBar.app/Contents/Resources/install-helper.sh"

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// Ejecuta install-helper.sh con la ventana de contraseña de macOS (copia los perfiles a la carpeta protegida).
    @MainActor static func applyProfiles(completion: @escaping @MainActor (String?) -> Void) {
        guard let script = Bundle.main.url(forResource: "install-helper", withExtension: "sh") else {
            return completion("no se encontró install-helper.sh")
        }
        let command = "'\(script.path)' '\(NSUserName())'"
        let source = "do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        DispatchQueue.global().async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message = error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "error desconocido" }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(message) } }
        }
    }

    /// Pide Touch ID (o la contraseña de tu Mac si no hay huella) y copia los perfiles con "vpn-helper import",
    /// que corre sin contraseña de sudo. Si el helper instalado es antiguo y no lo admite, lo reinstala
    /// una vez con la ventana de administrador de macOS.
    @MainActor static func importProfiles(completion: @escaping @MainActor (String?) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "aplicar los cambios de la conexión") { ok, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ok else { return completion(error?.localizedDescription ?? "cancelado") }
                    if isOutdated { return applyProfiles(completion: completion) }
                    run(["import"]) { error in
                        if error == nil { completion(nil) } else { applyProfiles(completion: completion) }
                    }
                }
            }
        }
    }

    /// El vpn-helper instalado difiere del que trae esta versión de la app (hay que reinstalarlo con sudo).
    static var isOutdated: Bool {
        guard isInstalled, let bundled = Bundle.main.url(forResource: "vpn-helper", withExtension: "sh") else { return false }
        return !FileManager.default.contentsEqual(atPath: bundled.path, andPath: executable.path)
    }

    /// Ejecuta `sudo -n vpn-helper <args>`; devuelve el mensaje de error, o nil si salió bien.
    static func run(_ args: [String], completion: @escaping @MainActor (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", executable.path] + args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { process in
            let ok = process.terminationStatus == 0
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in completion(ok ? nil : (message.isEmpty ? "Error del helper." : message)) }
        }
        do { try process.run() } catch {
            Task { @MainActor in completion(error.localizedDescription) }
        }
    }
}

// MARK: - Carpeta personal ~/.openforti (como ~/.ssh o ~/.aws)
//
// ~/.openforti/            (700)
//   profiles/  *.conf *.pem  perfiles y certificados (600)
//   icons/     custom-icon.png
//   backups/   openforti-backup-AAAAMMDD-HHMMSS.zip

enum ConfigDir {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openforti", isDirectory: true)
    static let profiles = root.appendingPathComponent("profiles", isDirectory: true)
    static let icons = root.appendingPathComponent("icons", isDirectory: true)
    static let backups = root.appendingPathComponent("backups", isDirectory: true)
    static let legacyProfiles = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/openfortivpn", isDirectory: true)
    static let legacyIcon = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenFortiBar/custom-icon.png")

    /// Crea la estructura y copia (sin borrar) lo que había en las rutas anteriores.
    static func prepare() {
        let fm = FileManager.default
        for dir in [root, profiles, icons, backups] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if (try? fm.contentsOfDirectory(atPath: profiles.path))?.isEmpty ?? true,
           let old = try? fm.contentsOfDirectory(at: legacyProfiles, includingPropertiesForKeys: nil) {
            for file in old where ["conf", "pem"].contains(file.pathExtension) {
                let dest = profiles.appendingPathComponent(file.lastPathComponent)
                try? fm.copyItem(at: file, to: dest)
                if file.pathExtension == "conf", var text = try? String(contentsOf: dest, encoding: .utf8) {
                    // ca-file apuntaba a la carpeta anterior: ahora a ~/.openforti/profiles
                    text = text.replacingOccurrences(of: legacyProfiles.path, with: profiles.path)
                    text = text.replacingOccurrences(of: "~/.config/openfortivpn", with: profiles.path)
                    try? text.write(to: dest, atomically: true, encoding: .utf8)
                }
            }
        }
        let icon = icons.appendingPathComponent("custom-icon.png")
        if !fm.fileExists(atPath: icon.path), fm.fileExists(atPath: legacyIcon.path) {
            try? fm.copyItem(at: legacyIcon, to: icon)
        }
        secure()
    }

    /// Permisos estilo ~/.ssh: carpetas 700, archivos 600.
    static func secure() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: isDir ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Backup

@MainActor
enum Backup {
    /// Preferencias de la app que se guardan en el backup.
    static let keys = ["icon", "profileIcons", "dimWhenDisconnected", "showLogs", "logsExpanded", "autoCheckUpdates", "profile", "browser", "browserProfile", "browserAskIfClosed", "autoReconnect", "preventSleep"]

    private static func ditto(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    static var defaultName: String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "openforti-backup-\(f.string(from: Date())).zip"
    }

    /// Crea un .zip con profiles/, icons/ y settings.json.
    static func create(at destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("openforti-backup-\(UUID().uuidString)/openforti", isDirectory: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for dir in [ConfigDir.profiles, ConfigDir.icons] where fm.fileExists(atPath: dir.path) {
            try fm.copyItem(at: dir, to: staging.appendingPathComponent(dir.lastPathComponent))
        }
        var settings: [String: Any] = ["app": "OpenForti Bar", "version": Updater.currentVersion, "created": ISO8601DateFormatter().string(from: Date())]
        var prefs: [String: Any] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key) { prefs[key] = v } }
        settings["preferences"] = prefs
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("settings.json"))
        try? fm.removeItem(at: destination)
        guard ditto(["-c", "-k", "--keepParent", staging.path, destination.path]) else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo crear el .zip"])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Restaura un backup: reemplaza profiles/ e icons/ y aplica las preferencias.
    /// Antes guarda automáticamente un backup del estado actual en ~/.openforti/backups.
    static func restore(from zip: URL) throws -> URL {
        let fm = FileManager.default
        let safety = ConfigDir.backups.appendingPathComponent("antes-de-restaurar-" + defaultName.replacingOccurrences(of: "openforti-backup-", with: ""))
        try create(at: safety)
        let tmp = fm.temporaryDirectory.appendingPathComponent("openforti-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        guard ditto(["-x", "-k", zip.path, tmp.path]) else {
            throw NSError(domain: "Backup", code: 2, userInfo: [NSLocalizedDescriptionKey: "El archivo no es un .zip válido"])
        }
        let base = tmp.appendingPathComponent("openforti", isDirectory: true)
        guard fm.fileExists(atPath: base.appendingPathComponent("settings.json").path) else {
            throw NSError(domain: "Backup", code: 3, userInfo: [NSLocalizedDescriptionKey: "No es un backup de OpenForti Bar"])
        }
        for name in ["profiles", "icons"] {
            let src = base.appendingPathComponent(name), dst = ConfigDir.root.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("settings.json")),
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefs = json["preferences"] as? [String: Any] {
            for (key, value) in prefs where keys.contains(key) { UserDefaults.standard.set(value, forKey: key) }
        }
        ConfigDir.secure()
        MenuBarIcon.clearCache()
        return safety
    }

    static var existing: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: ConfigDir.backups, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

// MARK: - Perfiles de conexión (carpeta protegida del helper)

struct Profile: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let file: URL
}

enum ProfileStore {
    /// Copia protegida del helper; mientras no esté instalado, los perfiles originales.
    static var directory: URL {
        Helper.isInstalled ? Helper.base.appendingPathComponent("profiles", isDirectory: true) : Helper.sourceProfiles
    }

    static func load() -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "conf" }
            .compactMap { file -> Profile? in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let id = file.deletingPathExtension().lastPathComponent
                let port = field("port", in: text).map { ":\($0)" } ?? ""
                return Profile(
                    id: id,
                    name: field("nombre", in: text, comment: true) ?? id,
                    host: (field("host", in: text) ?? "?") + port,
                    file: file)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Lee `clave = valor`, o `# clave: valor` cuando `comment` es true.
    private static func field(_ key: String, in text: String, comment: Bool = false) -> String? {
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if comment {
                guard line.hasPrefix("#") else { continue }
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard let sep = line.firstIndex(where: { $0 == "=" || $0 == ":" }),
                  line[..<sep].trimmingCharacters(in: .whitespaces) == key else { continue }
            return line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Estado

enum VPNState {
    case disconnected, waitingLogin, connecting, connected, disconnecting, external

    var title: String {
        switch self {
        case .disconnected: "Desconectado"
        case .waitingLogin: "Inicia sesión en el navegador…"
        case .connecting: "Conectando…"
        case .connected: "Conectado"
        case .disconnecting: "Desconectando…"
        case .external: "Conectado fuera de la app"
        }
    }

    var color: Color {
        switch self {
        case .connected, .external: .green
        case .disconnected: .secondary
        default: .orange
        }
    }

    /// Punto de estado sobre el logo en la barra; sin punto = desconectado.
    var dotColor: NSColor? {
        switch self {
        case .connected, .external: .systemGreen
        case .disconnected: nil
        default: .systemOrange
        }
    }
}

// MARK: - Íconos (configurables desde ⚙︎)

enum AppIcon: String, CaseIterable, Identifiable {
    case shield, utp, lockShield, network, key, bolt, globe, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shield: "Escudo"
        case .utp: "UTP"
        case .lockShield: "Candado"
        case .network: "Red"
        case .key: "Llave"
        case .bolt: "Túnel"
        case .globe: "Mundo"
        case .custom: "Personalizado"
        }
    }

    /// PNG incluido en la app, o símbolo del sistema (SF Symbols).
    private var resource: String? {
        switch self {
        case .shield: "openfortibar-logo"
        case .utp: "utp-logo"
        default: nil
        }
    }

    private var symbol: String? {
        switch self {
        case .lockShield: "lock.shield.fill"
        case .network: "network.badge.shield.half.filled"
        case .key: "key.fill"
        case .bolt: "bolt.horizontal.circle.fill"
        case .globe: "globe.americas.fill"
        default: nil
        }
    }

    var isSymbol: Bool { symbol != nil }

    static var customURL: URL { ConfigDir.icons.appendingPathComponent("custom-icon.png") }

    var image: NSImage? {
        if let resource { return Bundle.main.url(forResource: resource, withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            return NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
        }
        return NSImage(contentsOf: Self.customURL)
    }

    static var current: AppIcon {
        AppIcon(rawValue: UserDefaults.standard.string(forKey: "icon") ?? "") ?? .shield
    }

    /// Íconos por conexión, guardados como JSON {perfil: ícono} en la clave "profileIcons".
    static func decode(_ json: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    static func encode(_ map: [String: String]) -> String {
        (try? String(decoding: JSONEncoder().encode(map), as: UTF8.self)) ?? "{}"
    }

    /// Ícono de la conexión seleccionada; si no tiene uno propio, el ícono de la app.
    static func resolve(app: String, profileIcons: String, profile: String?) -> AppIcon {
        if let profile, let raw = decode(profileIcons)[profile], let icon = AppIcon(rawValue: raw) { return icon }
        return AppIcon(rawValue: app) ?? .shield
    }
}

@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func clearCache() { cache.removeAll() }

    static func image(for state: VPNState, icon: AppIcon, dim: Bool) -> NSImage {
        let key = "\(state)-\(icon.rawValue)-\(dim)"
        if let cached = cache[key] { return cached }
        let logo = icon.image
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let fraction: CGFloat = dim && state == .disconnected ? 0.45 : 1
            let rect = NSRect(x: 1, y: 1, width: 16, height: 16)
            if icon.isSymbol, let logo {
                // Los símbolos se pintan con el color del texto de la barra (claro u oscuro).
                let tinted = NSImage(size: logo.size, flipped: false) { r in
                    logo.draw(in: r)
                    NSColor.labelColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            } else {
                logo?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            }
            if let dot = state.dotColor {
                let rect = NSRect(x: 10, y: 10, width: 7, height: 7)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect).fill()
                dot.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

// MARK: - Controlador

@MainActor
final class VPNController: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "profile") }
    }
    @Published var launchAtLogin: Bool {
        didSet { LoginItem.set(launchAtLogin) }
    }
    @Published private(set) var state: VPNState = .disconnected
    @Published private(set) var logTail = ""
    @Published private(set) var interface: String?
    @Published private(set) var address: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var lastError: String?
    /// Intento de reconexión automática en curso (0 = ninguno) y cuándo se lanza el siguiente.
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var reconnectAt: Date?
    static let reconnectDelays: [TimeInterval] = [3, 10, 20, 30, 60]

    var logURL: URL { Helper.logURL }
    private var reconnectWork: DispatchWorkItem?
    private var sleepAssertion: IOPMAssertionID = 0
    private var wakeObserver: Any?

    private var starting = false
    private var stopping = false
    private var startRequestedAt: Date?
    private var loginURL: URL?
    private var timer: Timer?

    init() {
        selectedID = UserDefaults.standard.string(forKey: "profile") ?? ""
        // La primera vez, el ícono queda configurado para aparecer al iniciar sesión.
        // Solo abre la app: la VPN nunca se conecta sola.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            LoginItem.set(true)
        }
        launchAtLogin = LoginItem.isEnabled
        reloadProfiles()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Al despertar, una reconexión pendiente se lanza en unos segundos (lo que tarda en volver la red).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.poll()
                if self.reconnectWork != nil { self.scheduleReconnectWork(after: 5) }
            }
        }
    }

    var selected: Profile? { profiles.first { $0.id == selectedID } ?? profiles.first }

    func reloadProfiles() {
        profiles = ProfileStore.load()
        if !profiles.contains(where: { $0.id == selectedID }), let first = profiles.first {
            selectedID = first.id
        }
    }

    func connect(auto: Bool = false) {
        guard let profile = selected, state == .disconnected else { return }
        if !auto { cancelReconnect() }
        guard Helper.isInstalled else {
            lastError = "Primero instala el helper (ver aviso arriba)."
            return
        }
        lastError = nil
        loginURL = nil
        starting = true
        state = .connecting
        Helper.run(["start", profile.id]) { [weak self] error in
            guard let self else { return }
            self.starting = false
            if let error { self.lastError = error } else { self.startRequestedAt = Date() }
            self.poll()
        }
    }

    /// Cierra el túnel, incluido uno abierto fuera de la app (p. ej. `openforti-cli` en Terminal).
    func disconnect() {
        cancelReconnect()
        lastError = nil
        stopping = true
        state = .disconnecting
        Helper.run(["stop"]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.stopping = false
                self.lastError = error
            }
            self.poll()
        }
    }

    /// Cierra la app; si hay un túnel abierto, primero lo desconecta.
    func quit() { stopTunnel { NSApp.terminate(nil) } }

    /// Desconecta el túnel si hay uno abierto y luego ejecuta `then`.
    func stopTunnel(then: @escaping @MainActor () -> Void) {
        guard state != .disconnected else { return then() }
        Helper.run(["stop"]) { _ in then() }
    }

    func reopenLogin() {
        if let loginURL { Browser.open(loginURL) }
    }

    func poll() {
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        logTail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(300).joined(separator: "\n")
        let wasActive = [.waitingLogin, .connecting, .connected].contains(state)

        if Self.pgrep("-f", Helper.openfortivpn.path) {
            startRequestedAt = nil
            if log.contains("Tunnel is up and running") {
                if connectedSince == nil { connectedSince = Date() }
                reconnectAttempt = 0
                (interface, address) = Self.pppAddress() ?? (nil, nil)
                state = stopping ? .disconnecting : .connected
            } else {
                if loginURL == nil, let url = Self.authenticateURL(in: log) {
                    loginURL = url
                    Browser.openLogin(url)
                }
                state = stopping ? .disconnecting : (loginURL != nil ? .waitingLogin : .connecting)
            }
        } else if starting {
            state = .connecting
        } else if let started = startRequestedAt, Date().timeIntervalSince(started) < 5 {
            state = .connecting
        } else {
            if wasActive && !stopping {
                let lastErrorLine = log.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
                lastError = lastErrorLine.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                    ?? (state == .connected ? "Se perdió la conexión." : "No se pudo conectar.")
                // Reconecta si se cortó estando conectada (p. ej. tras suspender) o si falló un intento automático.
                if state == .connected || reconnectAttempt > 0 { scheduleReconnect() }
            }
            stopping = false
            startRequestedAt = nil
            connectedSince = nil
            interface = nil
            address = nil
            state = Self.pgrep("-x", "openfortivpn") ? .external : .disconnected
        }
        StatusItemTooltip.set("OpenForti Bar — \(state.title)")
        updateSleepAssertion()
    }

    // MARK: Reconexión automática y suspensión

    private func scheduleReconnect() {
        guard UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true else { return }
        guard reconnectAttempt < Self.reconnectDelays.count else {
            lastError = "No se pudo reconectar después de \(reconnectAttempt) intentos."
            reconnectAttempt = 0
            return
        }
        reconnectAttempt += 1
        scheduleReconnectWork(after: Self.reconnectDelays[reconnectAttempt - 1])
    }

    private func scheduleReconnectWork(after delay: TimeInterval) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconnectNow() } }
        reconnectWork = work
        reconnectAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reconnectNow() {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAt = nil
        guard state == .disconnected else { return }
        connect(auto: true)
    }

    func cancelReconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAt = nil
        reconnectAttempt = 0
    }

    /// Mientras está conectada (y si la opción está activa) impide que la Mac se suspenda por inactividad.
    /// Cerrar la tapa o suspender a mano sigue suspendiendo.
    private func updateSleepAssertion() {
        let want = state == .connected && UserDefaults.standard.bool(forKey: "preventSleep")
        if want && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "OpenForti Bar: VPN conectada" as CFString, &sleepAssertion)
        } else if !want && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    private static func authenticateURL(in log: String) -> URL? {
        guard let line = log.split(separator: "\n").first(where: { $0.contains("Authenticate at '") }),
              let start = line.range(of: "'"), let end = line.range(of: "'", options: .backwards),
              start.upperBound < end.lowerBound else { return nil }
        return URL(string: String(line[start.upperBound..<end.lowerBound]))
    }

    /// true si `pgrep <args>` encuentra algún proceso (incluidos los de root).
    private static func pgrep(_ args: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-q"] + args
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func pppAddress() -> (String, String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("ppp"), let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return (name, String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return nil
    }
}

// MARK: - Tooltip del ícono

enum StatusItemTooltip {
    @MainActor static func set(_ text: String) {
        if let button = AppDelegate.shared?.statusItem?.button, button.toolTip != text { button.toolTip = text }
    }
}

// MARK: - Actualizaciones (último release de GitHub)

@MainActor
final class Updater: ObservableObject {
    static let repo = "SebastianEPH/OpenFortiBar"
    enum Status: Equatable { case idle, checking, upToDate, available(String), downloading, failed(String) }

    @Published var status: Status = .idle
    private var assetURL: URL?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }

    /// Compara versiones "1.2.0" numéricamente; las de desarrollo cuentan como antiguas.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let parse = { (v: String) in v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
        let (r, l) = (parse(remote), parse(local))
        for i in 0..<max(r.count, l.count) {
            let (a, b) = (i < r.count ? r[i] : 0, i < l.count ? l[i] : 0)
            if a != b { return a > b }
        }
        return local.contains("-")
    }

    func check() {
        status = .checking
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try JSONDecoder().decode(Release.self, from: data)
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                assetURL = release.assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url
                status = Self.isNewer(version, than: Self.currentVersion) && assetURL != nil ? .available(version) : .upToDate
            } catch {
                status = .failed("No se pudo consultar GitHub")
            }
        }
    }

    /// Descarga el .zip, lo descomprime y reemplaza la app actual; luego la reabre.
    func install(beforeQuit: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) {
        guard let assetURL else { return }
        status = .downloading
        Task {
            do {
                let (zip, _) = try await URLSession.shared.download(from: assetURL)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openfortibar-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, dir.path]
                try unzip.run(); unzip.waitUntilExit()
                let newApp = dir.appendingPathComponent("OpenFortiBar.app")
                guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: newApp.path) else {
                    status = .failed("El paquete descargado no es válido"); return
                }
                let target = Bundle.main.bundleURL.path
                let script = """
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
                rm -rf "\(target)" && ditto "\(newApp.path)" "\(target)"
                xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
                open "\(target)"; rm -rf "\(dir.path)"
                """
                let relauncher = Process()
                relauncher.executableURL = URL(fileURLWithPath: "/bin/zsh")
                relauncher.arguments = ["-c", script]
                try relauncher.run()
                beforeQuit { NSApp.terminate(nil) }
            } catch {
                status = .failed("Error al descargar: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Configuración (⚙︎)

/// Campos editables de un perfil .conf; el resto de líneas se conserva tal cual.
struct ProfileForm: Equatable {
    var name = "", host = "", port = "", domains = "", setDNS = true

    init() {}
    init(text: String) {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let v = Self.value(body, "nombre", ":") { name = v }
                if let v = Self.value(body, "dns-domains", ":") { domains = v }
            } else {
                if let v = Self.value(line, "host", "=") { host = v }
                if let v = Self.value(line, "port", "=") { port = v }
                if let v = Self.value(line, "set-dns", "=") { setDNS = v != "0" }
            }
        }
    }

    private static func value(_ line: String, _ key: String, _ sep: Character) -> String? {
        guard let i = line.firstIndex(of: sep), line[..<i].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
    }

    /// Devuelve `text` con los campos del formulario puestos (reemplaza la línea o la agrega).
    func apply(to text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        func set(_ key: String, _ value: String, comment: Bool) {
            let match: (String) -> Bool = { raw in
                var l = raw.trimmingCharacters(in: .whitespaces)
                if comment { guard l.hasPrefix("#") else { return false }; l = l.dropFirst().trimmingCharacters(in: .whitespaces) }
                else if l.hasPrefix("#") { return false }
                guard let i = l.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return false }
                return l[..<i].trimmingCharacters(in: .whitespaces) == key
            }
            let newLine = comment ? "# \(key): \(value)" : "\(key) = \(value)"
            if let i = lines.firstIndex(where: match) {
                if value.isEmpty { lines.remove(at: i) } else { lines[i] = newLine }
            } else if !value.isEmpty {
                if comment { lines.insert(newLine, at: lines.prefix { $0.hasPrefix("#") }.count) } else { lines.append(newLine) }
            }
        }
        set("nombre", name.trimmingCharacters(in: .whitespaces), comment: true)
        set("dns-domains", domains.trimmingCharacters(in: .whitespaces), comment: true)
        set("host", host.trimmingCharacters(in: .whitespaces), comment: false)
        set("port", port.trimmingCharacters(in: .whitespaces), comment: false)
        set("set-dns", setDNS ? "1" : "0", comment: false)
        return lines.joined(separator: "\n")
    }
}

/// Estado local de la UI (se evita `@State`, que con swiftc directo requiere el plugin de macros).
@MainActor
final class UIState: ObservableObject {
    @Published var showSettings = false
    @Published var editProfileID = ""
    @Published var editText = ""
    @Published var editSaved = ""
    @Published var form = ProfileForm()
    @Published var formSaved = ProfileForm()
    @Published var showRaw = false
    @Published var editMessage: String?
    @Published var editError = false
    @Published var applying = false
    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .panelDidClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings = false; self?.backupMessage = nil }
        }
        qaObserver = NotificationCenter.default.addObserver(forName: .qaSettings, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.showSettings = note.object as? Bool ?? false }
        }
    }
    private var qaObserver: Any?
    @Published var customError: String?
    @Published var backupMessage: String?
    @Published var backupError = false
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, connection, appearance, backup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .connection: "Conexión"
        case .appearance: "Personalización"
        case .backup: "Backup"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connection: "network"
        case .appearance: "paintbrush"
        case .backup: "externaldrive"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @AppStorage("icon") private var icon = AppIcon.shield.rawValue
    @AppStorage("dimWhenDisconnected") private var dim = true
    @AppStorage("showLogs") private var showLogs = true
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("profileIcons") private var profileIcons = "{}"
    @AppStorage("browser") private var browser = Browser.system.rawValue
    @AppStorage("browserProfile") private var browserProfile = ""
    @AppStorage("browserAskIfClosed") private var browserAskIfClosed = false
    @AppStorage("settingsTab") private var tab = SettingsTab.general.rawValue
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("preventSleep") private var preventSleep = false
    @ObservedObject var ui: UIState
    @ObservedObject var updater: Updater

    private var updateRow: some View {
        HStack(spacing: 8) {
            Text("v\(Updater.currentVersion)").font(.caption).foregroundStyle(.secondary)
            switch updater.status {
            case .idle: EmptyView()
            case .checking: ProgressView().controlSize(.mini); Text("Buscando…").font(.caption)
            case .upToDate: Text("Estás en la última versión").font(.caption).foregroundStyle(.green)
            case .available(let v): Text("Nueva versión v\(v)").font(.caption).foregroundStyle(.orange)
            case .downloading: ProgressView().controlSize(.mini); Text("Actualizando…").font(.caption)
            case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            if case .available = updater.status {
                Button("Actualizar ahora") { updater.install(beforeQuit: vpn.stopTunnel) }.buttonStyle(.borderedProminent)
            } else {
                Button("Buscar actualizaciones") { updater.check() }
                    .disabled(updater.status == .checking || updater.status == .downloading)
            }
        }
        .controlSize(.small)
    }

    private var backupSummary: String {
        let list = Backup.existing
        guard let last = list.first else { return "Incluye perfiles, certificados, íconos y preferencias. Aún no hay backups." }
        return "\(list.count) backup(s) en ~/.openforti/backups · último: \(last.lastPathComponent)"
    }

    private func createBackup(choose: Bool) {
        var dest = ConfigDir.backups.appendingPathComponent(Backup.defaultName)
        if choose {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Backup.defaultName
            panel.allowedContentTypes = [.zip]
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dest = url
        }
        do {
            try Backup.create(at: dest)
            ui.backupError = false
            ui.backupMessage = "Backup creado: \(dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        } catch {
            ui.backupError = true
            ui.backupMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = ConfigDir.backups
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let safety = try Backup.restore(from: url)
            vpn.reloadProfiles()
            ui.backupError = false
            ui.backupMessage = "Restaurado. Estado anterior guardado en \(safety.lastPathComponent). Para aplicar los perfiles, pulsa «Guardar y aplicar» en Conexión."
        } catch {
            ui.backupError = true
            ui.backupMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func profileBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { AppIcon.decode(profileIcons)[id] ?? "" },
            set: { value in
                var map = AppIcon.decode(profileIcons)
                map[id] = value.isEmpty ? nil : value
                profileIcons = AppIcon.encode(map)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { ui.showSettings = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text("Configuración").font(.headline)
                Spacer()
            }
            tabBar
            Divider()
            switch SettingsTab(rawValue: tab) ?? .general {
            case .general: generalTab
            case .connection: connectionTab
            case .appearance: appearanceTab
            case .backup: backupTab
            }
        }
        .toggleStyle(.checkbox)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                let active = tab == item.rawValue
                Button { tab = item.rawValue } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 16)).frame(height: 18)
                        Text(item.title).font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .background(active ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var generalTab: some View {
        Text("Inicio").font(.subheadline.bold())
        Toggle("Abrir al iniciar sesión", isOn: $vpn.launchAtLogin)
        Toggle("Mostrar logs en el panel", isOn: $showLogs)

        Divider()
        Text("Actualizaciones").font(.subheadline.bold())
        updateRow
        Toggle("Buscar actualizaciones al abrir el panel", isOn: $autoCheckUpdates)
    }

    @ViewBuilder private var connectionTab: some View {
        Text("Perfil de conexión").font(.subheadline.bold())
        connectionEditor

        Divider()
        Text("Navegador para el login").font(.subheadline.bold())
        browserSection

        Divider()
        Text("Suspensión y cortes").font(.subheadline.bold())
        Toggle("Reconectar automáticamente si la conexión se corta", isOn: $autoReconnect)
        Toggle("Evitar que la Mac se suspenda sola mientras está conectada", isOn: $preventSleep)
        Text("La VPN no puede seguir abierta mientras la Mac está suspendida (tampoco al cerrar la tapa). Al despertar se reconecta sola; si tu sesión de Microsoft sigue abierta en el navegador, normalmente el login se completa sin pedirte nada.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var appearanceTab: some View {
        Text("Ícono de la app").font(.subheadline.bold())
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(AppIcon.allCases) { option in
                Button { select(option) } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let image = option.image {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .foregroundStyle(.primary)
                            } else {
                                Image(systemName: "plus.square.dashed").resizable().scaledToFit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        Text(option.title).font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(icon == option.rawValue ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(icon == option.rawValue ? Color.accentColor : .secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            Button("Elegir imagen…") { pickCustom() }
            if let customError = ui.customError { Text(customError).font(.caption).foregroundStyle(.red) }
        }
        .controlSize(.small)
        Toggle("Atenuar el ícono cuando está desconectado", isOn: $dim)

        if !vpn.profiles.isEmpty {
            Divider()
            Text("Ícono por conexión").font(.subheadline.bold())
            Text("Al seleccionar una conexión en el panel, la barra muestra su ícono.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(vpn.profiles) { profile in
                    GridRow {
                        Text(profile.name).lineLimit(1)
                        Picker("", selection: profileBinding(profile.id)) {
                            Text("Igual que la app").tag("")
                            Divider()
                            ForEach(AppIcon.allCases.filter { $0 != .custom || $0.image != nil }) {
                                Text($0.title).tag($0.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                    }
                }
            }
        }
    }

    @ViewBuilder private var backupTab: some View {
        Text("Backup").font(.subheadline.bold())
        Text("Incluye perfiles, certificados, íconos y preferencias en un .zip.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Crear backup") { createBackup(choose: false) }
            Button("Guardar en…") { createBackup(choose: true) }
            Button("Restaurar…") { restoreBackup() }
            Button { NSWorkspace.shared.open(ConfigDir.root) } label: { Image(systemName: "folder") }
                .help("Abrir ~/.openforti")
        }
        .controlSize(.small)
        if let message = ui.backupMessage {
            Text(message).font(.caption).foregroundStyle(ui.backupError ? .red : .green)
                .textSelection(.enabled)
        } else {
            Text(backupSummary).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var browserSection: some View {
        let current = Browser(rawValue: browser) ?? .system
        let options = Browser.installed
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Navegador").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { browser }, set: { browser = $0; browserProfile = "" })) {
                    ForEach(options) { Text($0.displayName).tag($0.rawValue) }
                    if !options.contains(current) { Text("\(current.title) (no instalado)").tag(current.rawValue) }
                }
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
            }
            if current.supportsProfiles {
                let profiles = current.profiles
                GridRow {
                    Text("Perfil").foregroundStyle(.secondary)
                    Picker("", selection: $browserProfile) {
                        Text("El último que usaste").tag("")
                        if !profiles.isEmpty { Divider() }
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                        if !browserProfile.isEmpty && !profiles.contains(where: { $0.id == browserProfile }) {
                            Text("\(browserProfile) (no encontrado)").tag(browserProfile)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
        if current != .system {
            Toggle("Si \(current.title) no está abierto, preguntar antes de abrirlo", isOn: $browserAskIfClosed)
            if !current.supportsProfiles {
                Text("\(current.title) no permite elegir el perfil desde otra app; se usa el que tenga abierto.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Probar") { Browser.open(URL(string: "https://example.com")!) }
                .help("Abre una página de prueba con el navegador y perfil elegidos")
            Text("Aquí se abrirá la página de inicio de sesión (SSO/SAML).").font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var connectionEditor: some View {
        if vpn.profiles.isEmpty {
            Text("No hay conexiones en ~/.openforti/profiles.").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Perfil", selection: Binding(get: { ui.editProfileID }, set: { loadProfile($0) })) {
                ForEach(vpn.profiles) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
            .onAppear { if ui.editProfileID.isEmpty { loadProfile(vpn.selectedID) } }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Nombre").foregroundStyle(.secondary)
                    TextField("UTP", text: $ui.form.name)
                }
                GridRow {
                    Text("Servidor").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("vpn.empresa.com", text: $ui.form.host)
                        Text(":").foregroundStyle(.secondary)
                        TextField("443", text: $ui.form.port).frame(width: 60)
                    }
                }
                GridRow {
                    Text("Dominios").foregroundStyle(.secondary)
                    TextField("empresa.com intranet.local", text: $ui.form.domains)
                        .help("Dominios que se resuelven con el DNS de la VPN, separados por espacio")
                }
                GridRow {
                    Text("")
                    Toggle("Usar el DNS de la VPN", isOn: $ui.form.setDNS)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(ui.showRaw)

            DisclosureGroup("Avanzado", isExpanded: Binding(get: { ui.showRaw }, set: { toggleRaw($0) })) {
                TextEditor(text: $ui.editText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            }
            .font(.caption)

            HStack {
                Button("Guardar") { saveProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || ui.applying)
                Button("Descartar") { loadProfile(ui.editProfileID) }
                    .disabled(!hasChanges || ui.applying)
                if ui.applying { ProgressView().controlSize(.mini) }
            }
            .controlSize(.small)
            if let message = ui.editMessage {
                Text(message).font(.caption).foregroundStyle(ui.editError ? .red : .green).textSelection(.enabled)
            }
        }
    }

    private var hasChanges: Bool { ui.form != ui.formSaved || ui.editText != ui.editSaved }

    private func sourceFile(_ id: String) -> URL { Helper.sourceProfiles.appendingPathComponent("\(id).conf") }

    private func loadProfile(_ id: String) {
        let id = vpn.profiles.contains { $0.id == id } ? id : (vpn.profiles.first?.id ?? "")
        ui.editProfileID = id
        ui.editText = (try? String(contentsOf: sourceFile(id), encoding: .utf8)) ?? ""
        ui.editSaved = ui.editText
        ui.form = ProfileForm(text: ui.editText)
        ui.formSaved = ui.form
        ui.showRaw = false
        ui.editMessage = nil
    }

    /// Al abrir "Avanzado" el texto refleja el formulario; al cerrarlo, el formulario refleja el texto.
    private func toggleRaw(_ open: Bool) {
        if open { ui.editText = ui.form.apply(to: ui.editText) } else { ui.form = ProfileForm(text: ui.editText) }
        ui.showRaw = open
    }

    private func saveProfile() {
        let text = ui.showRaw ? ui.editText : ui.form.apply(to: ui.editText)
        let file = sourceFile(ui.editProfileID)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            ui.editError = true; ui.editMessage = "No se pudo guardar: \(error.localizedDescription)"; return
        }
        ui.applying = true
        ui.editMessage = nil
        Helper.importProfiles { error in
            ui.applying = false
            vpn.reloadProfiles()
            if let error {
                ui.editError = true; ui.editMessage = "Guardado, pero no se aplicó: \(error)"
            } else {
                let id = ui.editProfileID
                loadProfile(id)
                ui.editError = false; ui.editMessage = "Guardado. Se usará en la próxima conexión."
            }
        }
    }

    private func select(_ option: AppIcon) {
        if option == .custom && option.image == nil { return pickCustom() }
        icon = option.rawValue
        MenuBarIcon.clearCache()
    }

    /// Copia la imagen elegida a Application Support para que no dependa del archivo original.
    private func pickCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        do {
            try FileManager.default.createDirectory(at: AppIcon.customURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: AppIcon.customURL)
            ui.customError = nil
            icon = AppIcon.custom.rawValue
            MenuBarIcon.clearCache()
        } catch {
            ui.customError = "No se pudo guardar la imagen"
        }
    }
}

// MARK: - Navegador para el login SAML

/// Navegadores soportados. Los basados en Chromium permiten elegir el perfil (`--profile-directory`).
enum Browser: String, CaseIterable, Identifiable {
    case system = "", safari, chrome, edge, brave, chromium, vivaldi, arc, firefox
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Predeterminado del sistema"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .chromium: "Chromium"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        case .firefox: "Firefox"
        }
    }

    var bundleID: String? {
        switch self {
        case .system: nil
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .chromium: "org.chromium.Chromium"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .arc: "company.thebrowser.Browser"
        case .firefox: "org.mozilla.firefox"
        }
    }

    /// Carpeta de datos (donde está "Local State") de los navegadores Chromium que aceptan --profile-directory.
    private var chromiumDataDir: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        switch self {
        case .chrome: return base.appendingPathComponent("Google/Chrome")
        case .edge: return base.appendingPathComponent("Microsoft Edge")
        case .brave: return base.appendingPathComponent("BraveSoftware/Brave-Browser")
        case .chromium: return base.appendingPathComponent("Chromium")
        case .vivaldi: return base.appendingPathComponent("Vivaldi")
        default: return nil
        }
    }

    var supportsProfiles: Bool { chromiumDataDir != nil }

    var appURL: URL? {
        guard let bundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var isInstalled: Bool { self == .system || appURL != nil }

    var isRunning: Bool {
        guard let bundleID else { return true }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Nombre a mostrar: para "Predeterminado" incluye cuál es (p. ej. "Predeterminado del sistema (Safari)").
    var displayName: String {
        guard self == .system else { return title }
        if let probe = URL(string: "https://example.com"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: probe) {
            return "\(title) (\(app.deletingPathExtension().lastPathComponent))"
        }
        return title
    }

    static var installed: [Browser] { allCases.filter(\.isInstalled) }

    static var selected: Browser { Browser(rawValue: UserDefaults.standard.string(forKey: "browser") ?? "") ?? .system }

    struct Profile: Identifiable, Hashable { let id: String; let name: String }

    /// Perfiles leídos de "Local State" (profile.info_cache): id = carpeta ("Default", "Profile 1"), name = nombre visible.
    var profiles: [Profile] {
        guard let dir = chromiumDataDir,
              let data = try? Data(contentsOf: dir.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        return cache.map { key, info in
            let name = (info["name"] as? String) ?? key
            let account = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(id: key, name: account.map { "\(name) — \($0)" } ?? name)
        }
        .sorted { a, b in
            if a.id == "Default" { return true }
            if b.id == "Default" { return false }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    /// Abre `url` con el navegador y perfil configurados. Si el navegador elegido no está instalado, usa el predeterminado.
    @MainActor static func open(_ url: URL) {
        let browser = selected
        guard browser != .system, let app = browser.appURL else {
            NSWorkspace.shared.open(url); return
        }
        let profile = UserDefaults.standard.string(forKey: "browserProfile") ?? ""
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if browser.supportsProfiles, !profile.isEmpty {
            // Una instancia nueva le pasa los argumentos a la que ya está abierta (o la abre si no lo está).
            config.createsNewApplicationInstance = true
            config.arguments = ["--profile-directory=\(profile)", url.absoluteString]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) } }
            }
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        }
    }

    /// Abre la URL de login respetando la opción "si no está abierto": abrirlo directamente o preguntar antes.
    @MainActor static func openLogin(_ url: URL) {
        let browser = selected
        guard browser != .system, browser.appURL != nil, !browser.isRunning,
              UserDefaults.standard.bool(forKey: "browserAskIfClosed") else { return open(url) }
        // Se muestra después del ciclo actual para no bloquear el poll que detectó la URL.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(browser.title) no está abierto"
            alert.informativeText = "OpenForti Bar necesita abrir la página de inicio de sesión de la VPN. ¿Quieres abrir \(browser.title)?"
            alert.addButton(withTitle: "Abrir \(browser.title)")
            alert.addButton(withTitle: "Usar el predeterminado")
            alert.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: open(url)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(url)
            default: break // Se puede reabrir con «Abrir de nuevo» en el panel.
            }
        }
    }
}

// MARK: - Inicio de sesión (LaunchAgent)

enum LoginItem {
    static let label = "io.github.sebastianeph.openfortibar"
    static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ enabled: Bool) {
        guard enabled else {
            try? FileManager.default.removeItem(at: plist)
            return
        }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? ""],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: plist)
        }
    }
}

// MARK: - Interfaz

struct PanelView: View {
    @EnvironmentObject var vpn: VPNController
    @AppStorage("showLogs") private var showLogs = true
    @AppStorage("logsExpanded") private var logsExpanded = true
    @StateObject private var updater = Updater()
    @AppStorage("icon") private var icon = AppIcon.shield.rawValue
    @AppStorage("profileIcons") private var profileIcons = "{}"
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @StateObject private var ui = UIState()

    var body: some View {
        Group {
            if ui.showSettings {
                SettingsView(ui: ui, updater: updater)
            } else {
                main
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            vpn.reloadProfiles()
            if autoCheckUpdates && updater.status == .idle { updater.check() }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if vpn.state == .connected { details }
            notes
            actionButton
            if showLogs {
                Divider()
                logs
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.resolve(app: icon, profileIcons: profileIcons, profile: vpn.selected?.id).image ?? NSImage())
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(vpn.state == .disconnected ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenForti Bar").font(.headline)
                Text(vpn.state.title).font(.subheadline).foregroundStyle(vpn.state.color)
            }
            Spacer()
            if vpn.profiles.isEmpty {
                Text("Sin conexiones").font(.caption).foregroundStyle(.red)
            } else {
                Picker("Conexión", selection: $vpn.selectedID) {
                    ForEach(vpn.profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(vpn.state != .disconnected)
                .help(vpn.selected?.host ?? "")
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("IP").foregroundStyle(.secondary)
                Text(vpn.address ?? "—").textSelection(.enabled)
            }
            GridRow {
                Text("Interfaz").foregroundStyle(.secondary)
                Text(vpn.interface ?? "—")
            }
            if let since = vpn.connectedSince {
                GridRow {
                    Text("Tiempo").foregroundStyle(.secondary)
                    Text(since, style: .timer).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var notes: some View {
        if !Helper.isInstalled || Helper.isOutdated {
            VStack(alignment: .leading, spacing: 6) {
                Label(Helper.isInstalled
                      ? "Hay una actualización del componente de conexión. Instálala para seguir conectando sin problemas."
                      : "Falta un paso (una sola vez): instalar el componente que conecta la VPN.",
                      systemImage: "info.circle.fill")
                    .font(.caption)
                HStack {
                    Button(Helper.isInstalled ? "Actualizar componente" : "Instalar componente") {
                        ui.applying = true
                        ui.editMessage = nil
                        Helper.applyProfiles { error in
                            ui.applying = false
                            ui.editError = error != nil
                            ui.editMessage = error.map { "No se pudo instalar: \($0)" }
                            vpn.reloadProfiles()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ui.applying)
                    if ui.applying { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .controlSize(.small)
                Text(ui.editError ? (ui.editMessage ?? "") : "macOS te pedirá tu contraseña.")
                    .font(.caption)
                    .foregroundStyle(ui.editError ? .red : .secondary)
            }
            .padding(8)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
        switch vpn.state {
        case .waitingLogin:
            HStack {
                Text("Completa el login de Microsoft en el navegador.").font(.caption)
                Spacer()
                Button("Abrir de nuevo") { vpn.reopenLogin() }.controlSize(.small)
            }
        case .external:
            Text("Hay una VPN abierta fuera de la app (por ejemplo, con openforti-cli en Terminal). Desconéctala para usar la app.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
        if let error = vpn.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
        if let at = vpn.reconnectAt {
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label("Reconectando en \(max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))) s (intento \(vpn.reconnectAttempt) de \(VPNController.reconnectDelays.count))",
                          systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                Spacer()
                Button("Ahora") { vpn.reconnectNow() }
                Button("Cancelar") { vpn.cancelReconnect() }
            }
            .controlSize(.small)
        } else if vpn.reconnectAttempt > 0, [.connecting, .waitingLogin].contains(vpn.state) {
            Label("Reconectando (intento \(vpn.reconnectAttempt) de \(VPNController.reconnectDelays.count))…", systemImage: "arrow.clockwise")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch vpn.state {
        case .disconnected:
            Button { vpn.connect() } label: {
                Label("Conectar", systemImage: "power").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vpn.selected == nil)
        case .waitingLogin, .connecting, .connected:
            Button(role: .destructive) { vpn.disconnect() } label: {
                Label(vpn.state == .connected ? "Desconectar" : "Cancelar", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .external:
            Button(role: .destructive) { vpn.disconnect() } label: {
                Label("Desconectar", systemImage: "xmark.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .disconnecting:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private var logs: some View {
        DisclosureGroup(isExpanded: $logsExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vpn.logTail.isEmpty ? "Sin actividad todavía." : vpn.logTail)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .onAppear { proxy.scrollTo("end") }
                .onChange(of: vpn.logTail) { proxy.scrollTo("end") }
            }
            HStack {
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vpn.logTail, forType: .string)
                }
                Button("Abrir archivo") { NSWorkspace.shared.open(vpn.logURL) }
                Spacer()
            }
            .controlSize(.small)
            .padding(.top, 4)
        } label: {
            Text("Logs").font(.headline)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Abrir al iniciar sesión", isOn: $vpn.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button { NSWorkspace.shared.open(Helper.sourceProfiles) } label: {
                Image(systemName: "folder")
            }
            .help("Conexiones (~/.openforti/profiles). Para editarlas: ⚙︎ Configuración → Conexión")
            Button { ui.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .overlay(alignment: .topTrailing) {
                        if case .available = updater.status {
                            Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 3, y: -3)
                        }
                    }
            }
            .keyboardShortcut(",")
            .help({ if case .available(let v) = updater.status { return "Configuración — nueva versión v\(v) disponible" }; return "Configuración (⌘,)" }())
            Button { vpn.quit() } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q")
            .help(vpn.state == .disconnected ? "Salir (⌘Q)" : "Desconectar y salir (⌘Q)")
        }
        .controlSize(.small)
    }
}

// MARK: - Ícono en la barra + popover
//
// Se usa NSStatusItem + NSPopover en lugar de MenuBarExtra: el popover ajusta su tamaño al
// contenido SwiftUI automáticamente (preferredContentSize), sin estirarse ni dejar huecos.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static weak var shared: AppDelegate?
    let vpn = VPNController()
    var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observers: [Any] = []
    private var cancellable: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        ConfigDir.prepare()
        vpn.reloadProfiles()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        let host = NSHostingController(rootView: PanelView().environmentObject(vpn))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        refreshIcon()
        cancellable = vpn.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        })

        // QA: OPENFORTIBAR_OPEN=1 abre el panel al iniciar (para capturas automáticas).
        if ProcessInfo.processInfo.environment["OPENFORTIBAR_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.toggle() }
        }
        // QA: OPENFORTIBAR_QA_BACKUP=1 crea un backup, lo restaura, imprime el resultado y sale.
        if ProcessInfo.processInfo.environment["OPENFORTIBAR_QA_BACKUP"] == "1" {
            let dest = ConfigDir.backups.appendingPathComponent("qa-" + Backup.defaultName)
            do {
                try Backup.create(at: dest)
                print("CREADO \(dest.path)")
                let safety = try Backup.restore(from: dest)
                print("RESTAURADO; respaldo previo \(safety.path)")
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.removeItem(at: safety)
            } catch { print("ERROR \(error.localizedDescription)") }
            exit(0)
        }
        // QA: OPENFORTIBAR_QA=1 recorre main → config → main → sin logs → config → main (3 s por paso).
        if ProcessInfo.processInfo.environment["OPENFORTIBAR_QA"] == "1" {
            let steps: [() -> Void] = [
                { self.toggle() },
                { NotificationCenter.default.post(name: .qaSettings, object: true) },
                { NotificationCenter.default.post(name: .qaSettings, object: false) },
                { UserDefaults.standard.set(false, forKey: "showLogs") },
                { NotificationCenter.default.post(name: .qaSettings, object: true) },
                { NotificationCenter.default.post(name: .qaSettings, object: false) },
                { UserDefaults.standard.set(true, forKey: "showLogs") },
            ]
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 3, execute: step)
            }
        }
    }

    func refreshIcon() {
        let defaults = UserDefaults.standard
        let icon = AppIcon.resolve(app: defaults.string(forKey: "icon") ?? AppIcon.shield.rawValue,
                                   profileIcons: defaults.string(forKey: "profileIcons") ?? "{}",
                                   profile: vpn.selected?.id)
        let dim = defaults.object(forKey: "dimWhenDisconnected") as? Bool ?? true
        let image = MenuBarIcon.image(for: vpn.state, icon: icon, dim: dim)
        if statusItem?.button?.image !== image { statusItem?.button?.image = image }
    }

    @objc func toggle() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .panelDidClose, object: nil)
    }
}

extension Notification.Name {
    static let panelDidClose = Notification.Name("OpenFortiBarPanelDidClose")
    static let qaSettings = Notification.Name("OpenFortiBarQASettings")
}

@main
struct OpenFortiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
