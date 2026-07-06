import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationManager.shared.requestAuthorization()
        // Khởi động web server và giữ app sống ở chế độ nền.
        WebServer.shared.start()
        BackgroundKeeper.shared.start()
        return true
    }
}
