import SwiftUI
import AppKit

/// A live, scrolling view of the captured server output.
struct LogView: View {
    @EnvironmentObject var log: LogStore
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: log.lines.count) { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
            }
            Divider()
            HStack {
                statusBadge
                Spacer()
                Button("Open Dashboard") { NSWorkspace.shared.open(settings.dashboardURL) }
                    .disabled(server.status != .running)
                Button("Reveal Log File") { NSWorkspace.shared.activateFileViewerSelecting([log.logFileURL]) }
                Button("Clear") { log.clear() }
            }
            .padding(8)
        }
        .frame(minWidth: 640, minHeight: 380)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption)
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .crashed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusText: String {
        switch server.status {
        case .running: return "Running on port \(settings.port)"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .crashed(let r): return "Crashed: \(r)"
        }
    }
}
