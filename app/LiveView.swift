import SwiftUI
import SceneKit
import simd

@_silgen_name("AxialPreviewReadMapped") func previewReadMapped(_ device: UInt32, _ axes: UnsafeMutablePointer<Double>) -> Bool
@_silgen_name("AxialShapeInput") func shapeInput(_ raw: Double, _ sensitivity: Double, _ deadzone: Double, _ curve: UInt32, _ amount: Double, _ center: Double, _ range: Double) -> Double

/// Lock-free sample of the service's raw and post-mapping streams for one device.
struct LiveSample: Equatable {
    var raw = [Double](repeating: 0, count: 6)
    var mapped = [Double](repeating: 0, count: 6)
    var buttons: UInt32 = 0
    var hasMapped = false
    static func read(device: UInt32) -> LiveSample {
        var s = LiveSample()
        s.raw.withUnsafeMutableBufferPointer {_ = previewRead(device, $0.baseAddress!, &s.buttons)}
        s.hasMapped = s.mapped.withUnsafeMutableBufferPointer {previewReadMapped(device, $0.baseAddress!)}
        return s
    }
}

/// Publishes samples at display-friendly rate while a live pane is visible.
@MainActor final class LiveInput: ObservableObject {
    @Published private(set) var sample = LiveSample()
    var device: UInt32 = 0
    private var timer: Timer?
    private var users = 0
    func start() {
        users += 1
        guard timer == nil else {return}
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {[weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return}
                let next = LiveSample.read(device: self.device)
                if next != self.sample {self.sample = next}
            }
        }
    }
    func stop() {users = max(0, users - 1);if users == 0 {timer?.invalidate();timer = nil}}
}

// MARK: - SceneKit: physical SpaceExplorer and virtual 6DoF output

enum PuckGeometry {
    // Device axis -> scene axis: X→+x, Y→+z, Z→−y for both translation and rotation
    // (matches Axial's Blender-convention test scene).
    static func translation(_ a: [Double], scale: Double) -> SIMD3<Float> {
        SIMD3(Float(a[0]), Float(-a[2]), Float(a[1])) * Float(scale / 350)
    }
    static func rotation(_ a: [Double], degrees: Double) -> simd_quatf {
        let v = SIMD3(Float(a[3]), Float(-a[5]), Float(a[4])) / 350
        let length = simd_length(v)
        guard length > 1e-4 else {return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))}
        return simd_quatf(angle: length * Float(degrees * .pi / 180), axis: v / length)
    }
    static func material(_ color: NSColor, metal: CGFloat = 0.2, rough: CGFloat = 0.45, emission: NSColor? = nil) -> SCNMaterial {
        let m = SCNMaterial();m.lightingModel = .physicallyBased
        m.diffuse.contents = color;m.metalness.contents = metal;m.roughness.contents = rough
        if let emission {m.emission.contents = emission}
        return m
    }
    static let axisColors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemRed, .systemGreen, .systemBlue]

    static func arrow(color: NSColor) -> SCNNode {
        let node = SCNNode()
        let shaft = SCNCylinder(radius: 0.018, height: 1);shaft.materials = [material(color, emission: color.withAlphaComponent(0.6))]
        let head = SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.12);head.materials = shaft.materials
        let s = SCNNode(geometry: shaft);s.position.y = 0.5;s.name = "shaft"
        let h = SCNNode(geometry: head);h.position.y = 1.06;h.name = "head"
        node.addChildNode(s);node.addChildNode(h)
        return node
    }
    static func lights(_ scene: SCNScene) {
        let key = SCNNode();key.light = SCNLight();key.light!.type = .directional;key.light!.intensity = 900
        key.light!.castsShadow = true;key.light!.shadowRadius = 6;key.light!.shadowColor = NSColor.black.withAlphaComponent(0.45)
        key.eulerAngles = SCNVector3(-1.0, 0.6, 0);scene.rootNode.addChildNode(key)
        let fill = SCNNode();fill.light = SCNLight();fill.light!.type = .ambient;fill.light!.intensity = 380
        fill.light!.color = NSColor(calibratedRed: 0.75, green: 0.85, blue: 1, alpha: 1);scene.rootNode.addChildNode(fill)
        let rim = SCNNode();rim.light = SCNLight();rim.light!.type = .omni;rim.light!.intensity = 500
        rim.position = SCNVector3(-2, 2, -2.5);scene.rootNode.addChildNode(rim)
    }
    static func camera(_ scene: SCNScene, distance: Float = 3.2, height: Float = 1.9) -> SCNNode {
        let c = SCNNode();c.camera = SCNCamera();c.camera!.fieldOfView = 38;c.camera!.wantsHDR = true
        c.camera!.bloomIntensity = 0.4;c.camera!.bloomThreshold = 0.85
        c.position = SCNVector3(0, height, distance);c.look(at: SCNVector3(0, 0.15, 0))
        scene.rootNode.addChildNode(c);return c
    }
    static func floor(_ scene: SCNScene) {
        let f = SCNFloor();f.reflectivity = 0.08;f.materials = [material(NSColor(white: 0.13, alpha: 1), metal: 0, rough: 0.9)]
        let n = SCNNode(geometry: f);n.position.y = -0.2;scene.rootNode.addChildNode(n)
    }
}

