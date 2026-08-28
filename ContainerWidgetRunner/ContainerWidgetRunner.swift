import SwiftUI
import WidgetKit

private struct ProfileCarrierEntry: TimelineEntry {
    let date: Date
}

private struct ProfileCarrierProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProfileCarrierEntry {
        ProfileCarrierEntry(date: .now)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ProfileCarrierEntry) -> Void
    ) {
        completion(ProfileCarrierEntry(date: .now))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ProfileCarrierEntry>) -> Void
    ) {
        completion(Timeline(entries: [ProfileCarrierEntry(date: .now)], policy: .never))
    }
}

private struct ProfileCarrierWidget: Widget {
    let kind = "ContainerWidgetRunner.ProfileCarrier"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProfileCarrierProvider()) { _ in
            Color.clear
        }
        .configurationDisplayName("Widget Runner Profile")
        .description("Build-time provisioning profile carrier.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ContainerWidgetRunnerBundle: WidgetBundle {
    var body: some Widget {
        ProfileCarrierWidget()
    }
}
