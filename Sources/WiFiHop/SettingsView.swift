import RoamCore
import ServiceManagement
import SwiftUI

/// State behind the Settings window. Lives on the main thread.
final class SettingsModel: ObservableObject {
    @Published var saved: [String] = []
    @Published var inRange: [String: Int] = [:]
    @Published var selected: [String]
    @Published var withPassword: Set<String>
    @Published var showOutOfRange = false
    @Published var scanning = false
    @Published var sensitivity: Sensitivity
    @Published var startAtLogin: Bool

    private let prefs: Prefs
    private let passwords: PasswordStore
    private let roamer: Roamer

    init(prefs: Prefs, passwords: PasswordStore, roamer: Roamer) {
        self.prefs = prefs
        self.passwords = passwords
        self.roamer = roamer
        selected = prefs.managed
        withPassword = Set(prefs.managed.filter { passwords.has($0) })
        sensitivity = prefs.sensitivity
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    var rows: [SetupRow] {
        setupRows(saved: saved, selected: selected, inRange: inRange, showOutOfRange: showOutOfRange)
    }

    var missingPasswords: [String] {
        selected.filter { !withPassword.contains($0) }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        roamer.survey { [weak self] saved, inRange in
            self?.saved = saved
            self?.inRange = inRange
            self?.scanning = false
        }
    }

    func setSelected(_ ssid: String, _ on: Bool) {
        if on {
            guard !selected.contains(ssid) else { return }
            selected.append(ssid)
            if passwords.has(ssid) { withPassword.insert(ssid) }
            Log.write("Added \(ssid)")
        } else {
            selected.removeAll { $0 == ssid }
            passwords.remove(ssid)
            withPassword.remove(ssid)
            Log.write("Removed \(ssid)")
        }
        prefs.managed = selected
        roamer.networksChanged()
    }

    func savePassword(_ password: String, for ssid: String) {
        guard passwords.set(password, for: ssid) else {
            Log.write("The Keychain refused to store the password for \(ssid)")
            return
        }
        withPassword.insert(ssid)
        Log.write("Saved password for \(ssid)")
        roamer.passwordChanged(for: ssid)
    }

    func setSensitivity(_ value: Sensitivity) {
        sensitivity = value
        prefs.sensitivity = value
        Log.write("Sensitivity: \(value.rawValue)")
    }

    func setStartAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("Could not change the login setting: \(error.localizedDescription)")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }
}

extension SignalQuality {
    var label: String {
        switch self {
        case .strong: return "Strong"
        case .good: return "Good"
        case .weak: return "Weak"
        }
    }
}

/// "Strong, -42 dBm", for lists and the menu.
func describeSignal(_ rssi: Int) -> String {
    "\(SignalQuality(rssi: rssi).label), \(rssi) dBm"
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your home networks").font(.headline)
            Text("Tick the Wi-Fi networks that belong to your home and enter each one's password. When the signal gets weak, WiFiHop moves this Mac to whichever ticked network is stronger. It never touches any other network.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if model.rows.isEmpty {
                    Text(model.scanning ? "Looking for networks…" : "No saved networks in range.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rows, id: \.ssid) { row in
                    NetworkRow(model: model, row: row)
                }
            }
            .frame(height: 210)

            HStack {
                Toggle("Show saved networks that are out of range", isOn: $model.showOutOfRange)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button("Rescan") { model.rescan() }.disabled(model.scanning)
            }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Picker("Switch", selection: Binding(get: { model.sensitivity }, set: model.setSensitivity)) {
                Text("Sooner").tag(Sensitivity.sooner)
                Text("Balanced").tag(Sensitivity.balanced)
                Text("Later").tag(Sensitivity.later)
            }
            .pickerStyle(.segmented)
            Text(sensitivityNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: model.setStartAtLogin))
        }
        .padding(20)
        .frame(width: 540)
    }

    /// The one thing still standing between the user and a working setup.
    private var status: String {
        if model.selected.count < 2 {
            return "Tick at least two networks. Only networks this Mac has joined before are listed. A router at the far end of your home may be out of range from here: carry the Mac closer and rescan, or show out-of-range networks."
        }
        if let ssid = model.missingPasswords.first {
            return "Enter the password for \(ssid) so WiFiHop can switch to it."
        }
        return "All set. WiFiHop is watching the signal and will switch between your \(model.selected.count) networks."
    }

    private var sensitivityNote: String {
        switch model.sensitivity {
        case .sooner:
            return "Switches as soon as the signal dips. Suits homes where walls cut the signal off sharply, at the cost of more switches."
        case .balanced:
            return "Switches when the signal is weak enough to slow things down."
        case .later:
            return "Holds on until the signal is poor. Fewer interruptions, for example during calls."
        }
    }
}

private struct NetworkRow: View {
    @ObservedObject var model: SettingsModel
    let row: SetupRow
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { row.selected }, set: { model.setSelected(row.ssid, $0) })) {
                Text(row.ssid).lineLimit(1)
            }
            Spacer()
            if row.selected {
                if model.withPassword.contains(row.ssid) && !editing {
                    Text("Password saved").foregroundStyle(.secondary)
                    Button("Change") { editing = true }
                } else {
                    SecureField("Password", text: $draft)
                        .frame(width: 140)
                        .onSubmit(save)
                    Button("Save", action: save).disabled(draft.isEmpty)
                }
            }
            Text(row.rssi.map(describeSignal) ?? "Not in range")
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
        }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        model.savePassword(draft, for: row.ssid)
        draft = ""
        editing = false
    }
}