/// Builds a stylised SpaceExplorer: wedge base, 15 keys, rubber-ringed cap.
final class PhysicalPuckScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cap = SCNNode()
    let translationArrow = PuckGeometry.arrow(color: .systemOrange)
    private(set) var cameraNode = SCNNode()
    private var keyNodes: [Int: SCNNode] = [:]
    private var current = LiveSample()
    private var smoothedT = SIMD3<Float>.zero
    private var smoothedR = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    var device: UInt32 = 0
    var useMapped = false

    override init() {
        super.init()
        scene.background.contents = NSColor.clear
        PuckGeometry.lights(scene);PuckGeometry.floor(scene)
        cameraNode = PuckGeometry.camera(scene)
        let base = SCNBox(width: 2.1, height: 0.22, length: 1.45, chamferRadius: 0.1)
        base.materials = [PuckGeometry.material(NSColor(white: 0.16, alpha: 1), metal: 0.1, rough: 0.55)]
        let baseNode = SCNNode(geometry: base);baseNode.position.y = -0.09;scene.rootNode.addChildNode(baseNode)
        let palm = SCNBox(width: 2.0, height: 0.1, length: 0.55, chamferRadius: 0.05)
        palm.materials = [PuckGeometry.material(NSColor(white: 0.24, alpha: 1), metal: 0.6, rough: 0.3)]
        let palmNode = SCNNode(geometry: palm);palmNode.position = SCNVector3(0, 0.05, 0.42);scene.rootNode.addChildNode(palmNode)
        // SpaceExplorer key layout (slot -> position), approximating the real device.
        let layout: [(Int, Float, Float)] = [
            (0, -0.92, -0.45), (1, 0.92, -0.45),                         // 1, 2
            (2, -0.92, -0.12), (3, -0.92, 0.12), (4, 0.92, -0.12), (5, 0.92, 0.12), // Top, Left, Right, Front
            (6, -0.75, 0.48), (7, -0.45, 0.52), (8, -0.15, 0.54), (9, 0.15, 0.54), // Esc Alt Shift Ctrl
            (10, 0.45, 0.52), (11, 0.75, 0.48),                          // Fit Panel
            (12, 0.62, -0.5), (13, 0.62, -0.25), (14, -0.62, -0.5),      // + − 2D
        ]
        for (slot, x, z) in layout {
            let key = SCNBox(width: 0.2, height: 0.05, length: 0.13, chamferRadius: 0.03)
            key.materials = [PuckGeometry.material(NSColor(white: 0.42, alpha: 1), metal: 0.1, rough: 0.4)]
            let node = SCNNode(geometry: key);node.position = SCNVector3(x, 0.04, z)
            scene.rootNode.addChildNode(node);keyNodes[slot] = node
        }
        let post = SCNCylinder(radius: 0.12, height: 0.1);post.materials = [PuckGeometry.material(.black)]
        let postNode = SCNNode(geometry: post);postNode.position.y = 0.06;scene.rootNode.addChildNode(postNode)
        let body = SCNCylinder(radius: 0.42, height: 0.26)
        body.materials = [PuckGeometry.material(NSColor(white: 0.2, alpha: 1), metal: 0.2, rough: 0.7),
                          PuckGeometry.material(NSColor(white: 0.55, alpha: 1), metal: 0.9, rough: 0.25),
                          PuckGeometry.material(NSColor(white: 0.2, alpha: 1))]
        let bodyNode = SCNNode(geometry: body);cap.addChildNode(bodyNode)
        let ring = SCNTorus(ringRadius: 0.42, pipeRadius: 0.035)
        ring.materials = [PuckGeometry.material(NSColor.systemBlue, metal: 0.3, rough: 0.3, emission: NSColor.systemBlue.withAlphaComponent(0.4))]
        let ringNode = SCNNode(geometry: ring);ringNode.position.y = 0.13;ringNode.name = "ring";cap.addChildNode(ringNode)
        // Orientation marker on the cap so twist and roll are readable.
        let notch = SCNBox(width: 0.06, height: 0.02, length: 0.2, chamferRadius: 0.01)
        notch.materials = [PuckGeometry.material(.systemOrange, emission: .systemOrange)]
        let notchNode = SCNNode(geometry: notch);notchNode.position = SCNVector3(0, 0.135, -0.25);cap.addChildNode(notchNode)
        cap.position.y = 0.28;scene.rootNode.addChildNode(cap)
        translationArrow.position.y = 0.28;translationArrow.isHidden = true;scene.rootNode.addChildNode(translationArrow)
    }
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let s = LiveSample.read(device: device)
        let axes = useMapped ? s.mapped : s.raw
        // Visual easing only; numeric readouts show exact values.
        smoothedT = simd_mix(smoothedT, PuckGeometry.translation(axes, scale: 0.16), SIMD3(repeating: 0.35))
        smoothedR = simd_slerp(smoothedR, PuckGeometry.rotation(axes, degrees: 22), 0.35)
        let t = smoothedT, r = smoothedR, buttons = s.buttons
        let magnitude = simd_length(t)
        SCNTransaction.begin();SCNTransaction.disableActions = true
        cap.simdPosition = SIMD3(0, 0.28, 0) + t;cap.simdOrientation = r
        if magnitude > 0.004 {
            translationArrow.isHidden = false
            let direction = t / magnitude
            translationArrow.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction)
            translationArrow.simdScale = SIMD3(1, min(1.2, magnitude * 6), 1)
            translationArrow.simdPosition = SIMD3(0, 0.28, 0) + t
        } else {translationArrow.isHidden = true}
        for (slot, node) in keyNodes {
            let down = buttons & (1 << UInt32(slot)) != 0
            node.geometry?.firstMaterial?.emission.contents = down ? NSColor.systemGreen : NSColor.black
            node.position.y = down ? 0.02 : 0.04
        }
        SCNTransaction.commit()
    }
}

