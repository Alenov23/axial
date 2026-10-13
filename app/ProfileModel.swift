import Foundation

// SpaceControl profile model. Every field decodes with a default, so profiles
// written by upstream Axial load unchanged, and upstream frameworks ignore the
// added keys. The service (src/service.mm parseProfile) validates the same ranges.

enum AxisInfo {
    static let short = ["X", "Y", "Z", "RX", "RY", "RZ"]
    static let names = ["Pan left / right", "Push / pull", "Lift / press", "Tilt fwd / back", "Roll left / right", "Twist (spin)"]
    static let outputs = ["Pan X", "Zoom / dolly", "Pan Y", "Tilt", "Roll", "Spin"]
    static let symbols = ["arrow.left.and.right", "arrow.up.and.down.and.arrow.left.and.right", "arrow.up.and.down", "rotate.3d", "arrow.triangle.2.circlepath", "arrow.clockwise"]
    static func isRotation(_ i: Int) -> Bool {i >= 3}
}

enum CurveKind: String, Codable, CaseIterable, Identifiable {
    case linear, expo, power, scurve
    var id: String {rawValue}
    var title: String {
        switch self {case .linear: "Linear"; case .expo: "Expo"; case .power: "Power"; case .scurve: "S-curve"}
    }
    var index: UInt32 {UInt32(Self.allCases.firstIndex(of: self)!)}
}

enum AxisLock: String, Codable, CaseIterable, Identifiable {
    case none, dominant, group
    var id: String {rawValue}
    var title: String {
        switch self {case .none: "Free 6DoF"; case .dominant: "Dominant axis only"; case .group: "Translate OR rotate"}
    }
}

struct MacroStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var keyCode: Int? = nil
    var modifiers: UInt64? = nil
    var text: String? = nil
    var delay: Double? = nil
    var label: String? = nil
    enum CodingKeys: String, CodingKey {case keyCode, modifiers, text, delay, label}
    var summary: String {
        if keyCode != nil {return label ?? "Key \(keyCode!)"}
        if let text {return "Type “\(text)”"}
        if let delay {return "Wait \(Int(delay)) ms"}
        return "Empty"
    }
}

struct ButtonAction: Codable, Equatable {
    var keyCode: Int? = nil
    var modifiers: UInt64? = nil
    var command: String? = nil
    var action: String? = nil
    var label: String? = nil
    var macro: [MacroStep]? = nil
    var open: String? = nil
    var shell: String? = nil
    /// false: the native button event is withheld from the application.
    var passthrough: Bool? = nil

    enum Kind: String, CaseIterable, Identifiable {
        case none, shortcut, macro, command, driver, open, shell
        var id: String {rawValue}
        var title: String {
            switch self {
            case .none: "Native button (app decides)"
            case .shortcut: "Keyboard shortcut"
            case .macro: "Macro sequence"
            case .command: "Application command"
            case .driver: "Driver action"
            case .open: "Open app / file / URL"
            case .shell: "Run shell command"
            }
        }
        var symbol: String {
            switch self {
            case .none: "circle.dashed"; case .shortcut: "command"; case .macro: "list.bullet.rectangle"
            case .command: "app.badge"; case .driver: "gearshape.2"; case .open: "arrow.up.forward.app"; case .shell: "terminal"
            }
        }
    }
    var kind: Kind {
        if keyCode != nil {return .shortcut}
        if macro != nil {return .macro}
        if command != nil {return .command}
        if action != nil {return .driver}
        if open != nil {return .open}
        if shell != nil {return .shell}
        return .none
    }
    var summary: String {
        switch kind {
        case .none: "—"
        case .shortcut: label ?? "Key \(keyCode ?? 0)"
        case .macro: "\(macro?.count ?? 0)-step macro"
        case .command: command ?? ""
        case .driver: DriverAction(rawValue: action ?? "")?.title ?? (action ?? "")
        case .open: (open as NSString?)?.lastPathComponent ?? ""
        case .shell: shell ?? ""
        }
    }
}

