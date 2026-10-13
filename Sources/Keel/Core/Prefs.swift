import Foundation

/// Preference access through CFPreferences, so detection does not spawn `defaults` per key.
enum Prefs {
    static func appID(_ domain: String) -> CFString {
        (domain == "NSGlobalDomain" || domain == "-g" || domain == "Apple Global Domain") ? kCFPreferencesAnyApplication : domain as CFString
    }
    static func host(_ currentHost: Bool) -> CFString { currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }

    /// Raw value or nil when the key is not set. Absolute plist paths are read from the file.
    static func value(_ domain: String, _ key: String, currentHost: Bool = false) -> Any? {
        if domain.hasPrefix("/") {
            let path = domain.hasSuffix(".plist") ? domain : domain + ".plist"
            return (NSDictionary(contentsOfFile: path) as? [String: Any])?[key]
        }
        let id = appID(domain)
        CFPreferencesSynchronize(id, kCFPreferencesCurrentUser, host(currentHost))
        return CFPreferencesCopyValue(key as CFString, id, kCFPreferencesCurrentUser, host(currentHost))
    }

    /// The value rendered like `defaults read` prints it (booleans as 1/0).
    static func string(_ domain: String, _ key: String, currentHost: Bool = false) -> String? {
        guard let v = value(domain, key, currentHost: currentHost) else { return nil }
        return render(v)
    }

    static func render(_ v: Any) -> String {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
            return n.stringValue
        }
        if let s = v as? String { return s }
        if let a = v as? [Any] { return "(\(a.count) items)" }
        if let d = v as? [String: Any] { return "{\(d.count) keys}" }
        return "\(v)"
    }

    static func type(of v: Any) -> DefaultsType {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool }
            return CFNumberIsFloatType(n) ? .float : .int
        }
        return .string
    }

    static func typed(_ s: String, as type: DefaultsType) -> CFPropertyList {
        switch type {
        case .bool: return (["1", "true", "yes"].contains(s.lowercased())) as CFBoolean
        case .int: return NSNumber(value: Int(s) ?? Int(Double(s) ?? 0))
        case .float: return NSNumber(value: Double(s) ?? 0)
        case .string: return s as CFString
        }
    }

    @discardableResult
    static func write(_ domain: String, _ key: String, _ value: String, type: DefaultsType, currentHost: Bool = false) -> Bool {
        let id = appID(domain)
        CFPreferencesSetValue(key as CFString, typed(value, as: type), id, kCFPreferencesCurrentUser, host(currentHost))
        return CFPreferencesSynchronize(id, kCFPreferencesCurrentUser, host(currentHost))
    }

    @discardableResult
    static func delete(_ domain: String, _ key: String, currentHost: Bool = false) -> Bool {
        let id = appID(domain)
        CFPreferencesSetValue(key as CFString, nil, id, kCFPreferencesCurrentUser, host(currentHost))
        return CFPreferencesSynchronize(id, kCFPreferencesCurrentUser, host(currentHost))
    }
}
