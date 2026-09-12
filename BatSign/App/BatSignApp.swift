//
//  BatSignApp.swift
//  BatSign
//

import SwiftUI
import UserNotifications
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Notification banners must appear instantly, even in the foreground.
        UNUserNotificationCenter.current().delegate = self

        UserDefaults.standard.register(defaults: [
            "preventSleep": true,
            "systemNotifications": true,
            "autoSign": true,
            "zipLevel": 6,
        ])

        // Background tasks must be registered before launch finishes.
        BackgroundKeeper.shared.register()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UISceneDelegate {
    func sceneDidDisconnect(_ scene: UIScene) {
        BackgroundKeeper.shared.schedule()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        BackgroundKeeper.shared.schedule()
    }
}

@main
struct BatSignApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var appState = AppState()
    @ObservedObject private var library = AppLibrary.shared
    // Shared singletons: the signing engine, background keeper and UI must
    // all observe the same stores — duplicate instances caused stale state.
    @ObservedObject private var certManager = CertificateManager.shared
    @ObservedObject private var jobQueue = JobQueue.shared
    @ObservedObject private var notificationHub = NotificationHub.shared
    @ObservedObject private var sourceManager = SourceManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(library)
                .environmentObject(certManager)
                .environmentObject(jobQueue)
                .environmentObject(notificationHub)
                .environmentObject(sourceManager)
                .preferredColorScheme(.dark)
                .tint(.batAmber)
        }
    }
}