enum DriverAction: String, CaseIterable, Identifiable {
    case dominant, group, translation, rotation, pause, faster, slower, resetSpeed, fit
    var id: String {rawValue}
    var title: String {
        switch self {
        case .dominant: "Toggle dominant-axis lock"
        case .group: "Toggle translate-or-rotate lock"
        case .translation: "Toggle translation"
        case .rotation: "Toggle rotation"
        case .pause: "Pause / resume all motion"
        case .faster: "Increase speed (×1.25)"
        case .slower: "Decrease speed (÷1.25)"
        case .resetSpeed: "Reset speed to profile"
        case .fit: "Fit view"
        }
    }
}

struct Profile: Codable, Equatable {
    var name: String? = nil
    // Output stage (upstream Axial fields keep their meaning).
    var gain: [Double] = Array(repeating: 1, count: 6)
    var invert: [Bool] = Array(repeating: false, count: 6)
    var enabled: [Bool] = Array(repeating: true, count: 6)
    // Input stage.
    var deadzone: [Double] = Array(repeating: 0, count: 6)
    var sensitivity: [Double] = Array(repeating: 1, count: 6)
    var curve: [CurveKind] = Array(repeating: .linear, count: 6)
    var curveAmount: [Double] = Array(repeating: 0.5, count: 6)
    var smoothing: [Double] = Array(repeating: 0, count: 6)
    var center: [Double] = Array(repeating: 0, count: 6)
    var range: [Double] = Array(repeating: 350, count: 6)
    /// matrix[output][input]
    var matrix: [[Double]] = Profile.identity
    var lock: AxisLock = .none
    var translation = true
    var rotation = true
    var orbit = true
    var led = true
    var buttons: [ButtonAction] = Array(repeating: ButtonAction(), count: 32)

    static let identity: [[Double]] = (0..<6).map {o in (0..<6).map {$0 == o ? 1 : 0}}
    /// Upstream compatibility: `dominant` mirrors the dominant lock.
    var dominant: Bool {
        get {lock == .dominant}
        set {lock = newValue ? .dominant : (lock == .dominant ? .none : lock)}
    }
    enum CodingKeys: String, CodingKey {
        case name, gain, invert, enabled, deadzone, sensitivity, curve, curveAmount, smoothing, center, range, matrix, lock
        case dominant, translation, rotation, orbit, led, buttons
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {try c.decodeIfPresent(T.self, forKey: key) ?? fallback}
        name = try c.decodeIfPresent(String.self, forKey: .name)
        gain = try value(.gain, gain);invert = try value(.invert, invert);enabled = try value(.enabled, enabled)
        deadzone = try value(.deadzone, deadzone);sensitivity = try value(.sensitivity, sensitivity)
        curve = try value(.curve, curve);curveAmount = try value(.curveAmount, curveAmount)
        smoothing = try value(.smoothing, smoothing);center = try value(.center, center);range = try value(.range, range)
        matrix = try value(.matrix, matrix)
        let legacyDominant = try value(.dominant, false)
        lock = try value(.lock, legacyDominant ? AxisLock.dominant : .none)
        if lock == .none && legacyDominant && !c.contains(.lock) {lock = .dominant}
        translation = try value(.translation, translation);rotation = try value(.rotation, rotation)
        orbit = try value(.orbit, orbit);led = try value(.led, led)
        buttons = try value(.buttons, buttons)
        buttons += Array(repeating: ButtonAction(), count: max(0, 32 - buttons.count))
        let six = [gain.count, invert.count, enabled.count, deadzone.count, sensitivity.count, curve.count, curveAmount.count, smoothing.count, center.count, range.count, matrix.count]
        guard six.allSatisfy({$0 == 6}), matrix.allSatisfy({$0.count == 6}), buttons.count == 32 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid profile dimensions"))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(gain, forKey: .gain);try c.encode(invert, forKey: .invert);try c.encode(enabled, forKey: .enabled)
        try c.encode(deadzone, forKey: .deadzone);try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(curve, forKey: .curve);try c.encode(curveAmount, forKey: .curveAmount)
        try c.encode(smoothing, forKey: .smoothing);try c.encode(center, forKey: .center);try c.encode(range, forKey: .range)
        try c.encode(matrix, forKey: .matrix);try c.encode(lock, forKey: .lock);try c.encode(dominant, forKey: .dominant)
        try c.encode(translation, forKey: .translation);try c.encode(rotation, forKey: .rotation)
        try c.encode(orbit, forKey: .orbit);try c.encode(led, forKey: .led);try c.encode(buttons, forKey: .buttons)
    }

