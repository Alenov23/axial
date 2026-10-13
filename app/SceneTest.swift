import SwiftUI
import SceneKit
import simd

@_silgen_name("AxialPreviewActivity") func previewActivity(_ callback: @convention(c) () -> Void)
@_silgen_name("AxialPreviewWatch") func previewWatch(_ enabled: Bool)
private let previewActivityNotification = Notification.Name("AxialPreviewActivity")

@_silgen_name("AxialPreviewStart") func previewStart()
@_silgen_name("AxialPreviewStop") func previewStop()
@_silgen_name("AxialPreviewNow") func previewNow() -> UInt64
@_silgen_name("AxialPreviewLostLogs") func previewLostLogs() -> UInt64
@_silgen_name("AxialPreviewRead") func previewRead(_ device: UInt32, _ axes: UnsafeMutablePointer<Double>, _ buttons: UnsafeMutablePointer<UInt32>) -> Bool
@_silgen_name("AxialPreviewPopLog") func previewPopLog(_ timestamp: UnsafeMutablePointer<UInt64>, _ device: UnsafeMutablePointer<UInt32>, _ changed: UnsafeMutablePointer<UInt32>, _ buttons: UnsafeMutablePointer<UInt32>, _ reason: UnsafeMutablePointer<UInt32>, _ identity: UnsafeMutablePointer<UInt32>) -> Bool

