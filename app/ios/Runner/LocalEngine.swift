// 「本机」引擎:iOS 上把 Node 24 跑在 App 里(nodejs-mobile),启动一次 dsh web,
// 把端口和 token 交给 Dart 的 `dsh/runtime`。默认不启动——没人调 start,这里什么都不做。
//
// iOS 不允许 fork/exec,所以引擎用 JS 替身跑命令(Fish Pocket 的 runtime/,MIT)。
// HOME 指到 App 沙箱里,DSH 的会话、插件都写在沙箱内。

import Flutter
import Foundation

final class LocalEngine {
  static let shared = LocalEngine()

  private var channel: FlutterMethodChannel?
  private var running = false
  private var port = 0
  private var token = ""
  private var startedAt: Date?

  func register(messenger: any FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/runtime", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "start": self.start(result: result)
      case "stop": self.stop(result: result)
      case "status": result(self.status())
      // iOS 没有这些能力,按「不支持」回答,和别的通道一致。
      case "install", "reset", "cancelManagedSkill", "clearFailure", "setAutoSafe",
           "setDirectEngine", "openAllFilesAccess", "batteryExempt",
           "requestBatteryExempt", "openBackgroundSettings", "openVendorSettings",
           "networkMetered", "reopenApp":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func status() -> [String: Any] {
    [
      "phase": running ? "running" : "stopped",
      "installed": FileManager.default.fileExists(atPath: home.path),
      "port": port,
      "token": token,
      "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    ]
  }

  private var home: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("dsh-home", isDirectory: true)
  }

  private func start(result: @escaping FlutterResult) {
    if running {
      result(status())
      return
    }
    do {
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      try? copyEngineIfNeeded()
      setenv("HOME", home.path, 1)
      setenv("DSH_HOME", home.path.appendingPathComponent(".dsh"), 1)
      setenv("TMPDIR", NSTemporaryDirectory(), 1)

      let engine = enginePaths()
      guard FileManager.default.fileExists(atPath: engine.boot.path) else {
        result(FlutterError(code: "missing_engine", message: "engine assets not bundled", details: nil))
        return
      }

      let args = ["node", engine.boot.path, "--port", "0"]
      // nodejs-mobile 的 Objective-C 入口:NodeRunner。
      guard let runnerClass = NSClassFromString("NodeRunner") as? NSObject.Type else {
        result(FlutterError(code: "missing_node", message: "NodeMobile not linked", details: nil))
        return
      }
      running = true
      startedAt = Date()
      _ = runnerClass.perform(NSSelectorFromString("run:"), with: args as NSArray)
      // 端口与 token 由 boot.mjs 写进 launch.json,这里轮询读取。
      waitForLaunch(result: result, deadline: Date().addingTimeInterval(25))
    } catch {
      running = false
      result(FlutterError(code: "start_failed", message: "\(error)", details: nil))
    }
  }

  private func waitForLaunch(result: @escaping FlutterResult, deadline: Date) {
    let file = home.appendingPathComponent("launch.json")
    DispatchQueue.global().async { [weak self] in
      guard let self else { return }
      while Date() < deadline {
        if let data = try? Data(contentsOf: file),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = map["port"] as? Int {
          DispatchQueue.main.async {
            self.port = p
            self.token = map["token"] as? String ?? ""
            result(self.status())
          }
          return
        }
        Thread.sleep(forTimeInterval: 0.5)
      }
      DispatchQueue.main.async {
        result(FlutterError(code: "timeout", message: "engine did not report a port", details: nil))
      }
    }
  }

  private func stop(result: @escaping FlutterResult) {
    // nodejs-mobile 没有公开的 stop;真实实现要让 boot.mjs 收到信号后 process.exit。
    running = false
    port = 0
    token = ""
    result(nil)
  }

  private struct EnginePaths {
    let boot: URL
  }

  /// Flutter 的 assets 在 App.framework/flutter_assets 里,swift 侧用
  /// lookupKey 换到真实路径。
  private func assetPath(_ name: String) -> URL? {
    let key = FlutterDartProject.lookupKey(forAsset: name)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func enginePaths() -> EnginePaths {
    let boot = assetPath("assets/engine_local/boot.mjs")
      ?? Bundle.main.resourceURL!.appendingPathComponent("engine_local/boot.mjs")
    return EnginePaths(boot: boot)
  }

  private func copyEngineIfNeeded() throws {
    // 引擎直接从 flutter_assets 读,不再复制。
  }
}
