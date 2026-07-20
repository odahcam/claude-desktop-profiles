// Claude Profiles — a SwiftUI window for managing Claude Desktop profiles.
//
// This app is a frontend only: profile creation and removal shell out to the
// copy of `cdp` bundled in Resources, so the CLI, the AppleScript chooser,
// and this app share one implementation. Profiles are discovered from the
// filesystem (~/Library/Application Support/Claude-<Name>) on every refresh;
// there is no registry to sync. Running instances are detected by reading
// each Claude process's --user-data-dir argument out of `ps`, because all
// instances share one binary and differ only in that flag.

import SwiftUI
import AppKit
import Combine

// MARK: - Shared helpers

let claudeAppPath: String = {
    let candidates = ["/Applications/Claude.app",
                      NSHomeDirectory() + "/Applications/Claude.app"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
}()

var claudeIcon: NSImage { NSWorkspace.shared.icon(forFile: claudeAppPath) }

@discardableResult
func runTool(_ tool: String, _ args: [String], env: [String: String] = [:]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if !env.isEmpty {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
    }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    // Read before waiting so a chatty child can't fill the pipe and deadlock.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let errText = String(data: errData, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        throw NSError(domain: "cdp", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? out : errText])
    }
    return out
}

// MARK: - Model

// Mirrors the HUES palette in bin/cdp — names must stay in sync.
struct ProfileColor: Identifiable, Hashable {
    let name: String
    let hue: Double        // degrees of hue rotation applied to Claude's icon
    let swatch: Color      // matching UI accent

    var id: String { name }

    static let all: [ProfileColor] = [
        ProfileColor(name: "orange", hue: 0,   swatch: Color(red: 0.85, green: 0.47, blue: 0.34)),
        ProfileColor(name: "red",    hue: -25, swatch: Color(red: 0.86, green: 0.34, blue: 0.32)),
        ProfileColor(name: "yellow", hue: 40,  swatch: Color(red: 0.80, green: 0.63, blue: 0.25)),
        ProfileColor(name: "green",  hue: 110, swatch: Color(red: 0.36, green: 0.69, blue: 0.42)),
        ProfileColor(name: "teal",   hue: 160, swatch: Color(red: 0.27, green: 0.65, blue: 0.62)),
        ProfileColor(name: "blue",   hue: 200, swatch: Color(red: 0.33, green: 0.56, blue: 0.83)),
        ProfileColor(name: "purple", hue: 250, swatch: Color(red: 0.62, green: 0.47, blue: 0.83)),
        ProfileColor(name: "pink",   hue: 310, swatch: Color(red: 0.83, green: 0.42, blue: 0.62)),
    ]

    static func named(_ name: String) -> ProfileColor {
        all.first { $0.name == name } ?? all[0]
    }
}

struct Profile: Identifiable, Hashable {
    let name: String
    let dataDir: String?          // nil = the default Claude install
    let colorName: String
    var id: String { name }
    var isDefault: Bool { dataDir == nil }
    var color: ProfileColor { ProfileColor.named(colorName) }
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
    @Published var running: Set<String> = []
    @Published var errorMessage: String?

    private let appSupport = NSHomeDirectory() + "/Library/Application Support"
    private var cdpPath: String? { Bundle.main.path(forResource: "cdp", ofType: nil) }

    func refresh() {
        var list = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: appSupport) {
            for entry in entries.sorted() where entry.hasPrefix("Claude-") {
                var isDir: ObjCBool = false
                let full = appSupport + "/" + entry
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    let color = (try? String(contentsOfFile: full + "/.cdp-color", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "orange"
                    list.append(Profile(name: String(entry.dropFirst("Claude-".count)),
                                        dataDir: full, colorName: color))
                }
            }
        }
        // Only publish on actual change: every @Published assignment re-renders
        // the cards, which dismisses any open Menu mid-interaction.
        if list != profiles { profiles = list }
        refreshRunning()
    }

    func refreshRunning() {
        guard let out = try? runTool("/bin/ps", ["-axo", "command"]) else { return }
        var found = Set<String>()
        for lineSub in out.split(separator: "\n") {
            let line = String(lineSub)
            // Match the main binary of the original bundle OR a profile clone
            // ("Claude Work.app/Contents/MacOS/Claude"). Helper (Renderer/
            // GPU/…) processes inherit the flag; skip them so one instance
            // doesn't show up five times.
            guard line.contains("/Contents/MacOS/Claude"),
                  !line.contains("Helper") else { continue }
            if let r = line.range(of: "--user-data-dir=") {
                let rest = String(line[r.upperBound...])
                for p in profiles {
                    if let d = p.dataDir, rest.hasPrefix(d) { found.insert(p.id) }
                }
            } else if line.contains("Claude.app/Contents/MacOS/Claude") {
                found.insert("Default")
            }
        }
        // Same deal as refresh(): the 2s poller must not republish an
        // unchanged set, or it closes menus the user is currently using.
        if found != running { running = found }
    }

    func launch(_ p: Profile) {
        if p.isDefault {
            do { try runTool("/usr/bin/open", ["-a", claudeAppPath]) }
            catch { errorMessage = error.localizedDescription }
        } else {
            // cdp launch runs the profile from its own Claude.app clone (the
            // Dock tile wears the profile color and owns the window) or
            // focuses the running instance without spawning a new window.
            callCdp(["launch", p.name])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refreshRunning() }
    }