/// Virtual output: what the CAD application receives, as a 6DoF gizmo.
final class OutputGizmoScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let gizmo = SCNNode()
    private var arrows: [SCNNode] = []
    private var smoothedT = SIMD3<Float>.zero
    private var smoothedR = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    var device: UInt32 = 0
    override init() {
        super.init()
        PuckGeometry.lights(scene);PuckGeometry.floor(scene);_ = PuckGeometry.camera(scene, distance: 3.0, height: 1.6)
        let cube = SCNBox(width: 0.5, height: 0.5, length: 0.5, chamferRadius: 0.08)
        let faces: [NSColor] = [.systemBlue, .systemRed, .systemBlue, .systemRed, .systemGreen, .systemGreen]
        cube.materials = faces.map {PuckGeometry.material($0.blended(withFraction: 0.55, of: .black) ?? $0, metal: 0.4, rough: 0.35)}
        gizmo.addChildNode(SCNNode(geometry: cube))
        // Body axes: x red, y green (up), z blue.
        for (axis, color) in [(SIMD3<Float>(1, 0, 0), NSColor.systemRed), (SIMD3<Float>(0, 1, 0), NSColor.systemGreen), (SIMD3<Float>(0, 0, 1), NSColor.systemBlue)] {
            let a = PuckGeometry.arrow(color: color);a.simdScale = SIMD3(1, 0.6, 1)
            a.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: axis);gizmo.addChildNode(a)
        }
        gizmo.position.y = 0.45;scene.rootNode.addChildNode(gizmo)
        // Ghost at rest for reference.
        let ghost = SCNBox(width: 0.52, height: 0.52, length: 0.52, chamferRadius: 0.08)
        let ghostMaterial = SCNMaterial();ghostMaterial.diffuse.contents = NSColor.white.withAlphaComponent(0.06)
        ghostMaterial.fillMode = .lines;ghost.materials = [ghostMaterial]
        let ghostNode = SCNNode(geometry: ghost);ghostNode.position.y = 0.45;scene.rootNode.addChildNode(ghostNode)
    }
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let s = LiveSample.read(device: device)
        smoothedT = simd_mix(smoothedT, PuckGeometry.translation(s.mapped, scale: 0.55), SIMD3(repeating: 0.35))
        smoothedR = simd_slerp(smoothedR, PuckGeometry.rotation(s.mapped, degrees: 40), 0.35)
        SCNTransaction.begin();SCNTransaction.disableActions = true
        gizmo.simdPosition = SIMD3(0, 0.45, 0) + smoothedT;gizmo.simdOrientation = smoothedR
        SCNTransaction.commit()
    }
}

