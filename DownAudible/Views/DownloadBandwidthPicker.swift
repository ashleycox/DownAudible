import SwiftUI

struct DownloadBandwidthPicker: View {
    @Binding var bytesPerSecond: Int
    @State private var choosingCustom = false

    private enum Limit: Hashable {
        case unlimited
        case preset(Int)
        case custom
    }

    private static let presets = [512, 1_000, 2_000, 5_000, 10_000, 25_000]
    private static let bytesPerKilobit = 125

    var body: some View {
        Picker("Bandwidth per download (kbps)", selection: selection) {
            Text("Unlimited").tag(Limit.unlimited)
            ForEach(Self.presets, id: \.self) { rate in
                Text("\(rate, format: .number) kbps").tag(Limit.preset(rate))
            }
            Text("Custom").tag(Limit.custom)
        }
        if selection.wrappedValue == .custom {
            LabeledContent("Custom bandwidth (kbps)") {
                TextField("Custom bandwidth (kbps)", value: customRate,
                          format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 128)
            }
        }
    }

    private var selection: Binding<Limit> {
        Binding {
            if choosingCustom { return .custom }
            guard bytesPerSecond > 0 else { return .unlimited }
            let preset = Self.presets.first { $0 * Self.bytesPerKilobit == bytesPerSecond }
            return preset.map(Limit.preset) ?? .custom
        } set: { limit in
            choosingCustom = limit == .custom
            switch limit {
            case .unlimited: bytesPerSecond = 0
            case .preset(let rate): bytesPerSecond = rate * Self.bytesPerKilobit
            case .custom: break
            }
        }
    }

    private var customRate: Binding<Double?> {
        Binding {
            guard bytesPerSecond > 0 else { return nil }
            return Double(bytesPerSecond) / Double(Self.bytesPerKilobit)
        } set: { rate in
            guard let rate, rate > 0,
                  let bytes = Int(exactly: (rate * Double(Self.bytesPerKilobit)).rounded()) else { return }
            bytesPerSecond = max(1, bytes)
        }
    }
}
