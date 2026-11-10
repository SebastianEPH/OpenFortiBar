import AppKit
import Darwin
import SwiftUI

// MARK: - Helper root (instalado con install-helper.sh)

enum Helper {
    static let base = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/openfortibar", isDirectory: true)
    static let executable = base.appendingPathComponent("vpn-helper")
    static let logURL = base.appendingPathComponent("run/vpn.log")
    static let openfortivpn = base.appendingPathComponent("bin/openfortivpn")
    /// Perfiles originales; install-helper.sh los copia a la carpeta protegida.
    static let sourceProfiles = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/openfortivpn", isDirectory: true)

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

// MARK: - Ícono de la barra (logo + punto de estado)

@MainActor
enum MenuBarIcon {
    static let logo = Bundle.main.url(forResource: "openfortibar-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    private static var cache: [String: NSImage] = [:]

    static func image(for state: VPNState) -> NSImage {
        let key = "\(state)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            logo?.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16), from: .zero,
                       operation: .sourceOver, fraction: state == .disconnected ? 0.45 : 1)
            // El cuadrante superior derecho del logo está vacío: ahí va el punto.
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

/// MenuBarExtra no permite poner tooltip: se busca el botón del ícono en la barra y se le asigna.
@MainActor
enum StatusItemTooltip {
    static func set(_ text: String) {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView.flatMap(findButton), button.toolTip != text {
                button.toolTip = text
            }
        }
    }

    private static func findButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
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
    @StateObject private var updater = Updater()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if vpn.state == .connected { details }
            notes
            actionButton
            Divider()
            logs
            Divider()
            updateRow
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { vpn.reloadProfiles() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.logo ?? NSImage())
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
        DisclosureGroup(isExpanded: $showLogs) {
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
                Button("Actualizar") { updater.install(beforeQuit: vpn.stopTunnel) }
            } else {
                Button("Buscar actualizaciones") { updater.check() }
                    .disabled(updater.status == .checking || updater.status == .downloading)
            }
        }
        .controlSize(.small)
        .onAppear { if updater.status == .idle { updater.check() } }
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
            .help("Conexiones (~/.config/openfortivpn). Tras editarlas: sudo /Applications/OpenFortiBar.app/Contents/Resources/install-helper.sh")
            Button { vpn.quit() } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q")
            .help(vpn.state == .disconnected ? "Salir (⌘Q)" : "Desconectar y salir (⌘Q)")
        }
        .controlSize(.small)
    }
}

@main
struct OpenFortiBarApp: App {
    @StateObject private var vpn = VPNController()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(vpn)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: vpn.state))
        }
        .menuBarExtraStyle(.window)
    }
}
