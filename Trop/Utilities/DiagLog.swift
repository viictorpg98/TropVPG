//
//  DiagLog.swift
//  Trop
//
//  Registro detallado de una sesion de uso: pantallas que se abren, peticiones de red con su tiempo, bloqueos de la
//  pantalla, uso de CPU, memoria y bateria, cambios de red, errores... Al final se junta todo en un informe corto (un
//  resumen con numeros y los eventos destacados) para poder leerlo y ver que se puede mejorar. Se consulta en
//  Ajustes > Acerca de > Informe de reproduccion.
//

import Darwin
import Foundation
import UIKit

final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    /// Se apaga desde Ajustes (Acerca de). Se lee desde cualquier hilo.
    nonisolated(unsafe) static var isEnabled = true

    // MARK: - Estado (protegido por `lock`)

    private struct Entry {
        let ms: Int
        let category: String
        let text: String
        let important: Bool
    }

    private struct Sample {
        let ms: Int
        let cpu: Double
        let memoryMB: Double
        let battery: Float
        let charging: Bool
        let thermal: Int
        let lowPower: Bool
        let network: String
        let active: Bool
        let playing: Bool
    }

    private struct ScreenStat {
        var visits = 0
        var seconds = 0.0
        var touches = 0
        var hitches = 0
    }

    private struct EndpointStat {
        var count = 0
        var totalMs = 0
        var maxMs = 0
        var errors = 0
        var bytes = 0
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var samples: [Sample] = []
    private var screens: [String: ScreenStat] = [:]
    private var screenStack: [String] = []
    private var screenSince = Date()
    private var endpoints: [String: EndpointStat] = [:]
    private var pending: [String: (label: String, start: Date)] = [:]
    private var hitchCounts = [0, 0, 0, 0]          // >100, >250, >500, >1000 ms
    private var worstHitches: [(ms: Int, screen: String, at: Int)] = []
    private var issueCount = 0
    private var firstIssues: [String] = []
    private var memoryWarnings = 0
    private var appActive = true
    private var started = false

    private let maxEntries = 5000
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var watchdog: DispatchSourceTimer?
    private var sampler: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.686udjie.Trop.DiagLog", qos: .utility)

    private init() {}

    // MARK: - Apuntar

    /// `important`: sale entre los eventos destacados del informe (el resto solo en los ultimos eventos).
    static func event(_ category: String, _ text: String, important: Bool = false) {
        guard isEnabled else { return }
        shared.add(category, text, important: important)
    }

    private func add(_ category: String, _ text: String, important: Bool) {
        let entry = Entry(ms: LaunchClock.ms(), category: category, text: text, important: important)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        lock.unlock()
    }

    // MARK: - Pantallas

    static func screenAppeared(_ name: String) {
        guard isEnabled else { return }
        shared.screenChange { stack in
            stack.removeAll { $0 == name }
            stack.append(name)
        }
        shared.screenStat(name) { $0.visits += 1 }
        event("pantalla", "abre \(name)")
    }

    static func screenDisappeared(_ name: String) {
        guard isEnabled else { return }
        shared.screenChange { stack in stack.removeAll { $0 == name } }
        event("pantalla", "cierra \(name)")
    }

    static func touch() {
        guard isEnabled else { return }
        shared.lock.lock()
        let name = shared.screenStack.last ?? "arranque"
        shared.screens[name, default: ScreenStat()].touches += 1
        shared.lock.unlock()
    }

    private var currentScreen: String { screenStack.last ?? "arranque" }

    private func screenChange(_ change: (inout [String]) -> Void) {
        lock.lock()
        let now = Date()
        screens[currentScreen, default: ScreenStat()].seconds += now.timeIntervalSince(screenSince)
        screenSince = now
        change(&screenStack)
        lock.unlock()
    }

    private func screenStat(_ name: String, _ change: (inout ScreenStat) -> Void) {
        lock.lock()
        change(&screens[name, default: ScreenStat()])
        lock.unlock()
    }

    // MARK: - Red (peticiones de YouTube)

    /// Lo llama el registro de SwiftyTube con cada mensaje: se sacan de ahi el tipo de peticion, su tiempo y su resultado.
    static func swiftyTube(_ message: String, isError: Bool) {
        guard isEnabled else { return }
        if message.hasPrefix("[HTTP][") {
            shared.parseHTTP(message)
        } else if isError {
            event("error", "[red] " + String(message.prefix(200)), important: true)
        }
    }

    private func parseHTTP(_ message: String) {
        // "[HTTP][ID] -> browse url=..." / "[HTTP][ID] <- endpoint=browse status=200 bytes=1234 ..." (con flechas unicode)
        let parts = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return }
        let head = parts[0]
        guard head.hasPrefix("[HTTP]["), head.hasSuffix("]") else { return }
        let id = String(head.dropFirst("[HTTP][".count).dropLast())
        let rest = String(parts[1])

        if rest.hasPrefix("\u{2192}") {
            let body = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            let endpoint = body.split(separator: " ").first.map(String.init) ?? "?"
            var label = endpoint
            if let range = body.range(of: "browseId=") {
                let value = body[range.upperBound...].prefix { !$0.isWhitespace }
                if value != "-" { label += "(\(value))" }
            }
            if body.contains("continuation=yes") { label += "+continuacion" }
            lock.lock()
            pending[id] = (label, Date())
            if pending.count > 200 { pending.removeAll() }
            lock.unlock()
        } else if rest.hasPrefix("\u{2190}") {
            lock.lock()
            let started = pending.removeValue(forKey: id)
            lock.unlock()
            guard let started else { return }
            let ms = Int(Date().timeIntervalSince(started.start) * 1000)
            let status = Self.value(of: "status=", in: rest) ?? "?"
            let bytes = Int(Self.value(of: "bytes=", in: rest) ?? "") ?? 0
            let failed = !status.hasPrefix("2")
            lock.lock()
            var stat = endpoints[started.label, default: EndpointStat()]
            stat.count += 1
            stat.totalMs += ms
            stat.maxMs = max(stat.maxMs, ms)
            stat.bytes += bytes
            if failed { stat.errors += 1 }
            endpoints[started.label] = stat
            lock.unlock()
            add("red", "\(started.label) \(status) \(ms) ms \(bytes / 1024) KB", important: failed || ms > 1500)
        } else if rest.hasPrefix("retry=") {
            add("red", "reintento \(rest.prefix(120))", important: true)
        }
    }

    private static func value(of key: String, in text: String) -> String? {
        guard let range = text.range(of: key) else { return nil }
        return String(text[range.upperBound...].prefix { !$0.isWhitespace })
    }

    // MARK: - Errores

    static func issue(_ level: String, _ category: String, _ message: String) {
        guard isEnabled else { return }
        let line = "[\(category)] " + String(message.prefix(220))
        shared.lock.lock()
        shared.issueCount += 1
        if shared.firstIssues.count < 15 { shared.firstIssues.append("\(level) \(line)") }
        shared.lock.unlock()
        shared.add("error", "\(level) \(line)", important: true)
    }

    /// Una consulta a la base de datos que tarda mucho se apunta (en el informe sale entre los eventos destacados).
    static func slowDB(_ label: String, since start: Date) {
        guard isEnabled else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if ms >= 120 { event("bd", "\(label) tardo \(ms) ms", important: true) }
    }

    /// Borra lo apuntado (boton "Borrar" del informe).
    func reset() {
        lock.lock()
        entries = []
        samples = []
        screens = [:]
        endpoints = [:]
        pending = [:]
        hitchCounts = [0, 0, 0, 0]
        worstHitches = []
        issueCount = 0
        firstIssues = []
        memoryWarnings = 0
        lock.unlock()
    }

    // MARK: - Arranque de la vigilancia

    /// Empieza a vigilar (ciclo de vida, bloqueos de la pantalla, recursos). Se llama una vez al arrancar la app.
    @MainActor
    func start() {
        guard Self.isEnabled, !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        add("app", "registro detallado activo", important: true)
        observeSystem()
        startWatchdog()
        startSampler()
    }

    /// Apaga la vigilancia (al quitar el registro detallado en Ajustes).
    @MainActor
    func stop() {
        started = false
        watchdog?.cancel()
        watchdog = nil
        sampler?.cancel()
        sampler = nil
    }

    @MainActor
    private func observeSystem() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ text: @escaping (Notification) -> String, active: Bool? = nil) {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                if let active {
                    self.lock.lock()
                    self.appActive = active
                    self.lock.unlock()
                }
                if name == UIApplication.didReceiveMemoryWarningNotification {
                    self.lock.lock()
                    self.memoryWarnings += 1
                    self.lock.unlock()
                }
                Self.event("sistema", text(note), important: true)
                if name == UIApplication.didEnterBackgroundNotification { self.saveToDisk() }
            }
        }
        observe(UIApplication.didBecomeActiveNotification, { _ in "app activa" }, active: true)
        observe(UIApplication.willResignActiveNotification, { _ in "app inactiva" }, active: false)
        observe(UIApplication.didEnterBackgroundNotification, { _ in "app en segundo plano" }, active: false)
        observe(UIApplication.willEnterForegroundNotification, { _ in "app vuelve a primer plano" })
        observe(UIApplication.didReceiveMemoryWarningNotification, { _ in "AVISO DE MEMORIA del sistema" })
        observe(ProcessInfo.thermalStateDidChangeNotification, { _ in
            "estado termico: \(Self.thermalName(ProcessInfo.processInfo.thermalState))"
        })
        observe(Notification.Name.NSProcessInfoPowerStateDidChange, { _ in
            "modo de bajo consumo: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "si" : "no")"
        })
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "normal"
        case .fair: return "algo caliente"
        case .serious: return "caliente"
        case .critical: return "critico"
        @unknown default: return "?"
        }
    }

    // MARK: - Bloqueos de la pantalla (hilo principal)

    /// Cada cuarto de segundo, con la app abierta, se pide al hilo principal que conteste: si tarda, la pantalla se quedo parada.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.appActive
            self.lock.unlock()
            guard active else { return }
            let sent = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let delay = Int((CFAbsoluteTimeGetCurrent() - sent) * 1000)
                // 250 ms de intervalo: lo que pasa de ~100 ms es un tirón visible.
                if delay >= 100 { self.recordHitch(ms: delay) }
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func recordHitch(ms: Int) {
        let now = LaunchClock.ms()
        lock.lock()
        let screen = currentScreen
        if ms >= 100 { hitchCounts[0] += 1 }
        if ms >= 250 { hitchCounts[1] += 1 }
        if ms >= 500 { hitchCounts[2] += 1 }
        if ms >= 1000 { hitchCounts[3] += 1 }
        screens[screen, default: ScreenStat()].hitches += 1
        worstHitches.append((ms, screen, now))
        worstHitches.sort { $0.ms > $1.ms }
        if worstHitches.count > 8 { worstHitches.removeLast(worstHitches.count - 8) }
        lock.unlock()
        add("bloqueo", "pantalla parada \(ms) ms en \(screen)", important: ms >= 250)
    }

    // MARK: - Recursos (cada 10 s)

    @MainActor
    private func startSampler() {
        sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.takeSample()
            }
        }
    }

    @MainActor
    private func takeSample() {
        let device = UIDevice.current
        let network: String
        if !NetworkMonitor.shared.isOnline {
            network = "sin red"
        } else {
            network = DownloadManager.shared.isOnWiFiNow ? "wifi" : "datos"
        }
        let sample = Sample(
            ms: LaunchClock.ms(),
            cpu: Self.cpuPercent(),
            memoryMB: Self.memoryMB(),
            battery: device.batteryLevel,
            charging: device.batteryState == .charging || device.batteryState == .full,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            network: network,
            active: UIApplication.shared.applicationState == .active,
            playing: NowPlaying.shared.isPlaying
        )
        lock.lock()
        samples.append(sample)
        if samples.count > 1500 { samples.removeFirst(samples.count - 1500) }
        let count = samples.count
        lock.unlock()
        if count % 3 == 0 { saveToDisk() }
        let battery = sample.battery >= 0 ? "\(Int(sample.battery * 100))%" : "?"
        add(
            "recursos",
            String(
                format: "cpu %.0f%% mem %.0f MB bateria %@%@ %@ %@ %@",
                sample.cpu, sample.memoryMB, battery, sample.charging ? " (cargando)" : "",
                sample.network, sample.active ? "abierta" : "segundo plano", sample.playing ? "sonando" : "en pausa"
            ),
            important: sample.cpu > 80
        )
    }

    /// CPU usada por la app, sumando todos los hilos (100 % = un nucleo entero).
    private static func cpuPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threads = threadList else {
            return 0
        }
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        _ = vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: threads)),
            vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
        )
        return total
    }

    private static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    // MARK: - Informe

    /// El informe: un resumen con numeros, los eventos destacados y los ultimos eventos.
    func report() -> String {
        lock.lock()
        let entries = self.entries
        let samples = self.samples
        var screens = self.screens
        let endpoints = self.endpoints
        let hitchCounts = self.hitchCounts
        let worst = self.worstHitches
        let issueCount = self.issueCount
        let firstIssues = self.firstIssues
        let warnings = self.memoryWarnings
        let current = currentScreen
        let since = screenSince
        lock.unlock()
        screens[current, default: ScreenStat()].seconds += Date().timeIntervalSince(since)

        var lines: [String] = []
        let minutes = Double(LaunchClock.ms()) / 60_000
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        lines.append("== RESUMEN DE LA SESION ==")
        lines.append(String(format: "Duracion: %.1f min | version %@ | %@ | iOS %@",
                            minutes, version, UIDevice.current.model, UIDevice.current.systemVersion))

        if let first = samples.first, let last = samples.last, last.ms > first.ms {
            let span = Double(last.ms - first.ms) / 3_600_000
            if first.battery >= 0, last.battery >= 0 {
                let drop = Double(first.battery - last.battery) * 100
                let rate = span > 0.05 ? String(format: " (unos %.0f%% por hora)", drop / span) : ""
                let charged = samples.contains { $0.charging } ? " [estuvo cargando: el consumo no es fiable]" : ""
                lines.append(String(format: "Bateria: %.0f%% -> %.0f%% en %.0f min%@%@",
                                    Double(first.battery) * 100, Double(last.battery) * 100, span * 60, rate, charged))
            }
            func average(_ items: [Sample]) -> Double { items.isEmpty ? 0 : items.map(\.cpu).reduce(0, +) / Double(items.count) }
            let foreground = samples.filter(\.active)
            let background = samples.filter { !$0.active }
            lines.append(String(
                format: "CPU: media %.0f%% (abierta %.0f%%, segundo plano %.0f%%), maxima %.0f%%",
                average(samples), average(foreground), average(background), samples.map(\.cpu).max() ?? 0
            ))
            lines.append(String(
                format: "Memoria: media %.0f MB, maxima %.0f MB | avisos de memoria: %d",
                samples.map(\.memoryMB).reduce(0, +) / Double(samples.count), samples.map(\.memoryMB).max() ?? 0, warnings
            ))
            let thermal = samples.map(\.thermal).max() ?? 0
            let lowPower = samples.contains { $0.lowPower }
            let networks = Dictionary(grouping: samples, by: \.network).mapValues { $0.count * 10 }
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value / 60) min" }
                .joined(separator: ", ")
            lines.append("Termico maximo: \(Self.thermalName(ProcessInfo.ThermalState(rawValue: thermal) ?? .nominal)) | bajo consumo: \(lowPower ? "si" : "no") | red: \(networks)")
            let playing = samples.filter(\.playing).count * 10 / 60
            lines.append("Sonando: \(playing) min de \(Int(minutes)) | muestras: \(samples.count)")
        } else {
            lines.append("Todavia no hay muestras de recursos (se toman cada 10 s).")
        }

        lines.append("")
        lines.append("Pantallas (visitas, tiempo, toques, tirones):")
        for (name, stat) in screens.sorted(by: { $0.value.seconds > $1.value.seconds }).prefix(14) {
            lines.append(String(format: "  %@: %d visitas, %.0f s, %d toques, %d tirones", name, stat.visits, stat.seconds, stat.touches, stat.hitches))
        }

        lines.append("")
        lines.append(String(
            format: "Pantalla parada (hilo principal): >100 ms %d veces, >250 ms %d, >500 ms %d, >1 s %d",
            hitchCounts[0], hitchCounts[1], hitchCounts[2], hitchCounts[3]
        ))
        for item in worst.prefix(6) {
            lines.append("  \(item.ms) ms en \(item.screen) (a los \(item.at / 1000) s)")
        }

        lines.append("")
        lines.append("Peticiones a YouTube (cuantas, media, maxima, KB, fallos):")
        for (label, stat) in endpoints.sorted(by: { $0.value.totalMs > $1.value.totalMs }).prefix(14) {
            lines.append(String(
                format: "  %@: %d, %d ms, %d ms, %d KB, %d fallos",
                label, stat.count, stat.totalMs / max(1, stat.count), stat.maxMs, stat.bytes / 1024, stat.errors
            ))
        }

        lines.append("")
        lines.append("Errores y avisos: \(issueCount)")
        for issue in firstIssues { lines.append("  " + issue) }

        let important = entries.filter(\.important).suffix(350)
        lines.append("")
        lines.append("== EVENTOS DESTACADOS (\(important.count)) ==")
        for entry in important { lines.append(format(entry)) }

        let tail = entries.suffix(120)
        lines.append("")
        lines.append("== ULTIMOS EVENTOS (\(tail.count)) ==")
        for entry in tail { lines.append(format(entry)) }
        return lines.joined(separator: "\n")
    }

    private func format(_ entry: Entry) -> String {
        String(format: "%6.1f s %@ %@", Double(entry.ms) / 1000, entry.category, entry.text)
    }

    // MARK: - Guardado (por si la app se cierra)

    private var reportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("informe-sesion.txt")
    }

    private var previousURL: URL {
        reportURL.deletingLastPathComponent().appendingPathComponent("informe-sesion-anterior.txt")
    }

    /// La sesion anterior pasa a "anterior" (si la app se cerro o fallo, su informe sigue ahi).
    func archivePreviousSession() {
        let size = (try? FileManager.default.attributesOfItem(atPath: reportURL.path)[.size] as? Int) ?? 0
        // Si la sesion que acaba de cerrarse apenas llego a apuntar nada (por ejemplo, un arranque seguido de otro), no se pisa
        // la anterior, que es la que tiene datos.
        guard size > 2_000 else {
            try? FileManager.default.removeItem(at: reportURL)
            return
        }
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: reportURL, to: previousURL)
    }

    var previousSessionReport: String? {
        try? String(contentsOf: previousURL, encoding: .utf8)
    }

    /// Guarda el informe a disco (cada medio minuto y al pasar a segundo plano).
    func saveToDisk() {
        guard Self.isEnabled else { return }
        let text = report()
        let url = reportURL
        queue.async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
