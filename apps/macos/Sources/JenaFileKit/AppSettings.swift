import Foundation
import JenaFileCore

/// User settings (설정 window + 보기 menu), in UserDefaults.
public final class AppSettings {
    /// What to do when a transfer's destination exists.
    public enum OnConflict: String, CaseIterable {
        case ask, overwrite, rename, skip

        public var title: String {
            switch self {
            case .ask: L("매번 묻기")
            case .overwrite: L("덮어쓰기")
            case .rename: L("이름 바꿔 저장")
            case .skip: L("건너뛰기")
            }
        }

        public var action: ConflictAction? {
            switch self {
            case .ask: nil
            case .overwrite: .overwrite
            case .rename: .rename
            case .skip: .skip
            }
        }
    }

    private let d: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: [
            "transferLimit": 3, "onConflict": OnConflict.ask.rawValue, "showLocalHidden": false,
            "showLog": true, "showTransfers": true, "showTerminal": true, "logErrorsOnly": false,
        ])
    }

    /// Files at once per connection, 1…10.
    public var transferLimit: Int {
        get { min(max(d.integer(forKey: "transferLimit"), 1), 10) }
        set { d.set(min(max(newValue, 1), 10), forKey: "transferLimit") }
    }

    public var onConflict: OnConflict {
        get { OnConflict(rawValue: d.string(forKey: "onConflict") ?? "") ?? .ask }
        set { d.set(newValue.rawValue, forKey: "onConflict") }
    }

    /// Where the local pane starts. nil = home folder.
    public var localFolder: String? {
        get { d.string(forKey: "localFolder") }
        set { d.set(newValue, forKey: "localFolder") }
    }

    public var showLocalHidden: Bool {
        get { d.bool(forKey: "showLocalHidden") }
        set { d.set(newValue, forKey: "showLocalHidden") }
    }

    public var showLog: Bool {
        get { d.bool(forKey: "showLog") }
        set { d.set(newValue, forKey: "showLog") }
    }

    public var showTransfers: Bool {
        get { d.bool(forKey: "showTransfers") }
        set { d.set(newValue, forKey: "showTransfers") }
    }

    public var showTerminal: Bool {
        get { d.bool(forKey: "showTerminal") }
        set { d.set(newValue, forKey: "showTerminal") }
    }

    public var logErrorsOnly: Bool {
        get { d.bool(forKey: "logErrorsOnly") }
        set { d.set(newValue, forKey: "logErrorsOnly") }
    }
}
