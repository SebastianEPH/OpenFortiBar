import AppKit
import Combine
import Darwin
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
    static let keys = ["icon", "profileIcons", "dimWhenDisconnected", "showLogs", "logsExpanded", "autoCheckUpdates", "profile"]

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

    var logURL: URL { Helper.logURL }

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
    }

    var selected: Profile? { profiles.first { $0.id == selectedID } ?? profiles.first }

    func reloadProfiles() {
        profiles = ProfileStore.load()
        if !profiles.contains(where: { $0.id == selectedID }), let first = profiles.first {
            selectedID = first.id
        }
    }

    func connect() {
        guard let profile = selected, state == .disconnected else { return }
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
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }

    func poll() {
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        logTail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(300).joined(separator: "\n")
        let wasActive = [.waitingLogin, .connecting, .connected].contains(state)

        if Self.pgrep("-f", Helper.openfortivpn.path) {
            startRequestedAt = nil
            if log.contains("Tunnel is up and running") {
                if connectedSince == nil { connectedSince = Date() }
                (interface, address) = Self.pppAddress() ?? (nil, nil)
                state = stopping ? .disconnecting : .connected
            } else {
                if loginURL == nil, let url = Self.authenticateURL(in: log) {
                    loginURL = url
                    NSWorkspace.shared.open(url)
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
            }
            stopping = false
            startRequestedAt = nil
            connectedSince = nil
            interface = nil
            address = nil
            state = Self.pgrep("-x", "openfortivpn") ? .external : .disconnected
        }
        StatusItemTooltip.set("OpenForti Bar — \(state.title)")
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

/// Estado local de la UI (se evita `@State`, que con swiftc directo requiere el plugin de macros).
@MainActor
final class UIState: ObservableObject {
    @Published var showSettings = false
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

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @AppStorage("icon") private var icon = AppIcon.shield.rawValue
    @AppStorage("dimWhenDisconnected") private var dim = true
    @AppStorage("showLogs") private var showLogs = true
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("profileIcons") private var profileIcons = "{}"
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
            ui.backupMessage = "Restaurado. Estado anterior guardado en \(safety.lastPathComponent). Ejecuta el comando del helper para aplicar los perfiles."
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
            Divider()

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

            Divider()
            Text("General").font(.subheadline.bold())
            Toggle("Abrir al iniciar sesión", isOn: $vpn.launchAtLogin)
            Toggle("Mostrar logs en el panel", isOn: $showLogs)

            Divider()
            Text("Actualizaciones").font(.subheadline.bold())
            updateRow
            Toggle("Buscar actualizaciones al abrir el panel", isOn: $autoCheckUpdates)

            Divider()
            Text("Conexiones").font(.subheadline.bold())
            HStack {
                Button("Abrir carpeta de perfiles") { NSWorkspace.shared.open(Helper.sourceProfiles) }
                Button("Copiar comando del helper") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Helper.installCommand, forType: .string)
                }
            }
            .controlSize(.small)
            Text("Tus perfiles están en ~/.openforti/profiles. Después de editarlos, ejecuta el comando del helper en Terminal.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Backup").font(.subheadline.bold())
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
        .toggleStyle(.checkbox)
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
        if !Helper.isInstalled {
            VStack(alignment: .leading, spacing: 6) {
                Label("Falta un paso (una sola vez): instalar el helper para conectar sin contraseña. En Terminal ejecuta:",
                      systemImage: "info.circle.fill")
                    .font(.caption)
                HStack {
                    Text(Helper.installCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Helper.installCommand, forType: .string)
                    }
                    .controlSize(.small)
                }
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
            .help("Conexiones (~/.openforti/profiles). Tras editarlas: sudo /Applications/OpenFortiBar.app/Contents/Resources/install-helper.sh")
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
