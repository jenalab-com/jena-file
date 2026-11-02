import AppKit
import JenaFileKit

/// 기획서 §7.1 quick-connect bar. Bastion is optional (FR-02a: off by default).
/// Pasting an `ssh ...` command into the host field fills the bar (FR-09).
final class QuickConnectBar: NSView {
    let host = NSTextField()
    let user = NSTextField()
    let password = NSSecureTextField()
    let port = NSTextField()
    let via = NSButton(checkboxWithTitle: L("경유"), target: nil, action: nil)
    let bastion = NSTextField()
    let button = NSButton(title: L("접속"), target: nil, action: nil)
    var onSubmit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.placeholderString = L("호스트 (user@host:port도 가능)")
        user.placeholderString = L("사용자")
        password.placeholderString = L("비밀번호")
        port.placeholderString = "22"
        bastion.placeholderString = "bastion: user@host:port"
        via.target = self
        via.action = #selector(viaToggled)
        via.toolTip = L("bastion(점프 서버)를 거쳐 접속해요. 필요할 때만 켜세요.")
        for field in [host, user, password, port, bastion] {
            field.target = self
            field.action = #selector(submit)
        }
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(submit)

        let row = NSStackView(views: [
            label(L("호스트")), host, label(L("사용자")), user, label(L("비밀번호")), password, label(L("포트")), port,
            via, bastion, button,
        ])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            bastion.widthAnchor.constraint(equalToConstant: 190),
            user.widthAnchor.constraint(equalToConstant: 110),
            password.widthAnchor.constraint(equalToConstant: 130),
            port.widthAnchor.constraint(equalToConstant: 56),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var editable = true

    func setConnected(_ connected: Bool, busy: Bool) {
        button.title = connected ? L("끊기") : L("접속")
        button.isEnabled = !busy
        editable = !connected && !busy
        for c in [host, user, password, port, via] as [NSControl] { c.isEnabled = editable }
        bastion.isEnabled = editable && via.state == .on
    }

    /// Bastion `user@host[:port]` when 경유 is on.
    var bastionText: String? {
        via.state == .on ? bastion.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }

    func apply(_ fill: QuickConnectFill) {
        host.stringValue = fill.host
        user.stringValue = fill.user
        port.stringValue = fill.port
        via.state = fill.bastion == nil ? .off : .on
        bastion.stringValue = fill.bastion ?? ""
        bastion.isEnabled = editable && via.state == .on
        window?.makeFirstResponder(fill.user.isEmpty ? user : password)
    }

    @objc private func viaToggled() {
        bastion.isEnabled = editable && via.state == .on
        if via.state == .on { window?.makeFirstResponder(bastion) }
    }

    @objc private func submit() { onSubmit?() }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
    }
}
