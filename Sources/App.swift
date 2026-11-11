import UIKit
import Security

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        SceneConfiguration.configuration(for: connectingSceneSession)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        Hosts.seedFromEnvironment()
        let w = UIWindow(windowScene: scene)
        // HP module self-test harness: launch with VOXL_HP_SELFTEST=1 to run the
        // offline HP checks and show results on screen (used for Simulator verification).
        if ProcessInfo.processInfo.environment["VOXL_HP_SELFTEST"] == "1" {
            w.rootViewController = HPSelfTest.makeView()
            w.makeKeyAndVisible(); window = w
            return
        }
        let nav = UINavigationController(rootViewController: HostPickerViewController())
        w.rootViewController = nav
        w.makeKeyAndVisible()
        window = w
        // iOS 27+ (looked up at runtime): unique external-display content instead of a mirror.
        _ = VPRegisterExternalSceneAccessory(nav, ExternalSceneDelegate.self)
        // Testing from a Mac (devicectl launch --environment-variables): VOXL_SELFTEST=1
        // checks the decoders, VOXL_AUTOCONNECT=<part of a saved URL> opens that host.
        let env = ProcessInfo.processInfo.environment
        if env["VOXL_SELFTEST"] == "1" { Diagnostics.displayTest(in: w) }
        if let want = env["VOXL_AUTOCONNECT"], !want.isEmpty,
           let host = Hosts.all.first(where: { $0.url.contains(want) }) {
            Diagnostics.note("autoconnect", host.url)
            nav.pushViewController(RemoteViewController(host: host), animated: false)
        }
    }
}

struct Host: Codable, Equatable {
    var name: String
    var url: String
}

/// Saved hosts. The list lives in UserDefaults, each host's password in the Keychain
/// (keyed by URL). First run can be seeded from the launch environment (VOXL_URL,
/// VOXL_PASSWORD) so a password never has to be typed or shown.
enum Hosts {
    static var all: [Host] {
        get {
            UserDefaults.standard.data(forKey: "hosts").flatMap { try? JSONDecoder().decode([Host].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "hosts") }
    }

    static func seedFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["VOXL_URL"].flatMap(normalize) else { return }
        if !all.contains(where: { $0.url == url }) { all.append(Host(name: URL(string: url)?.host ?? url, url: url)) }
        if let p = env["VOXL_PASSWORD"], !p.isEmpty { setPassword(p, for: url) }
    }

    /// "mac.ts.net:6901" or "https://mac.ts.net" -> "wss://mac.ts.net:6901/ws". Nil if unusable.
    static func normalize(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") { t = "wss://" + t }
        // A password belongs in the Keychain, never in a stored, displayed URL.
        guard var c = URLComponents(string: t), c.host?.isEmpty == false, c.user == nil, c.password == nil
        else { return nil }
        switch c.scheme?.lowercased() {
        case "https", "wss": c.scheme = "wss"
        // iOS allows unencrypted connections only on the local network (ATS).
        case "http", "ws":
            guard isLocal(c.host!) else { return nil }
            c.scheme = "ws"
        default: return nil
        }
        if c.path.isEmpty || c.path == "/" { c.path = "/ws" }
        return c.string
    }

