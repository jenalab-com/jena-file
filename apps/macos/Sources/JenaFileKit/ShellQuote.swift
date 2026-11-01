import Foundation

/// LANG to send to remote shells, like Terminal.app + `ssh` SendEnv: ko_KR.UTF-8 etc.
public enum TerminalLocale {
    public static var lang: String { lang(for: Locale.current) }

    public static func lang(for locale: Locale) -> String {
        guard let language = locale.language.languageCode?.identifier,
              let region = locale.region?.identifier else { return "en_US.UTF-8" }
        return "\(language)_\(region).UTF-8"
    }
}

/// POSIX single-quoting, same rule as the core's `shell_quote`.
public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