    /// Route one physical input exclusively to an output (drag-and-drop assignment).
    mutating func assign(input: Int, to output: Int, weight: Double = 1) {
        for o in 0..<6 where matrix[o][input] != 0 && o != output {matrix[o][input] = 0}
        matrix[output] = Array(repeating: 0, count: 6);matrix[output][input] = weight
    }
    /// Exchange two outputs' sources (swap axes).
    mutating func swapOutputs(_ a: Int, _ b: Int) {matrix.swapAt(a, b)}
    /// The dominant input feeding an output, if any.
    func source(of output: Int) -> Int? {
        let row = matrix[output];guard let best = row.indices.max(by: {abs(row[$0]) < abs(row[$1])}), row[best] != 0 else {return nil}
        return best
    }
}

/// Built-in mapping presets; applied to the motion part of the selected profile.
enum MappingPreset: String, CaseIterable, Identifiable {
    case identity, twistZoom, swapYZ, panOnly, rotateOnly, invertRotation, liftZoom, mixed
    var id: String {rawValue}
    var title: String {
        switch self {
        case .identity: "Straight through (default)"
        case .twistZoom: "Twist knob → zoom"
        case .swapYZ: "Swap push/pull ↔ lift/press"
        case .panOnly: "Pan & zoom only (no rotation)"
        case .rotateOnly: "Rotate only"
        case .invertRotation: "Invert all rotations"
        case .liftZoom: "Lift/press → zoom, push/pull → pan Y"
        case .mixed: "Tilt also pans (mixed)"
        }
    }
    func apply(_ p: inout Profile) {
        p.matrix = Profile.identity;p.enabled = Array(repeating: true, count: 6);p.invert = Array(repeating: false, count: 6)
        switch self {
        case .identity: break
        case .twistZoom: p.assign(input: 5, to: 1);p.enabled[5] = false
        case .swapYZ: p.swapOutputs(1, 2)
        case .panOnly: for o in 3..<6 {p.enabled[o] = false}
        case .rotateOnly: for o in 0..<3 {p.enabled[o] = false}
        case .invertRotation: for o in 3..<6 {p.invert[o] = true}
        case .liftZoom: p.matrix[1] = [0, 0, 1, 0, 0, 0];p.matrix[2] = [0, 1, 0, 0, 0, 0]
        case .mixed: p.matrix[0][4] = 0.5;p.matrix[2][3] = -0.5
        }
    }
}

/// Application presets offered when adding profiles.
struct AppPreset: Identifiable {
    let id: String   // bundle identifier
    let title: String
    let configure: (inout Profile) -> Void
    static let all: [AppPreset] = [
        AppPreset(id: "com.autodesk.fusion360", title: "Autodesk Fusion") {p in
            p.name = "Fusion";p.lock = .none
            for i in 0..<6 {p.curve[i] = .expo;p.curveAmount[i] = 0.35;p.deadzone[i] = 8;p.smoothing[i] = 12}
        },
        AppPreset(id: "com.orcaslicer.OrcaSlicer", title: "OrcaSlicer") {p in
            p.name = "OrcaSlicer";for i in 0..<6 {p.curve[i] = .expo;p.curveAmount[i] = 0.5;p.deadzone[i] = 10}
            p.gain[4] = 0.6
        },
        AppPreset(id: "org.blenderfoundation.blender", title: "Blender") {p in
            p.name = "Blender";for i in 0..<6 {p.curve[i] = .scurve;p.curveAmount[i] = 0.4;p.deadzone[i] = 6;p.smoothing[i] = 8}
        },
        AppPreset(id: "com.prusa3d.slic3r.", title: "PrusaSlicer") {p in
            p.name = "PrusaSlicer";for i in 0..<6 {p.curve[i] = .expo;p.curveAmount[i] = 0.5;p.deadzone[i] = 10}
        },
        AppPreset(id: "org.freecad.FreeCAD", title: "FreeCAD") {p in
            p.name = "FreeCAD";for i in 0..<6 {p.curve[i] = .expo;p.curveAmount[i] = 0.3;p.deadzone[i] = 8}
        },
    ]
}

/// Portable profile file (`.spacecontrol.json`): one or many profiles with their keys.
struct ProfileBundle: Codable {
    var format = "axial-spacecontrol-profiles"
    var version = 1
    var profiles: [String: Profile]
}
