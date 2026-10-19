import SliceKit
import SwiftUI

/// Small ⓘ button that explains a setting in a popover.
struct HelpButton: View {
    let key: SettingKey
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Erklärung: \(key.help.title)")
        .accessibilityIdentifier("help-\(key.rawValue)")
        .popover(isPresented: $shown) {
            SettingHelpCard(help: key.help)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// What a setting does, what more/less causes and a practical tip.
struct SettingHelpCard: View {
    let help: SettingHelp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(help.title).font(.headline)
                Text(help.summary).font(.subheadline)
                if let increase = help.increase {
                    effect("arrow.up.circle", "Mehr / an", increase, .green)
                }
                if let decrease = help.decrease {
                    effect("arrow.down.circle", "Weniger / aus", decrease, .orange)
                }
                if let tip = help.tip {
                    effect("lightbulb", "Tipp", tip, .yellow)
                }
            }
            .padding()
            .frame(maxWidth: 340, alignment: .leading)
        }
        .frame(idealWidth: 340, maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func effect(_ icon: String, _ title: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.subheadline)
            }
        }
    }
}

/// A form row with its control, an ⓘ button and – if wanted – the explanation right below.
struct HelpRow<Content: View>: View {
    let key: SettingKey
    @ViewBuilder var content: Content
    @AppStorage("showInlineHelp") private var inline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                content
                HelpButton(key: key)
            }
            if inline {
                Text(key.help.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
