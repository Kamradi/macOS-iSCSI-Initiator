import XCTest
import AppLocalization
import ISCSICore
import ConnectionLifecycle

final class LocalizationTests: XCTestCase {
    func testExistingStatusChangesLanguageWithoutRecreatingIt() {
        let status: LocalizedText = "Диск безопасно извлечён."
        XCTAssertEqual(status.render(.english), "Disk safely ejected.")
        XCTAssertEqual(status.render(.russian), "Диск безопасно извлечён.")
        XCTAssertEqual(status.render(.english), "Disk safely ejected.")
    }
    func testInterpolatedValuesAreNeverTreatedAsTranslationsOrPlaceholders() {
        let value = "disk{1} %@ Русский"
        let status: LocalizedText = "Нет подключения к \(value):\(3260). Проверь адрес, сеть и службу iSCSI."
        XCTAssertEqual(status.render(.english), "Cannot connect to disk{1} %@ Русский:3260. Check the address, network and iSCSI service.")
    }
    func testNestedAppErrorsChangeWithTheirStatus() {
        let error = ISCSIError.message("Некорректный IQN")
        let status: LocalizedText = "Подключение не завершено. Требуется извлечение: \(LocalizedText(error: error))"
        XCTAssertEqual(status.render(.english), "Connection did not complete. Eject the disk: Invalid IQN")
        XCTAssertEqual(status.render(.russian), "Подключение не завершено. Требуется извлечение: Некорректный IQN")
    }
    func testSystemLanguageAndFallback() {
        XCTAssertEqual(AppLanguage.resolveSystem(["ru-RU", "en-US"]), .russian)
        XCTAssertEqual(AppLanguage.resolveSystem(["en-GB", "ru"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem(["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystem([]), .english)
    }
    func testPreferencePersistsAndUnknownPreferenceFallsBack() {
        let name = "LocalizationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppLanguage.read(from: defaults), .system)
        AppLanguage.english.save(to: defaults)
        XCTAssertEqual(AppLanguage.read(from: defaults), .english)
        AppLanguage.russian.save(to: defaults)
        XCTAssertEqual(AppLanguage.read(from: defaults), .russian)
        defaults.set("unknown", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.read(from: defaults), .system)
    }
    func testTimeoutAndExternalErrors() {
        let timeout = CommandError.timedOut("hdiutil")
        XCTAssertEqual(LocalizedText(error: timeout).render(.english), "The hdiutil operation timed out. No forced eject was performed.")
        let native = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "External system error {0}"])
        XCTAssertEqual(LocalizedText(error: native).render(.english), "External system error {0}")
    }
    func testEnglishCatalogHasMatchingArgumentsAndNoRussianFallback() {
        for (key, value) in EnglishCatalog.values {
            XCTAssertNil(value.range(of: "[А-Яа-яЁё]", options: .regularExpression), key)
            let regex = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
            func placeholders(_ text: String) -> Set<String> {
                Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
            }
            XCTAssertEqual(placeholders(key), placeholders(value), key)
        }
    }
}
