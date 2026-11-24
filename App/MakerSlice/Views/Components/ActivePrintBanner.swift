import PrinterKit
import SwiftUI

/// A running (or stopped) print, visible on every tab; tapping opens the printer.
struct ActivePrintBanner: View {
    @Environment(AppModel.self) private var app

    /// Printers with a job that needs attention: printing, paused, or stopped by an error.
    private var active: [(PrinterConnection, PrinterStatus)] {
        app.printers.printers.compactMap { p in
            guard app.printers.isOnline(p), let s = app.printers.status(of: p) else { return nil }
            let busy = s.state == .printing || s.state == .paused || (s.state == .error && !s.isIdle)
            return busy ? (p, s) : nil
        }
    }

    var body: some View {
        if let (printer, status) = active.first {
            Button { app.show(printer: printer.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: icon(status.state)).foregroundStyle(status.state.color)
                        Text(printer.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(detail(status)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if active.count > 1 {
                            Text("+\(active.count - 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    ProgressView(value: min(max(status.progress, 0), 1))
                        .tint(status.state.color)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activePrintBanner")
        }
    }

    private func icon(_ state: PrinterStatus.JobState) -> String {
        switch state {
        case .printing: return "printer.fill"
        case .paused: return "pause.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func detail(_ s: PrinterStatus) -> String {
        switch s.state {
        case .paused: return "pausiert · \(Int(s.progress * 100)) %"
        case .error: return "gestoppt – bitte ansehen"
        default:
            let percent = "\(Int(s.progress * 100)) %"
            return s.remainingSeconds.map { "\(percent) · noch \(Format.duration($0))" } ?? percent
        }
    }
}