struct SceneHost: NSViewRepresentable {
    let scene: SCNScene
    let delegate: SCNSceneRendererDelegate
    var allowsCamera = true
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.scene = scene;view.delegate = delegate;view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X;view.preferredFramesPerSecond = 60
        view.rendersContinuously = true;view.isPlaying = true;view.allowsCameraControl = allowsCamera
        view.defaultCameraController.interactionMode = .orbitTurntable
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {}
    static func dismantleNSView(_ view: SCNView, coordinator: ()) {view.isPlaying = false;view.rendersContinuously = false;view.delegate = nil}
}

// MARK: - Readouts

struct SignedBar: View {
    let value: Double
    var color: Color = .accentColor
    var body: some View {
        GeometryReader {g in
            let half = g.size.width / 2, fraction = min(abs(value) / 350, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(value < 0 ? Color.orange : color).frame(width: half * fraction)
                    .offset(x: value < 0 ? half * (1 - fraction) : half)
                Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1).offset(x: half - 0.5)
            }
        }.frame(height: 8)
    }
}

struct AxisReadoutTable: View {
    let sample: LiveSample
    let profile: Profile
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                Text("PHYSICAL INPUT").gridCellColumns(3)
                Text("")
                Text("OUTPUT TO APP").gridCellColumns(3)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(0..<6, id: \.self) {i in
                GridRow {
                    Text(AxisInfo.short[i]).font(.system(.callout, design: .monospaced).bold()).foregroundStyle(Color(nsColor: PuckGeometry.axisColors[i])).frame(width: 28, alignment: .leading)
                    SignedBar(value: sample.raw[i]).frame(minWidth: 70)
                    Text(String(format: "%+5.0f", sample.raw[i])).font(.system(.callout, design: .monospaced)).frame(width: 46, alignment: .trailing)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(AxisInfo.outputs[i]).font(.caption).frame(width: 82, alignment: .leading).foregroundStyle(profile.enabled[i] ? .primary : .tertiary)
                    SignedBar(value: sample.mapped[i], color: .green).frame(minWidth: 70)
                    Text(String(format: "%+5.0f", sample.mapped[i])).font(.system(.callout, design: .monospaced)).frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

struct LiveTab: View {
    @EnvironmentObject var model: Model
    @StateObject private var live = LiveInput()
    @State private var physical = PhysicalPuckScene()
    @State private var output = OutputGizmoScene()
    var body: some View {
        let device = UInt32(model.device?.id ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live").font(.title2.bold())
                Text("Editing “\(model.profileName(model.selected))” · changes apply instantly").foregroundStyle(.secondary)
                Spacer()
                if !live.sample.hasMapped && model.status != nil {
                    Label("Move the cap to stream the mapped output", systemImage: "hand.point.up.left").font(.caption).foregroundStyle(.secondary)
                }
                Menu("Mapping preset") {
                    ForEach(MappingPreset.allCases) {preset in Button(preset.title) {model.edit {preset.apply(&$0)}}}
                }.frame(width: 160)
            }
            HStack(spacing: 12) {
                panel(title: "Physical SpaceExplorer", subtitle: "raw HID input", symbol: "cube.transparent") {
                    SceneHost(scene: physical.scene, delegate: physical)
                }
                panel(title: "Mapped 6DoF output", subtitle: "exactly what the CAD app receives", symbol: "move.3d") {
                    SceneHost(scene: output.scene, delegate: output)
                }
            }.frame(maxHeight: .infinity)
            GroupBox {
                AxisReadoutTable(sample: live.sample, profile: model.profile).padding(4)
            }
            HStack(spacing: 14) {
                Label(model.status?.activeProfile.map {"Active in \(model.status?.foregroundApp ?? ""): \(model.profileName($0))"} ?? "Service not connected", systemImage: "app.connected.to.app.below.fill")
                Spacer()
                Label("Lock: \(model.profile.lock.title)", systemImage: "lock")
                Label(model.profile.translation ? "Translation on" : "Translation off", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label(model.profile.rotation ? "Rotation on" : "Rotation off", systemImage: "rotate.3d")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {physical.device = device;output.device = device;live.device = device;live.start()}
        .onDisappear {live.stop()}
        .onChange(of: device) {value in physical.device = value;output.device = value;live.device = value}
    }
    func panel<Content: View>(title: String, subtitle: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(title, systemImage: symbol).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            .overlay(alignment: .bottomTrailing) {Text("drag to orbit").font(.caption2).foregroundStyle(.tertiary).padding(8)}
            .panelSurface().clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
