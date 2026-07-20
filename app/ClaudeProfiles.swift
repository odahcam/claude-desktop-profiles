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

struct Profile: Identifiable, Hashable {
    let name: String
    let dataDir: String?          // nil = the default Claude install
    var id: String { name }
    var isDefault: Bool { dataDir == nil }
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = [Profile(name: "Default", dataDir: nil)]
    @Published var running: Set<String> = []
    @Published var errorMessage: String?

    private let appSupport = NSHomeDirectory() + "/Library/Application Support"
    private var cdpPath: String? { Bundle.main.path(forResource: "cdp", ofType: nil) }

    func refresh() {
        var list = [Profile(name: "Default", dataDir: nil)]
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: appSupport) {
            for entry in entries.sorted() where entry.hasPrefix("Claude-") {
                var isDir: ObjCBool = false
                let full = appSupport + "/" + entry
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    list.append(Profile(name: String(entry.dropFirst("Claude-".count)),
                                        dataDir: full))
                }
            }
        }
        profiles = list
        refreshRunning()
    }

    func refreshRunning() {
        guard let out = try? runTool("/bin/ps", ["-axo", "command"]) else { return }
        var found = Set<String>()
        for lineSub in out.split(separator: "\n") {
            let line = String(lineSub)
            // Helper (Renderer/GPU/…) processes inherit the flag; only count
            // the main binary so one instance doesn't show up five times.
            guard line.contains("Claude.app/Contents/MacOS/Claude"),
                  !line.contains("Helper") else { continue }
            if let r = line.range(of: "--user-data-dir=") {
                let rest = String(line[r.upperBound...])
                for p in profiles {
                    if let d = p.dataDir, rest.hasPrefix(d) { found.insert(p.id) }
                }
            } else {
                found.insert("Default")
            }
        }
        running = found
    }

    func launch(_ p: Profile) {
        do {
            if let d = p.dataDir {
                // -n forces a new instance; if this profile is already running,
                // Chromium's singleton lock forwards to it and focuses instead.
                try runTool("/usr/bin/open", ["-n", "-a", claudeAppPath,
                                              "--args", "--user-data-dir=\(d)"])
            } else {
                try runTool("/usr/bin/open", ["-a", claudeAppPath])
            }
        } catch { errorMessage = error.localizedDescription }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshRunning() }
    }

    func add(_ name: String) {
        callCdp(["add", name])
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
            AddSheet { name in store.add(name) }
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
    let remove: (() -> Void)?
    @State private var hovering = false

    private let claudeTint = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: claudeIcon)
                .resizable()
                .frame(width: 54, height: 54)
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
            Button(action: launch) {
                Text(isRunning ? "Focus" : "Launch")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRunning ? .secondary : claudeTint)
            .controlSize(.small)
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
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Launch") { launch() }
            Button("Reveal Data Folder in Finder") { reveal() }
            if let remove {
                Divider()
                Button("Remove…", role: .destructive) { remove() }
            }
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
    let create: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New profile").font(.title3.bold())
            TextField("personal, client-acme…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
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
        create(n)
        dismiss()
    }
}
