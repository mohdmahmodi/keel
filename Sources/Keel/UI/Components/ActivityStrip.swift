import SwiftUI

/// Thin strip at the bottom: what Keel is doing right now, else the last log line.
struct ActivityStrip: View {
    let log: ActivityLog
    var app: AppState = AppState.shared
    var store: TweakStore = TweakStore.shared
    var digest: TweakDigest = TweakDigest.shared
    let openActivity: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 8)
            if store.detecting {
                Text("Checking \(digest.detectedCount)/\(digest.total)").font(Theme.monoSmall).foregroundStyle(.secondary)
            }
            Button(action: openActivity) {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 10))
                    Text("Activity").font(.system(size: 11))
                }
            }
            .buttonStyle(KeelButtonStyle(kind: .ghost, small: true))
            .accessibilityLabel("Open the Activity log")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 26)
        .background(Theme.sidebarBG)
        .overlay(alignment: .top) { HLine() }
    }

    @ViewBuilder private var status: some View {
        if app.waitingForAdmin {
            Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Theme.warn).accessibilityHidden(true)
            Text("Waiting for your administrator password in the macOS dialog").font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1)
        } else if let busy = app.busyMessage {
            ProgressView().controlSize(.mini)
            Text(busy).font(.system(size: 11)).lineLimit(1)
        } else if let e = log.last {
            Dot(color: Theme.color(for: e.level), size: 6)
            Text(e.date.formatted(date: .omitted, time: .shortened)).font(Theme.monoSmall).foregroundStyle(.secondary)
            Text(e.message).font(.system(size: 11)).foregroundStyle(e.level == .error ? Theme.fail : .primary).lineLimit(1).truncationMode(.middle)
        } else {
            Dot(color: Theme.neutral, size: 6)
            Text("Ready").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
