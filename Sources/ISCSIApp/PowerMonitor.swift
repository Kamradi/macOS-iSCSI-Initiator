import Foundation
import IOKit
import IOKit.pwr_mgt

private final class PowerAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledged = false
    private let port: io_connect_t
    private let token: Int
    init(port: io_connect_t, token: Int) { self.port = port; self.token = token }
    func allow() {
        lock.withLock {
            guard !acknowledged else { return }
            acknowledged = true
            IOAllowPowerChange(port, token)
        }
    }
}

/// IOKit gives applications up to 30 seconds to finish preparing for sleep.
/// Lid-close sleep cannot be vetoed: the acknowledgement is bounded to 25 sec.
final class PowerMonitor: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_connect_t = 0
    let onSleep: @Sendable (@escaping @Sendable () -> Void) -> Void
    let onWake: @Sendable () -> Void
    var isRegistered: Bool { root != 0 }
    init(onSleep: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void, onWake: @escaping @Sendable () -> Void) {
        self.onSleep = onSleep; self.onWake = onWake
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, type, argument in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, Int(bitPattern: argument))
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, .main) }
    }
    private func handle(_ type: UInt32, _ token: Int) {
        switch type {
        // IOMessage.h: iokit_common_msg(code) = 0xe0000000 | code.
        // Swift cannot import these function-like C macros.
        case 0xe0000270: IOAllowPowerChange(root, token)
        case 0xe0000280:
            let acknowledgement = PowerAcknowledgement(port: root, token: token)
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { acknowledgement.allow() }
            onSleep { acknowledgement.allow() }
        case 0xe0000300: onWake()
        default: break
        }
    }
    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        if root != 0 { IOServiceClose(root) }
    }
}
