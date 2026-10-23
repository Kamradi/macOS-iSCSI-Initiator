import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, english = "en", russian = "ru"
    public static let preferenceKey = "interfaceLanguage"
    public static var saved: AppLanguage {
        read(from: .standard)
    }
    public static func read(from defaults: UserDefaults) -> AppLanguage { AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "system") ?? .system }
    public func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }
    public static func resolveSystem(_ preferredLanguages: [String]) -> AppLanguage { preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? .russian : .english }
    public static var current: AppLanguage {
        if let override = ProcessInfo.processInfo.environment["ISCSI_LANGUAGE"], let value = AppLanguage(rawValue: override) { return value.effective }
        return saved.effective
    }
    public var effective: AppLanguage {
        guard self == .system else { return self }
        return Self.resolveSystem(Locale.preferredLanguages)
    }
}

public protocol LocalizableError: Error { var localizedText: LocalizedText { get } }

/// Keep the message template and interpolated values separate so changing the
/// UI language immediately redraws existing statuses and nested app errors.
public struct LocalizedText: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [LocalizedText]
    private let verbatim: Bool
    public init(_ key: String) { self.key = key; arguments = []; verbatim = false }
    public init(stringLiteral value: String) { self.init(value) }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments; verbatim = false
    }
    public init(error: any Error) {
        if let error = error as? any LocalizableError { self = error.localizedText }
        else { self = .literal(error.localizedDescription) }
    }
    public static func literal(_ string: String) -> LocalizedText { LocalizedText(key: string, arguments: [], verbatim: true) }
    private init(key: String, arguments: [LocalizedText], verbatim: Bool) { self.key = key; self.arguments = arguments; self.verbatim = verbatim }
    public func render(_ language: AppLanguage = .current) -> String {
        if verbatim { return key }
        let template = language.effective == .russian ? key : (EnglishCatalog.values[key] ?? key)
        // One-pass substitution: argument contents can never become placeholders.
        var result = "", cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]), arguments.indices.contains(index) {
                result += arguments[index].render(language); cursor = template.index(after: end)
            } else { result.append(template[cursor]); cursor = template.index(after: cursor) }
        }
        return result
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [LocalizedText] = []
        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) { appendInterpolation(LocalizedText.literal(String(describing: value))) }
        public mutating func appendInterpolation(_ value: LocalizedText) { key += "{\(arguments.count)}"; arguments.append(value) }
    }
}
