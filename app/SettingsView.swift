import SwiftUI
import AppKit

enum SettingsTab: Int, CaseIterable, Identifiable {
    case live, mapping, tuning, buttons, profiles, test, service
    var id: Int {rawValue}
    var title: String {
        switch self {
        case .live: "Live"; case .mapping: "Mapping"; case .tuning: "Tuning"; case .buttons: "Buttons"
        case .profiles: "Profiles"; case .test: "Test"; case .service: "Service"
        }
    }
    var symbol: String {
        switch self {
        case .live: "move.3d"; case .mapping: "square.grid.3x3.fill"; case .tuning: "slider.horizontal.3"
        case .buttons: "keyboard"; case .profiles: "person.2.crop.square.stack"; case .test: "car"; case .service: "stethoscope"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HSplitView {
            sidebar.padding(18).frame(minWidth: 230, idealWidth: 240, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading) {
                Picker("Settings", selection: $model.tab) {
                    ForEach(SettingsTab.allCases) {Label($0.title, systemImage: $0.symbol).tag($0.rawValue)}
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Settings tabs")
                Group {
                    switch SettingsTab(rawValue: model.tab) ?? .live {
                    case .live: LiveTab()
                    case .mapping: MappingTab().disabled(!model.configurationReady)
                    case .tuning: TuningTab().disabled(!model.configurationReady)
                    case .buttons: ButtonsTab().disabled(!model.configurationReady)
                    case .profiles: ProfilesTab().disabled(!model.configurationReady)
                    case .test: TestTab()
                    case .service: service
                    }
                }.environmentObject(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).contentSurface()
                if !model.message.isEmpty {
                    Divider()
                    Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
            }.padding(12).frame(minWidth: 820)
        }.frame(minWidth: 1100, minHeight: 760)
            .groupBoxStyle(AxialGroupBoxStyle()).buttonStyle(.bordered).controlSize(.regular)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Axial").font(.title.bold())
                    Text("SpaceControl edition").font(.caption).foregroundStyle(.secondary)
                }
            }
            Label(model.status == nil ? "Service stopped" : "Service running", systemImage: model.status == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(model.status == nil ? Color.secondary : Color.green)
            Divider()
            Text("EDITING PROFILE").font(.caption).foregroundStyle(.secondary)
            NativePopup(label: "Profile", selection: model.selected,
                        choices: model.config.profiles.keys.sorted().map {PopupChoice($0, model.profileName($0))}, height: 30) {model.selected = $0}
                .frame(maxWidth: .infinity).sidebarSurface()
            NativePopup(label: "Add application profile", choices: AppPreset.all.map {PopupChoice($0.id, $0.title)} + [PopupChoice("choose", "Choose application…")], actionMenu: true, height: 30) {id in
                if id == "choose" {model.addApplication()} else if let preset = AppPreset.all.first(where: {$0.id == id}) {model.addPreset(preset)}
            }.frame(maxWidth: .infinity).sidebarSurface().disabled(!model.configurationReady)
            if let active = model.status?.activeProfile {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACTIVE NOW").font(.caption).foregroundStyle(.secondary)
                    Label(model.profileName(active), systemImage: "bolt.horizontal.circle.fill").foregroundStyle(.green)
                    Text(model.status?.foregroundApp ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Divider()
            if let device = model.device {
                Label(device.displayName, systemImage: "cable.connector").font(.headline)
                Label("USB connected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
                if (model.status?.devices.count ?? 0) > 1 {
                    NativePopup(label: "Device", selection: String(model.device?.id ?? 0),
                                choices: (model.status?.devices ?? []).map {PopupChoice(String($0.id), $0.displayName)}, height: 30) {model.recording = nil;model.selectedDevice = Int($0)}
                        .frame(maxWidth: .infinity).sidebarSurface()
                }
                Toggle("LED illumination", isOn: Binding(get: {model.profile.led}, set: {x in model.edit {$0.led = x}})).disabled(device.ledSupported == false)
                HStack {
                    Text("Navigation")
                    NativePopup(label: "Navigation", selection: model.profile.orbit ? "orbit" : "camera", choices: [PopupChoice("orbit", "Orbit target"), PopupChoice("camera", "Move camera")]) {choice in model.edit {$0.orbit = choice == "orbit"}}.popupSurface()
                }
            } else {Text("Connect a supported USB controller.").foregroundStyle(.secondary)}
            Spacer()
            Text("Based on Axial by consi (MIT)").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    var service: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {Text("Service & diagnostics").font(.title2.bold());Spacer();Button("Export…", action: model.exportDiagnostics)}
            HStack {Spacer();Toggle("Start at login", isOn: Binding(get: {model.launchAtLogin}, set: {model.login($0)}))}
            GroupBox("Permissions") {
                HStack {
                    Label(model.status?.accessibility == true ? "Keyboard shortcuts & macros enabled" : "Keyboard shortcuts need permission", systemImage: "keyboard");Spacer()
                    Button(action: model.requestAccessibility) {Text("Accessibility…").frame(width: 145)}.disabled(model.status == nil)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            DiagnosticsCharts(samples: model.diagnostics.samples).equatable()
            WebCompatibilityView(model: model, setup: model.webSetup)
            if model.status?.mock == true {Label("Mock input service", systemImage: "testtube.2").foregroundStyle(.orange)}
            Spacer(minLength: 0)
        }
    }
}
