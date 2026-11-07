#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// Shared between the app (which starts/updates activities) and the widget extension (which renders them).
public struct GlucoseActivityAttributes: ActivityAttributes {
    public typealias ContentState = GlucoseActivityState

    public init() {}
}
#endif
