import Foundation
import JenaFileCore

/// Transfer pane model: latest info per transfer, in queue order.
@MainActor
public final class TransferList {
    public private(set) var items: [TransferInfo] = []
    private var index: [UInt64: Int] = [:]
    public var onChange: (() -> Void)?
    /// A transfer finished: refresh the pane showing its destination folder.
    public var onFinished: ((TransferInfo) -> Void)?

    public init() {}

    public func update(_ info: TransferInfo) {
        if let i = index[info.id] {
            let wasDone = items[i].state == .done
            items[i] = info
            if info.state == .done, !wasDone { onFinished?(info) }
        } else {
            index[info.id] = items.count
            items.append(info)
            if info.state == .done { onFinished?(info) }
        }
        onChange?()
    }

    /// Mirrors `clear_finished_transfers` in the core.
    public func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .skipped || $0.state == .cancelled }
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        onChange?()
    }

    public var hasActive: Bool {
        items.contains { $0.state == .queued || $0.state == .running || $0.state == .waiting }
    }

    public var summary: String {
        let running = items.filter { $0.state == .running }.count
        let queued = items.filter { $0.state == .queued }.count
        let done = items.filter { $0.state == .done }.count
        let failed = items.filter { if case .failed = $0.state { true } else { false } }.count
        var parts = [L("진행 %@", "\(running)"), L("대기 %@", "\(queued)"), L("완료 %@", "\(done)")]
        if failed > 0 { parts.append(L("실패 %@", "\(failed)")) }
        return parts.joined(separator: " · ")
    }
}

public extension Format {
    static func speed(_ bytesPerSec: UInt64) -> String {
        bytesPerSec == 0 ? "" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytesPerSec), countStyle: .file) + "/s"
    }

    /// `m:ss` / `h:mm:ss` left at the current speed.
    static func eta(remaining: UInt64, bytesPerSec: UInt64) -> String {
        guard bytesPerSec > 0 else { return "" }
        let s = Int((Double(remaining) / Double(bytesPerSec)).rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func state(_ s: TransferState) -> String {
        switch s {
        case .queued: L("대기")
        case .running: L("진행 중")
        case .paused: L("일시정지")
        case .waiting: L("연결 대기")
        case .done: L("완료")
        case .skipped: L("건너뜀")
        case .cancelled: L("취소됨")
        case .failed(let message): L("실패: %@", "\(message)")
        }
    }
}
