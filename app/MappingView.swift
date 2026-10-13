import SwiftUI
import UniformTypeIdentifiers

/// 6×6 routing matrix: rows are outputs sent to the app, columns are physical inputs.
/// Drag an input chip onto an output row to route it; drag an output handle onto
/// another output to swap them. Click a cell to cycle 0 → +1 → −1, right-click for weights.
struct MappingTab: View {
    @EnvironmentObject var model: Model
    @StateObject private var live = LiveInput()
    @State private var dropTarget: Int?
    private static let weights: [Double] = [2, 1.5, 1, 0.75, 0.5, 0.25, 0, -0.25, -0.5, -0.75, -1, -1.5, -2]

    var body: some View {
        let p = model.profile
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Axis mapping").font(.title2.bold())
                Text("Any input → any output · swap, invert, disable, mix").foregroundStyle(.secondary)
                Spacer()
                Menu("Presets") {
                    ForEach(MappingPreset.allCases) {preset in Button(preset.title) {model.edit {preset.apply(&$0)}}}
                }.frame(width: 120)
                Button("Reset matrix") {model.edit {$0.matrix = Profile.identity}}
            }
            GroupBox("Physical inputs — drag onto an output") {
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) {i in inputChip(i)}
                }
            }
            GroupBox {
                Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Text("Output to application").font(.caption.bold()).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        ForEach(0..<6, id: \.self) {i in
                            Text(AxisInfo.short[i]).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(Color(nsColor: PuckGeometry.axisColors[i]))
                        }
                        Text("On").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Invert").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Speed").font(.caption.bold()).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text("Live").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(0..<6, id: \.self) {o in
                        GridRow {
                            outputHandle(o, p)
                            ForEach(0..<6, id: \.self) {i in cell(output: o, input: i, weight: p.matrix[o][i])}
                            Toggle("", isOn: Binding(get: {model.profile.enabled[o]}, set: {x in model.edit {$0.enabled[o] = x}})).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            Toggle("", isOn: Binding(get: {model.profile.invert[o]}, set: {x in model.edit {$0.invert[o] = x}})).labelsHidden()
                            HStack(spacing: 4) {
                                Slider(value: Binding(get: {model.profile.gain[o]}, set: {x in model.edit {$0.gain[o] = x}}), in: 0...5).frame(width: 110)
                                Text(p.gain[o], format: .number.precision(.fractionLength(2))).monospacedDigit().font(.caption).frame(width: 32)
                            }
                            SignedBar(value: live.sample.mapped[o], color: .green).frame(width: 90)
                        }
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(dropTarget == o ? Color.accentColor.opacity(0.18) : Color.clear))
                        .onDrop(of: [UTType.plainText], isTargeted: Binding(get: {dropTarget == o}, set: {dropTarget = $0 ? o : (dropTarget == o ? nil : dropTarget)})) {providers in
                            accept(providers, output: o)
                        }
                        if o == 2 {Divider().gridCellUnsizedAxes(.horizontal)}
                    }
                }.padding(4)
            }
            GroupBox("Routing summary") {
                let lines = (0..<6).map {o in routeText(o, p)}
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(0..<6, id: \.self) {o in Text(lines[o]).font(.caption).foregroundStyle(p.enabled[o] ? .primary : .tertiary)}
                }
            }
            Text("Tip: drag an input chip onto a row to route it there exclusively (it is removed from other rows). Drag an output's ⠿ handle onto another output to swap. Mix several inputs into one output by setting more than one weight in a row; translation ↔ rotation mappings work in both directions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .onAppear {live.device = UInt32(model.device?.id ?? 0);live.start()}
        .onDisappear {live.stop()}
    }

    func inputChip(_ i: Int) -> some View {
        let value = live.sample.raw[i]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Text(AxisInfo.short[i]).font(.system(.callout, design: .monospaced).bold()).foregroundStyle(Color(nsColor: PuckGeometry.axisColors[i]))
                Spacer(minLength: 0)
                Text(String(format: "%+.0f", value)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(AxisInfo.names[i]).font(.caption).lineLimit(1)
            SignedBar(value: value)
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(abs(value) > 20 ? 0.12 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: PuckGeometry.axisColors[i]).opacity(abs(value) > 20 ? 0.8 : 0.25)))
        .onDrag {NSItemProvider(object: "input:\(i)" as NSString)}
        .help("Drag onto an output to route \(AxisInfo.names[i]) there")
    }

    func outputHandle(_ o: Int, _ p: Profile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                .onDrag {NSItemProvider(object: "output:\(o)" as NSString)}
                .help("Drag onto another output to swap")
            VStack(alignment: .leading, spacing: 0) {
                Text(AxisInfo.outputs[o]).font(.callout.weight(.medium))
                Text(AxisInfo.isRotation(o) ? "rotation output" : "translation output").font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(width: 150, alignment: .leading)
    }

    func cell(output o: Int, input i: Int, weight: Double) -> some View {
        let activity = min(1, abs(live.sample.raw[i] * weight) / 350)
        let color: Color = weight > 0 ? .accentColor : .orange
        return Text(weight == 0 ? "·" : String(format: weight == weight.rounded() ? "%+.0f" : "%+.2f", weight))
            .font(.system(.callout, design: .monospaced).weight(weight == 0 ? .regular : .bold))
            .foregroundStyle(weight == 0 ? Color.secondary : Color.white)
            .frame(width: 50, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(weight == 0 ? Color.primary.opacity(0.05) : color.opacity(0.55 + 0.45 * activity)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(activity * 0.9), lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture {model.edit {$0.matrix[o][i] = weight == 0 ? 1 : (weight > 0 ? -1 : 0)}}
            .contextMenu {
                ForEach(Self.weights, id: \.self) {w in Button(String(format: "%+.2f", w)) {model.edit {$0.matrix[o][i] = w}}}
                Divider()
                Button("Route only \(AxisInfo.short[i]) here") {model.edit {$0.assign(input: i, to: o)}}
            }
            .help("\(AxisInfo.names[i]) → \(AxisInfo.outputs[o]): click to cycle, right-click for weights")
    }

    func routeText(_ o: Int, _ p: Profile) -> String {
        let parts = (0..<6).filter {p.matrix[o][$0] != 0}.map {i -> String in
            let w = p.matrix[o][i];return (w < 0 ? "−" : "") + (abs(w) == 1 ? "" : String(format: "%.2g·", abs(w))) + AxisInfo.short[i]
        }
        return "\(AxisInfo.outputs[o]) ← " + (parts.isEmpty ? "nothing" : parts.joined(separator: " + ")) + (p.enabled[o] ? "" : " (off)") + (p.invert[o] ? " (inverted)" : "")
    }

    func accept(_ providers: [NSItemProvider], output o: Int) -> Bool {
        guard let provider = providers.first else {return false}
        _ = provider.loadObject(ofClass: NSString.self) {object, _ in
            guard let text = object as? String else {return}
            let parts = text.split(separator: ":");guard parts.count == 2, let index = Int(parts[1]), (0..<6).contains(index) else {return}
            DispatchQueue.main.async {
                if parts[0] == "input" {model.edit {$0.assign(input: index, to: o)}}
                else if parts[0] == "output", index != o {model.edit {$0.swapOutputs(index, o)}}
            }
        }
        return true
    }
}
