//
//  SceneDelegate.swift
//  Artemis
//
//  Hosts the SwiftUI app in the window, presents the stream view from it and
//  forwards home-screen quick actions. Apps built with the iOS 27 SDK must use scenes.
//

import SwiftUI
import UIKit

@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let store = ComputerStore(demo: DemoData.isEnabled)
    /// The demo opened with Try the Demo, shown in place of `store` until Exit Demo.
    private var tryingDemo: ComputerStore?
    private var hosting: UIHostingController<AnyView>?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        if DemoData.disablesAnimations {
            UIView.setAnimationsEnabled(false)
        }
        Typography.register()
        Typography.styleNavigationBars()
        NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { _ in
            Typography.styleNavigationBars()
        }

        prepare(store)
        let hosting = UIHostingController(rootView: root(store))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        self.hosting = hosting
        // Code from before scenes looks for the window on the app delegate
        (UIApplication.shared.delegate as? AppDelegate)?.window = window

        store.start()

        if let shortcut = connectionOptions.shortcutItem {
            store.handleShortcut(shortcut)
        }
    }

    /// Outermost, so sheets and alerts' text without a style of its own take the app's typeface too.
    private func root(_ store: ComputerStore) -> AnyView {
        AnyView(RootView().environment(store).artemisFont(.body))
    }

    private func prepare(_ store: ComputerStore) {
        store.presentStream = { [weak self, unowned store] config, onExit in
            guard let hosting = self?.hosting else { return }
            let stream: UIViewController
            if store.isDemo && !DemoData.usesRealStream {
                // A picture of a desktop that records the input instead of a stream
                stream = DemoDesktopViewController(appName: config.appName ?? "Desktop", onExit: { onExit(true) })
            } else {
                stream = ArtemisBridge.streamViewController(with: config, onExit: onExit)
            }
            var presenter: UIViewController = hosting
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(stream, animated: true)
        }
        // The demo (-ArtemisDemo YES) is already one; Try the Demo is for the real app
        if !DemoData.isEnabled || store.isTryingDemo {
            store.switchDemo = { [weak self] on in self?.showDemo(on) }
        }
    }

    /// Try the Demo (on) and Exit Demo (off): the demo PCs for this launch, nothing saved.
    private func showDemo(_ on: Bool) {
        DemoData.isTrying = on
        if on {
            let demo = ComputerStore(demo: true, trying: true)
            prepare(demo)
            demo.start()
            tryingDemo = demo
            hosting?.rootView = root(demo)
        } else {
            tryingDemo = nil
            hosting?.rootView = root(store)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if tryingDemo != nil { showDemo(false) }
        completionHandler(store.handleShortcut(shortcutItem))
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.saveContext()
    }
}
