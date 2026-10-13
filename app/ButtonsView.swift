import SwiftUI
import AppKit

struct ButtonsTab: View {
    @EnvironmentObject var model: Model
    @StateObject private var live = LiveInput()
    @State private var selection = 0
    @State private var recordingMacro = false
    @State private var textStep = ""
    @State private var delayStep = 100.0

    var buttons: [ControllerButton] {model.device?.layout?.buttons ?? DeviceCatalog.layouts[0x046dc627]?.buttons ?? []}

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Buttons").font(.title2.bold())
                    Spacer()
                    Text("\(model.device?.displayName ?? "SpaceExplorer") · \(buttons.count) buttons").foregroundStyle(.secondary)
                }
                Text("Click a key — or just press it on the device — to edit it.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(buttons) {button in row(button)}
                    }.padding(.trailing, 6)
                }
            }.frame(width: 380)
            editor.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            live.device = UInt32(model.device?.id ?? 0);live.start()
            if !buttons.contains(where: {$0.id == selection}) {selection = buttons.first?.id ?? 0}
        }
        .onDisappear {live.stop();model.recording = nil}
        .onChange(of: live.sample.buttons) {value in
            // Pressing a physical key selects it (unless a shortcut is being recorded).
            guard model.recording == nil, !recordingMacro, value != 0 else {return}
            if let pressed = buttons.first(where: {value & (1 << UInt32($0.id)) != 0}) {selection = pressed.id}
        }
    }

    func row(_ button: ControllerButton) -> some View {
        let a = model.profile.buttons[button.id]
        let down = live.sample.buttons & (1 << UInt32(button.id)) != 0
        return Button {selection = button.id;model.recording = nil;recordingMacro = false} label: {
            HStack(spacing: 10) {
                Text(button.name).font(.system(.callout, design: .rounded).bold())
                    .frame(width: 52, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(down ? Color.green : Color.primary.opacity(0.1)))
                    .foregroundStyle(down ? Color.black : Color.primary)
                Image(systemName: a.kind.symbol).foregroundStyle(a.kind == .none ? Color.secondary : Color.accentColor).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.kind == .none ? "Native button" : a.summary).lineLimit(1)
                    Text(a.kind.title + (a.passthrough == false ? " · withheld from app" : "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(selection == button.id ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.035)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var appKey: String {String(model.selected.split(separator: "@").first ?? "*")}
    func set(_ change: @escaping (inout ButtonAction) -> Void) {let i = selection;model.edit {change(&$0.buttons[i])}}

    @ViewBuilder var editor: some View {
        let i = selection
        let a = model.profile.buttons[i]
        let name = buttons.first(where: {$0.id == i})?.name ?? "Button \(i + 1)"
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("“\(name)” key").font(.title3.bold())
                Text("in \(model.profileName(model.selected))").foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {set {$0 = ButtonAction()}}
            }
            GroupBox("Behaviour") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Type", selection: Binding(get: {a.kind}, set: {kind in
                        set {b in
                            guard b.kind != kind else {return}
                            let keepPass = b.passthrough
                            b = ButtonAction()
                            switch kind {
                            case .none: break
                            case .shortcut: model.recording = i
                            case .macro: b.macro = []
                            case .command: b.command = (model.commands[appKey]?.first?.id) ?? ""
                            case .driver: b.action = DriverAction.fit.rawValue
                            case .open: b.open = ""
                            case .shell: b.shell = ""
                            }
                            // Custom assignments own the key by default to avoid double actions.
                            b.passthrough = kind == .none || kind == .command ? nil : (keepPass ?? false)
                        }
                    })) {
                        ForEach(ButtonAction.Kind.allCases) {Label($0.title, systemImage: $0.symbol).tag($0)}
                    }
                    switch a.kind {
                    case .none where model.recording == i: shortcutEditor(a)
                    case .none:
                        Text("The application receives this button natively (e.g. Fusion and Blender map Fit, views and modifiers themselves).").font(.caption).foregroundStyle(.secondary)
                    case .shortcut: shortcutEditor(a)
                    case .macro: macroEditor(a)
                    case .command: commandEditor(a)
                    case .driver:
                        Picker("Action", selection: Binding(get: {a.action ?? ""}, set: {x in set {$0.action = x}})) {
                            ForEach(DriverAction.allCases) {Text($0.title).tag($0.rawValue)}
                        }
                    case .open:
                        HStack {
                            TextField("URL, file or application path", text: Binding(get: {a.open ?? ""}, set: {x in set {$0.open = x}}))
                            Button("Choose…") {
                                let panel = NSOpenPanel();panel.canChooseDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {set {$0.open = url.path}}
                            }
                        }
                    case .shell:
                        TextField("/bin/sh command, e.g. osascript -e 'beep'", text: Binding(get: {a.shell ?? ""}, set: {x in set {$0.shell = x}}))
                            .font(.system(.body, design: .monospaced))
                        Text("Runs as you, in the background, when the key is pressed.").font(.caption).foregroundStyle(.secondary)
                    }
                    if a.kind != .none && a.kind != .command {
                        Toggle("Also send the native button to the application", isOn: Binding(get: {a.passthrough ?? true}, set: {x in set {$0.passthrough = x ? nil : false}}))
                    }
                }.padding(4)
            }
            if model.status?.accessibility == false && [.shortcut, .macro].contains(a.kind) {
                HStack {
                    Label("Shortcuts and macros need Accessibility permission for the Axial service.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Grant…", action: model.requestAccessibility)
                }.font(.caption)
            }
            GroupBox("Application-specific") {
                Text("Button assignments belong to the selected profile. Select an application profile in the sidebar (Fusion, OrcaSlicer, Blender…) to give this key a different meaning there; Axial switches automatically when that app is in front.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    func shortcutEditor(_ a: ButtonAction) -> some View {
        HStack {
            if model.recording == selection {
                Text("Press the shortcut on your keyboard…").foregroundStyle(.tint)
                    .background(KeyRecorder {key, flags, label in set {$0.keyCode = key;$0.modifiers = flags;$0.label = label};model.recording = nil}.frame(width: 1, height: 1))
                Button("Cancel") {model.recording = nil}
            } else {
                Text(a.label ?? "Key \(a.keyCode ?? 0)").font(.system(.title3, design: .rounded).bold()).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.1)))
                Button("Record again") {model.recording = selection}
            }
            Spacer()
            Text("Held while the key is held").font(.caption).foregroundStyle(.secondary)
        }
    }

    func commandEditor(_ a: ButtonAction) -> some View {
        let commands = model.commands[appKey] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            if commands.isEmpty {
                Text("No command catalog has been published for this profile's application yet. Open the app (Navlib apps such as Fusion publish their commands), or type a command id:").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Command", selection: Binding(get: {a.command ?? ""}, set: {x in set {$0.command = x}})) {
                    ForEach(commands) {Text($0.label).tag($0.id)}
                }
            }
            TextField("Command id", text: Binding(get: {a.command ?? ""}, set: {x in set {$0.command = x}}))
        }
    }

    func macroEditor(_ a: ButtonAction) -> some View {
        let steps = a.macro ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if steps.isEmpty {Text("Add steps below. They run in order when the key is pressed.").font(.caption).foregroundStyle(.secondary)}
            ForEach(Array(steps.enumerated()), id: \.element.id) {index, step in
                HStack {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                    Image(systemName: step.keyCode != nil ? "command" : (step.text != nil ? "character.cursor.ibeam" : "timer"))
                    Text(step.summary)
                    Spacer()
                    Button {set {$0.macro?.swapAt(index, index - 1)}} label: {Image(systemName: "chevron.up")}.disabled(index == 0).buttonStyle(.borderless)
                    Button {set {$0.macro?.swapAt(index, index + 1)}} label: {Image(systemName: "chevron.down")}.disabled(index == steps.count - 1).buttonStyle(.borderless)
                    Button {set {$0.macro?.remove(at: index)}} label: {Image(systemName: "trash")}.buttonStyle(.borderless)
                }.padding(.horizontal, 6).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            Divider()
            HStack {
                if recordingMacro {
                    Text("Press a key…").foregroundStyle(.tint)
                        .background(KeyRecorder {key, flags, label in set {$0.macro?.append(MacroStep(keyCode: key, modifiers: flags, label: label))};recordingMacro = false}.frame(width: 1, height: 1))
                    Button("Cancel") {recordingMacro = false}
                } else {
                    Button {recordingMacro = true} label: {Label("Add key", systemImage: "command")}
                }
                TextField("Text to type", text: $textStep).frame(width: 150)
                Button("Add text") {let t = textStep;guard !t.isEmpty else {return};set {$0.macro?.append(MacroStep(text: t))};textStep = ""}
                Stepper("\(Int(delayStep)) ms", value: $delayStep, in: 10...5000, step: 50).frame(width: 120)
                Button("Add delay") {let d = delayStep;set {$0.macro?.append(MacroStep(delay: d))}}
            }.disabled(steps.count >= 64)
        }
    }
}
