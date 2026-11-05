// 把 Dart 的 live 推送接到 ActivityKit。通道名不变（`dsh/notify` 的 `live` /
// `liveStatus`），Dart 侧一行不用改。
//
// 一次只保留一个活动：聊天里同时只有一件事在跑，多个活动会互相抢岛的显示位。

import ActivityKit
import Flutter
import Foundation

enum LiveActivityBridge {
  /// iOS 16.1 起才有 ActivityKit；更低的系统按「没有」处理，和别的通道一致。
  static var supported: Bool {
    if #available(iOS 16.1, *) { return true }
    return false
  }

  static func status() -> [String: Any] {
    if #available(iOS 16.1, *) {
      return ["supported": true, "allowed": ActivityAuthorizationInfo().areActivitiesEnabled]
    }
    return ["supported": false, "allowed": false]
  }

  static func apply(_ args: [String: Any], result: @escaping FlutterResult) {
    guard #available(iOS 16.1, *) else {
      result(nil)
      return
    }
    let enabled = args["enabled"] as? Bool ?? false
    let activity = args["activity"] as? [String: Any]
    // 关掉开关、或没有内容:结束掉正在显示的那个。
    guard enabled, let activity else {
      Task {
        await endAll()
        result(nil)
      }
      return
    }
    let state = contentState(activity)
    let sessionId = (activity["sessionId"] as? String) ?? (activity["target"] as? String) ?? ""
    Task {
      await show(state: state, sessionId: sessionId)
      result(nil)
    }
  }

  private static func contentState(_ map: [String: Any]) -> DshActivityAttributes.ContentState {
    let sinceMs = map["sinceMs"] as? Double
    return DshActivityAttributes.ContentState(
      kind: map["kind"] as? String ?? "running",
      title: map["title"] as? String ?? "",
      text: map["text"] as? String ?? "",
      chip: map["chip"] as? String ?? "",
      publicText: map["publicText"] as? String ?? "",
      mood: map["mood"] as? String ?? "",
      since: sinceMs.map { Date(timeIntervalSince1970: $0 / 1000) },
      target: map["sessionId"] as? String ?? ""
    )
  }

  private static func show(
    state: DshActivityAttributes.ContentState,
    sessionId: String
  ) async {
    let attributes = DshActivityAttributes(sessionId: sessionId)
    // 已有活动:原地更新，不重新请求（重启会闪一下，而且系统限量）。
    for activity in Activity<DshActivityAttributes>.activities {
      if activity.attributes.sessionId == sessionId {
        await activity.update(
          ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        )
        return
      }
      // 换了会话:旧的收掉，一个岛只讲一件事。
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    // waiting 状态的岛要留住，直到人处理；其余在半小时后自己变灰。
    _ = try? Activity.request(
      attributes: attributes,
      content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
      pushType: nil
    )
  }

  private static func endAll() async {
    for activity in Activity<DshActivityAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}
