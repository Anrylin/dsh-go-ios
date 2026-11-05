// The live activity the chat runs on iOS: what the agent is doing, in one
// place both the app and the widget extension compile against.
//
// Mirrors `LiveActivity.toMap` on the Dart side (app/lib/notify/live_activity.dart),
// so nothing in Dart has to change.

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct DshActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// running | waiting | done | failed
    var kind: String
    var title: String
    var text: String
    /// A word or two for the compact island.
    var chip: String
    /// The lock screen's line when sensitive content is hidden.
    var publicText: String
    /// The pet state whose glyph goes with it.
    var mood: String
    /// When the run started, for the counter.
    var since: Date?
    /// What a tap opens.
    var target: String
  }

  /// The conversation this activity belongs to.
  var sessionId: String
}