struct ButtonEntry: Identifiable {
    let id: UInt64
    let time: Date
    let device: UInt32
    let button: Int
    let pressed: Bool
    let reset: Bool
    let deviceName: String
    let buttonName: String
    init(id: UInt64, time: Date, device: UInt32, button: Int, pressed: Bool, reset: Bool, identity: UInt32) {
        self.id = id;self.time = time;self.device = device;self.button = button
        self.pressed = pressed;self.reset = reset
        let layout = DeviceCatalog.layouts[identity]
        deviceName = layout?.name ?? (identity == 0 ? "Unknown controller" : String(format: "USB controller %04x:%04x", identity >> 16, identity & 0xffff))
        buttonName = layout?.buttonName(slot: button - 1) ?? "Unknown button (\(button))"
    }
    var csvRow: String {
        func quoted(_ text: String) -> String {"\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""}
        return "\(time.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))),\(device),\(button),\(pressed ? "pressed" : "released"),\(reset ? "reset" : "device"),\(quoted(deviceName)),\(quoted(buttonName))\n"
    }
}

final class TestRenderer: NSObject, SCNSceneRendererDelegate {
    private static let pauseRetryDelay = DispatchTimeInterval.milliseconds(1)
    let scene = SCNScene()
    let object = SCNNode()
    let camera = SCNNode()
    private(set) var modelError: String?
    private let lock = NSLock()
    private let frameLock = NSLock()
    private var gain = SIMD8<Double>(repeating: 1)
    private var deadzone = SIMD8<Double>(repeating: 0)
    private var dominant = false
    private var device: UInt32 = 0
    private var resetRequested = false
    private var lastTime: TimeInterval = 0
    private var idleReported = false
    private var navigation = TestNavigation()
    override init() {
        super.init()
        previewActivity {NotificationCenter.default.post(name: previewActivityNotification, object: nil)}
        scene.rootNode.addChildNode(object)
        do {
            guard let url = Bundle.main.url(forResource: "ToyCar", withExtension: "scn") else {throw CocoaError(.fileNoSuchFile)}
            object.addChildNode(try TestModel.load(from: url))
        } catch {modelError = "Could not load the toy car: \(error.localizedDescription)"}
        TestModel.studio(in: scene, camera: camera)
    }
    func configure(device: UInt32, profile: Profile) {
        lock.lock()
        let oldDevice = self.device, oldGain = gain, oldDeadzone = deadzone, oldDominant = dominant
        self.device = device;dominant = profile.lock == .dominant
        for i in 0..<6 {
            let off = !profile.enabled[i] || (i < 3 && !profile.translation) || (i >= 3 && !profile.rotation)
            gain[i] = off ? 0 : profile.gain[i] * (profile.invert[i] ? -1 : 1)
            deadzone[i] = profile.deadzone[i]
        }
        let changed = oldDevice != device || oldGain != gain || oldDeadzone != deadzone || oldDominant != dominant
        lock.unlock()
        if changed {notifyActivity()}
    }
    private func notifyActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}
            NotificationCenter.default.post(name: previewActivityNotification, object: self)
        }
    }
    func reset() {lock.lock();resetRequested = true;lock.unlock();notifyActivity()}
    func pauseTiming() {
        guard frameLock.try() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseRetryDelay) { [weak self] in self?.pauseTiming() }
            return
        }
        lastTime = 0;idleReported = false;frameLock.unlock()
    }
    private func axes() -> SIMD8<Double> {
        lock.lock();let device = self.device, gain = self.gain, deadzone = self.deadzone, dominant = self.dominant;lock.unlock()
        var values = SIMD8<Double>.zero;var buttons: UInt32 = 0
        // Prefer the service's post-mapping stream: it already applied the
        // profile (dead zones, curves, gain, inversion, matrix, locks and
        // toggles) and is zero when stale, so the car moves exactly like the
        // real output. Older services send no mapped frames; approximate then.
        let mapped = withUnsafeMutableBytes(of: &values) {bytes in
            previewReadMapped(device, bytes.bindMemory(to: Double.self).baseAddress!)
        }
        if mapped {return values}
        values = .zero
        withUnsafeMutableBytes(of: &values) {bytes in
            _ = previewRead(device, bytes.bindMemory(to: Double.self).baseAddress!, &buttons)
        }
        for i in 0..<6 {let x = values[i];values[i] = (x < 0 ? -1 : 1) * max(0, abs(x) - deadzone[i]) * gain[i]}
        if dominant, let index = (0..<6).max(by: {abs(values[$0]) < abs(values[$1])}) {
            for i in 0..<6 where i != index {values[i] = 0}
        }
        return values
    }
    var needsFrames: Bool {
        lock.lock();let reset = resetRequested;lock.unlock()
        return reset || axes() != .zero
    }
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // A tab transition can briefly leave two SceneKit views using this scene.
        guard frameLock.try() else {return};defer {frameLock.unlock()}
        lock.lock();let reset = resetRequested;resetRequested = false;lock.unlock()
        let axes = axes()
        guard reset || axes != .zero else {
            if !idleReported {idleReported = true;lastTime = 0;notifyActivity()}
            return
        }
        idleReported = false
        if reset {navigation.reset();object.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))}
        let dt = Float(lastTime == 0 ? 0 : min(max(time - lastTime, 0), 0.05));lastTime = time
        navigation.advance(horizontal: axes[0] / 350, vertical: -axes[2] / 350, zoom: -axes[1] / 350, seconds: Double(dt))
        camera.camera?.orthographicScale = navigation.scale
        let right = camera.simdWorldRight, up = camera.simdWorldUp
        object.position = SCNVector3(CGFloat(Double(right.x) * navigation.pan.x + Double(up.x) * navigation.pan.y), CGFloat(Double(right.y) * navigation.pan.x + Double(up.y) * navigation.pan.y), CGFloat(Double(right.z) * navigation.pan.x + Double(up.z) * navigation.pan.y))
        // Rotating the model needs the opposite sign from rotating a camera around it.
        let rotation = SIMD3<Float>(Float(axes[3]), Float(-axes[5]), Float(axes[4])) / 350
        let length = simd_length(rotation)
        if length > 0 {object.simdOrientation = simd_normalize(simd_quatf(angle: length * dt * 1.8, axis: rotation / length) * object.simdOrientation)}
    }
}
// Closing settings keeps the menu-bar app alive, so dismantle alone is insufficient.
// Render at full speed only while the test scene can actually be seen.
final class TestSceneView: SCNView {
    // Keep the Metal layer nonzero until SwiftUI gives its host a real size.
    static let placeholderFrame = NSRect(x: 0, y: 0, width: 1, height: 1)
    weak var motionSource: TestRenderer?
    weak var frameDelegate: SCNSceneRendererDelegate?
    private var observers: [NSObjectProtocol] = []
    private var watching = false
    private func watch(_ enabled: Bool) {
        guard watching != enabled else {return}
        watching = enabled;previewWatch(enabled)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver);observers.removeAll()
        guard let window else {updateRendering();return}
        observers.append(center.addObserver(forName: previewActivityNotification, object: nil, queue: .main) { [weak self] note in
            // Active frames already sample the latest input. Only wake a
            // sleeping scene here, avoiding work at the HID report rate.
            if self?.rendersContinuously == false || note.object is TestRenderer {self?.updateRendering()}
        })
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateRendering() })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.watch(false);self?.setRendering(false) })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateRendering() })
        }
        updateRendering()
    }
    private func setRendering(_ enabled: Bool) {
        // SceneKit schedules delegate updates even with isPlaying=false.
        // Detach the delegate as well so an idle view has no frame callback.
        delegate = enabled ? (frameDelegate ?? motionSource) : nil
        guard rendersContinuously != enabled || isPlaying != enabled else {return}
        motionSource?.pauseTiming()
        rendersContinuously = enabled;isPlaying = enabled
    }
    func updateRendering() {
        let visible = window.map {$0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)} ?? false
        let shown = visible && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
        let enabled = shown && motionSource?.needsFrames == true
        setRendering(enabled)
        watch(shown && !enabled && motionSource != nil)
    }
    override func viewDidHide() {super.viewDidHide();updateRendering()}
    override func viewDidUnhide() {super.viewDidUnhide();updateRendering()}
    deinit {if watching {previewWatch(false)};observers.forEach(NotificationCenter.default.removeObserver)}
}
final class TestSceneHost: NSView {
    let sceneView: TestSceneView
    init(sceneView: TestSceneView) {self.sceneView = sceneView;super.init(frame: .zero)}
    required init?(coder: NSCoder) {fatalError("Use init(sceneView:)")}
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else {park();return}
        if sceneView.superview !== self {sceneView.removeFromSuperview();addSubview(sceneView)}
        sceneView.frame = bounds
    }
    func park() {
        guard sceneView.superview === self else {return}
        sceneView.removeFromSuperview();sceneView.updateRendering()
    }
}
struct TestScene: NSViewRepresentable {
    let renderer: TestRenderer
    let sceneView: TestSceneView
    let device: UInt32
    let profile: Profile
    func makeNSView(context: Context) -> TestSceneHost {
        let host = TestSceneHost(sceneView: sceneView)
        sceneView.autoresizingMask = []
        sceneView.motionSource = renderer;sceneView.scene = renderer.scene;sceneView.pointOfView = renderer.camera
        sceneView.preferredFramesPerSecond = 120;sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = .clear
        return host
    }
    func updateNSView(_ host: TestSceneHost, context: Context) {renderer.configure(device: device, profile: profile)}
    static func dismantleNSView(_ host: TestSceneHost, coordinator: ()) {
        guard host.sceneView.superview === host else {return}
        host.park();host.sceneView.motionSource = nil
    }
}
struct TestTab: View {
    @EnvironmentObject var model: Model
    var body: some View {
        GeometryReader {space in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Test").font(.title2.bold())
                    Spacer()
                    Button("Reset object") {model.testRenderer.reset()}
                        .help("Restore position, rotation and zoom")
                }
                TestScene(renderer: model.testRenderer, sceneView: model.testSceneView, device: UInt32(model.device?.id ?? 0), profile: model.profile)
                    .frame(height: max(190, space.size.height * 0.53))
                    .overlay(alignment: .bottomLeading) {
                        Text("Toy Car · Guido Odendahl & Eric Chadwick · CC0")
                            .font(.caption2).foregroundStyle(.secondary).padding(10)
                    }
                    .panelSurface().clipShape(RoundedRectangle(cornerRadius: 12))
                    .help("Pan and rotate with the cap. Near / far zooms continuously.")
                if let error = model.testRenderer.modelError {Text(error).font(.caption).foregroundStyle(.orange)}
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Button events").font(.headline)
                        Text("\(model.buttonLog.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Export…", action: model.exportButtonLog).help("Export the full session, including events outside the visible history")
                        Button("Clear view", action: model.clearButtonLog)
                    }.padding(12)
                    Divider()
                    ScrollView {
                        if model.buttonLog.isEmpty {
                            Text("Press a controller button to see its events.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.buttonLog.reversed()) {entry in
                                HStack {
                                    Text(entry.time, format: .dateTime.hour().minute().second(.twoDigits).secondFraction(.fractional(3))).monospacedDigit().frame(width: 110, alignment: .leading)
                                    Text(entry.buttonName).frame(width: 160, alignment: .leading).lineLimit(2)
                                    Text(entry.pressed ? "Pressed" : (entry.reset ? "Released · reset" : "Released"))
                                        .foregroundStyle(entry.pressed ? Color.green : Color.secondary)
                                    Spacer()
                                    Text(entry.deviceName).foregroundStyle(.secondary).lineLimit(2).help(entry.deviceName)
                                }.font(.system(.caption, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 7)
                                Divider().opacity(0.4)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.lostButtonLogs > 0 {
                        Text("\(model.lostButtonLogs) events exceeded the log buffer.").font(.caption).foregroundStyle(.orange).padding(8)
                    }
                    if let error = model.buttonLogError {Text(error).font(.caption).foregroundStyle(.orange).padding(8)}
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panelSurface()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }.frame(width: space.size.width, height: space.size.height, alignment: .top)
        }
    }
}
