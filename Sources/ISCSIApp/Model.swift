import AppLocalization
import SwiftUI
import Network
import ISCSICore
import ConnectionLifecycle

@MainActor final class Model: ObservableObject {
    static let shared = Model()
    @Published var host = ""
    @Published var port = "3260"
    @Published var target = ""
    @Published var lun = "0"
    @Published var username = ""
    @Published var password = ""
    @Published var chap = false
    @Published var connectionStarted: Date?
    @Published var busy = true
    @Published var targets: [Target] = []
    @Published var status: LocalizedText = "Проверка предыдущего подключения…"
    @Published var details: LocalizedText = ""
    @Published var disk: MountedDisk?
    @Published var automatic = false
    @Published var needsAttention = false
    @Published var language = AppLanguage.saved
    func tr(_ text: LocalizedText) -> String { text.render(language) }
    func languageChanged() { language.save() }
    private let connection = DiskConnection()
    private var policy = ReconnectPolicy()
    private var power: PowerMonitor?
    private let network = NWPathMonitor()
    private var networkAvailable = true
    private var timer: Timer?
    private var checking = false
    private var sleepGeneration = 0
    private var lastWake: Date?
    private var bridgeReconnecting = false
    private let logURL: URL
    init() {
        logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SynologyInitiator/lifecycle.log")
        power = PowerMonitor(onSleep: { acknowledge in Task { @MainActor in await Model.shared.prepareForSleep(acknowledge: acknowledge) } }, onWake: { Task { @MainActor in Model.shared.didWake() } })
        network.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in
                let model = Model.shared
                let changed = model.networkAvailable != available
                model.networkAvailable = available
                if changed && available { model.policy.retryNow() }
                if changed { await model.tick() }
            }
        }
        network.start(queue: DispatchQueue(label: "SynologyInitiator.network"))
        Task {
            do {
                if let profile = try await connection.loadProfile() {
                    host = profile.host; port = String(profile.port); target = profile.target; lun = String(profile.lun)
                    chap = profile.chap; username = profile.username; automatic = profile.automatic
                    if profile.needsAttention { policy.unsafeDisconnect() }
                }
                disk = try await connection.recover()
                policy.enabled = automatic
                needsAttention = policy.needsAttention
                if power?.isRegistered != true {
                    policy.unsafeDisconnect(); needsAttention = true
                    status = "Не удалось включить подготовку ко сну. Автоподключение остановлено."
                } else if needsAttention {
                    status = "Предыдущее отключение не было подтверждено. Сначала извлеки оставшийся диск."
                } else { status = disk == nil ? (host.isEmpty ? "Укажи адрес NAS / сервера, Target IQN и номер LUN." : "Ожидание доступа к iSCSI-серверу. Сеть или VPN можно подключить позже.") : "Диск подключён. Подготовка ко сну включена." }
                await persist()
            } catch { policy.unsafeDisconnect(); needsAttention = true; status = LocalizedText(error: error) }
            busy = false
            log("started; power notifications registered=\(power?.isRegistered == true)")
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in await Model.shared.tick() } }
            await tick()
        }
    }
    private func configuration() -> Configuration? {
        guard let number = UInt16(port), number > 0 else { return nil }
        return Configuration(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: number, username: chap ? username : "", password: chap ? password : "")
    }
    private func log(_ message: String) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let file = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + message + "\n").utf8))
    }
    private func persist() async {
        guard let config = configuration(), let lun = UInt16(lun) else { return }
        let profile = ConnectionProfile(host: config.host, port: config.port, target: target, lun: lun, chap: chap, username: username, automatic: automatic, needsAttention: policy.needsAttention)
        do { try await connection.saveProfile(profile) } catch { log("profile save failed") }
    }
    func automaticChanged() {
        policy.enabled = automatic; policy.retryNow()
        Task { await persist(); await tick() }
    }
    func connect() {
        guard !busy, disk == nil, !policy.sleeping else { return }
        if needsAttention {
            status = "Автоматическое восстановление остановлено после ошибки. Проверь и извлеки прежнее подключение."; return
        }
        automatic = true; policy.enabled = true; policy.retryNow()
        Task { await attemptConnection(manual: true) }
    }
    func inspectPreviousConnection() async {
        guard !busy else { return }
        busy = true
        do {
            disk = try await connection.recover()
            busy = false
            _ = await disconnect(manual: true)
        } catch { busy = false; status = LocalizedText(error: error) }
    }
    private func attemptConnection(manual: Bool) async {
        guard !busy, disk == nil, !policy.sleeping, !policy.needsAttention,
              let config = configuration(), let lunNumber = UInt16(lun), lunNumber <= 16383, !target.isEmpty else { return }
        if chap && password.isEmpty { status = "Введи пароль CHAP для подключения. Пароль не сохраняется."; return }
        busy = true
        connectionStarted = Date()
        defer { connectionStarted = nil }
        let generation = sleepGeneration
        await persist()
        let reachable = await Task.detached { Session.isReachable(host: config.host, port: config.port) }.value
        guard reachable, networkAvailable, !policy.sleeping, generation == sleepGeneration else {
            policy.failed(now: Date()); busy = false
            if !policy.sleeping { status = "iSCSI-сервер недоступен. Жду доступа к сети; подключение повторится автоматически." }
            return
        }
        status = "Подключение диска…"
        do {
            disk = try await connection.connect(configuration: config, target: target.trimmingCharacters(in: .whitespacesAndNewlines), lun: lunNumber, progress: { message in
                Task { @MainActor in
                    if Model.shared.busy, Model.shared.disk == nil { Model.shared.status = message }
                }
            })
            policy.connected()
            if generation != sleepGeneration {
                // A connect that crossed a sleep boundary is never accepted as
                // a healthy newly mounted disk, even if its command succeeded.
                policy.unsafeDisconnect(); needsAttention = true
                status = "Подключение пересеклось со сном. Требуется безопасно извлечь диск."
            } else { status = "Диск подключён. Перед сном приложение извлечёт его автоматически."; log("connected \(disk?.device ?? "")") }
        } catch {
            policy.failed(now: Date())
            // A partially created attachment must be recovered before any retry.
            do { if let recovered = try await connection.recover() { disk = recovered; policy.unsafeDisconnect(); needsAttention = true } }
            catch { policy.unsafeDisconnect(); needsAttention = true }
            status = needsAttention ? "Подключение не завершено. Требуется извлечение: \(LocalizedText(error: error))" : (manual ? LocalizedText(error: error) : "iSCSI-сервер пока недоступен. Повторю подключение позже.")
            log("connect failed")
        }
        busy = false; await persist()
    }
    func disconnect(manual: Bool = true, timeout: TimeInterval = 60) async -> Bool {
        guard !busy else { return false }
        if manual { automatic = false; policy.manualStop() }
        busy = true; status = "Сохранение данных и извлечение диска…"
        await persist()
        do {
            try await connection.disconnect(timeout: timeout)
            disk = nil; policy.cleanDetach(); needsAttention = false
            busy = false; status = "Диск безопасно извлечён."; log("clean detach")
            await persist(); return true
        } catch {
            policy.unsafeDisconnect(); needsAttention = true; busy = false
            let reason = error.localizedDescription
            if reason.contains("dissented") || reason.localizedCaseInsensitiveContains("resource busy") {
                status = "Извлечение заблокировано открытым файлом или просмотром. Закрой проигрыватель и окна просмотра. Диск остаётся подключённым."
                details = .literal(reason)
            } else {
                status = "Диск не удалось безопасно извлечь. Закрой файлы на нём и повтори: \(LocalizedText(error: error))"
            }
            log("detach failed; automatic reconnect blocked: " + error.localizedDescription.replacingOccurrences(of: "\n", with: " "))
            await persist(); return false
        }
    }
    func prepareForSleep(acknowledge: @escaping @Sendable () -> Void) async {
        sleepGeneration += 1; policy.willSleep(recoverMountedDisk: disk != nil || busy); log("sleep requested")
        let deadline = ProcessInfo.processInfo.systemUptime + 23
        // A pending connect/probe must finish first; never race mount and detach.
        while busy && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !busy {
            if disk != nil {
                _ = await disconnect(manual: false, timeout: max(0.1, deadline - ProcessInfo.processInfo.systemUptime))
            }
        } else { policy.unsafeDisconnect(); needsAttention = true; await persist() }
        if disk != nil || busy || needsAttention { policy.unsafeDisconnect(); needsAttention = true; await persist(); status = "Сон начался до завершения извлечения. Автоподключение остановлено."; log("sleep preparation incomplete") }
        else { status = "Диск извлечён перед сном. После пробуждения буду ждать iSCSI-сервер."; log("sleep prepared cleanly") }
        acknowledge()
    }
    func didWake() {
        sleepGeneration += 1; lastWake = Date(); policy.woke(now: Date()); log("wake received")
        if policy.needsAttention || disk != nil {
            policy.unsafeDisconnect(); needsAttention = true
            status = policy.recoveryAfterSleep && automatic
                ? "Проверка существующего подключения после сна…"
                : "Осталось подключение после сна. Закрой файлы и нажми «Извлечь диск»."
        } else { status = "Ожидание доступа к iSCSI-серверу. Сеть или VPN можно подключить позже." }
        Task { await persist() }
    }
    private func tick() async {
        guard !busy, !checking, !policy.sleeping else { return }
        checking = true
        defer { checking = false }
        if networkAvailable && policy.shouldRecoverAfterSleep(now: Date(), mounted: disk != nil, busy: busy) {
            if let wake = lastWake, disk != nil {
                do {
                    switch try await connection.wakeHealth(since: wake) {
                    case .healthy:
                        policy.retainedAfterSleep(); needsAttention = policy.needsAttention
                        status = "Диск доступен после сна. Существующее подключение сохранено."
                        log("wake: existing session confirmed healthy; no detach")
                        await persist(); return
                    case .reconnecting:
                        status = "Ожидание восстановления связи с NAS. Диск остаётся подключённым."
                        return
                    case .waiting:
                        if Date().timeIntervalSince(wake) < 25 {
                            status = "Проверка существующего подключения после сна…"; return
                        }
                    case .failed: break
                    }
                } catch { log("wake session check failed") }
            }
            // Retry only an ordinary detach. Never force-unmount, bypass the
            // filesystem flush, replay a write, or mount over the old session.
            if await disconnect(manual: false, timeout: 15) {
                log("wake recovery: previous attachment safely removed")
                if automatic { await attemptConnection(manual: false) }
            } else {
                policy.failed(now: Date())
                status = "После сна диск пока занят или не отвечает. Закрой файлы и окна просмотра; безопасное восстановление повторится автоматически."
            }
            return
        }
        if disk != nil {
            let observed = disk?.runtimeDirectory
            do {
                let health = try await connection.health()
                guard !busy, disk?.runtimeDirectory == observed else { return }
                switch health {
                case .healthy:
                    if bridgeReconnecting {
                        bridgeReconnecting = false
                        status = "Связь с NAS восстановлена. Диск остался подключённым."
                    }
                case .reconnecting:
                    bridgeReconnecting = true
                    status = "Ожидание восстановления связи с NAS. Диск остаётся подключённым."
                case .failed:
                    if !needsAttention { log("transport lost; automatic reconnect blocked") }
                    policy.unsafeDisconnect(); needsAttention = true
                    status = "Связь с iSCSI-сервером потеряна. Запись остановлена; извлеки диск перед переподключением."
                    await persist()
                case .ejected:
                    _ = await disconnect(manual: true)
                }
            } catch { log("health check failed") }
        } else if networkAvailable && policy.shouldConnect(now: Date(), mounted: false, busy: busy) {
            await attemptConnection(manual: false)
        } else if !networkAvailable && automatic && !needsAttention {
            status = "Нет сети. Диск отключён; жду доступа к iSCSI-серверу."
        }
    }
    func selectTarget(_ name: String) {
        guard !busy, disk == nil, !needsAttention, target != name else { return }
        automatic = false; policy.manualStop()
        target = name; details = ""
        status = "Target выбран. Проверь номер LUN и нажми «Проверить LUN» перед подключением."
        Task { await persist() }
    }
    func run(discovery: Bool) {
        guard !busy, disk == nil, !policy.sleeping, let config = configuration(), let lunNumber = UInt16(lun) else { return }
        busy = true; details = ""; status = "Подключение к iSCSI-серверу…"
        let iqn = target
        Task {
            do {
                let result = try await Task.detached { () -> ([Target], LocalizedText) in
                    let session = try Session(configuration: config); defer { session.close() }
                    try session.login(target: discovery ? nil : iqn)
                    if discovery { return (try session.discover(), "") }
                    try session.requireAvailableLUN(lunNumber)
                    let info = try session.inspect(lun: lunNumber)
                    return ([], "\(info.vendor) \(info.model) • \(info.byteCount) байт • блок \(info.blockSize) байт")
                }.value
                if discovery { targets = result.0; status = "Найдено Target: \(targets.count)." }
                else { details = result.1; status = "LUN доступен." }
            } catch { status = LocalizedText(error: error) }
            busy = false
        }
    }
}
