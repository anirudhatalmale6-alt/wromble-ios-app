import SwiftUI
import UserNotifications

@main
struct WrombleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var deviceToken: String = ""
    @Published var notificationsEnabled: Bool = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    @Published var locationEnabled: Bool = UserDefaults.standard.bool(forKey: "locationEnabled")
    @Published var biometricEnabled: Bool = UserDefaults.standard.bool(forKey: "biometricEnabled")
    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @Published var isAuthenticated: Bool = false
    @Published var networkAvailable: Bool = true

    func save() {
        UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
        UserDefaults.standard.set(locationEnabled, forKey: "locationEnabled")
        UserDefaults.standard.set(biometricEnabled, forKey: "biometricEnabled")
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        AppState.shared.deviceToken = token
        sendTokenToServer(token)
    }

    private func sendTokenToServer(_ token: String) {
        guard let userId = UserDefaults.standard.string(forKey: "userId"), !userId.isEmpty else { return }
        guard let url = URL(string: "\(baseURL)/api/register-push-token.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["user_id": Int(userId) ?? 0, "token": token, "platform": "ios"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request).resume()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
            NotificationCenter.default.post(name: .init("OpenURL"), object: url)
        }
        completionHandler()
    }
}