    func add(_ name: String, color: String) {
        callCdp(["add", name, "--color", color])
    }

    func setColor(_ p: Profile, color: String) {
        callCdp(["color", p.name, color])
    }

    func remove(_ p: Profile, deleteData: Bool) {
        callCdp(["remove", p.name, deleteData ? "--delete-data" : "--keep-data"])
    }

    private func callCdp(_ args: [String]) {
        guard let cdp = cdpPath else {
            errorMessage = "Bundled cdp script is missing from the app. Rebuild with: cdp gui"
            return
        }
        do {
            // CDP_FROM_CHOOSER stops cdp from rebuilding the app bundle
            // that is currently running us.
            try runTool("/bin/zsh", [cdp] + args, env: ["CDP_FROM_CHOOSER": "1"])
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func revealData(_ p: Profile) {
        let dir = p.dataDir ?? (appSupport + "/Claude")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }
}

// MARK: - App

@main
struct ClaudeProfilesApp: App {
    var body: some Scene {
        WindowGroup("Claude Profiles") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    @State private var showAdd = false
    @State private var removing: Profile?
    @State private var confirmWipe: Profile?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.profiles) { p in
                        ProfileCard(
                            profile: p,
                            isRunning: store.running.contains(p.id),
                            launch: { store.launch(p) },
                            reveal: { store.revealData(p) },
                            setColor: p.isDefault ? nil : { store.setColor(p, color: $0) },
                            remove: p.isDefault ? nil : { removing = p }
                        )
                    }
                    AddCard { showAdd = true }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 380, idealHeight: 420)
        .background(WindowBackground())
        .onAppear { store.refresh() }
        .onReceive(timer) { _ in store.refreshRunning() }
        .sheet(isPresented: $showAdd) {
            AddSheet { name, color in store.add(name, color: color) }
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil },
                                 set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { p in
            Button("Remove Launcher Only") { store.remove(p, deleteData: false) }
            Button("Delete Everything…", role: .destructive) { confirmWipe = p }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Launcher Only” deletes the Spotlight app but keeps chats, login, and settings on disk — the profile stays in this window and can be fully removed later.")
        }
        .alert(
            "Delete all data for “\(confirmWipe?.name ?? "")”?",
            isPresented: Binding(get: { confirmWipe != nil },
                                 set: { if !$0 { confirmWipe = nil } }),
            presenting: confirmWipe
        ) { p in
            Button("Delete", role: .destructive) { store.remove(p, deleteData: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Chats, login, and settings will be permanently erased. This cannot be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.errorMessage != nil },
                                 set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: claudeIcon)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Profiles").font(.title2.bold())
                Text("Isolated Claude Desktop accounts, side by side")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAdd = true
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct WindowBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor),
                     Color(nsColor: .underPageBackgroundColor)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct ProfileCard: View {
    let profile: Profile
    let isRunning: Bool
    let launch: () -> Void
    let reveal: () -> Void
    let setColor: ((String) -> Void)?
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: claudeIcon)
                .resizable()
                .frame(width: 54, height: 54)
                .hueRotation(.degrees(profile.color.hue))
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.1),
                        radius: hovering ? 7 : 3, y: 2)
            Text(profile.name)
                .font(.headline)
                .lineLimit(1)
            Text(profile.isDefault ? "your main install" : "isolated profile")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(isRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isRunning {
                Button(action: launch) {
                    Text("Focus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(action: launch) {
                    Text("Launch").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(profile.color.swatch)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1.0 : 0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            // Discoverable stand-in for the right-click context menu.
            Menu {
                cardActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(7)
            .opacity(hovering ? 1.0 : 0.4)
        }
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            cardActions
        }
    }

    // Shared between the right-click context menu and the ellipsis button.
    @ViewBuilder
    private var cardActions: some View {
        Button("Launch") { launch() }
        Button("Reveal Data Folder in Finder") { reveal() }
        if let setColor {
            Menu("Change Color") {
                ForEach(ProfileColor.all) { c in
                    Button {
                        setColor(c.name)
                    } label: {
                        if c.name == profile.colorName {
                            Label(c.name.capitalized, systemImage: "checkmark")
                        } else {
                            Text(c.name.capitalized)
                        }
                    }
                }
            }
        }
        if let remove {
            Divider()
            Button("Remove…", role: .destructive) { remove() }
        }
    }
}

struct AddCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                Text("New profile")
                    .font(.headline)
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.65 : 0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorName = "orange"
    let create: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New profile").font(.title3.bold())
            TextField("personal, client-acme…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack(spacing: 10) {
                Image(nsImage: claudeIcon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .hueRotation(.degrees(ProfileColor.named(colorName).hue))
                ForEach(ProfileColor.all) { c in
                    Circle()
                        .fill(c.swatch)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(.primary.opacity(c.name == colorName ? 0.8 : 0),
                                                  lineWidth: 2)
                        )
                        .onTapGesture { colorName = c.name }
                        .help(c.name.capitalized)
                }
            }
            Text("Creates a fully isolated Claude — its own login, chats, and settings — plus a Spotlight launcher (“Claude <Name>”).\n\nBefore its first sign-in, quit every other Claude window: the login link lands on whichever instance is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        create(n, colorName)
        dismiss()
    }
}
