import UIKit

/// One saved connection: name, voxl URL and password, and the High Performance switch
/// with its Mac username, password (Keychain), port and stream options.
final class HostSettingsViewController: UITableViewController, UITextFieldDelegate {
    private let original: Host
    private var host: Host
    private let notice: String?

    private let nameField = UITextField()
    private let urlField = UITextField()
    private let passwordField = UITextField()
    private let userField = UITextField()
    private let hpPasswordField = UITextField()
    private let portField = UITextField()
    private let hpSwitch = UISwitch()
    private let muteSwitch = UISwitch()
    private let statsSwitch = UISwitch()
    private let naturalSwitch = UISwitch()

    private enum Row { case name, url, password, hp, user, hpPassword, port, mute, stats, natural }
    private var sections: [[Row]] {
        var hpRows: [Row] = [.hp]
        if hpSwitch.isOn { hpRows += [.user, .hpPassword, .port] }
        var out: [[Row]] = [[.name, .url, .password], hpRows]
        if hpSwitch.isOn { out.append([.mute, .stats]) }
        out.append([.natural])
        return out
    }

    init(host: Host, notice: String? = nil) {
        original = host; self.host = host; self.notice = notice
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = host.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
        setUp(nameField, "Name", host.name)
        setUp(urlField, "wss://host:port/ws", host.url, url: true)
        setUp(passwordField, "voxl password (unchanged)", nil, secure: true)
        setUp(userField, "Mac username", host.hpUsername, url: true)
        setUp(hpPasswordField, Hosts.hpPassword(for: host) == nil ? "Mac password" : "Mac password (saved)", nil, secure: true)
        setUp(portField, "5900", host.hpPort.map(String.init) ?? (host.isHPSS ? String(host.hpPortValue) : nil))
        portField.keyboardType = .numberPad
        hpSwitch.isOn = host.usesHP
        hpSwitch.isEnabled = !host.isHPSS
        hpSwitch.accessibilityIdentifier = "hpSwitch"
        hpSwitch.addAction(UIAction { [weak self] _ in self?.tableView.reloadData() }, for: .valueChanged)
        muteSwitch.isOn = host.hpMuted
        statsSwitch.isOn = host.hpShowStats
        naturalSwitch.isOn = InputMap.naturalScrolling
        naturalSwitch.accessibilityIdentifier = "naturalScrolling"
        naturalSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            InputMap.naturalScrolling = self.naturalSwitch.isOn
        }, for: .valueChanged)
        if host.isHPSS { userField.isEnabled = false; portField.isEnabled = false }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func setUp(_ f: UITextField, _ placeholder: String, _ text: String?, secure: Bool = false, url: Bool = false) {
        f.placeholder = placeholder; f.text = text
        f.isSecureTextEntry = secure
        if secure { f.textContentType = .password }
        if url || secure { f.autocapitalizationType = .none; f.autocorrectionType = .no }
        if url { f.keyboardType = .URL }
        f.clearButtonMode = .whileEditing
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
    }

    func textFieldShouldReturn(_ f: UITextField) -> Bool { f.resignFirstResponder(); return true }

    override func numberOfSections(in t: UITableView) -> Int { sections.count }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].count }

    override func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? {
        switch sections[s].first {
        case .name: return "voxl"
        case .hp: return "High Performance mode"
        case .mute: return "High Performance options"
        case .natural: return "On this iPhone"
        default: return nil
        }
    }

    override func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        switch sections[s].first {
        case .hp:
            if host.isHPSS { return "This is an hpss:// address, so it always uses High Performance mode. Add the Mac's voxl address instead to be able to switch." }
            return hpSwitch.isOn
                ? "Uses macOS Screen Sharing (High Performance: HEVC 4:4:4, up to 4K) on the same Mac instead of voxl. Turn on Screen Sharing on the Mac and sign in with your Mac account. If it fails you can switch back to voxl from the session."
                : "Off: the normal voxl client. On: macOS Screen Sharing's High Performance mode to the same Mac."
        case .mute:
            return "Mac audio stays muted unless you turn it on, so it doesn't echo when you're next to the Mac."
        case .natural:
            return "Natural scrolling matches a Mac trackpad: content follows your fingers. This applies in both voxl and High Performance mode. You can also change it from the session toolbar."
        default:
            return nil
        }
    }

    override func tableView(_ t: UITableView, viewForHeaderInSection s: Int) -> UIView? {
        guard s == 0, let notice else { return nil }
        let l = UILabel()
        l.text = notice; l.numberOfLines = 0
        l.font = .preferredFont(forTextStyle: .footnote); l.textColor = .systemOrange
        let v = UIView(); v.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            l.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        return v
    }

    override func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let row = sections[i.section][i.row]
        func field(_ label: String, _ f: UITextField) {
            let l = UILabel(); l.text = label; l.textColor = .label
            l.setContentHuggingPriority(.required, for: .horizontal)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 118).isActive = true
            f.removeFromSuperview()
            let stack = UIStackView(arrangedSubviews: [l, f]); stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 11),
                stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -11),
            ])
        }
        func toggle(_ label: String, _ sub: String?, _ sw: UISwitch) {
            var c = cell.defaultContentConfiguration(); c.text = label; c.secondaryText = sub
            c.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = c
            cell.accessoryView = sw
        }
        switch row {
        case .name: field("Name", nameField)
        case .url: field("Address", urlField)
        case .password: field("Password", passwordField)
        case .hp: toggle("High Performance mode", hpSwitch.isOn ? "macOS Screen Sharing" : "Using voxl", hpSwitch)
        case .user: field("Mac user", userField)
        case .hpPassword: field("Mac password", hpPasswordField)
        case .port: field("Port", portField)
        case .mute: toggle("Mute Mac audio", nil, muteSwitch)
        case .stats: toggle("Stats overlay", "fps, bitrate, latency", statsSwitch)
        case .natural: toggle("Natural scrolling", "Like a Mac trackpad", naturalSwitch)
        }
        return cell
    }

    private func save() {
        view.endEditing(true)
        guard let url = Hosts.normalize(urlField.text ?? "") else {
            return alert("That isn't a host or wss:// URL (without a password in it). Unencrypted ws:// works only on the local network.")
        }
        var list = Hosts.all
        if list.contains(where: { $0.url == url && $0.url != original.url }) { return alert("That URL is already in the list.") }
        let user = (userField.text ?? "").trimmingCharacters(in: .whitespaces)
        let portText = (portField.text ?? "").trimmingCharacters(in: .whitespaces)
        if hpSwitch.isOn && !host.isHPSS {
            if user.isEmpty { return alert("High Performance mode needs the Mac's username (the account you log in to the Mac with).") }
            if !portText.isEmpty && UInt16(portText) == nil { return alert("The port should be a number like 5900.") }
        }
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        var h = original
        h.name = name.isEmpty ? (URL(string: url)?.host ?? url) : name
        h.url = url
        if !h.isHPSS {
            h.hp = hpSwitch.isOn
            h.hpUser = user.isEmpty ? nil : user
            h.hpPort = portText.isEmpty ? nil : Int(portText)
        }
        h.hpMute = muteSwitch.isOn
        h.hpStats = statsSwitch.isOn
        // Passwords follow the URL (they're keyed by it); blank fields keep the saved ones.
        if url != original.url {
            Hosts.setPassword(Hosts.password(for: original.url), for: url)
            Hosts.setPassword(nil, for: original.url)
            Hosts.setHPPassword(Hosts.hpPassword(for: original), for: h)
            Hosts.setHPPassword(nil, for: original)
        }
        if let pw = passwordField.text, !pw.isEmpty { Hosts.setPassword(pw, for: url) }
        if let pw = hpPasswordField.text, !pw.isEmpty { Hosts.setHPPassword(pw, for: h) }
        if let i = list.firstIndex(where: { $0.url == original.url }) { list[i] = h } else { list.append(h) }
        Hosts.all = list
        navigationController?.popViewController(animated: true)
    }

    private func alert(_ text: String) {
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