    /// An IP address, a .local name or a single-label name ("my-mac").
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        return !h.contains(".") || h.hasSuffix(".local") || h.contains(":") || h.allSatisfy { $0.isNumber || $0 == "." }
    }

    static let privacyURL = URL(string: "https://github.com/ericmigi/voxl-pocket-ios#privacy")!

    static func password(for url: String) -> String? { keychain("pw:" + url) }
    static func setPassword(_ pw: String?, for url: String) { setKeychain("pw:" + url, pw) }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "voxl",
         kSecAttrAccount as String: account]
    }

    private static func keychain(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func setKeychain(_ account: String, _ value: String?) {
        SecItemDelete(query(account) as CFDictionary)
        guard let v = value, !v.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// First screen: the saved hosts. Tap one to connect; swipe to edit or delete; + adds a URL.
final class HostPickerViewController: UITableViewController {
    private var hosts = Hosts.all

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Voxl Pocket"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in
            self?.edit(nil)
        })
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Privacy", primaryAction: UIAction { _ in
            UIApplication.shared.open(Hosts.privacyURL)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "host")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        hosts = Hosts.all
        tableView.reloadData()
    }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { hosts.count }

    override func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        hosts.isEmpty ? "Tap + to add a computer running the voxl server." : nil
    }

    override func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "host", for: i)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = hosts[i.row].name
        c.secondaryText = hosts[i.row].url
        c.secondaryTextProperties.color = .secondaryLabel
        c.image = UIImage(systemName: "desktopcomputer")
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ t: UITableView, didSelectRowAt i: IndexPath) {
        t.deselectRow(at: i, animated: true)
        let host = hosts[i.row]
        if Hosts.password(for: host.url) == nil {
            askPassword(host) { [weak self] in self?.connect(host) }
        } else {
            connect(host)
        }
    }

    override func tableView(_ t: UITableView, trailingSwipeActionsConfigurationForRowAt i: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            Hosts.setPassword(nil, for: self.hosts[i.row].url)
            self.hosts.remove(at: i.row)
            Hosts.all = self.hosts
            t.deleteRows(at: [i], with: .automatic)
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, done in
            self?.edit(i.row)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }

    private func connect(_ host: Host) {
        navigationController?.pushViewController(RemoteViewController(host: host), animated: true)
    }

    private func askPassword(_ host: Host, then: @escaping () -> Void) {
        let a = UIAlertController(title: host.name, message: "Password for \(host.url)", preferredStyle: .alert)
        a.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "Password"; $0.textContentType = .password }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Connect", style: .default) { [weak a] _ in
            guard let pw = a?.textFields?[0].text, !pw.isEmpty else { return }
            Hosts.setPassword(pw, for: host.url)
            then()
        })
        present(a, animated: true)
    }

    /// Adds a host (nil) or edits hosts[index]. A blank password keeps the saved one.
    private func edit(_ index: Int?) {
        let old = index.map { hosts[$0] }
        let a = UIAlertController(title: old == nil ? "Add Host" : "Edit Host", message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = "Name"; $0.text = old?.name }
        a.addTextField {
            $0.placeholder = "wss://host:port/ws"; $0.text = old?.url
            $0.keyboardType = .URL; $0.autocapitalizationType = .none; $0.autocorrectionType = .no
        }
        a.addTextField {
            $0.isSecureTextEntry = true; $0.textContentType = .password
            $0.placeholder = old == nil ? "Password" : "Password (unchanged)"
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
            guard let self, let f = a?.textFields, let url = Hosts.normalize(f[1].text ?? "") else {
                self?.alert("That isn't a host or wss:// URL (without a password in it). Unencrypted ws:// works only on the local network.")
                return
            }
            // One password per URL, so each URL appears once.
            if self.hosts.indices.contains(where: { $0 != index && self.hosts[$0].url == url }) {
                self.alert("That URL is already in the list.")
                return
            }
            let name = (f[0].text ?? "").trimmingCharacters(in: .whitespaces)
            let host = Host(name: name.isEmpty ? (URL(string: url)?.host ?? url) : name, url: url)
            let pw = f[2].text ?? ""
            if let old, old.url != url {
                if pw.isEmpty { Hosts.setPassword(Hosts.password(for: old.url), for: url) }
                Hosts.setPassword(nil, for: old.url)
            }
            if !pw.isEmpty { Hosts.setPassword(pw, for: url) }
            if let index { self.hosts[index] = host } else { self.hosts.append(host) }
            Hosts.all = self.hosts
            self.tableView.reloadData()
        })
        present(a, animated: true)
    }

    private func alert(_ text: String) {
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
