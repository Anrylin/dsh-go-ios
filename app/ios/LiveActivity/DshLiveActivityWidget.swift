// 锁屏卡片 + 灵动岛三态。状态全部来自 ContentState，视图不自己判断业务。

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DshLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    DshLiveActivityWidget()
  }
}

struct DshLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DshActivityAttributes.self) { context in
      LockScreenCard(state: context.state)
        .activityBackgroundTint(Color.black)
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label {
            Text(state.chip.isEmpty ? "运行中" : state.chip).font(.caption).foregroundStyle(.white)
          } icon: {
            Image(systemName: glyph(state.kind)).foregroundStyle(tint(state.kind))
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Counter(state: state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 2) {
            Text(state.title.isEmpty ? "DSH" : state.title)
              .font(.headline).foregroundStyle(.white).lineLimit(1)
            Text(state.text).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: glyph(state.kind))
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint(state.kind))
      } compactTrailing: {
        CompactTrailing(state: state)
      } minimal: {
        Image(systemName: glyph(state.kind)).foregroundStyle(tint(state.kind))
      }
      .widgetURL(URL(string: "dshgo://open/chat"))
      .keylineTint(tint(state.kind))
    }
  }

  func glyph(_ kind: String) -> String {
    switch kind {
    case "waiting": return "hand.raised.fill"
    case "done": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.triangle.fill"
    case "idle": return "moon.zzz.fill"
    default: return "ellipsis.circle.fill"
    }
  }

  func tint(_ kind: String) -> Color {
    switch kind {
    case "waiting": return .yellow
    case "done": return .green
    case "failed": return .red
    case "idle": return .white.opacity(0.55)
    default: return .white
    }
  }
}

private struct Counter: View {
  let state: DshActivityAttributes.ContentState

  var body: some View {
    if let since = state.since, state.kind == "running" || state.kind == "waiting" {
      Text(timerInterval: since...Date.distantFuture, countsDown: false)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
    } else {
      Text(state.chip).font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct CompactTrailing: View {
  let state: DshActivityAttributes.ContentState

  var body: some View {
    if let since = state.since, state.kind == "running" || state.kind == "waiting" {
      Text(timerInterval: since...Date.distantFuture, countsDown: false)
        .font(.caption2.monospacedDigit()).foregroundStyle(.white)
    } else {
      Text(shortChip).font(.caption2).foregroundStyle(.white)
    }
  }

  private var shortChip: String {
    switch state.kind {
    case "waiting": return "待确认"
    case "idle": return "待命"
    case "done": return "完成"
    case "failed": return "出错"
    default: return state.chip
    }
  }
}

private struct LockScreenCard: View {
  let state: DshActivityAttributes.ContentState

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: glyph).font(.title3)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
        Text(state.text).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
      }
      Spacer(minLength: 8)
      if let since = state.since, state.kind == "running" || state.kind == "waiting" {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
          .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
      }
    }
    .padding(12)
  }

  private var glyph: String {
    switch state.kind {
    case "waiting": return "hand.raised.fill"
    case "done": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.triangle.fill"
    case "idle": return "moon.zzz.fill"
    default: return "ellipsis.circle.fill"
    }
  }

  private var tint: Color {
    switch state.kind {
    case "waiting": return .yellow
    case "done": return .green
    case "failed": return .red
    case "idle": return .white.opacity(0.55)
    default: return .white
    }
  }
}
