import SwiftUI
import ISCSICore

struct ContentView: View {
    @StateObject private var model = Model.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Synology iSCSI").font(.largeTitle.bold())
            Text("iSCSI-диск для Finder • экспериментальная версия").foregroundStyle(.secondary)
            Toggle("Автоматически подключать, когда Synology доступен", isOn: $model.automatic)
                .onChange(of: model.automatic) { _, _ in model.automaticChanged() }
                .disabled(model.busy)
            Form {
                TextField("Адрес NAS", text: $model.host)
                TextField("Порт", text: $model.port)
                TextField("Target IQN", text: $model.target)
                TextField("LUN", text: $model.lun)
                Toggle("Авторизация CHAP", isOn: $model.chap)
                if model.chap {
                    TextField("Имя CHAP", text: $model.username)
                    SecureField("Пароль CHAP", text: $model.password)
                    Text("Пароль используется в памяти и не сохраняется.").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy || model.disk != nil)
            HStack {
                Button("Найти Target") { model.run(discovery: true) }
                Button("Проверить LUN") { model.run(discovery: false) }.buttonStyle(.borderedProminent)
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy || model.disk != nil)
            HStack {
                if let disk = model.disk {
                    Button("Извлечь диск") { Task { _ = await model.disconnect() } }
                    if let volume = disk.volume {
                        Button("Открыть в Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: volume)) }.buttonStyle(.borderedProminent)
                    }
                    Text(disk.device).font(.caption).foregroundStyle(.secondary)
                } else if model.needsAttention {
                    Button("Проверить прежнее подключение") { Task { await model.inspectPreviousConnection() } }
                } else {
                    Button("Подключить диск") { model.connect() }.buttonStyle(.borderedProminent)
                }
            }.disabled(model.busy)
            if !model.targets.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.targets) { target in
                            Button { model.target = target.name } label: {
                                VStack(alignment: .leading) {
                                    Text(target.name).textSelection(.enabled)
                                    Text(target.portals.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).padding(6)
                        }
                    }
                }.frame(maxHeight: 110)
            }
            Text(model.status).textSelection(.enabled)
            if !model.details.isEmpty {
                ScrollView { Text(model.details).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 130)
            }
            Spacer(minLength: 0)
            Text("Перед сном диск извлекается автоматически. Без домашней сети приложение ждёт доступа к Synology. Не отключай сеть во время записи.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 700, minHeight: 540)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = Model.shared
        if model.busy { return .terminateCancel }
        guard model.disk != nil else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await model.disconnect(manual: false)) }
        return .terminateLater
    }
}
@main struct ISCSIApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup(id: "main") { ContentView() }.windowResizability(.contentMinSize)
        MenuBarExtra("Synology iSCSI", systemImage: "externaldrive") { StatusMenu() }
    }
}

struct StatusMenu: View {
    @ObservedObject private var model = Model.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        Divider()
        Button("Открыть Synology iSCSI") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if let volume = model.disk?.volume {
            Button("Открыть диск в Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: volume)) }
        }
        if model.disk != nil {
            Button("Извлечь диск") { Task { _ = await model.disconnect() } }.disabled(model.busy)
        } else if model.needsAttention {
            Button("Проверить прежнее подключение") { Task { await model.inspectPreviousConnection() } }.disabled(model.busy)
        } else {
            Button("Подключить диск") { model.connect() }.disabled(model.busy)
        }
        Divider()
        Button("Завершить работу") { NSApp.terminate(nil) }.disabled(model.busy)
    }
}
