import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: Controller

    @State private var token: String = ""
    @State private var chatID: String = ""
    @State private var saveError: String?
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case sending
        case ok
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { controller.loginItemEnabled },
                    set: { controller.setLoginItemEnabled($0) }
                ))
            } header: {
                Text("Startup")
                    .font(.headline)
            } footer: {
                Text("Keeps the menubar icon present after login so Decaf state is always visible. Does not disable sleep — pmset is still only touched while an agent is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sleep Mac when Claude Code / Codex finish", isOn: Binding(
                    get: { controller.sleepWhenDone },
                    set: { controller.setSleepWhenDone($0) }
                ))
                Stepper(value: Binding(
                    get: { controller.sleepDelayMinutes },
                    set: { controller.setSleepDelayMinutes($0) }
                ), in: 0...240, step: 5) {
                    if controller.sleepDelayMinutes == 0 {
                        Text("Fallback timer: off")
                    } else {
                        Text("Fallback timer: \(controller.sleepDelayMinutes) min")
                    }
                }
                .disabled(controller.sleepWhenDone)
            } header: {
                Text("Sleep behavior")
                    .font(.headline)
            } footer: {
                Text("When off, the Mac stays awake after Claude Code / Codex finish (battery permitting). The fallback timer puts it to sleep anyway after N minutes of continuous idle. The timer resets when a new prompt arrives. Changes apply within ~5 seconds while Decaf is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Bot token", text: $token)
                TextField("Chat ID", text: $chatID)
            } header: {
                Text("Telegram notifications")
                    .font(.headline)
            } footer: {
                Text("Get the token from @BotFather. Get your chat ID by messaging @userinfobot. Leave blank to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Send test message") {
                    Task { await sendTest() }
                }
                .disabled(token.isEmpty || chatID.isEmpty || testStatus == .sending)

                switch testStatus {
                case .idle:                 EmptyView()
                case .sending:              ProgressView().controlSize(.small)
                case .ok:                   Text("✓ sent").foregroundStyle(.green)
                case .failed(let msg):      Text("× \(msg)").foregroundStyle(.red).lineLimit(2)
                }

                Spacer()

                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .disabled(unchanged)
            }

            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.caption)
            }
        }
        .padding()
        .frame(width: 480, height: 520)
        .onAppear(perform: reload)
    }

    private var unchanged: Bool {
        let (t, c) = controller.loadTelegramCreds()
        return t == token && c == chatID
    }

    private func reload() {
        let (t, c) = controller.loadTelegramCreds()
        token = t
        chatID = c
    }

    private func save() {
        do {
            try controller.saveTelegramCreds(token: token, chatID: chatID)
            saveError = nil
        } catch {
            saveError = "save failed: \(error.localizedDescription)"
        }
    }

    private func sendTest() async {
        testStatus = .sending
        let result = await controller.sendTelegramTest(token: token, chatID: chatID)
        switch result {
        case .sent:               testStatus = .ok
        case .failed(let msg):    testStatus = .failed(msg)
        }
    }
}
