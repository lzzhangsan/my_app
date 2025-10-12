import Flutter
import UIKit
import WebKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "browser_cookies", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        if call.method == "getCookies" {
          guard let args = call.arguments as? [String: Any], let urlString = args["url"] as? String, let url = URL(string: urlString) else {
            result("")
            return
          }
          if #available(iOS 11.0, *) {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
              let filtered = cookies.filter { cookie in
                guard let domain = url.host else { return false }
                return cookie.domain.contains(domain)
              }
              let cookieHeader = filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
              result(cookieHeader)
            }
          } else {
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            result(cookieHeader)
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
