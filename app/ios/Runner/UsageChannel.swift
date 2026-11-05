// `dsh/usage` 的 iOS 半边：匿名统计请求体里那几个"设备事实"。
//
// Android 报 versionName / versionCode / sdk / abi / maker；iOS 没有厂商和 ABI
// 的概念，能给的是版本号、build 号、系统主版本，abi 固定 arm64（这个包只出
// arm64）。Dart 侧缺字段时会退化成只用版本号，所以这里少报也不会坏。

import Flutter
import UIKit

final class UsageChannel {
  init(messenger: any FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/usage", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "device": result(Self.device())
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func device() -> [String: Any] {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    let build = Int(info?["CFBundleVersion"] as? String ?? "") ?? 0
    return [
      "versionName": version,
      "versionCode": build,
      // 和 Android 的 Build.VERSION.SDK_INT 对齐：iOS 主版本号足够区分系统。
      "sdk": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      "abi": "arm64",
      // 苹果没有厂商名，统计里统一记 apple。
      "maker": "apple",
    ]
  }
}
