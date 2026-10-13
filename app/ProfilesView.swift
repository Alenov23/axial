import SwiftUI
import AppKit

struct ProfilesTab: View {
    @EnvironmentObject var model: Model
    var body: some View {
        let keys = model.config.profiles.keys.sorted {a, b in a == "*" ? true : (b == "*" ? false : model.profileName(a) < model.profileName(b))}
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profiles").font(.title2.bold())
                Text("Switch automatically with the frontmost application").foregroundStyle(.secondary)
                Spacer()
                Menu("Add application") {
                    ForEach(AppPreset.all) {preset in Button(preset.title + (model.config.profiles[preset.id] == nil ? "" : " ✓")) {model.addPreset(preset)}}
                    Divider()
                    Button("Choose application…") {model.addApplication()}
                }.frame(width: 150)
                Button("Import…", action: model.importProfiles)
                Button("Export all…") {model.exportProfiles(all: true)}
            }
            if let status = model.status {
                Label("Frontmost: \(status.foregroundApp.isEmpty ? "—" : status.foregroundApp) → using “\(status.activeProfile.map(model.profileName) ?? "All applications")”", systemImage: "arrow.triangle.swap")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(keys, id: \.self) {key in row(key)}
                }
            }.frame(maxHeight: .infinity)
            GroupBox("Selected: \(model.profileName(model.selected))") {
                HStack(spacing: 10) {
                    TextField("Display name", text: Binding(get: {model.profile.name ?? ""}, set: {x in model.edit {$0.name = x.isEmpty ? nil : x}})).frame(width: 220)
                    Button("Duplicate to app…", action: model.duplicateToApplication)
                    if let d = model.device, !model.selected.contains("@") {
                        Button("Duplicate for this device") {model.duplicateSelected(to: model.selected + String(format: "@%04x:%04x", d.vendor, d.product))}
                    }
                    Button("Export…") {model.exportProfiles(all: false)}
                    Spacer()
                    Button("Reset to defaults") {model.edit {let name = $0.name;$0 = Profile();$0.name = name}}
                    if model.selected != "*" {Button("Delete", role: .destructive, action: model.removeSelectedProfile)}
                }.padding(4)
            }
        }
    }
    func row(_ key: String) -> some View {
        let p = model.config.profiles[key] ?? Profile()
        let active = model.status?.activeProfile == key
        let remapped = p.matrix != Profile.identity || p.enabled.contains(false) || p.invert.contains(true)
        let assigned = p.buttons.filter {$0.kind != .none}.count
        return Button {model.selected = key} label: {
            HStack(spacing: 12) {
                appIcon(key).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.name.map {"\($0) — \(model.profileName(key))"} ?? model.profileName(key)).font(.headline)
                        if active {Text("ACTIVE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.3)))}
                    }
                    Text(key == "*" ? "Fallback for every application" : key).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                tag(remapped ? "remapped" : "default axes", remapped)
                tag(p.lock == .none ? "6DoF" : p.lock.title, p.lock != .none)
                tag("\(assigned) buttons", assigned > 0)
            }.padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(model.selected == key ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func tag(_ text: String, _ on: Bool) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07)))
    }
    func appIcon(_ key: String) -> Image {
        let id = String(key.split(separator: "@").first ?? "*")
        if id != "*", let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))}
        return Image(nsImage: NSApp.applicationIconImage)
    }
}
