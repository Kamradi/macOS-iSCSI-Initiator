import AppLocalization
import SwiftUI
import ISCSICore

struct ContentView: View {
    @StateObject private var model = Model.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iSCSI Initiator").font(.largeTitle.bold())
            Text(model.tr("iSCSI-диск для Finder • экспериментальная версия")).foregroundStyle(.secondary)
            Toggle(model.tr("Автоматически подключать, когда сервер доступен"), isOn: $model.automatic)
                .onChange(of: model.automatic) { _, _ in model.automaticChanged() }
                .disabled(model.busy)
            Picker(model.tr("Язык"), selection: $model.language) {
                Text(model.tr("Системный")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("Русский").tag(AppLanguage.russian)
            }.onChange(of: model.language) { _, _ in model.languageChanged() }
            Form {
                TextField(model.tr("Адрес NAS / сервера"), text: $model.host)
                TextField(model.tr("Порт"), text: $model.port)
                TextField("Target IQN", text: $model.target)
                TextField("LUN", text: $model.lun)
                Toggle(model.tr("Авторизация CHAP"), isOn: $model.chap)
                if model.chap {
                    TextField(model.tr("Имя CHAP"), text: $model.username)
                    SecureField(model.tr("Пароль CHAP"), text: $model.password)
                    Text(model.tr("Пароль используется в памяти и не сохраняется.")).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy || model.disk != nil)
            HStack {
                Button(model.tr("Найти Target")) { model.run(discovery: true) }
                Button(model.tr("Проверить LUN")) { model.run(discovery: false) }.buttonStyle(.borderedProminent)
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy || model.disk != nil)
            HStack {
                if let disk = model.disk {
                    Button(model.tr("Извлечь диск")) { Task { _ = await model.disconnect() } }
                    if let volume = disk.volume {
                        Button(model.tr("Открыть в Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: volume)) }.buttonStyle(.borderedProminent)
                    }
                    Text(disk.device).font(.caption).foregroundStyle(.secondary)
                } else if model.needsAttention {
                    Button(model.tr("Проверить прежнее подключение")) { Task { await model.inspectPreviousConnection() } }
                } else {
                    Button(model.tr("Подключить диск")) { model.connect() }.buttonStyle(.borderedProminent)
                }
            }.disabled(model.busy)
            if !model.targets.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.targets) { target in
                            Button { model.selectTarget(target.name) } label: {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Image(systemName: model.target == target.name ? "checkmark.circle.fill" : "circle")
                                        Text(target.name).textSelection(.enabled)
                                    }
                                    Text(target.portals.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).padding(6)
                        }
                    }
                }.frame(maxHeight: 110).disabled(model.busy || model.disk != nil || model.needsAttention)
            }
            Text(model.tr(model.status)).textSelection(.enabled)
            if !model.details.key.isEmpty {
                ScrollView { Text(model.tr(model.details)).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 130)
            }
            Spacer(minLength: 0)
            Text(model.tr("Перед сном диск извлекается автоматически. Если сервер недоступен, приложение ждёт подключения. Не отключай сеть во время записи."))
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
        MenuBarExtra("iSCSI Initiator", systemImage: "externaldrive") { StatusMenu() }
    }
}

struct StatusMenu: View {
    @ObservedObject private var model = Model.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.tr(model.status))
        Divider()
        Button(model.tr("Открыть iSCSI Initiator")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if let volume = model.disk?.volume {
            Button(model.tr("Открыть диск в Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: volume)) }
        }
        if model.disk != nil {
            Button(model.tr("Извлечь диск")) { Task { _ = await model.disconnect() } }.disabled(model.busy)
        } else if model.needsAttention {
            Button(model.tr("Проверить прежнее подключение")) { Task { await model.inspectPreviousConnection() } }.disabled(model.busy)
        } else {
            Button(model.tr("Подключить диск")) { model.connect() }.disabled(model.busy)
        }
        Divider()
        Button(model.tr("Завершить работу")) { NSApp.terminate(nil) }.disabled(model.busy)
    }
}
