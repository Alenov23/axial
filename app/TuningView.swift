import SwiftUI

/// Plots the service's exact shaping function (via the bridge) with the live input.
struct CurvePlot: View {
    let profile: Profile
    let axis: Int
    let raw: Double
    var body: some View {
        Canvas {context, size in
            let range = max(profile.range[axis], 1) * 1.1
            func y(_ x: Double) -> Double {
                shapeInput(x, profile.sensitivity[axis], profile.deadzone[axis], profile.curve[axis].index, profile.curveAmount[axis], profile.center[axis], profile.range[axis])
            }
            let maxOut = max(350 * 1.1, abs(y(range)) * 1.05, abs(y(-range)) * 1.05)
            func point(_ x: Double, _ v: Double) -> CGPoint {
                CGPoint(x: (x / range + 1) / 2 * size.width, y: (1 - (v / maxOut + 1) / 2) * size.height)
            }
            var grid = Path()
            for f in stride(from: -1.0, through: 1.0, by: 0.25) {
                grid.move(to: CGPoint(x: (f + 1) / 2 * size.width, y: 0));grid.addLine(to: CGPoint(x: (f + 1) / 2 * size.width, y: size.height))
                grid.move(to: CGPoint(x: 0, y: (f + 1) / 2 * size.height));grid.addLine(to: CGPoint(x: size.width, y: (f + 1) / 2 * size.height))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 1)
            var axes = Path();axes.move(to: CGPoint(x: size.width / 2, y: 0));axes.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            axes.move(to: CGPoint(x: 0, y: size.height / 2));axes.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(axes, with: .color(.primary.opacity(0.25)), lineWidth: 1)
            // Linear reference.
            var linear = Path();linear.move(to: point(-range, -range * 350 / max(profile.range[axis], 1)));linear.addLine(to: point(range, range * 350 / max(profile.range[axis], 1)))
            context.stroke(linear, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // Deadzone band.
            let dz = profile.deadzone[axis], c = profile.center[axis]
            if dz > 0 {
                let left = point(c - dz, 0).x, right = point(c + dz, 0).x
                context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: size.height)), with: .color(.orange.opacity(0.12)))
            }
            var curve = Path()
            let steps = 240
            for s in 0...steps {
                let x = -range + 2 * range * Double(s) / Double(steps)
                let p = point(x, y(x));if s == 0 {curve.move(to: p)} else {curve.addLine(to: p)}
            }
            context.stroke(curve, with: .linearGradient(Gradient(colors: [.orange, .accentColor, .green]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 2.5)
            let live = point(max(-range, min(range, raw)), y(raw))
            context.fill(Path(ellipseIn: CGRect(x: live.x - 6, y: live.y - 6, width: 12, height: 12)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: live.x - 6, y: live.y - 6, width: 12, height: 12)), with: .color(.accentColor), lineWidth: 2)
        }
        .overlay(alignment: .topLeading) {Text("output").font(.caption2).foregroundStyle(.secondary).padding(6)}
        .overlay(alignment: .bottomTrailing) {Text("physical input").font(.caption2).foregroundStyle(.secondary).padding(6)}
    }
}

@MainActor final class Calibration: ObservableObject {
    enum Phase: Equatable {case idle, center(Double), range(Double), done(String)}
    @Published var phase = Phase.idle
    @Published var minimum = [Double](repeating: 0, count: 6)
    @Published var maximum = [Double](repeating: 0, count: 6)
    private var sums = [Double](repeating: 0, count: 6)
    private var samples = 0
    private var timer: Timer?
    func run(device: UInt32, apply: @escaping (_ center: [Double], _ range: [Double]) -> Void) {
        timer?.invalidate();sums = Array(repeating: 0, count: 6);samples = 0
        minimum = Array(repeating: 0, count: 6);maximum = Array(repeating: 0, count: 6)
        let started = Date();phase = .center(0)
        var center = [Double](repeating: 0, count: 6)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) {[weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return}
                let sample = LiveSample.read(device: device), t = Date().timeIntervalSince(started)
                if t < 2 {
                    // Hands off: average resting values (device sends zeros at rest, so
                    // this only captures real drift).
                    for i in 0..<6 {self.sums[i] += sample.raw[i]};self.samples += 1;self.phase = .center(t / 2)
                } else if t < 12 {
                    if case .center = self.phase {center = self.sums.map {($0 / Double(max(self.samples, 1))).rounded()}}
                    for i in 0..<6 {self.minimum[i] = min(self.minimum[i], sample.raw[i]);self.maximum[i] = max(self.maximum[i], sample.raw[i])}
                    self.phase = .range((t - 2) / 10)
                } else {
                    self.timer?.invalidate();self.timer = nil
                    let range = (0..<6).map {i -> Double in
                        let r = max(abs(self.maximum[i] - center[i]), abs(self.minimum[i] - center[i]))
                        return r < 60 ? 350 : min(2000, max(60, r.rounded())) // untouched axes keep nominal range
                    }
                    apply(center, range)
                    let touched = (0..<6).filter {max(abs(self.maximum[$0]), abs(self.minimum[$0])) >= 60}.count
                    self.phase = .done("Calibrated: centers \(center.map {Int($0)}), ranges \(range.map {Int($0)}) · \(touched)/6 axes measured")
                }
            }
        }
    }
    func cancel() {timer?.invalidate();timer = nil;phase = .idle}
}

