import UIKit

/// The non-interactive external display (USB-C/HDMI or AirPlay), when iOS has given
/// the app its own scene instead of mirroring the phone.
enum ExternalDisplay {
    static weak var window: UIWindow?
    static weak var delegate: ExternalDisplayDelegate?

    static var isActive: Bool { window != nil }

    /// Native pixel size of the external window, or nil if there isn't one.
    static func nativePixels() -> (Int, Int)? {
        guard let w = window else { return nil }
        let scale = w.windowScene?.screen.nativeScale ?? w.traitCollection.displayScale
        let b = w.bounds
        let px = InputMap.nativePixels(widthPoints: b.width, heightPoints: b.height, scale: scale)
        return px.0 > 0 && px.1 > 0 ? px : nil
    }

    static var hostView: UIView? { window?.rootViewController?.view }

    static var screenScale: CGFloat {
        window?.windowScene?.screen.nativeScale ?? window?.traitCollection.displayScale ?? 1
    }
}

protocol ExternalDisplayDelegate: AnyObject {
    func externalDisplayDidConnect(_ window: UIWindow)
    func externalDisplayDidDisconnect()
    func externalDisplayDidLayout(_ window: UIWindow)
}

/// Scene on a connected monitor. The window is shown but never made key: the phone
/// stays the interactive surface (keyboard, trackpad, chrome).
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = ExternalDesktopViewController()
        w.isHidden = false
        window = w
        ExternalDisplay.window = w
        ExternalDisplay.delegate?.externalDisplayDidConnect(w)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if window != nil {
            window = nil
            ExternalDisplay.window = nil
            ExternalDisplay.delegate?.externalDisplayDidDisconnect()
        }
    }
}

final class ExternalDesktopViewController: UIViewController {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let w = view.window { ExternalDisplay.delegate?.externalDisplayDidLayout(w) }
    }
}

/// Picks the right scene configuration for a session. Declared in Info.plist as well.
enum SceneConfiguration {
    static func configuration(for session: UISceneSession) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let c = UISceneConfiguration(name: "External", sessionRole: session.role)
            c.delegateClass = ExternalSceneDelegate.self
            return c
        }
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}
