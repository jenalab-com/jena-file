import AppKit

/// 기획서 §7.1 quick-connect bar. Protocol picker and bastion arrive in M3 / MVP 2차.
final class QuickConnectBar: NSView {
    let host = NSTextField()
    let user = NSTextField()
    let password = NSSecureTextField()
    let port = NSTextField()
    let button = NSButton(title: "접속", target: nil, action: nil)
    var onSubmit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.placeholderString = "호스트 (user@host:port도 가능)"
        user.placeholderString = "사용자"
        password.placeholderString = "비밀번호"
        port.placeholderString = "22"
        for field in [host, user, password, port] {
            field.target = self
            field.action = #selector(submit)
        }
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(submit)

        let row = NSStackView(views: [
            label("호스트"), host, label("사용자"), user, label("비밀번호"), password, label("포트"), port, button,
        ])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            user.widthAnchor.constraint(equalToConstant: 110),
            password.widthAnchor.constraint(equalToConstant: 130),
            port.widthAnchor.constraint(equalToConstant: 56),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setConnected(_ connected: Bool, busy: Bool) {
        button.title = connected ? "끊기" : "접속"
        button.isEnabled = !busy
        for field in [host, user, password, port] { field.isEnabled = !connected && !busy }
    }

    @objc private func submit() { onSubmit?() }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
    }
}