struct TuningTab: View {
    @EnvironmentObject var model: Model
    @StateObject private var live = LiveInput()
    @StateObject private var calibration = Calibration()
    @State private var axis = 0
    var body: some View {
        let p = model.profile
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tuning").font(.title2.bold())
                ForEach(0..<6, id: \.self) {i in
                    Button {axis = i} label: {
                        HStack {
                            Text(AxisInfo.short[i]).font(.system(.callout, design: .monospaced).bold()).foregroundStyle(Color(nsColor: PuckGeometry.axisColors[i])).frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AxisInfo.names[i]).font(.callout)
                                Text("\(p.curve[i].title) · ×\(p.sensitivity[i], specifier: "%.2f") · dz \(Int(p.deadzone[i]))\(p.smoothing[i] > 0 ? " · ~\(Int(p.smoothing[i]))ms" : "")").font(.caption2).foregroundStyle(.secondary)
                                SignedBar(value: live.sample.raw[i])
                            }
                        }.padding(8).frame(width: 230, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9).fill(axis == i ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.04)))
                    }.buttonStyle(.plain)
                }
                Divider()
                GroupBox("Axis locking") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Lock", selection: Binding(get: {model.profile.lock}, set: {x in model.edit {$0.lock = x}})) {
                            ForEach(AxisLock.allCases) {Text($0.title).tag($0)}
                        }.labelsHidden()
                        Toggle("Translation", isOn: Binding(get: {model.profile.translation}, set: {x in model.edit {$0.translation = x}}))
                        Toggle("Rotation", isOn: Binding(get: {model.profile.rotation}, set: {x in model.edit {$0.rotation = x}}))
                    }
                }.frame(width: 246)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(AxisInfo.names[axis]).font(.title3.bold())
                    Text("input \(AxisInfo.short[axis])").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "raw %+.0f  →  shaped %+.0f", live.sample.raw[axis], shapeInput(live.sample.raw[axis], p.sensitivity[axis], p.deadzone[axis], p.curve[axis].index, p.curveAmount[axis], p.center[axis], p.range[axis])))
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                CurvePlot(profile: p, axis: axis, raw: live.sample.raw[axis]).frame(minHeight: 230).panelSurface().clipShape(RoundedRectangle(cornerRadius: 12))
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Response curve", selection: Binding(get: {model.profile.curve[axis]}, set: {x in model.edit {$0.curve[axis] = x}})) {
                            ForEach(CurveKind.allCases) {Text($0.title).tag($0)}
                        }.pickerStyle(.segmented)
                        slider("Curve strength", value: \.curveAmount, range: 0...1, format: "%.2f", disabled: p.curve[axis] == .linear)
                        slider("Sensitivity", value: \.sensitivity, range: 0...4, format: "×%.2f")
                        slider("Deadzone", value: \.deadzone, range: 0...150, format: "%.0f")
                        slider("Smoothing", value: \.smoothing, range: 0...200, format: "%.0f ms")
                    }.padding(4)
                }
                HStack {
                    Button("Apply these settings to all axes") {
                        model.edit {q in for i in 0..<6 where i != axis {q.curve[i] = q.curve[axis];q.curveAmount[i] = q.curveAmount[axis];q.sensitivity[i] = q.sensitivity[axis];q.deadzone[i] = q.deadzone[axis];q.smoothing[i] = q.smoothing[axis]}}
                    }
                    Button("Apply to \(AxisInfo.isRotation(axis) ? "rotation" : "translation") axes") {
                        let group = AxisInfo.isRotation(axis) ? 3..<6 : 0..<3
                        model.edit {q in for i in group where i != axis {q.curve[i] = q.curve[axis];q.curveAmount[i] = q.curveAmount[axis];q.sensitivity[i] = q.sensitivity[axis];q.deadzone[i] = q.deadzone[axis];q.smoothing[i] = q.smoothing[axis]}}
                    }
                    Spacer()
                    Button("Reset axis") {model.edit {q in let d = Profile();q.curve[axis] = d.curve[axis];q.curveAmount[axis] = d.curveAmount[axis];q.sensitivity[axis] = 1;q.deadzone[axis] = 0;q.smoothing[axis] = 0}}
                }
                GroupBox("Calibration") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Center \(Int(p.center[axis]))  ·  full range ±\(Int(p.range[axis]))").font(.system(.callout, design: .monospaced))
                            Spacer()
                            switch calibration.phase {
                            case .idle, .done:
                                Button("Calibrate…") {
                                    calibration.run(device: UInt32(model.device?.id ?? 0)) {center, range in model.edit {$0.center = center;$0.range = range}}
                                }.disabled(model.device == nil)
                                Button("Reset") {model.edit {$0.center = Array(repeating: 0, count: 6);$0.range = Array(repeating: 350, count: 6)}}
                            default: Button("Cancel") {calibration.cancel()}
                            }
                        }
                        switch calibration.phase {
                        case .center(let f): ProgressView(value: f) {Text("Step 1/2 — hands off the cap: measuring rest position…")}
                        case .range(let f):
                            ProgressView(value: f) {Text("Step 2/2 — push, pull, tilt and twist every axis to its limit…")}
                            HStack {ForEach(0..<6, id: \.self) {i in Text("\(AxisInfo.short[i]) \(Int(calibration.minimum[i]))…\(Int(calibration.maximum[i]))").font(.system(.caption2, design: .monospaced))}}
                        case .done(let text): Text(text).font(.caption).foregroundStyle(.green)
                        case .idle: Text("Measures rest drift and the full travel of each axis so all six reach the same output range.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {live.device = UInt32(model.device?.id ?? 0);live.start()}
        .onDisappear {live.stop();calibration.cancel()}
    }
    func slider(_ title: String, value: WritableKeyPath<Profile, [Double]>, range: ClosedRange<Double>, format: String, disabled: Bool = false) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: {model.profile[keyPath: value][axis]}, set: {x in model.edit {$0[keyPath: value][axis] = x}}), in: range)
            Text(String(format: format, model.profile[keyPath: value][axis])).monospacedDigit().frame(width: 70, alignment: .trailing)
        }.disabled(disabled)
    }
}
